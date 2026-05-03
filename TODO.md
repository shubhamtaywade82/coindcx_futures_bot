# TODO

Master checklist for this Ruby repo. Mirrors structure of sibling JS/TS bot
(`../coindcx-bot/TODO.md`) but adapted to the Ruby stack:

- Ruby 3.3, RSpec, RuboCop, SQLite (`sqlite3` gem), TTY toolkit
- `coindcx-client` gem (path `../coindcx-client`) for REST + Socket.IO
- `ollama-client` / `ollama_agent` for local LLM regime + validation
- Single-process runtime (no Node sidecar, no Redis Streams) — channels via
  in-process pub/sub (`Smc::TradeSetupStore`, journal, etc.)

Use this file as single source of truth for execution tracking. Tick boxes
ONLY after verification evidence (test, smoke run, screenshot) exists.

Existing modules already on disk are pre-checked where the implementation is
clearly present. Re-verify before relying on a tick.

## A) Existing Plan Execution (F1-F4)

### A1. NOW (Critical Path)

- [x] PR-01 Foundation tooling baseline
  - [x] Ruby version pin (`Gemfile` `>= 3.3.4, < 3.4`)
  - [x] RuboCop config + `bundle exec rubocop` clean baseline (via `.rubocop_todo.yml`)
  - [x] RSpec wired (`spec/`)
  - [x] CI script (`bin/ci` + `rake ci`) running rubocop + rspec
  - [x] GitHub Actions workflow (`.github/workflows/ci.yml`)
  - [ ] Sanity spec passes from clean checkout — 12/35 still failing
    - [x] Mechanical Class A fixes applied (23 fixed). 578 examples → 12 failures.
    - [ ] header_panel content drift (9 specs) — production no longer emits literals `MODE:`, `ENGINE: RUN`, `LAT`, `SCALP`, `EXE·OFF`, `REGIME·ON`, `LEV:`, `WALLET USDT:`, `KILL: ON`. Needs content rewrite (Class B).
    - [ ] header_panel `row_count` (2 specs) — production hardcodes 6, specs want 4/5 conditional. Either bug or stale spec — needs decision.
    - [ ] live_account_mirror (1 spec) — `available_balance + locked` synthesis contradicts spec contract. Needs decision.

- [ ] PR-02 Config and logging core
  - [x] `lib/coindcx_bot/config.rb` schema + ENV via dotenv
  - [x] Secret redactor (`lib/coindcx_bot/logging/redactor.rb`) — keys + HMAC hex
  - [x] Central structured logger (`lib/coindcx_bot/logging/logger.rb`) wraps tty-logger + redactor
  - [x] Specs: redaction (5) + logger (3) green
  - [ ] Wire `Logging::Logger` into gateways/cli (replace ad-hoc `puts`/`warn`) — separate slice
  - [ ] Schema parsing/validation spec on `Config` — separate slice (1049 LoC, needs scoping)

- [ ] PR-03 Persistence bootstrap
  - [x] SQLite store (`lib/coindcx_bot/persistence/paper_store.rb`)
  - [x] Journal (`lib/coindcx_bot/persistence/journal.rb`)
  - [ ] Migration runner (idempotent schema bootstrap)
  - [ ] Schema covers: signals, trades, positions, risk_events, orderbook_snapshots
  - [ ] End-to-end migration smoke (`bin/console` boot)

- [ ] PR-04 Signal plumbing
  - [ ] Audit module (immutable signal log)
  - [x] SignalBus equivalent (`smc_setup/trade_setup_store.rb`)
  - [ ] StdoutSink + FileSink + bounded queue spec
  - [ ] Drop-policy spec (full queue behavior)

- [ ] PR-05 Safety controls
  - [ ] Telegram sink with token-bucket + retry
  - [ ] ReadOnlyGuard around `OrderGateway` writes
  - [ ] Mode flag wired (`paper|live`) and respected by `live_broker`
  - [ ] Spec: blocked write in read-only, allowed read

- [ ] PR-06 Runtime lifecycle
  - [x] CLI entrypoint (`lib/coindcx_bot/cli.rb`, `bin/`)
  - [ ] Resume cursors (last processed candle/order id)
  - [ ] Bootstrap + graceful shutdown (signal trap, drain queues)
  - [ ] Steady-state + shutdown smoke test
  - [ ] README run guide updated

### A2. NEXT (Core Product Capabilities)

