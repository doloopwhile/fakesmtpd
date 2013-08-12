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

  after(:each) { clear_messages }

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
      smtp.send_message(msg, 'fakesmtpd@example.org', 'fruitcake@example.org')
    end
  end

  def get_messages
    uri = URI("http://localhost:#{RUNNER.http_port}/messages")
    JSON.parse(Net::HTTP.get_response(uri).body)
  end

  def clear_messages
    Net::HTTP.start('localhost', RUNNER.http_port) do |http|
      http.request(Net::HTTP::Delete.new('/messages'))
    end
  end

  def get_message(message_id)
    uri = URI("http://localhost:#{RUNNER.http_port}/messages/#{message_id}")
    JSON.parse(Net::HTTP.get_response(uri).body)
  end

  it 'accepts messages via SMTP' do
    send_message
  end

  it 'supports clearing sent messages via HTTP' do
    clear_messages
  end

  it 'supports getting messages sent via HTTP' do
    send_message
    response = get_messages

    message_file = response.fetch('_embedded').fetch('messages').last.fetch('filename')
    message_body = JSON.parse(File.read(message_file)).fetch('body')
    message_body.must_include("Subject: #{subject_header}")
  end

  it 'supports getting individual messages sent via HTTP' do
    send_message
    response = get_messages

    message_id = response.fetch('_embedded').fetch('messages').last.fetch('message_id')
    message_body = get_message(message_id).fetch('body')
    message_body.must_include("Subject: #{subject_header}")
  end
end
