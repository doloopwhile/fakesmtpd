require 'json'
require 'net/http'
require 'net/smtp'
require 'uri'

require 'fakesmtpd'

describe 'fakesmtpd server' do
  RUNNER = FakeSMTPd::Runner.new(
    dir: File.expand_path('../../.artifacts', __FILE__),
    port: rand(9100..9199),
    logfile: File.expand_path('../../.artifacts/fakesmtpd.log', __FILE__),
    pidfile: File.expand_path('../../.artifacts/fakesmtpd.pid', __FILE__),
  )
  RUNNER.start

  at_exit do
    RUNNER.stop
  end

  def randint
    @randint ||= rand(999..1999)
  end

  def subject_header
    @subject_header ||= "DERF DERF DERF #{randint}"
  end

  def msg
    <<-EOM.gsub(/^ {6}/, '')
      From: fakesmtpd <fakesmtpd@example.org>
      To: Fruit Cake <fruitcake@example.org>
      Subject: #{subject_header}
      Date: Sat, 10 Aug 2013 16:59:20 +0500
      Message-Id: <fancy.pants.are.fancy.#{randint}@example.org>

      Herp derp derp herp.
    EOM
  end

  def send_message
    Net::SMTP.start('localhost', RUNNER.port) do |smtp|
      smtp.send_message msg, 'fakesmtpd@example.org', 'fruitcake@example.org'
    end
  end

  it 'accepts messages via SMTP' do
    send_message
  end

  it 'reports messages sent via HTTP' do
    send_message

    uri = URI("http://localhost:#{RUNNER.http_port}/messages")
    response = JSON.parse(Net::HTTP.get_response(uri).body)
    message_file = response.fetch('message_files').last
    message_body = JSON.parse(File.read(message_file)).fetch('body')
    message_body.must_include("Subject: #{subject_header}")
  end
end
