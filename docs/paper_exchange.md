# CoinDCX-shaped paper exchange (HTTP)

This repository can run a **local REST simulator** that mimics selected CoinDCX **futures** wallet, order, and position endpoints. The trading bot then uses the normal **`coindcx-client`** adapters with `api_base_url` pointed at that server, instead of talking to production for order and account calls.

For Socket.IO private-stream parity (future work), see [`paper_exchange_socketio.md`](paper_exchange_socketio.md).

---

## When to use this vs in-process `PaperBroker`

| Mode | How it works |
|------|----------------|
| **Default paper** (`runtime.dry_run: true`, no `paper_exchange`) | **`Execution::PaperBroker`** writes to a local **`PaperStore`** SQLite file. Orders never leave the process. |
| **Paper exchange** (`paper_exchange.enabled: true` + `api_base_url`) | **`Execution::GatewayPaperBroker`** sends orders and account actions to **your Rack app** over HTTP. Fills are driven by **signed `POST …/simulation/tick`** from the engine (same API key/secret as CoinDCX-style signing). |

Use the HTTP exchange when you want **transport-level parity** with the real client (headers, paths, JSON shapes) or to share one simulator between multiple processes.

---

## Quick start

1. **Credentials:** The simulator and the bot both use **`COINDCX_API_KEY`** and **`COINDCX_API_SECRET`** for request signing (the paper exchange verifies HMAC the same way the real API expects).

2. **Start the server** (from the repo root, after `bundle install`):

   ```bash
   bundle exec bin/paper-exchange
   ```

   The `bin/paper-exchange` script runs **`Bundler.setup`** and **`Rackup::Handler::WEBrick`** so it works with **Rack 3** without relying on removed `rack/handler/webrick`. You can also run `./bin/paper-exchange` from the repo root (not plain `ruby` from another directory without Bundler, or you risk mixed Rack versions from RubyGems).

   Defaults: bind **`127.0.0.1`**, port **`9292`**. Override with **`PAPER_EXCHANGE_BIND`**, **`PAPER_EXCHANGE_PORT`**.

   **Logging (stdout):** **`Rack::CommonLogger`** is **on by default** (one line per request: method, path, status, size, duration). Simulation ticks also log **`pair`** and **`ltp`** after a successful dispatch. Disable access-style lines with **`PAPER_EXCHANGE_ACCESS_LOG=0`** (WEBrick startup messages still appear).

   **`401` on `/simulation/tick`:** the exchange verifies **`X-AUTH-APIKEY`** + HMAC body like CoinDCX. Use the **same** **`COINDCX_API_KEY`** / **`COINDCX_API_SECRET`** as when the server starts (both load `.env` from the repo). If the key exists but the secret in **`.env` changed**, restart **`bin/paper-exchange`** so the DB row is updated (or delete **`data/paper_exchange.sqlite3`** to re-seed).

   Each failed auth request logs one line to **stderr** (`[paper_exchange:auth] …`) and returns JSON `error.code` as below. Set **`PAPER_EXCHANGE_AUTH_DEBUG=1`** for an extra **`[paper_exchange:auth:debug]`** line on **`unknown_api_key`** (fingerprints + whether the header key equals this process’s `COINDCX_API_KEY`).

   **Shell vs `.env`:** `Dotenv.load` does **not** replace variables already exported in your environment. If one terminal has old `COINDCX_API_KEY` in the shell and another loads only `.env`, fingerprints differ → **`unknown_api_key`**. Fix: `unset COINDCX_API_KEY COINDCX_API_SECRET` in both shells, or run both processes from clean environments so the repo `.env` applies.

   | `error.code` (JSON) | Typical fix |
   | --- | --- |
   | `missing_auth_headers` | Request omitted `X-AUTH-APIKEY` / `X-AUTH-SIGNATURE` (unusual for **`GatewayPaperBroker`** + Faraday). |
   | `unknown_api_key` | Response includes **`error.hint`**: either the request key **fingerprint** ≠ server `.env` (align keys), or fingerprints match but the row is missing (stop server, delete the logged **`sqlite`** path, restart). Compare startup **`COINDCX_API_KEY fingerprint=…`** with the bot’s key (same string → same fingerprint). |
   | `invalid_signature` | **`COINDCX_API_SECRET`** on the bot must match the row in the DB. After changing **`.env`**, restart **`bin/paper-exchange`** (Boot updates the secret for an existing key) or wipe the DB and restart. |

   **`missing auth headers` on `GET …/data/instrument`:** fixed in current code — **`coindcx-client` uses `auth: false`** for that route (public market data on production). The simulator allows the same GETs **without** HMAC. If you still see this, upgrade to a revision that includes public market GET handling.