- [ ] PR-07 Market data base contracts
  - [x] `gateways/market_data_gateway.rb`
  - [x] `gateways/ws_gateway.rb`
  - [ ] Candle/orderbook/trade DTOs frozen + spec'd
  - [ ] Multi-interval fetch with pagination (≤1000 bars/call)

- [ ] PR-08 Book integrity engine
  - [x] `orderflow/order_book_store.rb`
  - [ ] Snapshot + delta merge with `vs` gap detection
  - [ ] Resync on gap; expose health metric

- [ ] PR-09 Market health monitoring
  - [ ] WS heartbeat + staleness watchdog (>5s gap → risk_event)
  - [ ] Latency / disconnect counters surfaced in TUI
  - [ ] Pause-new-entries flag on degraded health

- [ ] PR-10 Market controller integration
  - [x] `orderflow/engine.rb`, `orderflow/recorder.rb`, `orderflow/replayer.rb`
  - [ ] Single controller fans out to strategy + persistence
  - [ ] Replay parity test (recorder → replayer → identical signals)

- [ ] PR-11 Account reconciler foundations
  - [x] `gateways/account_gateway.rb`
  - [x] `position_tracker.rb`
  - [ ] Periodic reconcile loop (active orders + positions snapshot)
  - [ ] Diff vs local state → emit deltas

- [ ] PR-12 Reconciliation safety logic
  - [ ] Idempotency keys (`client_order_id + event_id`)
  - [ ] Dedup unique index in SQLite
  - [ ] Partial-fill handling via `remaining_quantity`
  - [ ] Restart reconciliation path covered by spec

- [ ] PR-13 Reconcile orchestration
  - [x] `execution/coordinator.rb`, `execution/order_tracker.rb`
  - [ ] WS fill handler joins REST reconcile output
  - [ ] Orphan order cleanup policy

- [ ] PR-14 Account-state hardening
  - [ ] Margin/leverage state cached + refreshed on change
  - [x] `risk/margin_simulator.rb`
  - [ ] Cross-margin handling explicit

### A3. LATER (Strategy + Backtesting + Execution Rollout)

- [ ] PR-15 Strategy framework skeleton
  - [x] `strategy/signal.rb`, `strategy/indicators.rb`
  - [x] `smc_setup/states.rb`, `smc_setup/state_builder.rb`
  - [ ] Pluggable strategy registry

- [ ] PR-16 Strategy drivers
  - [x] `strategy/smc_confluence.rb`
  - [x] `strategy/trend_continuation.rb`
  - [x] `strategy/dynamic_trail.rb`, `strategy/hwm_*`, `strategy/supertrend_profit.rb`
  - [ ] Driver spec coverage per strategy

- [ ] PR-17 Built-in strategies finalized
  - [x] `strategy/regime_vol_tier.rb`, `strategy/meta_first_win.rb`
  - [ ] Parameter table documented per strategy

- [ ] PR-18 Backtest data sources
  - [x] `lib/coindcx_bot/backtest/` skeleton
  - [ ] Candle ingest with pagination + persistence
  - [ ] Multi-interval cache

- [ ] PR-19 Backtest execution engine
  - [ ] Event-driven simulator reusing prod signal funcs
  - [ ] Slippage + fee model
  - [ ] Deterministic seed + reproducibility test

- [ ] PR-20 Backtest verification
  - [ ] Metrics: win rate, avg R, profit factor, max DD, Calmar, Sharpe
  - [ ] Median time-to-1R + BE-lock-before-stop %
  - [ ] Walk-forward harness (6m IS / 1m OOS)

### A4. Roadmap Execution Slices

- [ ] PR-21 Slice 1 runtime wiring (signals → intents, execution OFF default)
- [ ] PR-22 Slice 2 risk sizing (`Risk::Manager` + risk budget)
- [ ] PR-23 Slice 3 paper execution (`PaperBroker` end-to-end)
- [ ] PR-24 Slice 4 order lifecycle persistence (journal → SQLite tables)
- [ ] PR-25 Slice 5 TUI execution panels (`lib/coindcx_bot/tui/`)
- [ ] PR-26 Slice 6 backtest execution model upgrade
- [ ] PR-27 Slice 7 live adapter behind strict safety gates (`live_broker`)
- [ ] PR-28 Slice 8 live canary controls (risk %, leverage cap, kill switch)

## B) Framework Coverage Checklist (PDF + SimplefiedSMCConcepts.md)

