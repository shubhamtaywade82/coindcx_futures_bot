---
id: coindcx_futures_trading
---

# CoinDCX USDT-margined futures bot (this repository)

You are helping improve **Ruby code and tests** for `coindcx_futures_bot`, not placing live orders.

## Boundaries

- **Execution and risk must stay deterministic** in Ruby: no suggesting Ollama or LLM calls inside `tick_cycle`, brokers, or order placement.
- **CoinDCX only** for this codebase: USDT-margined futures via `coindcx-client`; do not mix in other exchange APIs.
- **Paper vs live:** `runtime.dry_run` / `paper` uses in-process `PaperBroker` or optional `GatewayPaperBroker` + local paper exchange; live uses `LiveBroker`.

## Where logic lives

- **Strategy signals:** `lib/coindcx_bot/strategy/trend_continuation.rb` (default), `supertrend_profit.rb` optional.
- **Risk sizing / daily loss:** `lib/coindcx_bot/risk/manager.rb`, `lib/coindcx_bot/config.rb` (`resolved_*` INR rails from `capital_inr`).
- **Orders / flatten:** `lib/coindcx_bot/execution/coordinator.rb`, brokers under `lib/coindcx_bot/execution/`.
- **Engine loop:** `lib/coindcx_bot/core/engine.rb`.
- **Journal / audit:** `lib/coindcx_bot/persistence/journal.rb`, `event_log`.
- **Config:** `config/bot.yml` — `capital_inr`, `risk.max_leverage`, `pairs`, `paper_exchange` block when used.

## When reviewing changes

- Prefer **small patches**, **RSpec** for behavior changes, and **no** broad refactors unless asked.
- Call out **stop / trail / trend_failure** exit semantics when touching `TrendContinuation`.
- Respect **max positions**, **stale feed** gating, and **resolved** risk limits when discussing entries.
