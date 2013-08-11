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
require 'optparse'
require 'socket'
require 'thread'

$fakesmtpd_mutex = Mutex.new

module FakeSMTPd
  class HTTPServer
    attr_reader :server, :port, :smtpd, :log

    def initialize(options = {})
      @port = options.fetch(:port)
      @smtpd = options.fetch(:smtpd)
      @log = Logger.new(options[:logfile]).tap do |l|
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
            $fakesmtpd_mutex.synchronize do
              client.puts JSON.pretty_generate(
                message_files: smtpd.message_files_written
              )
            end
          elsif request_line =~ /^DELETE \/messages /
            $fakesmtpd_mutex.synchronize do
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
      if @server
        log.info "FakeSMTPd HTTP server stopping"
        @server.kill
      end
    end
  end

  class Server
    VERSION = '0.1.1'
    USAGE = <<-EOU.gsub(/^ {6}/, '')
      Usage: #{File.basename($0)} <smtp-port> <message-dir> [options]

      The `<smtp-port>` argument will be incremented by 1 for the HTTP API port.
      The `<message-dir>` is where each SMTP transaction will be written as a
      JSON file containing the "smtp client id" (timestamp from beginning of SMTP
      transaction), the sender, recipients, and combined headers and body as
      an array of strings.

    EOU

    attr_reader :port, :message_dir, :log, :logfile, :pidfile
    attr_reader :message_files_written

    class << self
      def main(argv = [])
        options = {
          pidfile: nil,
          logfile: $stderr,
        }

        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on('--version', 'Show version and exit') do |*|
            puts "fakesmtpd #{FakeSMTPd::Server::VERSION}"
            exit 0
          end
          opts.on('-p PIDFILE', '--pidfile PIDFILE',
                  'Optional file where process PID will be written') do |pidfile|
            options[:pidfile] = pidfile
          end
          opts.on('-l LOGFILE', '--logfile LOGFILE',
                  'Optional file where all log messages will be written ' <<
                  '(default $stderr)') do |logfile|
            options[:logfile] = logfile
          end
        end.parse!(argv)

        unless argv.length == 2
          abort USAGE
        end

        @smtpd = FakeSMTPd::Server.new(
          port: Integer(argv.fetch(0)),
          dir: argv.fetch(1),
          pidfile: options[:pidfile],
          logfile: options[:logfile],
        )
        @httpd = FakeSMTPd::HTTPServer.new(
          port: Integer(argv.fetch(0)) + 1,
          smtpd: @smtpd,
          logfile: options[:logfile],
        )

        @httpd.start
        @smtpd.start
        loop { sleep 1 }
      rescue Exception => e
        if @httpd
          @httpd.kill!
        end
        if @smtpd
          @smtpd.kill!
        end
        unless e.is_a?(Interrupt)
          raise e
        end
      end
    end

    def initialize(options = {})
      @port = options.fetch(:port)
      @message_dir = options.fetch(:dir)
      @pidfile = options[:pidfile] || 'fakesmtpd.pid'
      @log = Logger.new(options[:logfile]).tap do |l|
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
      if @server
        log.info "FakeSMTPd SMTP server stopping"
        @server.kill
      end
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
      $fakesmtpd_mutex.synchronize do
        message_files_written << outfile
      end
      outfile
    end
  end
end

if __FILE__ == $0
  FakeSMTPd::Server.main(ARGV)
end
