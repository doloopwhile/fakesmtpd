# vim:fileencoding=utf-8

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fakesmtpd'

Gem::Specification.new do |spec|
  spec.name          = 'fakesmtpd'
  spec.version       = FakeSMTPd::VERSION
  spec.authors       = ['Dan Buch']
  spec.email         = ['d.buch@modcloth.com']
  spec.description   = %q{A fake SMTP server with a minimal HTTP API}
  spec.summary       = %q{A fake SMTP server with a minimal HTTP API}
  spec.homepage      = 'https://github.com/modcloth-labs/fakesmtpd'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = %w(lib)

  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake'
end
