# coindcx_futures_bot

Standalone, Rails-ready Ruby futures trading bot for **CoinDCX** using [`coindcx-client`](https://github.com/shubhamtaywade82/coindcx-client). It targets a **fixed pair whitelist** (default SOL + ETH USDT perpetual-style instruments), trend-continuation logic, SQLite journaling, and an optional **TTY** operator UI.

## Layout

- **Core** — [`lib/coindcx_bot/core/engine.rb`](lib/coindcx_bot/core/engine.rb): WebSocket ticks, candle refresh, strategy, risk, execution.
- **Gateways** — [`lib/coindcx_bot/gateways/`](lib/coindcx_bot/gateways/): thin wrappers over the gem (`MarketData`, `Orders`, `Ws`, `Account`).
- **Strategy** — [`lib/coindcx_bot/strategy/trend_continuation.rb`](lib/coindcx_bot/strategy/trend_continuation.rb): HTF + execution timeframe regime, breakout / pullback entries, trail / partial / trend-failure exits.
- **Persistence** — [`lib/coindcx_bot/persistence/journal.rb`](lib/coindcx_bot/persistence/journal.rb): SQLite state (positions, kill switch, daily PnL aggregate, event log).
- **TUI** — [`lib/coindcx_bot/tui/app.rb`](lib/coindcx_bot/tui/app.rb): read-only dashboard + pause / kill-switch / flatten commands (no strategy logic).

## Setup

```bash
bundle install
cp config/bot.yml.example config/bot.yml
# Edit config/bot.yml — set exact `pairs:` from doctor output
export COINDCX_API_KEY=...
export COINDCX_API_SECRET=...
```

`coindcx-client` resolves from the sibling path `../coindcx-client` when present; otherwise Bundler uses the GitHub source (see [`Gemfile`](Gemfile)).

## Commands

```bash
bin/bot doctor   # credentials + list instruments matching SOL/ETH
bin/bot run      # blocking engine (REST + Socket.io WS)
bin/bot tui      # engine in background thread + TTY menu
bin/bot help
```

Optional: `COINDCX_BOT_CONFIG=/path/to/bot.yml`.

## Safety defaults

- `runtime.dry_run: true` in the example config logs orders without placing them. Set to `false` only after validating pair codes, order payload, and risk limits against live API docs.
- Fails closed on stale ticks (no new entries when the feed is older than `stale_tick_seconds`).
- Whitelist is enforced in config: **one or two** `pairs` only.

## Rails later

Keep this tree as a library under `lib/` or package it as a gem. Mount the same gateways from a broker adapter; run the **engine in a dedicated process**; use Rails for config UI, journal mirroring (ActiveRecord), and kill-switch flags — matching the client gem’s integration guidance.

## Tests

```bash
bundle exec rspec
```
