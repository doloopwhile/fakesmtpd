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

require 'fileutils'
require 'gserver'
require 'json'
require 'logger'
require 'optparse'
require 'socket'
require 'thread'

module FakeSMTPd
  class HTTPServer < GServer
    attr_reader :server, :port, :smtpd, :log

    def initialize(options = {})
      @port = options.fetch(:port)
      super(@port)

      @smtpd = options.fetch(:smtpd)
      @log = Logger.new(options[:logfile]).tap do |l|
        l.formatter = proc do |severity, datetime, _, msg|
          "[fakesmtpd-http] #{severity} #{datetime} - #{msg}\n"
        end
      end
    end

    def start(*args)
      super(*args)
      log.info "FakeSMTPd HTTP server serving on #{port}"
      log.info "PID=#{$$} Thread=#{Thread.current.inspect}"
    end

    def stop(*args)
      log.info "FakeSMTPd HTTP server stopping"
      super(*args)
    end

    def serve(io)
      request_line = io.gets
      path = request_line.split[1]
      handle_client(request_line, path, io)
    rescue => e
      handle_500(path, io, e)
    end

    private

    def handle_client(request_line, path, client)
      log.info request_line.chomp
      case request_line
      when /^GET \/ /
        handle_get_root(path, client)
      when /^GET \/messages /
        handle_get_messages(path, client)
      when /^GET \/messages\/([[:digit:]]+) /
        handle_get_message(path, client, $1)
      when /^DELETE \/messages /
        handle_clear_messages(path, client)
      else
        handle_404(path, client)
      end
    end

    def handle_get_root(path, client)
      client.puts 'HTTP/1.1 200 OK'
      client.puts 'Content-type: application/json;charset=utf-8'
      client.puts
      client.puts JSON.pretty_generate(
        _links: {
          self: {href: path},
          messages: {href: '/messages'},
        }
      )
    end

    def handle_get_messages(path, client)
      client.puts 'HTTP/1.1 200 OK'
      client.puts 'Content-type: application/json;charset=utf-8'
      client.puts
      client.puts JSON.pretty_generate(
        _links: {
          self: {href: path}
        },
        _embedded: {
          messages: smtpd.messages.to_hash.map do |message_id, filename|
            {
              _links: {
                self: {href: "/messages/#{message_id}"}
              },
              message_id: message_id,
              filename: filename
            }
          end
        }
      )
    end

    def handle_get_message(path, client, message_id)
      message_file = smtpd.messages[message_id]
      if message_file
        client.puts 'HTTP/1.1 200 OK'
        client.puts 'Content-type: application/json;charset=utf-8'
        client.puts
        message = JSON.parse(File.read(message_file))
        client.puts JSON.pretty_generate(
          message.merge(
            _links: {
              self: {href: path}
            },
            filename: message_file
          )
        )
      else
        client.puts 'HTTP/1.1 404 Not Found'
        client.puts 'Content-type: application/json;charset=utf-8'
        client.puts
        client.puts JSON.pretty_generate(
          _links: {
            self: {href: path}
          },
          error: "Message #{message_id.inspect} not found"
        )
      end
    end

    def handle_clear_messages(path, client)
      smtpd.messages.clear
      client.puts 'HTTP/1.1 204 No Content'
      client.puts
    end

    def handle_404(path, client)
      client.puts 'HTTP/1.1 404 Not Found'
      client.puts 'Content-type: application/json;charset=utf-8'
      client.puts
      client.puts JSON.pretty_generate(
        _links: {
          self: {href: path}
        },
        error: 'Nothing is here'
      )
    end

    def handle_500(path, client, e)
      client.puts 'HTTP/1.1 500 Internal Server Error'
      client.puts 'Content-type: application/json;charset=utf-8'
      client.puts
      client.puts JSON.pretty_generate(
        _links: {
          self: {href: path}
        },
        error: "#{e.class.name} #{e.message}",
        backtrace: e.backtrace
      )
    end
  end

  class Server < GServer
    VERSION = '0.2.0'
    USAGE = <<-EOU.gsub(/^ {6}/, '')
      Usage: #{File.basename($0)} <smtp-port> <message-dir> [options]

      The `<smtp-port>` argument will be incremented by 1 for the HTTP API port.
      The `<message-dir>` is where each SMTP transaction will be written as a
      JSON file containing the "smtp client id" (timestamp from beginning of SMTP
      transaction), the sender, recipients, and combined headers and body as
      an array of strings.

    EOU

    attr_reader :port, :message_dir, :log, :logfile, :pidfile
    attr_reader :messages

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
        @httpd.join && @smtpd.join
      rescue Exception => e
        if @httpd && !@httpd.stopped?
          @httpd.stop
        end
        if @smtpd && !@smtpd.stopped?
          @smtpd.stop
        end
        unless e.is_a?(Interrupt)
          raise e
        end
      end
    end

    def initialize(options = {})
      @port = options.fetch(:port)
      super(@port)
      @message_dir = options.fetch(:dir)
      @pidfile = options[:pidfile] || 'fakesmtpd.pid'
      @log = Logger.new(options[:logfile]).tap do |l|
        l.formatter = proc do |severity, datetime, _, msg|
          "[fakesmtpd-smtp] #{severity} #{datetime} - #{msg}\n"
        end
      end
      @messages = MessageStore.new(@message_dir)
    end

    def start(*args)
      super(*args)
      File.open(pidfile, 'w') { |f| f.puts($$) }
      log.info "FakeSMTPd SMTP server serving on #{port}, " <<
               "writing messages to #{message_dir.inspect}"
      log.info "PID=#{$$} Thread=#{Thread.current.inspect}"
    end

    def stop(*args)
      log.info "FakeSMTPd SMTP server stopping"
      super(*args)
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
      messages.store(
        client.client_id, from, recipients, body
      )
    end
  end

  class MessageStore
    attr_reader :message_dir

    def initialize(message_dir)
      @message_dir = message_dir
    end

    def store(message_id, from, recipients, body)
      outfile = File.join(message_dir, "fakesmtpd-client-#{message_id}.json")
      File.open(outfile, 'w') do |f|
        f.write JSON.pretty_generate(
          message_id: message_id,
          from: from,
          recipients: recipients,
          body: body,
        )
      end
      outfile
    end

    def to_hash
      message_files.each_with_object({}) do |filename, h|
        message_id = File.basename(filename, '.json').gsub(/[^0-9]+/, '')
        h[message_id] = File.expand_path(filename)
      end
    end

    def [](message_id)
      message_file = "#{message_dir}/fakesmtpd-client-#{message_id}.json"
      if File.exists?(message_file)
        return message_file
      end
      nil
    end

    def clear
      FileUtils.rm_f(message_files)
    end

    private

    def message_files
      Dir.glob("#{message_dir}/fakesmtpd-client-*.json")
    end
  end
end

if __FILE__ == $0
  FakeSMTPd::Server.main(ARGV)
end