### B1. Exchange Surface and Protocol Requirements

- [ ] WebSocket client pinned via `coindcx-client` (Socket.IO 2.x compat)
  - [x] `socket_io_uri_compat.rb` shim present
  - [ ] Startup assertion: client version + protocol version
  - [ ] Handshake + event-receipt regression spec

- [ ] CoinDCX auth contract enforced for all private REST + private WS joins
  - [ ] `X-AUTH-APIKEY` header
  - [ ] `X-AUTH-SIGNATURE` HMAC-SHA256(secret, canonical JSON body)
  - [ ] `timestamp` field in body
  - [ ] Canonical JSON serialization spec
  - [ ] Clock-skew handling + retry guard

- [ ] `MarketCatalog` built/persisted from `/exchange/v1/markets_details`
  - [ ] Cache `pair ↔ symbol ↔ ecode ↔ precision ↔ step ↔ min_notional ↔ max_leverage`
  - [ ] Refresh job + stale-data alert

- [ ] Spot REST wrappers + smoke specs (provided by `coindcx-client`)
  - [ ] Public: ticker, markets, markets_details, trade_history, orderbook, candles
  - [ ] Account: balances, user info, create, status, status_multiple, active_orders
  - [ ] History/cancel/edit: trade_history, cancel, cancel_all, cancel_by_ids, edit
  - [ ] Wallet: transfer, sub_account_transfer
  - [ ] Optional: margin endpoints, lend endpoints
  - [ ] Rate-limit guard (`cancel_all` 30/60s)

- [ ] Futures REST endpoint capture + hardening
  - [x] `compass_artifact_*.md` + `docs/` reference captured
  - [x] `config/coindcx_futures_endpoints.yml` (verify exists)
  - [ ] Reject third-party gists as truth source
  - [ ] Wrappers covered:
    - [ ] instruments active/details/realtime trades/orderbook/candles
    - [ ] orders list/create/cancel/edit
    - [ ] positions list/get/update leverage
    - [ ] add/remove margin
    - [ ] cancel-all variants + exit position
    - [ ] TP/SL order create (`untriggered` status support)
    - [ ] transactions/trades/current prices/pair stats
    - [ ] cross margin details
    - [ ] wallet transfer/details/transactions
    - [ ] change margin type
    - [ ] currency conversion

- [ ] Spot WebSocket channels + handlers
  - [ ] Private: `balance-update`, `order-update`, `trade-update` on `coindcx`
  - [ ] Public: candlestick, depth-snapshot, depth-update, currentPrices,
        priceStats, new-trade, price-change
  - [ ] Join/leave multiplexing

- [ ] Futures WebSocket coverage
  - [x] `gateways/ws_gateway.rb` skeleton
  - [ ] Confirm exact futures channel strings against authenticated docs
  - [ ] Handlers: account/position/order/balance/candlestick/orderbook/
        current prices/new trade/LTP
  - [ ] Channel mapping doc with examples

- [ ] Explicit data-gap strategy for missing endpoints/streams
  - [ ] Mark price = last price policy
  - [x] `synthetic_l1.rb` synthetic basis-derived funding estimate
  - [ ] OI optional input + fallback
  - [ ] Liquidation price captured opportunistically from positions

### B2. Architecture and Runtime Topology

- [ ] Single-process Ruby runtime (no separate sidecar)
  - [x] `gateways/ws_gateway.rb` normalizes events
  - [ ] In-process pub/sub for `market.*` / `account.*` topics
  - [ ] Reconnect + resubscribe-all on disconnect

- [ ] Core runtime modules present and wired
  - [x] SignalEngine analogue (`smc_setup/planner_brain.rb`,
        `smc_setup/tick_evaluator.rb`)
  - [x] RegimeClassifier (`regime/state_machine.rb`, `regime/hmm_engine.rb`)
  - [x] ConfluenceScorer (`smc_confluence/`, `strategy/smc_confluence.rb`)
  - [x] RiskManager (`risk/manager.rb`)
  - [x] OrderRouter (`execution/coordinator.rb`, `execution/broker.rb`)
  - [x] PositionStateMachine (`smc_setup/states.rb`, `position_tracker.rb`)

- [ ] Worker/scheduler responsibilities
  - [ ] Candle-close jobs
  - [ ] Breakeven-protection ticker
  - [ ] Funding ticker before scheduled funding windows (IST 09:30 / 17:30 / 01:30)

