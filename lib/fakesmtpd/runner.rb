# vim:fileencoding=utf-8

require 'fileutils'
require 'logger'

class FakeSMTPd::Runner
  attr_reader :port, :dir, :pidfile, :http_port
  attr_reader :startup_sleep, :server_pid, :options, :logfile

  def initialize(options = {})
    @dir = options.fetch(:dir)
    @port = Integer(options.fetch(:port))
    @http_port = Integer(options[:http_port] || port + 1)
    @pidfile = options[:pidfile] || 'fakesmtpd.pid'
    @startup_sleep = options[:startup_sleep] || 0.5
    @logfile = options[:logfile] || $stderr
  end

  def description
    "fakesmtpd server on port #{port}"
  end

  def command
    (
      [
        RbConfig.ruby,
        File.expand_path('../server.rb', __FILE__),
        port.to_s,
        dir,
        '--pidfile', pidfile,
      ] + (logfile == $stderr ? [] : ['--logfile', logfile])
    ).join(' ')
  end

  def start
    if dir
      FileUtils.mkdir_p(dir)
    end
    process_command = command
    log.info "Starting #{description}"
    log.info "  ---> #{process_command}"
    @server_pid = Process.spawn(process_command)
    sleep startup_sleep
    server_pid
  end

  def stop
    real_pid = Integer(File.read(pidfile).chomp) rescue nil
    if server_pid && real_pid
      log.info "Stopping #{description} " <<
               "(shell PID=#{server_pid}, server PID=#{real_pid})"

      [real_pid, server_pid].each do |pid|
        Process.kill(:TERM, pid) rescue nil
      end
    end
  end

  def log
    @log ||= Logger.new(@logfile).tap do |l|
      l.formatter = proc do |severity, datetime, _, msg|
        "[fakesmtpd-runner] #{severity} #{datetime} - #{msg}\n"
      end
    end
  end
end
