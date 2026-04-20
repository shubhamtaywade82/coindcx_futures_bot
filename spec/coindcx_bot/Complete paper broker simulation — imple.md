Complete paper broker simulation — implementation plan

  Current baseline

  • `FillEngine`: `fill_market_order` only.
  • `PaperBroker`: synchronous fill in `place_order` / `close_position`.
  • `PaperStore`: paper_orders has `price`, `quantity`, `order_type`, `status` — no limit_price, stop_price, group_id, or bar-range fill metadata.
  • `Broker`: no process_tick; `Engine#tick_cycle` does not advance working orders.
  • Trailing (`Coordinator#trail_stop`): journal only; paper has no working stop to update.

  ┌─────────────────────────┬──────────────────────────────────────┐
  │          Today          │  Target                              │
  │                         │                                      │
  │                         │                                      │
  │ ┌─────────────────────┐ │ ┌──────────────────────────────────┐ │
  │ │                     │ │ │                                  │ │
  │ │     place_order     │ │ │           place_order            │ │
  │ │                     │ │ │                                  │ │
  │ └──────────┬──────────┘ │ └─────────────────┬────────────────┘ │
  │            ▼            │                   ▼                  │
  │ ┌─────────────────────┐ │ ┌──────────────────────────────────┐ │
  │ │                     │ │ │                                  │ │
  │ │    immediate fill   │ │ │ working orders store + OrderBook │ │
  │ │                     │ │ │                                  │ │
  │ └──────────┬──────────┘ │ └─────────────────┬────────────────┘ │
  │            ▼            │                   ▼                  │
  │ ┌─────────────────────┐ │ ┌──────────────────────────────────┐ │
  │ │                     │ │ │                                  │ │
  │ │   paper_positions   │ │ │           process_tick           │ │
  │ │                     │ │ │                                  │ │
  │ └─────────────────────┘ │ └─────────────────┬────────────────┘ │
  │                         │                   │                  │
  ├─┬─────────────────────┬─┘                   │                  │
  │ │                     │                     │                  │
  │ │ FillEngine.evaluate │◄────────────────────┘                  │
  │ │                     │                                        │
  │ └──────────┬──────────┘                                        │
  │            ▼                                                   │
  │ ┌─────────────────────┐                                        │
  │ │                     │                                        │
  │ │   fill + positions  │                                        │
  │ │                     │                                        │
  │ └─────────────────────┘                                        │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘
  ctrl+o to show source

  Goal

  Deterministic, restart-safe paper trading that can:

  1. Keep working orders until conditions are met.
  2. Fill market (config: same tick vs next tick), limit, stop / stop-market, take-profit using LTP and, where available, bar high/low.
  3. Optional OCO / bracket (entry + SL + TP; cancel sibling on fill).
  4. Trailing by updating the working SL (wired from trail_stop).
  5. Leave live `LiveBroker` unchanged; paper-only behavior behind broker.paper?.

  Non-goals (explicit)

  • Funding, liquidation, margin utilization, book depth.
  • Partial fills (optional later phase only).
  • Full CoinDCX order surface — map the subset this bot actually sends via `OrderGateway` / coordinator.

  ────────────────────────────────────────

  Phase A — Schema and persistence

  Extend `PaperStore` migrations (idempotent, e.g. PRAGMA user_version or “migrate if column missing”):
  • paper_orders: add `limit_price`, `stop_price`, `group_id`, `group_role`, `metadata` JSON, timestamps as needed; define meaning of existing `price`
     (e.g. anchor LTP at submit vs limit/stop for triggers).
  • New `paper_order_groups`: pair, status (active / completed), entry_order_id, sl_order_id, tp_order_id, timestamps.
  • Optional: paper_fills `trigger` enum string (market_order, limit, sl, tp).

  On `PaperBroker` boot: rebuild an in-memory `Execution::OrderBook` from rows with working-like statuses (new / accepted / working — pick one
  vocabulary and stick to it).

  ────────────────────────────────────────

  Phase B — Order book and fill engine

  • `Execution::OrderBook` (new file): thread-safe id -> WorkingOrder; add, remove, working_for(pair), update_stop(id, new_stop).
  • `FillEngine#evaluate(order, ltp:, high:, low:)` → nil or { fill_price:, quantity:, fee:, slippage:, trigger: }.
    • Reuse slippage for market-like fills; limits at limit price (slippage 0 unless you add a knob).
    • Stop/TP: explicit touch rules (e.g. long SL: bar low or LTP crosses stop — document and test).
  • `PaperBroker#process_tick(pair:, ltp:, high:, low:)`: scan working orders for pair, evaluate, persist fills, update positions, return list of fill
     events for the coordinator.

  `Broker` base: add `process_tick(...)` default `[]`. `LiveBroker` returns `[]`.

  ────────────────────────────────────────

  Phase C — Engine wiring

  In `Engine#tick_cycle`, before process_pair (after candles/tracker refresh):
  • If @broker.paper?, for each pair: ltp from tracker; `high` / `low` from latest execution candle when present (same family as stale refresh).
  • Call @broker.process_tick(...).
  • For each fill, call `Coordinator#handle_paper_fill` (new) to keep journal aligned with paper_positions (open on entry fill, update entry, close +
    INR on exit fill — single place for this logic).

  Order: process_tick before strategy so exits can fill on the same cycle as new signals.

  ────────────────────────────────────────

  Phase D — Coordinator / strategy contract (highest risk)

  • Paper `place_order`: create working order + persist + OrderBook.add; avoid opening a journal row until entry fill unless you keep a
    `paper.instant_market: true` (or fill_timing: instant_market) compatibility mode for one release.
  • Paper `close_position`: enqueue market exit as working order filled on `process_tick`, or keep synchronous close for flatten/emergency (document;
    flatten already passes LTP).
  • `trail_stop`: if paper, call `PaperBroker#update_trailing_stop` (or similar) when you can resolve SL order id (metadata or OCO group).

  Risk: Today the journal row exists immediately on open; “complete” sim usually means journal follows fills. That will break/update many paper specs
  and any implicit “open → instant position” assumptions.

  ────────────────────────────────────────

  Phase E — OCO / brackets

  • Create group row + three orders when coordinator/strategy places brackets (if live does not place them yet, implement paper API + persistence
    first, wire strategy later).
  • On SL or TP fill: cancel sibling in DB + OrderBook, complete group.

  ────────────────────────────────────────

  Phase F — TUI and metrics

  • Extend `paper_metrics` (engine snapshot) with working-order count, recent fills, optional group summary.
  • `StatusPanel` and/or small orders strip in `Tui::App`.

  ────────────────────────────────────────

  Phase G — Config and docs

  In `paper:` (`config/bot.yml.example`):
  • fill_timing: instant_market | next_tick (or booleans).
  • use_bar_range: true for limit/stop using high/low.
  • Keep slippage_bps, fee_bps.

  Update README with semantics and limitations.

  ────────────────────────────────────────

  Verification

  • RSpec: FillEngine (all order types, long/short); OrderBook; PaperBroker#process_tick + restart reconcile; coordinator fill-driven journal; live
    specs unchanged.
  • Manual: TUI — see working order then fill; optional WS-off + candle-driven touch test.

  ────────────────────────────────────────

  Risks and mitigations

  ┌────────────────────────┬────────────────────────────────────────────────┐
  │ Risk                   │ Mitigation                                     │
  ├────────────────────────┼────────────────────────────────────────────────┤
  │ Journal vs paper drift │ One `handle_paper_fill`; heavy integration tests │
  │ Existing users/tests   │ Short-lived `instant_market` compat flag         │
  │ SQLite upgrades        │ Idempotent migrations + version                │
  │ Wrong stop logic       │ Table-driven examples + docs                   │
  └────────────────────────┴────────────────────────────────────────────────┘

  ────────────────────────────────────────

  Recommended build order

  1. Schema + OrderBook + reconcile (no visible behavior change).
  2. process_tick + FillEngine#evaluate + engine loop (paper only).
  3. Market next-tick + `handle_paper_fill` + journal-on-fill.
  4. Limit / stop / TP + tests.
  5. OCO + cancel sibling.
  6. Trailing wire-up.
  7. TUI + config + README.

  ────────────────────────────────────────

  Open decisions (answer before coding)

  1. Journal: move paper to journal rows only after fill (recommended for “complete”), or keep immediate journal + patch on fill?
  2. Bar range: require execution candle high/low for limits/stops in v1, or LTP-only first slice?
  3. Brackets: does live currently place SL/TP orders? If not, is OCO paper-only until live catches up?

  ────────────────────────────────────────

  Suggested todos (for tracking)

  1. schema-orderbook — Migrations + OrderBook + reconcile on boot.
  2. fill-engine-tick — FillEngine#evaluate, PaperBroker#process_tick, Broker#process_tick / LiveBroker [].
  3. engine-coordinator — Engine calls process_tick; handle_paper_fill; paper lifecycle + fill_timing config.
  4. order-types-oco — Limit/stop/TP + OCO sibling cancel + tests.
  5. trailing-tui-config — Trailing SL updates, TUI/metrics, YAML + README.

  If you answer the three open decisions, the first slice can be scoped without rework.