- [ ] Persistence model implemented
  - [ ] `signals`, `trades`, `positions`, `risk_events` tables
  - [ ] orderbook snapshots + replay artifacts
  - [x] `orderflow/recorder.rb` produces replay artifacts

### B3. Signal Component Catalog (all layers)

- [ ] Layer 1 Microstructure indicators
  - [ ] Top-N book imbalance
  - [ ] CVD (maker/aggressor semantics)
  - [ ] Tape-speed acceleration
  - [ ] Aggressor ratio
  - [ ] Sweep detection (≤200ms burst cluster)
  - [x] `orderflow/absorption_tracker.rb` (iceberg/spoof persistence base)
  - [ ] Validate absorption thresholds against recorded data

- [ ] Layer 2 Intraday indicators (1m–15m)
  - [ ] Anchored VWAP (session/daily/swing)
  - [ ] TTM squeeze + breakout trigger
  - [ ] EMA stack 9/21/50 rules
  - [ ] RSI divergence detector
  - [ ] ATR percentile rank over 200 bars
  - [ ] Rolling order-flow imbalance
  - [x] `strategy/indicators.rb` (verify coverage of above)

- [ ] Layer 3 Swing indicators (1H–4H–1D)
  - [ ] Market structure shift (fractal swing based)
  - [ ] Daily/weekly pivots
  - [ ] 200/50 EMA bias filter
  - [ ] Funding-rate extremes (optional)
  - [ ] OI delta vs price truth-table
  - [ ] Spot–futures basis signal
  - [ ] BTC dominance / correlation filter for alts

### B4. Regime Classifier and Confluence Scoring

- [ ] Regime classifier cadence (5m close)
  - [x] `regime/features.rb`, `regime/hmm_engine.rb`, `regime/ml_predictor.rb`
  - [ ] Inputs: ADX_4H, ATR_PCTL, BB_WIDTH_PCTL, MSS_4H
  - [ ] States: Trending / Ranging / Volatile / Compressed
  - [ ] Threshold table from doc
  - [ ] Tie-break: Trending > Compressed > Ranging > Volatile
  - [ ] Regime change cancels pending entries

- [ ] Confluence scoring
  - [x] `lib/coindcx_bot/smc_confluence/`
  - [ ] Independent `long_score` + `short_score` in [0, 100]
  - [ ] Regime-dependent weights from doc
  - [ ] Component value [-1, +1] → side score
  - [ ] Trade-fire gate:
    - [ ] `max(score) >= 75`
    - [ ] `abs(long - short) >= 25`
    - [ ] Volatile-regime exception only on microstructure threshold

- [ ] Probability-of-profit analytics
  - [ ] SQL view grouped by `(regime, score_bucket_5)`
  - [ ] Output `p_hit_1r`, `p_hit_3r`, `p_hit_stop`, `expected_r`
  - [ ] Bayesian update via Beta prior on rolling trades
  - [ ] Probability block attached to fired signal payload

### B5. Trade Plan, Risk, and Position Rules

- [ ] TradePlan compute path with hard constraints
  - [x] `smc_setup/trade_setup.rb`, `smc_setup/planner_brain.rb`
  - [ ] Direction from score dominance
  - [ ] Structural invalidation stop with ATR buffer
  - [ ] Risk-capital based qty + leverage cap
  - [ ] Hard leverage cap 10x (regardless of venue max)
  - [ ] Liquidation buffer rule: distance to liq ≥ 2× stop distance
  - [ ] Targets: TP1 1R, TP2 3R, TP3 trailing (chandelier / HTF structure)
  - [x] `strategy/dynamic_trail.rb`, `strategy/supertrend_profit.rb` (trail)
  - [ ] Breakeven-plus includes fees + funding buffer

- [ ] "No close in negative PnL" policy
  - [ ] High-confluence gate enforced pre-entry
  - [ ] Asymmetric R management + BE-lock behavior
  - [ ] Time-stop kill = only permitted negative close path
  - [ ] Log `risk_event: time_stop_kill`

### B6. Position State Machine and Idempotency

- [x] Formal state machine (`smc_setup/states.rb`)
  - [ ] Verify states cover IDLE → SCANNING → SIGNAL_DETECTED →
        ENTRY_VALIDATED → ORDER_PLACED → POSITION_OPEN →
        BREAKEVEN_PROTECTED → PARTIAL_TP_HIT → TRAILING → POSITION_CLOSED
  - [ ] TIME_STOP_KILL side path

