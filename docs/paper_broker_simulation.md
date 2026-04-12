# Paper broker simulation — roadmap and phases

**HTTP paper exchange (optional):** A separate **CoinDCX-shaped REST** simulator (`bin/paper-exchange`, `CoindcxBot::PaperExchange::*`) integrates via **`Execution::GatewayPaperBroker`** when `paper_exchange.enabled` is set. That path uses HTTP order/account APIs and **signed `POST …/simulation/tick`** for fill simulation. Operator guide: [`paper_exchange.md`](paper_exchange.md). The phases below focus mainly on the **in-process** [`PaperBroker`](../lib/coindcx_bot/execution/paper_broker.rb) + [`PaperStore`](../lib/coindcx_bot/persistence/paper_store.rb) stack.

This document is the **source of truth** for turning the current **immediate-fill** paper broker into a **working-order, tick-driven** simulator. Implement **one phase at a time**; update the **status** lines below as you complete each phase.

**Next step:** Phase D+ (limit/stop matrix, OCO on HTTP path) or optional `paper.fill_timing`; tick-driven **exit** journal sync is done for both in-process and gateway paper.

**Related code today:** [`PaperBroker`](../lib/coindcx_bot/execution/paper_broker.rb), [`GatewayPaperBroker`](../lib/coindcx_bot/execution/gateway_paper_broker.rb), [`FillEngine`](../lib/coindcx_bot/execution/fill_engine.rb), [`PaperStore`](../lib/coindcx_bot/persistence/paper_store.rb), [`Coordinator`](../lib/coindcx_bot/execution/coordinator.rb), [`Engine`](../lib/coindcx_bot/core/engine.rb).

---

## Status

| Phase | Description | Status |
|-------|-------------|--------|
| **A** | Schema migrations, `paper_order_groups`, extended `insert_order` / `insert_fill`, `OrderBook`, reconcile on `PaperBroker` boot | **Done** |
| **B** | `FillEngine#evaluate`, `PaperBroker#process_tick`, `Broker#process_tick` (live returns `[]`) | **Done** |
| **C** | Engine `tick_cycle` calls `process_tick`; journal sync when tick-driven exits fill | **Done (exits)** — `Coordinator#handle_broker_exit` + `Engine#run_paper_process_tick`; in-process `PaperBroker` returns `kind: :exit`; HTTP paper returns `position_exits` on `POST …/simulation/tick` and `GatewayPaperBroker#process_tick` maps them. Optional: `paper.fill_timing`; deferred **entry** on HTTP still unsupported (see below). |
| **D** | Limit / stop / take-profit touch rules + RSpec matrix | Planned |
| **E** | OCO / `paper_order_groups` API, cancel sibling on fill | Planned |
| **F** | Trailing → `OrderBook#update_stop` + store persist | Planned |
| **G** | TUI / `paper_metrics`, `config/bot.yml.example`, README | Planned |

---

## Design goals

1. **Deterministic** fills from the same ticks and config.
2. **Restart-safe:** working orders live in SQLite; in-memory `OrderBook` rebuilt on boot.
3. **Live path unchanged:** only `PaperBroker` + engine `broker.paper?` branches grow.
4. **Journal stays strategy-facing:** tick-driven **full position closes** sync to the journal (Phase C exits); deferred limit **entries** on the HTTP simulator do not insert journal rows yet.

---

## Phase A — Schema + OrderBook + reconcile

**Delivered:**

- `paper_orders`: optional `limit_price`, `stop_price`, `group_id`, `group_role`, `metadata` (JSON text). Existing DBs upgraded via `ALTER TABLE` when columns are missing.
- `paper_fills`: optional `trigger` (`market_order`, later `limit`, `sl`, `tp`, …).
- `paper_order_groups`: table created for Phase E (OCO); unused until then.
- [`Execution::OrderBook`](../lib/coindcx_bot/execution/order_book.rb): mutex-backed working set; `reconcile_from_store`, `add`, `remove`, `working_for`, `update_stop`, `clear`, `size`.
- `PaperStore#working_orders` — rows with `status IN ('new','working','accepted')`.
- `PaperBroker` on `initialize`: `reconcile_order_book` loads working orders from the store (today usually **zero** while all orders still fill immediately).

**Order status vocabulary (convention):**

- `new` / `working` / `accepted` — eligible for `OrderBook` + future `process_tick`.
- `filled`, `canceled`, `rejected` — terminal.

---

## Phase B — Fill engine + `process_tick` (**done**)

- `FillEngine#evaluate(working_order, ltp:, high:, low:)` returns a fill hash or `nil` (market, limit, stop / take-profit).
- `PaperBroker#process_tick` iterates `OrderBook.working_for(pair)`, persists fills, updates positions; returns result rows for coordinator use later.
- `Broker#process_tick` → `[]`; live path unchanged.

---

## Phase C — Engine + coordinator (**exit sync done**)

- **Done:** `Engine#tick_cycle` runs `run_paper_process_tick` after mirroring the tracker: per pair, `@broker.process_tick` with execution candle high/low when available.
- **Done:** `Coordinator#handle_broker_exit` closes the journal row and books INR when results include `kind: :exit` (same shape for `PaperBroker` and `GatewayPaperBroker`).
- **HTTP paper:** `OrdersService#process_tick` returns `position_exits` for fills that **fully** close an exchange position (partial closes do not emit a journal sync row). The Rack tick handler includes them in the JSON body; `GatewayPaperBroker` parses `position_exits` into engine rows.
- **Todo (optional):** `paper.fill_timing: instant_market | next_tick` for in-process market semantics.
- **Not done:** Deferred **entry** (working limit opens position on a later tick) on the **HTTP** path — no `handle_broker_entry`; journal can drift if you rely on resting entry orders only on the simulator. In-process `PaperBroker` `kind: :entry` from `process_tick` is still not wired to the journal.

---

## Phase D — Order types

- **Market:** same-tick vs next-tick per config.
- **Limit:** long buy fills when `low <= limit` or `ltp <= limit` (exact rules + tests).
- **Stop / TP:** symmetric rules for long/short; document assumptions.

---

## Phase E — OCO

- Create group row linking entry, SL, TP order ids.
- On SL or TP fill: cancel sibling order in DB + `OrderBook`, mark group completed.

---

## Phase F — Trailing

- `Coordinator#trail_stop` resolves paper SL order id (metadata or group) and calls `PaperBroker#update_trailing_stop` → store + `OrderBook#update_stop`.

---

## Phase G — UX and config

- Extend `paper_metrics` (working count, recent fills).
- `config/bot.yml.example` + README: semantics, limitations, non-goals (no funding, no liquidation, no book depth unless added later).

---

## Non-goals (unless explicitly added later)

- Funding, liquidation, margin utilization, order-book depth.
- Partial fills (optional future phase).
- Full CoinDCX order-type parity — only what this bot emits.

---

## Open decisions (record answers here when decided)

1. **Journal timing:** fill-only journal rows for paper vs immediate journal + patch on fill?
2. **Bar range:** require execution candle high/low for limits/stops in v1, or LTP-only first?
3. **Live brackets:** does live coordinator place SL/TP today? If not, OCO may be **paper-first**.

---

## References

- [`docs/paper_exchange.md`](paper_exchange.md) — HTTP CoinDCX-shaped simulator and `GatewayPaperBroker`.
- [`docs/new_improvements.md`](new_improvements.md) — inventory of what the codebase implements today.
