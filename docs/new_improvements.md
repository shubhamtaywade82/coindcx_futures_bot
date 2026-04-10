# Improvements backlog — aligned with current codebase

This file replaces an earlier draft (`new_improvments.md`) that mixed chat transcripts, speculative designs, and APIs that do **not** exist in this repository. The sections below reflect the **actual** layout under `lib/coindcx_bot/` as of this branch.

---

## What is already implemented

### Runtime and config

- **`runtime.dry_run` / `runtime.paper`**: `Config#dry_run?` is true if either flag is set (`lib/coindcx_bot/config.rb`).
- **`paper:` config block**: `slippage_bps`, `fee_bps`, `db_path` — documented in `config/bot.yml.example` and read in `Core::Engine#build_broker` for **`PaperBroker`**. The **paper exchange** harness also reads **`paper:`** for slippage/fee when seeding the Rack app.
- **`paper_exchange:`** (optional): `enabled`, `api_base_url`, `tick_path` — when **`enabled`** and **`dry_run?`**, the engine uses **`GatewayPaperBroker`** and sets **`CoinDCX.configure { api_base_url }`** to the simulator. See **`docs/paper_exchange.md`**.
- **`Config#paper_config`**: Returns the raw `paper` hash from YAML (defaults are applied in the engine for slippage/fee/db_path, not merged in `paper_config` itself).

### Execution layer

- **`Execution::Broker`** (abstract **class**): `place_order`, `cancel_order`, `open_positions`, `open_position_for`, `close_position`, `paper?`, `process_tick`, `metrics` — not a `module Broker` with `Fill` from older drafts.
- **`Execution::LiveBroker`**: Wraps `OrderGateway` / `AccountGateway`; uses the journal for open positions; exits via account gateway. **`process_tick`** is a no-op (`[]`).
- **`Execution::PaperBroker`**: Persists orders, fills, positions, events, and optional account snapshots in **`Persistence::PaperStore`** (separate SQLite file from the bot journal). Uses **`Execution::FillEngine`** for slippage and fees; **`process_tick`** evaluates working orders against LTP / candle range.
- **`Execution::GatewayPaperBroker`**: Used when **`paper_exchange.enabled`** (and **`dry_run?`**). Still subclasses **`LiveBroker`** so order/account traffic goes through gateways, but **`api_base_url`** points at the local **paper exchange** Rack app. **`process_tick`** POSTs a **CoinDCX-signed** body to **`POST /exchange/v1/paper/simulation/tick`** so the HTTP simulator can match orders.
- **`Execution::Coordinator`**: Takes **`broker:`** (not `order_gateway:` + `account_gateway:`). Branches paper vs live for open/close; still journals positions for strategy/risk. Places orders with **`client_order_id`** and **`order_type: 'market_order'`** where applicable. **`flatten_all(pairs, ltps: {})`** — in paper mode, uses **`ltps`** to close paper positions before clearing the journal; daily INR on paper closes comes from realized USDT × **`inr_per_usdt`** when the broker returns that on close (including gateway-paper close payloads).

### Engine

- Builds **`@broker`** via **`build_broker`**: **`GatewayPaperBroker`** if **`paper_exchange.enabled`**, else **`PaperBroker`** when **`dry_run?`**, else **`LiveBroker`**; passes the broker to the coordinator.
- **`tick_cycle`**: After mirroring into **`TickStore`**, calls **`run_paper_process_tick`** when **`@broker.paper?`**, so both **`PaperBroker`** and **`GatewayPaperBroker`** receive per-pair ticks (local fill evaluation vs HTTP simulation tick).
- **`mirror_tracker_into_tick_store`**: Skips the mirror when **`TickStore`** already has a **newer `updated_at`** than the tracker tick (avoids REST-fresh LTP/age being overwritten by slower WS/candle mirrors).
- **`flatten_all!`**: Builds **`ltps`** per pair from **`PositionTracker`** then **execution candle close** fallback, passes them to **`Coordinator#flatten_all`**.
- **`#snapshot`**: Includes **`paper_metrics`** when the broker is paper: merges `@broker.metrics` with **`unrealized_pnl`** from `@broker.unrealized_pnl(ltp_map)` (`paper_snapshot_metrics`).

