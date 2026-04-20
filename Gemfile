# frozen_string_literal: true

source 'https://rubygems.org'

# Pinned for rbenv/IDEs; coindcx-client allows >= 3.2 (see Gemfile.lock RUBY VERSION)
ruby '3.3.4'

# Latest from GitHub (override with `bundle config local.coindcx-client ../coindcx-client` for local dev)
# gem 'coindcx-client', git: 'https://github.com/shubhamtaywade82/coindcx-client.git', branch: 'main'
gem 'coindcx-client', path: '../coindcx-client'

# Regime AI (local Ollama): trading analyst via ollama-client; optional retries via ollama_agent.
gem 'ollama-client', '~> 1.3'
gem 'ollama_agent'

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

