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
- **`Execution::Coordinator`**: Takes **`broker:`** (not `order_gateway:` + `account_gateway:`). Branches paper vs live for open/close; still journals positions for strategy/risk.

### Engine

- Builds **`@broker`** via `build_broker`; passes it to the coordinator.
- **`#snapshot`**: Includes **`paper_metrics`** when the broker is paper: merges `@broker.metrics` with **`unrealized_pnl`** from `@broker.unrealized_pnl(ltp_map)` (`paper_snapshot_metrics`).
- **No `process_tick` on the engine loop**: Working orders are not advanced on a separate tick phase; see gaps below.

### Paper simulation scope (today)

- **Market-style fills only** via `FillEngine#fill_market_order` (immediate fill in `PaperBroker#place_order` / `#close_position`).
- **No** separate `order_book.rb`, **no** limit/stop/take-profit evaluation on ticks, **no** OCO groups in the shipped schema.

### Persistence

- **`Persistence::Journal`**: Bot journal (positions for strategy, daily PnL INR, events). Still the source for `PositionTracker#open_position_for`.
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
| `journal#update_position_entry_price` for paper fills | Paper uses **`PaperStore#update_position_entry_price`** |
| Engine `tick_cycle` calls `broker.process_tick` + `handle_fill` | **Not implemented** |
| Separate `OrdersPanel` / `PnlPanel` | **Not present** |
| Long pasted `PaperStore` SQL | **Different** real schema |

---

## Known gaps and risks

1. **Two position ledgers in paper mode** — journal vs `paper_positions`; entry prices can diverge (signal LTP vs slipped fill).
2. **Flatten in paper** — `Coordinator#flatten_pair` skips broker close when paper; **journal** closes but **paper SQLite positions may remain open**.
3. **Double PnL paths on paper close** — `PaperBroker` realizes in store; `Coordinator#record_paper_realized_pnl` books INR from journal; confirm no double-count for reporting.
4. **No working-order / next-tick model** — immediate fills only.
5. **Trailing stops** — journal only; no paper stop orders.
6. **`paper_account_snapshots`** — not clearly wired to a periodic writer in the engine.

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

# Plan — close paper-mode gaps (implementation not started here)

This section follows the workspace planning format: **goal → assumptions → files → risks → slices → verification → open questions**. No code changes are implied until you approve a slice.

## 1. Goal

Make **paper mode** internally consistent: flatten and closes keep **journal** and **`PaperStore`** aligned; **one clear rule** for where entry/exit prices and daily PnL come from; optional later slices add working orders / TUI depth.

## 2. Assumptions

- Strategy and risk continue to use **`Journal` + `PositionTracker`** for open positions in both live and paper unless you explicitly migrate strategy to read `PaperStore`.
- **`PaperStore`** remains the audit trail for simulated orders/fills/fees/slippage.
- Breaking changes to public Ruby APIs are acceptable only with spec updates in the same slice.

## 3. Relevant files

| Area | Path |
|------|------|
| Flatten / close orchestration | `lib/coindcx_bot/execution/coordinator.rb` |
| Paper fills / positions | `lib/coindcx_bot/execution/paper_broker.rb` |
| Paper SQLite | `lib/coindcx_bot/persistence/paper_store.rb` |
| Engine snapshot / broker wiring | `lib/coindcx_bot/core/engine.rb` |
| Journal | `lib/coindcx_bot/persistence/journal.rb` |
| TUI | `lib/coindcx_bot/tui/panels/status_panel.rb`, `lib/coindcx_bot/tui/app.rb` |
| Specs | `spec/coindcx_bot/execution/coordinator_spec.rb`, `spec/coindcx_bot/execution/paper_broker_spec.rb` |

## 4. Risks

| Risk | Mitigation |
|------|------------|
| Double-counting INR daily PnL | Pick a single booking path for paper closes (journal vs paper-derived); add a spec that asserts one increment per closed trade. |
| Flatten leaves orphan `paper_positions` | Integration spec: open in paper → flatten → assert `paper_positions` empty or closed and journal empty. |
| Changing close order breaks live | Gate all behavior behind `broker.paper?`; live path unchanged in slice 1. |
| Large “OCO + order book” slice delays fixes | Defer working orders until ledger consistency is done. |

## 5. Implementation slices

**Slice A — Paper flatten / close uses broker (smallest)**  
- On `flatten_pair` when `broker.paper?`, resolve LTP per pair (from tracker or last known — **open question**: engine must pass LTP or coordinator reads tracker; today coordinator has no tracker reference).  
- Call `PaperBroker#close_position` for each open **paper** position before or while clearing journal rows.  
- **Unknown**: Coordinator does not hold `PositionTracker`; may need `ltp:` passed from engine into `flatten_all` / `flatten_pair`, or inject tracker into coordinator for paper only.

**Slice B — Single PnL booking rule for paper**  
- Document and implement: either (B1) journal daily PnL from paper fill metadata only, or (B2) stop calling `record_paper_realized_pnl` when `PaperBroker` already booked equivalent.  
- Add coordinator + paper_broker specs for one close → one INR delta.

**Slice C — Journal entry price vs fill (optional)**  
- After paper entry fill, update journal `entry_price` to slipped fill (new journal method or reuse pattern from paper store). Keeps risk/strategy math closer to simulated execution.

**Slice D — TUI (optional)**  
- Small panel or status line: last N fills from `PaperStore` or snapshot expansion; no change to engine tick model.

**Slice E — Working orders / `process_tick` (later)**  
- New internal APIs, engine tick hook, `FillEngine` extensions, schema if needed. Only after A–B stable.

## 6. Verification steps

- `bundle exec rspec` green for touched specs.
- Manual: `bin/bot tui` with `dry_run: true` — open, flatten, confirm journal and paper DB agree (inspect `data/paper_trading.sqlite3` if needed).
- If slice B touches PnL: assert `daily_pnl_inr` and paper `total_realized_pnl` relationship with a concrete example in spec.

## 7. Open questions

1. Should **flatten** use **last journal LTP**, **last WS tick**, or **candle close** when flattening paper without a fresh tick?  
2. Is **daily PnL in INR** authoritative in the **journal** only, with paper store purely USDT, or should one derive from the other?  
3. Do you want **Slice A** to require an **engine API change** (`flatten_all!(ltps:)`), or **inject** `PositionTracker` (or a small `LtpProvider`) into `Coordinator`?

---

When a slice is approved, implement it in one PR with tests; then update the “Known gaps” section above to reflect what was fixed.
