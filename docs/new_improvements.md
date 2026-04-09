# Improvements backlog — aligned with current codebase

This file replaces an earlier draft (`new_improvments.md`) that mixed chat transcripts, speculative designs, and APIs that do **not** exist in this repository. The sections below reflect the **actual** layout under `lib/coindcx_bot/` as of this branch.

---

## What is already implemented

### Runtime and config

- **`runtime.dry_run` / `runtime.paper`**: `Config#dry_run?` is true if either flag is set (`lib/coindcx_bot/config.rb`).
- **`paper:` config block**: `slippage_bps`, `fee_bps`, `db_path` — documented in `config/bot.yml.example` and read in `Core::Engine#build_broker`.
- **`Config#paper_config`**: Returns the raw `paper` hash from YAML (defaults are applied in the engine for slippage/fee/db_path, not merged in `paper_config` itself).

### Execution layer

- **`Execution::Broker`** (abstract **class**): `place_order`, `cancel_order`, `open_positions`, `open_position_for`, `close_position`, `paper?`, `metrics` — not a `module Broker` with `Fill` + `process_tick` from older drafts.
- **`Execution::LiveBroker`**: Wraps `OrderGateway` / `AccountGateway`; uses the journal for open positions; exits via account gateway.
- **`Execution::PaperBroker`**: Persists orders, fills, positions, events, and optional account snapshots in **`Persistence::PaperStore`** (separate SQLite file from the bot journal). Uses **`Execution::FillEngine#fill_market_order`** for slippage and fees on each fill.
- **`Execution::Coordinator`**: Takes **`broker:`** (not `order_gateway:` + `account_gateway:`). Branches paper vs live for open/close; still journals positions for strategy/risk. **`flatten_all(pairs, ltps: {})`** — in paper mode, uses **`ltps`** to close **`PaperStore`** positions before clearing the journal; daily INR on paper closes comes from **`PaperBroker`** realized USDT × `inr_per_usdt` (single path).

### Engine

- Builds **`@broker`** via `build_broker`; passes it to the coordinator.
- **`flatten_all!`**: Builds **`ltps`** per pair from **`PositionTracker`** then **execution candle close** fallback, passes them to **`Coordinator#flatten_all`**.
- **`#snapshot`**: Includes **`paper_metrics`** when the broker is paper: merges `@broker.metrics` with **`unrealized_pnl`** from `@broker.unrealized_pnl(ltp_map)` (`paper_snapshot_metrics`).
- **No `process_tick` on the engine loop**: Working orders are not advanced on a separate tick phase; see gaps below.

### Paper simulation scope (today)

- **Market-style fills only** via `FillEngine#fill_market_order` (immediate fill in `PaperBroker#place_order` / `#close_position`).
- **No** separate `order_book.rb`, **no** limit/stop/take-profit evaluation on ticks, **no** OCO groups in the shipped schema.

### Persistence

- **`Persistence::Journal`**: Bot journal (positions for strategy, daily PnL INR, events). Still the source for `PositionTracker#open_position_for`. Supports **`update_position_entry_price`** so paper opens can align journal entry with the slipped fill.
- **`Persistence::PaperStore`**: Tables include `paper_orders`, `paper_fills`, `paper_positions`, `paper_events`, `paper_account_snapshots` — see `lib/coindcx_bot/persistence/paper_store.rb` for the real schema.

### TUI

- **`Tui::TickStore`**: Mutex-backed; WebSocket ticks forwarded from the engine (`forward_tick_to_store` / `mirror_tracker_into_tick_store`).
- **`Tui::RenderLoop`**: Timer-driven redraw (~250ms); panels use `TTY::Cursor` and buffered `StringIO` output.
- **`LtpPanel`**: In-place LTP rows, stale marking, **2-decimal** LTP.
- **`StatusPanel`**: Mode, engine status, **journal** positions line, daily PnL, errors; extra **`paper_metrics_line`** in paper mode.
- **`Tui::App`**: `COINDCX_TUI_POLL_ONLY=1` disables interactive keys.
- **No** separate `OrdersPanel` / `PnlPanel`; paper extras are in **StatusPanel**.

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
| `execution/order_book.rb` | **Not present** |
| `journal#update_position_entry_price` for paper fills | **Both** — journal is updated after paper open to match slipped fill; **`PaperStore`** still tracks paper positions separately |
| Engine `tick_cycle` calls `broker.process_tick` + `handle_fill` | **Not implemented** |
| Separate `OrdersPanel` / `PnlPanel` | **Not present** |
| Long pasted `PaperStore` SQL | **Different** real schema |

---

## Known gaps and risks (remaining)

1. **Two position ledgers** — journal and `paper_positions` are still separate stores; after a paper **open**, journal **entry** matches the fill, but lifecycle bugs could desync until closed.
2. **Flatten without LTP** — if neither WS LTP nor exec candle exists for a pair, **journal** is flattened but **paper** may stay open (logged warning).
3. **No working-order / next-tick model** — immediate market fills only.
4. **Trailing stops** — journal only; no paper stop orders.
5. **`paper_account_snapshots`** — not wired to a periodic writer in the engine.

---

## Architecture note (TUI vs engine)

The TUI reads LTP from **`TickStore`**; the engine snapshot uses **`PositionTracker`** (journal-backed). Both are fed from the same WS path with mirroring for cold/stale cases. Trading decisions must stay on engine/journal/tracker inputs.

---

## References

- `lib/coindcx_bot/core/engine.rb`
- `lib/coindcx_bot/execution/coordinator.rb`
- `lib/coindcx_bot/execution/paper_broker.rb`
- `lib/coindcx_bot/persistence/paper_store.rb`
- `lib/coindcx_bot/tui/app.rb`
- `config/bot.yml.example`

---

# Follow-up plan (not yet implemented)

- **Working orders / `process_tick`** — queue market/limit/stop fills on subsequent ticks; extend `FillEngine` and `PaperStore` as needed.
- **TUI** — optional fills / orders panel from `PaperStore` or snapshot.
- **OCO / brackets** — not started.

**Done (ledger consistency):** engine supplies **`ltps`** for flatten (tracker → exec candle); paper **`flatten_all`** closes **`PaperStore`** when LTP present; **`PaperBroker#close_position`** returns **`{ ok:, realized_pnl_usdt:, fill_price:, position_id: }`**; coordinator books INR from that USDT once per close; journal **`entry_price`** updated after paper open to match slipped fill; specs cover flatten, PnL, and missing LTP degradation.