- [ ] Transition + reconciliation rules
  - [ ] Unfilled timeout cancellation path
  - [ ] Partial-fill handling from `remaining_quantity`
  - [ ] Idempotency key (`client_order_id + event_id`)
  - [ ] Dedup unique index in SQLite
  - [ ] Restart reconciliation via active orders + positions snapshot

### B7. Database and Data Contracts

- [ ] Schema essentials (SQLite via `sqlite3` gem)
  - [ ] `markets`
  - [ ] `candles`
  - [ ] `signals`
  - [ ] `trades`
  - [ ] `positions`
  - [ ] `risk_events`
  - [ ] `order_book_snapshots`

- [ ] Indexes + constraints for replay/idempotency
- [ ] JSON columns for dynamic-shape payloads (SQLite `JSON1`)
- [ ] Migration + rollback verification specs

### B8. Backtesting and Validation

- [ ] Candle data ingestion
  - [ ] `/market_data/candles` with pagination, max 1000 bars/call
  - [ ] Multi-interval persistence

- [ ] High-fidelity microstructure replay
  - [x] `orderflow/recorder.rb`, `orderflow/replayer.rb`
  - [ ] 30-day live depth/trade recording run
  - [ ] Persist raw events to durable storage (Parquet/SQLite blob/file)

- [ ] Event-driven simulator
  - [x] `lib/coindcx_bot/backtest/`
  - [ ] Reuse prod SignalEngine functions
  - [ ] No vectorized shortcuts on orderbook logic

- [ ] Metrics
  - [ ] Win rate, avg R, profit factor
  - [ ] Max drawdown, Calmar, Sharpe
  - [ ] Median time-to-1R
  - [ ] % reaching BE-lock before negative close (target ≥ 99%)

- [ ] Walk-forward validation
  - [ ] 6-month IS + 1-month OOS rolling windows
  - [ ] Reject param set when OOS Sharpe < 0.5× IS Sharpe

- [ ] Paper-trade gate before live
  - [x] `paper_exchange.rb`, `execution/paper_broker.rb`
  - [ ] Dry-run router writes to `paper_trades`
  - [ ] Min 30 calendar days run
  - [ ] Go-live criteria enforced

### B9. CoinDCX-Specific Operational Gotchas

- [ ] Symbol/pair resolver everywhere (no mixed semantics)
- [ ] `cancel_all` used sparingly + rate-limit aware
- [ ] Funding-window scheduler 09:30 / 17:30 / 01:30 IST + pre-event recompute
- [ ] WS disconnect handling
  - [ ] Gap > 5s → emit `risk_event`
  - [ ] Pause new entries until next clean candle
  - [ ] Reconcile state immediately after reconnect
- [ ] Low-liquidity guardrails
  - [x] `risk/exposure_guard.rb` (verify floor checks)
  - [ ] Notional floor for thin pairs
  - [ ] Top-of-book depth multiple vs intended notional
- [ ] Mark price = last price policy in risk constraints
- [x] Synthetic funding approximation (`synthetic_l1.rb`)
  - [ ] Daily reconcile vs UI values

### B10. Stage-Based Rollout and Runtime Controls

- [ ] Stage 0 Foundations
  - [ ] WS gateway + in-process bus verified on public channels
  - [ ] MarketCatalog built
  - [ ] HMAC signer smoke-tested (via `coindcx-client`)
  - [x] Futures endpoint YAML captured + versioned

- [ ] Stage 1 Read-only data plane
  - [ ] Stream/persist top USDT + INR pairs across required intervals
  - [ ] Orderbook snapshot+delta merge with `vs` gap recovery
  - [ ] 30-day recorder running continuously

- [ ] Stage 2 Signal + paper trading
  - [ ] Layer 2 + Layer 3 first, then Layer 1 integration
  - [ ] Regime + confluence emit signals with full components
  - [ ] Paper run meets:
    - [ ] ≥ 99% BE-lock before stop
    - [ ] expectancy ≥ +0.4R
    - [ ] max drawdown < 8%

- [ ] Stage 3 Live gated capital
  - [ ] Start 0.25% risk + 3x leverage cap for first 30 trades
  - [ ] Promote to 0.5% risk + 10x cap only after gate pass
  - [ ] Operator kill-switch wired + tested
  - [ ] Threshold policies:
    - [ ] Escalate on high rolling expectancy + BE compliance
    - [ ] De-escalate / disable on BE-compliance degradation
    - [ ] Constrain to Trending-only entries when rolling Sharpe degrades

