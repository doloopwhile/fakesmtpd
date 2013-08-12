require 'bundler/gem_tasks'

desc 'Run minitest tests in ./test'
task test: [:load_minitest, :clean_artifacts] do
  Dir.glob("#{File.expand_path('../test', __FILE__)}/*_test.rb").each do |f|
    require f
  end

  mkdir_p(File.expand_path('../.artifacts', __FILE__))
  exit(MiniTest::Unit.new.run(%W(#{ENV['MINITEST_ARGS'] || ''})) || 1)
end

task :load_minitest do
  require 'minitest/spec'
end

task :clean_artifacts do
  rm_rf(File.expand_path('../.artifacts', __FILE__))
end

desc 'Send a test email to a local SMTP server (on $PORT)'
task :send_email do
  smtp_port = Integer(ENV['PORT'])
  require 'net/smtp'
  msg = <<-EOMSG.gsub(/^ {4}/, '')
    From: Fake SMTPd <fakesmtpd@example.org>
    To: Recipient Person <recipient@example.org>
    Subject: Test Sandwich
    Date: Sun, 11 Aug 2013 21:54:13 +0500
    Message-Id: <this.sandwich.is.a.test.#{rand(999..1999)}@example.org>

    Why have one sandwich when you can have #{rand(2..9)}?
                          ____
              .----------'    '-.
             /  .      '     .   \\
            /        '    .      /|
           /      .             \ /
          /  ' .       .     .  || |
         /.___________    '    / //
         |._          '------'| /|
         '.............______.-' /
     jgs |-.                  | /
         `"""""""""""""-.....-'

  EOMSG
  Net::SMTP.start('localhost', smtp_port) do |smtp|
    smtp.send_message(msg, 'fakesmtpd@example.org', 'recipient@example.org')
  end
end

task default: :test
