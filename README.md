`fakesmtpd`
===========

[![Build Status](https://travis-ci.org/modcloth-labs/fakesmtpd.png?branch=master)](https://travis-ci.org/modcloth-labs/fakesmtpd)

A fake SMTP server with a minimal HTTP API.
Inspired by [mailtrap](https://github.com/mmower/mailtrap).

## Installation
`fakesmtpd` may be installed either as a Ruby gem or by directly
downloading the server file which may then be used as an executable,
e.g.:

``` bash
gem install fakesmtpd
```

**OR**

``` bash
curl -o fakesmtpd https://raw.github.com/modcloth-labs/fakesmtpd/master/lib/fakesmtpd/server.rb
chmod +x fakesmtpd
```

## Usage
`fakesmtpd` is usable either as an executable or from within a Ruby
process.  The following examples are roughly equivalent.

``` bash
# example command line invocation:
fakesmtpd 9025 ./fakesmtpd-messages -p ./fakesmtpd.pid -l ./fakesmtpd.log
```

``` ruby
# example in-process Ruby invocation:
require 'fakesmtpd'
FakeSMTPd::Server.main(
  %w(9025 ./fakesmtpd-messages -p ./fakesmtpd.pid -l ./fakesmtpd.log)
)
```

The `FakeSMTPd::Runner` class is intended to provide a
formalized way to spawn and manage a separate Ruby process running
`FakeSMTPd::Server`.  This example is also equivalent to those provided
above:

``` ruby
require 'fakesmtpd'

fakesmtpd = FakeSMTPd::Runner.new(
  dir: File.expand_path('../fakesmtpd-messages', __FILE__),
  port: 9025,
  logfile: File.expand_path('../fakesmtpd.log', __FILE__),
  pidfile: File.expand_path('../fakesmtpd.pid', __FILE__)
)
# This spawns another Ruby process via `RbConfig.ruby`
fakesmtpd.start

# ... do other stuff ...

# This will kill the previously-spawned process
fakesmtpd.stop
```
