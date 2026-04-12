# coindcx_futures_bot

Standalone Ruby futures trading bot for **CoinDCX** (USDT-margined), built around [`coindcx-client`](https://github.com/shubhamtaywade82/coindcx-client). Strategy, risk, journaling, and execution orchestration live here; the gem is transport-only.

**Scope:** intended for a small whitelist (e.g. SOL + ETH perpetuals), trend-continuation style entries, trailing exits — not a generic multi-exchange framework.

**Changelog:** [`CHANGELOG.md`](CHANGELOG.md). **Doc index:** [`docs/README.md`](docs/README.md). **HTTP paper exchange (optional):** [`docs/paper_exchange.md`](docs/paper_exchange.md).

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
bundle exec bin/bot run           # blocking engine (WS + REST candles + strategy loop)
bundle exec bin/bot tui           # engine + terminal dashboard (see TUI notes below)
bundle exec bin/bot doctor        # REST check + list active instruments (SOL/ETH hints)
bundle exec bin/bot paper-status  # journal snapshot: open rows, today's INR PnL, paper_realized
bundle exec bin/bot help
```

Override config path:

```bash
COINDCX_BOT_CONFIG=/path/to/bot.yml bundle exec bin/bot run
```

### Paper mode (`runtime.dry_run`)

**Roadmap** for in-process working orders, limits/stops, OCO: [`docs/paper_broker_simulation.md`](docs/paper_broker_simulation.md).

**Optional HTTP simulator:** run `bundle exec bin/paper-exchange` and set **`paper_exchange.enabled`** + **`paper_exchange.api_base_url`** so the bot uses **`GatewayPaperBroker`** against a local CoinDCX-shaped API (signed simulation ticks). See [`docs/paper_exchange.md`](docs/paper_exchange.md).

Use **`runtime.dry_run: true`** until order payloads are validated. In paper mode the bot:

- **Journals opens and closes** in SQLite (`positions` + `event_log`) so strategy state matches a live run.
- **Does not** call `futures.orders.create` or account exit APIs.
- **Simulated fills** go to a separate **`paper:`** SQLite file (`paper_orders`, `paper_fills`, `paper_positions`, …). On a paper **open**, the journal row’s **`entry_price`** is updated to the **slipped fill** from the paper broker so sizing and display track the simulator.
- **`f` flatten (paper):** the engine passes per-pair **LTP** from the last WebSocket tick, else the **latest execution candle close**. The coordinator closes the **paper position** at that price (fees/slippage in the paper DB), books **daily INR** from the paper position’s **realized USDT** × **live USDT/INR** (CoinDCX futures **conversions** API, cached; falls back to **`inr_per_usdt`** in config if disabled or unreachable), then closes journal rows. If no LTP is available for a pair, the journal is still flattened but the paper row may stay open (check logs).
- **Strategy closes (paper):** same rule — daily INR comes from **`PaperBroker`** realized USDT on the close fill, not a separate journal-only formula.
- **Resolves closes** by `position_id` when present; if it is missing in paper mode, uses the **single open row for that pair** (still requires a matching row or the close returns **`:failed`**).

REST candles and WebSocket ticks still require valid API credentials for market data.

**Strategy signals:** the engine calls `strategy.evaluate` on every pair every `tick_cycle`. Most cycles return **`hold`** with a reason (e.g. `no_regime`, `no_entry_setup`). **`hold` is silent in logs by default**, so it can look like “no signals”. To see them, set **`runtime.log_strategy_signals: true`** in `bot.yml` or **`COINDCX_STRATEGY_SIGNALS=1`** in the environment. That prints `[strategy] <pair> <action> reason=<…>` and, when the strategy asks to open but the engine blocks it, `[engine] … blocked: stale_feed|daily_loss_limit|max_positions|…`.

## TUI (`bin/bot tui`)

The dashboard and the trading **engine share one Ruby process** — `engine.snapshot` reads live `PositionTracker` / journal state. **No Redis or separate cache** is required for the numbers to update.

If the screen **never refreshes** (clock / LTP stuck) in **Cursor’s or another IDE’s embedded terminal**, stdin is often **not a real TTY**: `IO.select` can report stdin readable and the UI thread then **blocks on `getc`**, so the redraw loop never runs. The TUI detects non-TTY stdin and switches to **timer-only refresh** (about once per second). In that mode use **Ctrl+C** to exit; single-letter hotkeys may not work. For full keybindings, run `bin/bot tui` in a normal terminal (Windows Terminal, GNOME Terminal, iTerm, etc.). To **force** poll-only mode: `COINDCX_TUI_POLL_ONLY=1`.

## WebSocket (`SocketConnectionError`)

The stream uses **Socket.IO** over `wss://stream.coindcx.com`. The bot loads **`socket_io_uri_compat`** (Ruby 3 removed `URI.encode`, which `socket.io-client-simple` still uses). **`coindcx-client`** defaults to **Engine.IO v3** (`EIO=3`), which matches CoinDCX’s current stream and the bundled `socket.io-client-simple` parser. Set **`COINDCX_SOCKET_EIO`** only when you intentionally override that (e.g. a custom backend); **`EIO=4` is not supported** by the default gem backend.

If `bin/bot run` logs `CoinDCX::Errors::SocketConnectionError` with retries:

1. **Confirm you are not forcing `EIO=4`** in `.env` unless you know the stream and client both support it. Remove `COINDCX_SOCKET_EIO` to use the gem default, or set `COINDCX_SOCKET_EIO=3` explicitly.
2. **Optional URL override:** `COINDCX_SOCKET_BASE_URL=wss://stream.coindcx.com` (only if CoinDCX documents a different host).
3. **Network:** VPN, corporate firewall, or WSL DNS can block WebSockets — test from another network or `openssl s_client -connect stream.coindcx.com:443`.

**TUI “no WS” / STALE with moving LTP:** **LTP** can move from **REST** (candles and/or the TUI’s **`LtpRestPoller`** into **`TickStore`**) while **`@ws_tick_at`** (real WebSocket) stayed quiet — so you can see **STALE** while the LTP row still updates. The bot subscribes to **`currentPrices@futures#update`** and parses nested `prices` shapes when possible; if that still yields nothing, check logs for a one-time **`[ws] currentPrices@futures: no ticks matched…`** (pass `logger` via the engine — already wired). **`mirror_tracker_into_tick_store`** avoids overwriting **`TickStore.updated_at`** with an older WS/candle mirror when REST has already refreshed the row (so **AGE** can reflect the fast poller). **Paper / `dry_run`:** by default **`paper_rest_advances_ws_stale_clock: true`** advances the same clock when REST mirrors a candle, so STALE/AGE match the LTP you see (set **`runtime.paper_rest_advances_ws_stale_clock: false`** to keep strict “real WS only” behaviour in paper). **Live** never uses the REST clock for `@ws_tick_at`. **`COINDCX_WS_TRACE=1`** prints each tick that hits the bus.

**Stale feed:** `stale=true` on the snapshot means **at least one** pair has no WebSocket tick within `runtime.stale_tick_seconds`. **New entries are blocked only for pairs that are stale** (others can still open). Exits/strategy still use REST candles. In the TUI, the **STALE** badge on the LTP panel follows **`ws_feed_stale?`**; **AGE** follows **`TickStore.updated_at`** (often updated by **`LtpRestPoller`**), so **STALE** and **AGE** can diverge by design when REST is fresh but WS is not. The engine still mirrors WS/candles into **`PositionTracker`** for trading logic. While **`ws_feed_stale?`**, the engine reapplies the **latest execution candle close** on each `tick_cycle` (~`stale_recovery_sleep_seconds`), so strategy LTP can move with REST without clearing the stale banner. **`snapshot.last_error`** is reserved for real failures (e.g. WS connect); it is **not** set to `stale_feed`. If CoinDCX only pushes occasionally, **raise `stale_tick_seconds`** in `config/bot.yml`. While stale, the engine sleeps `stale_recovery_sleep_seconds` (default 5) between cycles instead of `refresh_candles_seconds`.

**REST bootstrap:** Before the first WS tick, LTP may be seeded once from the **last closed candle** only when there is no price yet — it does **not** reset timestamps when WS goes quiet (that would hide a dead feed).

## Risk and execution notes

- **Per-trade INR:** by default, sizing uses **`capital_inr`** and **`Config`** resolved rails (target ~1.5% of capital at the stop, clamp band and daily loss as % of capital). Optional explicit `risk.per_trade_inr_min` / `max`, `max_daily_loss_inr`, or `*_pct_of_capital` keys override; legacy **midpoint** behavior applies only when both INR min and max are set and `per_trade_capital_pct` is omitted. See [`config/bot.yml.example`](config/bot.yml.example).
- **Leverage:** `risk.max_leverage` caps leverage on new orders. If `execution.order_defaults` sets `leverage`, the effective value is `min(requested, max_leverage)`.
- **Partial at 1R:** The bot records partials in the journal for trailing logic; **it does not automatically place a reduce-only order on the exchange** yet. Confirm CoinDCX derivatives order fields in their docs and extend `Execution::Coordinator` when you have a verified payload.

## AI-assisted development (optional)

The repo can bundle **[ollama_agent](https://github.com/shubhamtaywade82/ollama_agent)** under **`group :development`** (path gem → `../../../ai-workspace/ollama_agent` from this checkout). It runs a **local Ollama** coding agent: read/search the tree, patches, **`self_review`**, **`improve`** (sandbox + tests + optional `--apply`). Use it to **iterate on strategy/risk code and specs**, not to drive live trades.

**Regime + Ollama (runtime, optional):** when `regime.enabled` and `regime.ai.enabled` are true, the engine calls **Ollama** on a **throttled** timer (see `min_interval_seconds`) for a **JSON regime narrative** only — **no LLM on order submission**. Quantitative **HMM** filtering (`regime.hmm.enabled`) runs on candle refresh; use `strategy.name: regime_vol_tier` to gate new entries by vol tier. **`bundle exec bin/bot regime-backtest [PAIR]`** runs a deterministic walk-forward HMM fit (REST candles, no Ollama).

**Prerequisites:** Ollama running with a tool-capable model; **`patch`** on `PATH`; **`rg`** or **`grep`** for search. See the upstream README for env vars (`OLLAMA_AGENT_MODEL`, cloud URL/key, etc.).

**Commands** (from repository root; **`OLLAMA_AGENT_ROOT`** defaults to this repo):

```bash
bundle exec bin/ollama-review                    # default: self_review --mode analysis (read-only report)
bundle exec bin/ollama-review improve --help
bundle exec bin/ollama-review ask --read-only "Summarize exit rules in lib/coindcx_bot/strategy"
```

**CoinDCX futures agent (`bin/coindcx-agent`):** read-only **`OllamaAgent::Agent`** scoped to this repo, with extra prompt skill under [`config/ollama_agent/skills/`](config/ollama_agent/skills/) (boundaries, key paths, strategy/risk notes). Use it for **natural-language questions** about the codebase; it does **not** place trades.

```bash
bundle exec bin/coindcx-agent "Where is daily loss enforced relative to capital_inr?"
```

**Orchestrator delegate:** to register a sub-agent id **`coindcx_futures`** for `ollama_agent orchestrate` / delegation tools, point at the merge overlay (this **adds** to upstream defaults, it does not replace them):

```bash
export OLLAMA_AGENT_EXTERNAL_AGENTS_CONFIG="$PWD/config/ollama_agent/external_agents.overlay.yml"
bundle exec bin/ollama-review agents    # should list coindcx_futures when ruby is on PATH
```

**Note:** older **`ollama_agent`** versions called the external program **`command`** for `command -v`; on distros without **`/usr/bin/command`** that raised **`ENOENT`**. The path gem under **`../../../ai-workspace/ollama_agent`** includes a **PATH-walk fallback**; update that checkout if you still see the error.

Optional: **`COINDCX_FUTURES_AGENT_RUBY_PATH`** — absolute path to `ruby` if the delegate subprocess cannot find it on `PATH`.

**Path layout:** if your `ollama_agent` checkout is not at `../../..` from `coindcx_futures_bot`, either adjust the **`path:`** in the `Gemfile` or run:

```bash
bundle config set local.ollama_agent /absolute/path/to/ollama_agent
```

**Deploy / lean installs:** `bundle install --without development` omits `ollama_agent` and keeps production bundles smaller.

**Dependency note:** `ollama_agent` expects **`dotenv` ~> 2.8**; this Gemfile uses **`dotenv` ~> 2.8** so both resolve together.

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