### B11. Security, Compliance, Incident-Readiness

- [ ] API keys IP-bound; withdrawal safeguards documented
- [ ] Futures wallet kept near working capital only
- [ ] Export-ready trade logs for tax/compliance
- [ ] Retention policy + auditability documented
- [ ] Incident playbook (exchange/API disruption) documented + drilled

### B12. Ruby-Specific Quality Gates

- [ ] RuboCop config aligned with `ruby-style` + `rails-style` skills
- [ ] RSpec coverage targets per module (`spec/` mirrors `lib/`)
- [ ] Frozen-string-literal magic comment on all new files
- [ ] No `Open3`/system calls without timeout + sandboxing in prod paths
- [ ] All public APIs documented with YARD-style comments where non-obvious
- [ ] `bundle exec rake` runs full suite (rubocop + rspec + boot smoke)

### B13. AI / LLM Layer (Ollama)

Mapped to `SimplefiedSMCConcepts.md` §"How would an ai play role in this".

- [x] Ollama client wired (`ollama-client`, `ollama_agent`)
- [x] `regime/ai_brain.rb`, `smc_setup/gatekeeper_brain.rb`,
      `smc_setup/planner_brain.rb`, `lib/coindcx_bot/trading_ai/`
- [ ] Strict JSON schema enforcement on all LLM outputs
- [ ] Per-signal cache keyed by signal id (determinism)
- [ ] Latency budget guard (skip if > 100ms in execution path)
- [ ] AI Signal Validator (filter weak SMC signals)
- [ ] Dynamic risk adjustment (`adjusted_risk = base * confidence`)
- [ ] Trade scoring / ranking when multiple signals exist
- [ ] Post-trade learning loop (closed-trade analyzer)
- [ ] Market regime classifier corroborated by AI (advisory, not authoritative)
- [ ] Hard rule: AI MUST NOT generate raw entries / SL / TP

## C) Definition of Done (per checklist item)

- [ ] Code/tests/docs updated
- [ ] Behavior verified by explicit spec or smoke command
- [ ] Item ticked ONLY after evidence captured (PR link, run log, screenshot)
- [ ] PR description links the completed checklist scope

## D) Framework → TODO Traceability Matrix

| Framework section | Requirement focus | Covered in TODO |
| --- | --- | --- |
| TL;DR | Confluence-gated state machine, 10x cap, liq buffer, arch split, data gaps | B2, B4, B5, B6, B9, B10 |
| A. CoinDCX API reference | Auth, spot/futures REST, sockets, endpoint/stream gaps | B1, B9, B10 |
| B. Signal component catalog | Layer 1/2/3 modules + formulas | B3 |
| C. Regime classifier | 4-state model + thresholds + cadence | B4 |
| D. Confluence scoring | Regime weights, fire conditions, conflict guard | B4 |
| E. Entry/stop/target/sizing | TradePlan, R-based exits, leverage/liq/BE constraints | B5 |
| F. "No negative close" SM | Lifecycle states, BE lock, time-stop kill | B5, B6 |
| G. Implementation architecture | Runtime modules, workers, storage | B2, B7 |
| H. Database schema essentials | markets/candles/signals/trades/positions/risk_events/orderbook | B7 |
| I. Backtesting & validation | Candle ingest, recorder, simulator, metrics, walk-forward, paper gate | B8, B10 |
| J. Probability-of-profit schema | p_hit fields, expected_R, payload attachment | B4 |
| K. CoinDCX gotchas | Pair/symbol mapping, reconnect, rate limits, funding, liq semantics | B9, B11 |
| Recommendations (Stage 0–3) | Sequenced rollout + risk escalation/de-escalation | B10 |
| Caveats | Futures docs limits, missing fields/streams, data-fidelity caveats | B1, B8, B9, B11 |
| SimplefiedSMCConcepts.md (AI roles) | LLM as validator/scorer/regime advisor, never raw entry generator | B13 |

### Traceability verification

- [ ] Every new framework requirement mapped to ≥1 B-section before implementation
- [ ] Any TODO item added during implementation includes its source section reference
- [ ] If a framework claim is intentionally out-of-scope, record rationale in PR description
