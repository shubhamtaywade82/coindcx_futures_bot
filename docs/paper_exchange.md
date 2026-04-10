# CoinDCX-shaped paper exchange (HTTP)

This repository can run a **local REST simulator** that mimics selected CoinDCX **futures** wallet, order, and position endpoints. The trading bot then uses the normal **`coindcx-client`** adapters with `api_base_url` pointed at that server, instead of talking to production for order and account calls.

For Socket.IO private-stream parity (future work), see [`paper_exchange_socketio.md`](paper_exchange_socketio.md).

---

## When to use this vs in-process `PaperBroker`

| Mode | How it works |
|------|----------------|
| **Default paper** (`runtime.dry_run` / `runtime.paper`, no `paper_exchange`) | **`Execution::PaperBroker`** writes to a local **`PaperStore`** SQLite file. Orders never leave the process. |
| **Paper exchange** (`paper_exchange.enabled: true` + `api_base_url`) | **`Execution::GatewayPaperBroker`** sends orders and account actions to **your Rack app** over HTTP. Fills are driven by **signed `POST …/simulation/tick`** from the engine (same API key/secret as CoinDCX-style signing). |

Use the HTTP exchange when you want **transport-level parity** with the real client (headers, paths, JSON shapes) or to share one simulator between multiple processes.

---

## Quick start

1. **Credentials:** The simulator and the bot both use **`COINDCX_API_KEY`** and **`COINDCX_API_SECRET`** for request signing (the paper exchange verifies HMAC the same way the real API expects).

2. **Start the server** (from the repo root, after `bundle install`):

   ```bash
   bundle exec bin/paper-exchange
   ```

   Defaults: bind **`127.0.0.1`**, port **`9292`**. Override with **`PAPER_EXCHANGE_BIND`**, **`PAPER_EXCHANGE_PORT`**.

3. **Database:** SQLite path defaults to **`./data/paper_exchange.sqlite3`**. Override with **`PAPER_EXCHANGE_DB`**.

4. **Bot config** (`config/bot.yml`):

   ```yaml
   runtime:
     dry_run: true   # or paper: true

   paper_exchange:
     enabled: true
     api_base_url: http://127.0.0.1:9292
     # tick_path: /exchange/v1/paper/simulation/tick   # optional; this is the default
   ```

5. **Slippage / fees on the simulator** are read from the optional **`paper:`** block in the same YAML the harness loads (`COINDCX_BOT_CONFIG` or default `config/bot.yml`), e.g. `slippage_bps`, `fee_bps`.

6. Run the bot as usual: `bundle exec bin/bot run` or `bundle exec bin/bot tui`.

---

## How the bot wires in

- **`CoindcxBot::Config#paper_exchange_enabled?`** is true only when **`dry_run?`** and **`paper_exchange.enabled`** are both set.
- **`Core::Engine#configure_coin_dcx`** sets **`CoinDCX.configure { |c| c.api_base_url = … }`** to **`paper_exchange.api_base_url`** so **`OrderGateway`** and **`AccountGateway`** hit the local app.
- **`Core::Engine#build_broker`** returns **`GatewayPaperBroker`**, which subclasses **`LiveBroker`** but overrides **`paper?`** and **`process_tick`**. Each tick cycle, **`process_tick`** signs a small JSON body (`pair`, `ltp`, optional candle **`high`** / **`low`**) and POSTs to the simulation tick path so the exchange can match limits/stops and update positions.

If **`paper_exchange.enabled`** is false, dry-run still uses **`Execution::PaperBroker`** (in-process) as before.

---

## HTTP surface (high level)

Implemented in **`CoindcxBot::PaperExchange::App`** (behind **`Auth::Middleware`** except **`GET /health`**):

- **`GET /health`** — liveness JSON.
- **Wallets:** `GET …/derivatives/futures/wallets`, `POST …/wallets/transfer`, `GET …/wallets/transactions`.
- **Orders:** `POST …/orders/create`, `POST …/orders/cancel`, `POST …/orders` (list).
- **Positions:** list, leverage, margin, exit, TP/SL helpers, transactions, cross-margin details, etc. (see `lib/coindcx_bot/paper_exchange/app.rb` for the exact path map).
- **`POST /exchange/v1/paper/simulation/tick`** — **signed** body; advances the internal matcher for the authenticated user.

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
