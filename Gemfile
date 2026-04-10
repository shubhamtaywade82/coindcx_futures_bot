# frozen_string_literal: true

source 'https://rubygems.org'

# coindcx-client gemspec requires Ruby >= 3.2
ruby '>= 3.2'

# Latest from GitHub (override with `bundle config local.coindcx-client ../coindcx-client` for local dev)
# gem 'coindcx-client', git: 'https://github.com/shubhamtaywade82/coindcx-client.git', branch: 'main'
gem 'coindcx-client', path: '../coindcx-client'

gem 'bigdecimal'
# ~> 2.8 aligns with optional ollama_agent (dev); Dotenv.load usage is unchanged from 3.x
gem 'dotenv', '~> 2.8'
gem 'sqlite3', '~> 2.1'

gem 'rack', '~> 3.1'
gem 'rackup', '~> 2.0' # Rack 3: WEBrick server lives here, not in `rack`
gem 'webrick', '~> 1.9'

gem 'pastel'
gem 'tty-box'
gem 'tty-logger'
gem 'tty-progressbar'
gem 'tty-prompt'
gem 'tty-reader'
gem 'tty-screen'
gem 'tty-spinner'
gem 'tty-table'

group :development, :test do
  gem 'rspec', '~> 3.13'
end

# Optional: local Ollama coding agent (self_review / improve). Path is project-relative:
# trading-workspace/coindcx/coindcx_futures_bot → ../../../ai-workspace/ollama_agent
# Override: bundle config set local.ollama_agent /absolute/path/to/ollama_agent
group :development do
  gem 'ollama_agent', path: '../../../ai-workspace/ollama_agent', require: false
end