### Paper simulation scope (today)

- **In-process `PaperBroker`:** **`FillEngine#evaluate`** on **`process_tick`** for working orders; market entries may still fill immediately on place depending on path. **`Execution::OrderBook`** + extended **`PaperStore`** schema support working orders (see **`docs/paper_broker_simulation.md`** for phased status).
- **HTTP `paper_exchange`:** Matching and ledger live in the Rack app; bot drives fills via signed simulation tick POSTs.
- **OCO / groups:** schema hooks exist; full OCO behavior may still be incomplete — see **`paper_broker_simulation.md`**.

### Persistence

- **`Persistence::Journal`**: Bot journal (positions for strategy, daily PnL INR, events). Still the source for `PositionTracker#open_position_for`. Supports **`update_position_entry_price`** so paper opens can align journal entry with the slipped fill.
- **`Persistence::PaperStore`**: Tables include `paper_orders`, `paper_fills`, `paper_positions`, `paper_events`, `paper_account_snapshots` — see `lib/coindcx_bot/persistence/paper_store.rb` for the real schema.

### TUI

- **`Tui::DeskViewModel`**: Pure projection from **`Engine#snapshot`** + **`TickStore#snapshot`** (execution rows, order flow with **working-age ms** from **`paper_orders.created_at`** via **`OrderBook#working_snapshot`**, depth rows, risk helpers).
- **`Tui::TickStore`**: Mutex-backed; WebSocket ticks forwarded from the engine (`forward_tick_to_store` / `mirror_tracker_into_tick_store`). Keys symbols with **`to_s`**; if **`change_pct`** or **bid/ask** are **`nil`** on update, **reuses** the previous value where applicable. **`stale?`** uses the same keying.
- **`Tui::LtpRestPoller`**: Periodically batch-fetches **`MarketDataGateway#fetch_futures_rt_quotes`** (public RT snapshot; **`Dto::Tick`** may carry **bid/ask** when the wire includes them) and writes **`TickStore`**; falls back per pair to **`fetch_instrument_display_quote`** (optional bid/ask on instrument payload).
- **`Tui::RenderLoop`**: Timer-driven redraw (~250ms); **skips terminal writes** when a panel’s rendered frame string is unchanged (still calls **`render`** to build the frame).
- **`HeaderPanel`**: Dense status strip (mode, engine, kill, WS/LAT, feed, BAL/NET, paper REAL/UNREAL, DD%, risk band, POS/ORD/ERR/LAST event).
- **`DeskExecutionOrderPanel`**: Per-symbol execution matrix + **`tui_working_orders`** order flow (type abbr, ACTIVE, **LAT** = ms since order row creation when **`placed_at`** is present).
- **`DeskMarketDepthPanel`**: SYMBOL / BID / ASK / SPREAD / Δ% / AGE / STATE from **`TickStore`** + **`ws_feed_stale?`** (spread populated only when bid and ask exist).
- **`DeskRiskStrategyPanel`**: Daily loss cap vs current loss, utilization, paper slippage aggregate, strategy name (config); placeholder strategy state/signal until the engine exposes them.
- **`EventLogPanel`**: Last rows from journal **`recent_events`** (via snapshot).
- **`KeybarPanel`**: Command-bus hints and footer (poll interval, render wake).
- **`Tui::App`**: `COINDCX_TUI_POLL_ONLY=1` disables interactive keys.
- **`Execution::OrderBook::WorkingOrder`**: Includes **`placed_at`** (from store **`created_at`** or **`Time.now`** on synthetic **`add`**) for TUI age display.

### Other