3. **Database:** **`Harness`** (used by **`bin/paper-exchange`** and any **`rackup`** of the same app) defaults to **`<repo>/data/paper_exchange.sqlite3`** resolved from the gem path, **not** `Dir.pwd`, so the simulator uses one stable file no matter which directory you start the server from. Override with **`PAPER_EXCHANGE_DB`**. On startup the server logs **`[paper_exchange] sqlite <path>`** and a **`COINDCX_API_KEY fingerprint=…`** line — the bot’s key must yield the **same** fingerprint (same `.env`).

   **Threading:** The app uses **one** `SQLite3::Database` per file. **`PaperExchange::SqlMutex::Middleware`** is the **outermost** Rack layer in **`Harness`** so WEBrick’s thread pool never touches SQLite concurrently (which can otherwise yield bogus “unknown api key” even when `pe_api_keys` is seeded). Custom Rack stacks should keep that middleware **outside** all other layers that might run handlers in parallel.

4. **Bot config** (`config/bot.yml`):

   ```yaml
   runtime:
     dry_run: true

   paper_exchange:
     enabled: true
     api_base_url: http://127.0.0.1:9292
     # tick_path: /exchange/v1/paper/simulation/tick   # optional; this is the default
   ```

5. **Slippage / fees on the simulator** are read from the optional **`paper:`** block in the same YAML the harness loads (`COINDCX_BOT_CONFIG` or default `config/bot.yml`), e.g. `slippage_bps`, `fee_bps`.

6. **USDT/INR conversions (public GET):** `GET /api/v1/derivatives/futures/data/conversions` returns a **JSON array** in the same shape as production (e.g. `USDTINR` with `conversion_price`). The harness **proxies** CoinDCX’s API with a **TTL cache** (default **60s**). If the upstream call fails or returns no usable row, the response is a **single synthetic** `USDTINR` element using top-level **`inr_per_usdt`** from the same bot YAML (default **83**).

   | Environment variable | Purpose |
   | --- | --- |
   | `PAPER_EXCHANGE_FX_TTL_SECONDS` | Cache TTL for upstream conversions (seconds, minimum 5). Default `60`. |
   | `PAPER_EXCHANGE_FX_UPSTREAM_HOST` | Base URL for the Faraday client (no trailing slash). Default `https://api.coindcx.com`. |
   | `PAPER_EXCHANGE_FX_UPSTREAM_PATH` | Path appended to the host. Default `/api/v1/derivatives/futures/data/conversions`. |

7. Run the bot as usual: `bundle exec bin/bot run` or `bundle exec bin/bot tui`.

---

## How the bot wires in

- **`CoindcxBot::Config#paper_exchange_enabled?`** is true only when **`dry_run?`** and **`paper_exchange.enabled`** are both set.
- **`Core::Engine#configure_coin_dcx`** sets **`CoinDCX.configure { |c| c.api_base_url = … }`** to **`paper_exchange.api_base_url`** so **`OrderGateway`** and **`AccountGateway`** hit the local app.
- **`Core::Engine#build_broker`** returns **`GatewayPaperBroker`**, which subclasses **`LiveBroker`** but overrides **`paper?`** and **`process_tick`**. Each tick cycle, **`process_tick`** signs a small JSON body (`pair`, `ltp`, optional candle **`high`** / **`low`**) and POSTs to the simulation tick path. The JSON response’s **`position_exits`** array is turned into the same `kind: :exit` rows as in-process **`PaperBroker`**, so **`run_paper_process_tick`** can call **`handle_broker_exit`**.

