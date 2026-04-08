# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.1'

coindcx_path = File.expand_path('../coindcx-client', __dir__)
if File.directory?(coindcx_path)
  gem 'coindcx-client', path: coindcx_path
else
  gem 'coindcx-client', git: 'https://github.com/shubhamtaywade82/coindcx-client.git'
end

gem 'bigdecimal'
gem 'sqlite3', '~> 2.1'

gem 'pastel'
gem 'tty-box'
gem 'tty-logger'
gem 'tty-progressbar'
gem 'tty-prompt'
gem 'tty-screen'
gem 'tty-spinner'
gem 'tty-table'

group :development, :test do
  gem 'rspec', '~> 3.13'
end
