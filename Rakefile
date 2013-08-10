require 'bundler/gem_tasks'

desc 'Run minitest tests in ./test'
task test: :load_minitest do
  Dir.glob("#{File.expand_path('../test', __FILE__)}/*_test.rb").each do |f|
    require f
  end

  mkdir_p(File.expand_path('../.artifacts', __FILE__))
  exit(MiniTest::Unit.new.run(%W(#{ENV['MINITEST_ARGS'] || ''})) || 1)
end

task :load_minitest do
  require 'minitest/spec'
end

task default: :test