If **`paper_exchange.enabled`** is false, dry-run still uses **`Execution::PaperBroker`** (in-process) as before.

---

## HTTP surface (high level)

Implemented in **`CoindcxBot::PaperExchange::App`** (behind **`Auth::Middleware`** except **`GET /health`** and **public market GETs** such as **`/api/v1/derivatives/futures/data/conversions`**):

- **`GET /health`** — liveness JSON.
- **`GET /api/v1/derivatives/futures/data/conversions`** — JSON **array** of conversion rows (proxied from CoinDCX with TTL cache; synthetic `USDTINR` from `inr_per_usdt` on failure). No auth.
- **Wallets:** `GET …/derivatives/futures/wallets`, `POST …/wallets/transfer`, `GET …/wallets/transactions`.
- **Orders:** `POST …/orders/create`, `POST …/orders/cancel`, `POST …/orders` (list).
- **Positions:** list, leverage, margin, exit, TP/SL helpers, transactions, cross-margin details, etc. (see `lib/coindcx_bot/paper_exchange/app.rb` for the exact path map).
- **`POST /exchange/v1/paper/simulation/tick`** — **signed** body (`pair`, `ltp`, optional `high` / `low`); updates mark prices and runs the fill engine on open orders for that pair.

  **Response (200):** `{ "status": "ok", "position_exits": [ ... ] }`. Each element describes a **full** position close that occurred during this tick (partial closes are omitted from this list):

  | Field | Meaning |
  | --- | --- |
  | `pair` | Instrument, e.g. `B-SOL_USDT` |
  | `realized_pnl_usdt` | Net USDT PnL for this close leg after fees (decimal string) |
  | `fill_price` | Exit fill price (decimal string) |
  | `position_id` | Exchange `pe_positions.id` |
  | `trigger` | Fill trigger, e.g. `stop_loss`, `take_profit`, `limit_order` |

  `GatewayPaperBroker#process_tick` reads `position_exits` and forwards them to `Coordinator#handle_broker_exit` so the bot journal matches the simulator when stops/limits fire without a strategy `:close` signal.

  **Limitation:** Resting **entry** orders that fill on a later tick do not create journal rows via this API; use market entries from the strategy or in-process `PaperBroker` if you need journal parity for deferred entries.

Exact JSON shapes aim to stay close enough for **`coindcx-client`**; refer to the service objects under `lib/coindcx_bot/paper_exchange/` for fields and error codes.

---

## TUI and market data (related improvements)

These changes land in the same development line as the paper exchange and improve the dashboard even when you are **not** using `paper_exchange`:

- **`LtpRestPoller`** batch-fetches RT quotes via **`MarketDataGateway#fetch_futures_rt_quotes`** so **CHG%** can track **`pc`**-style fields.
- **`TickStore`** keeps the **last known `change_pct`** when an update omits it.
- **`mirror_tracker_into_tick_store`** does not regress **`updated_at`** when REST has already refreshed the store more recently than the WS/candle mirror.

Public market data still uses real CoinDCX credentials unless you also point socket/REST config elsewhere.

---

## Tests

```bash
bundle exec rspec spec/paper_exchange/
bundle exec rspec spec/coindcx_bot/config_spec.rb spec/coindcx_bot/gateways/market_data_gateway_spec.rb spec/coindcx_bot/tui/tick_store_spec.rb
```

---

## See also

- [`paper_broker_simulation.md`](paper_broker_simulation.md) — roadmap for in-process **`PaperBroker`** (working orders, phases).
- [`paper_exchange_socketio.md`](paper_exchange_socketio.md) — private Socket.IO spike.
- [`new_improvements.md`](new_improvements.md) — inventory of what the codebase implements today.
- Root [`CHANGELOG.md`](../CHANGELOG.md) — release-style notes.
