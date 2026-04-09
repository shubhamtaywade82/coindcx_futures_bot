# coindcx_futures_bot

Standalone Ruby futures trading bot for **CoinDCX** (USDT-margined), built around [`coindcx-client`](https://github.com/shubhamtaywade82/coindcx-client). Strategy, risk, journaling, and execution orchestration live here; the gem is transport-only.

**Scope:** intended for a small whitelist (e.g. SOL + ETH perpetuals), trend-continuation style entries, trailing exits — not a generic multi-exchange framework.

The engine subscribes to the private **order update** Socket.io stream when running and appends a redacted snippet of each payload to the SQLite `event_log` (audit trail only; it does not reconcile positions automatically). Public futures ticks use **both** `@prices-futures` (`price-change`) and `@trades-futures` (`new-trade`) so LTP and staleness reflect trade flow, not only slow mark/LTP pushes.

## Setup

1. **Ruby** 3.1+

2. **Credentials** (environment):

   - `COINDCX_API_KEY`
   - `COINDCX_API_SECRET`

   For local runs, copy [`.env.example`](.env.example) to **`.env`** in the **repository root** (same folder as `Gemfile`). `bin/bot` loads `.env` then `.env.local` automatically. You can still export the variables in your shell instead.

3. **Config**

   ```bash
   cp config/bot.yml.example config/bot.yml
   ```

   Edit `pairs:` to match your instruments. UI names like `SOLUSDT.P` differ from API codes; discover exact `pair` strings:

   ```bash
   bundle exec bin/bot doctor
   ```

4. **Install**

   ```bash
   bundle install
   ```

5. **Journal / data**

   SQLite state lives under `./data/` by default (`runtime.journal_path` in `bot.yml`). The directory is gitignored except `.gitkeep`.

## Commands

```bash
bundle exec bin/bot run    # blocking engine (WS + REST candles + strategy loop)
bundle exec bin/bot tui    # engine + terminal dashboard (see TUI notes below)
bundle exec bin/bot doctor # REST check + list active instruments (SOL/ETH hints)
bundle exec bin/bot help
```

Override config path:

```bash
COINDCX_BOT_CONFIG=/path/to/bot.yml bundle exec bin/bot run
```

### Paper mode (`dry_run` / `paper`)

Use **`runtime.dry_run: true`** or **`runtime.paper: true`** (alias) until order payloads are validated. In paper mode the bot:

- **Journals opens and closes** in SQLite (`positions` + `event_log`) so strategy state matches a live run.
- **Does not** call `futures.orders.create` or account exit APIs; **`f` flatten** only closes journal rows.
- **Approximates realized PnL** on each close: for longs, USDT PnL ≈ `(exit − entry) × qty` (shorts invert the price difference), then multiplies by **`inr_per_usdt`** into the journal **daily INR** total. Exit price is the **LTP** passed from the engine at close time, not an exchange fill.
- **Resolves closes** by `position_id` when present; if it is missing in paper mode, uses the **single open row for that pair** (still requires a matching row or the close returns **`:failed`**).

REST candles and WebSocket ticks still require valid API credentials for market data.

## TUI (`bin/bot tui`)

The dashboard and the trading **engine share one Ruby process** — `engine.snapshot` reads live `PositionTracker` / journal state. **No Redis or separate cache** is required for the numbers to update.

If the screen **never refreshes** (clock / LTP stuck) in **Cursor’s or another IDE’s embedded terminal**, stdin is often **not a real TTY**: `IO.select` can report stdin readable and the UI thread then **blocks on `getc`**, so the redraw loop never runs. The TUI detects non-TTY stdin and switches to **timer-only refresh** (about once per second). In that mode use **Ctrl+C** to exit; single-letter hotkeys may not work. For full keybindings, run `bin/bot tui` in a normal terminal (Windows Terminal, GNOME Terminal, iTerm, etc.). To **force** poll-only mode: `COINDCX_TUI_POLL_ONLY=1`.

## WebSocket (`SocketConnectionError`)

The stream uses **Socket.IO** over `wss://stream.coindcx.com`. The bot loads **`socket_io_uri_compat`** (Ruby 3 removed `URI.encode`, which `socket.io-client-simple` still uses). **`coindcx-client`** defaults to **Engine.IO v3** (`EIO=3`), which matches CoinDCX’s current stream and the bundled `socket.io-client-simple` parser. Set **`COINDCX_SOCKET_EIO`** only when you intentionally override that (e.g. a custom backend); **`EIO=4` is not supported** by the default gem backend.

If `bin/bot run` logs `CoinDCX::Errors::SocketConnectionError` with retries:

1. **Confirm you are not forcing `EIO=4`** in `.env` unless you know the stream and client both support it. Remove `COINDCX_SOCKET_EIO` to use the gem default, or set `COINDCX_SOCKET_EIO=3` explicitly.
2. **Optional URL override:** `COINDCX_SOCKET_BASE_URL=wss://stream.coindcx.com` (only if CoinDCX documents a different host).
3. **Network:** VPN, corporate firewall, or WSL DNS can block WebSockets — test from another network or `openssl s_client -connect stream.coindcx.com:443`.

**Stale feed:** `stale=true` means **no WebSocket tick** for that pair within `runtime.stale_tick_seconds` (the engine tracks WS time separately from REST). **New entries are blocked** while stale; exits/strategy still use REST candles. The LTP column is **mirrored from `PositionTracker`**. With a live socket, WS ticks update it immediately. While **`ws_feed_stale?`** (no recent parseable WS tick), the engine reapplies the **latest execution candle close** on every `tick_cycle` (~`stale_recovery_sleep_seconds`), so the number moves with REST without clearing the stale banner or `@ws_tick_at`. If CoinDCX only pushes occasionally, **raise `stale_tick_seconds`** in `config/bot.yml`. While stale, the engine sleeps `stale_recovery_sleep_seconds` (default 5) between cycles instead of `refresh_candles_seconds`.

**REST bootstrap:** Before the first WS tick, LTP may be seeded once from the **last closed candle** only when there is no price yet — it does **not** reset timestamps when WS goes quiet (that would hide a dead feed).

## Risk and execution notes

- **Per-trade INR:** `risk.per_trade_inr_min` and `risk.per_trade_inr_max` define a band; position sizing uses the **midpoint** of that band (converted via `inr_per_usdt` to USDT risk at the stop).
- **Leverage:** `risk.max_leverage` caps leverage on new orders. If `execution.order_defaults` sets `leverage`, the effective value is `min(requested, max_leverage)`.
- **Partial at 1R:** The bot records partials in the journal for trailing logic; **it does not automatically place a reduce-only order on the exchange** yet. Confirm CoinDCX derivatives order fields in their docs and extend `Execution::Coordinator` when you have a verified payload.

## Tests

```bash
bundle exec rspec
```

## Embedding in Rails (later)

Keep the same boundaries the gem documents:

- Configure `CoinDCX` in a Rails initializer (API keys, logger, retries).
- **Do not** call `coindcx-client` from controllers; expose a small `Brokers::Coindcx::*` adapter that delegates to `CoindcxBot::Gateways::*` (or a thin wrapper).
- Run `CoindcxBot::Core::Engine` in a **long-lived process** (dedicated thread started from an initializer is possible but fragile on Puma reload; prefer a separate worker process or `solid_queue`/Sidekiq job that runs the engine loop).
- Reuse the same `config/bot.yml` shape or load equivalent settings from `Rails.application.credentials` / DB.
- **Journal:** keep using `CoindcxBot::Persistence::Journal` on disk, or implement the same interface backed by ActiveRecord for `meta`, `positions`, and `event_log` tables.

The TUI and CLI stay outside Rails; only the engine + gateways need to be loadable from the Rails app (`require 'coindcx_bot'` with the gem path or local path in the Gemfile).

## Disclaimer

Trading futures is high risk. This software is for educational and operational automation use; you are responsible for API keys, leverage, liquidation, and compliance.
