#!/usr/bin/env ruby
# vim:fileencoding=utf-8
# Inspired by mailtrap (https://github.com/mmower/mailtrap)
#
# Copyright (c) 2013 ModCloth, Inc.
#
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'json'
require 'logger'
require 'socket'
require 'thread'

$fakesmtpd_semaphore = Mutex.new

module FakeSMTPd
  class HTTPServer
    attr_reader :server, :port, :smtpd, :log

    def initialize(options = {})
      @port = options.fetch(:port)
      @smtpd = options.fetch(:smtpd)
      @log = Logger.new($stderr).tap do |l|
        l.formatter = proc do |severity, datetime, _, msg|
          "[fakesmtpd-http] #{severity} #{datetime} - #{msg}\n"
        end
      end
    end

    def start
      @server = Thread.new do
        httpd = TCPServer.new(port)
        log.info "FakeSMTPd HTTP server serving on #{port}"
        log.info "PID=#{$$} Thread=#{Thread.current.inspect}"
        loop do
          client = httpd.accept
          request_line = client.gets
          log.info request_line.chomp
          if request_line =~ /^GET \/messages /
            client.puts 'HTTP/1.1 200 OK'
            client.puts 'Content-type: application/json;charset=utf-8'
            client.puts
            $fakesmtpd_semaphore.synchronize do
              client.puts JSON.pretty_generate(
                message_files: smtpd.message_files_written
              )
            end
          elsif request_line =~ /^DELETE \/messages /
            $fakesmtpd_semaphore.synchronize do
            smtpd.message_files_written.clear
          end
          client.puts 'HTTP/1.1 204 No Content'
          client.puts
          else
            client.puts 'HTTP/1.1 405 Method Not Allowed'
            client.puts 'Content-type: text/plain;charset=utf-8'
            client.puts
            client.puts 'Only "(GET|DELETE) /messages" is supported, eh.'
          end
          client.close
        end
      end
    end

    def kill!
      @server && @server.kill
    end
  end

  class Server
    VERSION = '0.1.0'
    USAGE = "Usage: #{File.basename($0)} <port> <message-dir> [pidfile]"

    attr_reader :port, :message_dir, :log, :pidfile, :message_files_written

    class << self
      def main(argv = [].freeze)
        if argv.include?('-h') || argv.include?('--help')
          puts USAGE
          exit 0
        end
        if argv.include?('--version')
          puts FakeSMTPd::Server::VERSION
          exit 0
        end
        unless argv.length > 1
          abort USAGE
        end
        @smtpd = FakeSMTPd::Server.new(
          port: Integer(argv.fetch(0)),
          dir: argv.fetch(1),
          pidfile: argv[2]
        )
        @httpd = FakeSMTPd::HTTPServer.new(
          port: Integer(argv.fetch(0)) + 1,
          smtpd: @smtpd,
        )

        $stderr.puts '--- Starting up ---'
        @httpd.start
        @smtpd.start
        loop { sleep 1 }
      rescue Exception => e
        $stderr.puts '--- Shutting down ---'
        @httpd && @httpd.kill!
        @smtpd && @smtpd.kill!
        unless e.is_a?(Interrupt)
          raise e
        end
      end
    end

    def initialize(options = {})
      @port = options.fetch(:port)
      @message_dir = options.fetch(:dir)
      @pidfile = options[:pidfile] || 'fakesmtpd.pid'
      @log = Logger.new($stderr).tap do |l|
        l.formatter = proc do |severity, datetime, _, msg|
          "[fakesmtpd-smtp] #{severity} #{datetime} - #{msg}\n"
        end
      end
      @message_files_written = []
    end

    def start
      @server = Thread.new do
        smtpd = TCPServer.new(port)
        log.info "FakeSMTPd SMTP server serving on #{port}, " <<
        "writing messages to #{message_dir.inspect}"
        log.info "PID=#{$$}, Thread=#{Thread.current.inspect}"
        File.open(pidfile, 'w') { |f| f.puts($$) }

        loop do
          begin
            serve(smtpd.accept)
          rescue => e
            log.error "WAT: #{e.class.name} #{e.message}"
          end
        end
      end
    end

    def kill!
      @server && @server.kill
    end

    def serve(client)
      class << client
        attr_reader :client_id

        def getline
          line = gets
          line.chomp! unless line.nil?
          line
        end

        def to_s
          @client_id ||= Time.now.utc.strftime('%Y%m%d%H%M%S%N')
          "<smtp client #{@client_id}>"
        end
      end

      client.puts '220 localhost fakesmtpd ready ESMTP'
      helo = client.getline
      log.info "#{client} Helo: #{helo.inspect}"

      if helo =~ /^EHLO\s+/
        log.info "#{client} Seen an EHLO"
        client.puts '250-localhost only has this one extension'
        client.puts '250 HELP'
      end

      from = client.getline
      client.puts '250 OK'
      log.info "#{client} From: #{from.inspect}"

      recipients = []
      loop do
        to = client.getline
        break if to.nil?

        if to =~ /^DATA/
          client.puts '354 Lemme have it'
          break
        else
          log.info "#{client} To: #{to.inspect}"
          recipients << to
          client.puts '250 OK'
        end
      end

      lines = []
      loop do
        line = client.getline
        break if line.nil? || line == '.'
        lines << line
        log.debug "#{client} + #{line}"
      end

      client.puts '250 OK'
      client.gets
      client.puts '221 Buhbye'
      client.close
      log.info "#{client} ding!"

      record(client, from, recipients, lines)
    end

    def record(client, from, recipients, body)
      outfile = File.join(message_dir, "fakesmtpd-client-#{client.client_id}.json")
      File.open(outfile, 'w') do |f|
        f.write JSON.pretty_generate(
          client_id: client.client_id,
          from: from,
          recipients: recipients,
          body: body,
        )
      end
      $fakesmtpd_semaphore.synchronize do
        message_files_written << outfile
      end
      outfile
    end
  end
end

if __FILE__ == $0
  FakeSMTPd::Server.main(ARGV)
end