- **Pluggable strategies** (`trend_continuation`, `supertrend_profit`) and **Ruby 3 / Socket.IO URI compat** shim (README + specs).
- **`Core::EventBus`**: Used for tick distribution.

### Tests (representative)

- Specs exist for `FillEngine`, `PaperBroker`, `PaperStore`, `Coordinator`, TUI pieces, gateways, etc.

---

## What older drafts had wrong or obsolete

| Old draft claim | Actual repo |
|-----------------|------------|
| `Broker` as a module with `Fill` and `process_tick` | Abstract **class** `Broker`; no `process_tick` |
| `Coordinator` still `order_gateway:` + `account_gateway:` | **`broker:`** only |
| `Portfolio::PnlCalculator` | **Not present** |
| `execution/order_book.rb` | **Present** — `Execution::OrderBook` (see `paper_broker_simulation.md`) |
| `journal#update_position_entry_price` for paper fills | **Both** — journal is updated after paper open to match slipped fill; **`PaperStore`** still tracks paper positions separately |
| Engine `tick_cycle` never calls `process_tick` | **`run_paper_process_tick`** runs when **`@broker.paper?`** |
| Separate `OrdersPanel` / `PnlPanel` | **Not present** |
| Long pasted `PaperStore` SQL | **Different** real schema |

---

## Known gaps and risks (remaining)

1. **Two position ledgers** — journal and `paper_positions` are still separate stores; after a paper **open**, journal **entry** matches the fill, but lifecycle bugs could desync until closed.
2. **Flatten without LTP** — if neither WS LTP nor exec candle exists for a pair, **journal** is flattened but **paper** may stay open (logged warning).
3. **Paper exchange vs journal** — with **`GatewayPaperBroker`**, positions live in the simulator DB; keep journal and simulator state mentally separate when debugging.
4. **Trailing stops** — journal only; no paper stop orders.
5. **`paper_account_snapshots`** — not wired to a periodic writer in the engine.

---

## Architecture note (TUI vs engine)

The TUI reads LTP / CHG% from **`TickStore`**, refreshed by **WebSocket** mirroring and **`LtpRestPoller`** (REST). The engine snapshot uses **`PositionTracker`** (journal-backed). **`mirror_tracker_into_tick_store`** will not overwrite **`TickStore`** with an older timestamp when REST has already updated the row. Trading decisions must stay on engine/journal/tracker inputs.

---

## References

- [`docs/paper_exchange.md`](paper_exchange.md) — HTTP paper exchange setup and routes.
- [`docs/paper_broker_simulation.md`](paper_broker_simulation.md) — phased plan for in-process **`PaperBroker`** (working orders, journal sync).
- [`CHANGELOG.md`](../CHANGELOG.md) — release-style summary of recent work.
- `lib/coindcx_bot/core/engine.rb`
- `lib/coindcx_bot/execution/coordinator.rb`
- `lib/coindcx_bot/execution/paper_broker.rb`
- `lib/coindcx_bot/execution/gateway_paper_broker.rb`
- `lib/coindcx_bot/persistence/paper_store.rb`
- `lib/coindcx_bot/tui/app.rb`
- `config/bot.yml.example`

---

# Follow-up plan (not yet implemented)

- **Coordinator journal sync on deferred paper fills** — align journal rows when working orders fill on a later tick (`paper_broker_simulation.md` Phase C).
- **TUI** — optional fills / orders panel from `PaperStore` or snapshot.
- **OCO / brackets** — partial schema; behavior still evolving.

**Done (ledger consistency):** engine supplies **`ltps`** for flatten (tracker → exec candle); paper **`flatten_all`** closes **`PaperStore`** when LTP present; **`PaperBroker#close_position`** returns **`{ ok:, realized_pnl_usdt:, fill_price:, position_id: }`**; coordinator books INR from that USDT once per close; journal **`entry_price`** updated after paper open to match slipped fill; specs cover flatten, PnL, and missing LTP degradation.
