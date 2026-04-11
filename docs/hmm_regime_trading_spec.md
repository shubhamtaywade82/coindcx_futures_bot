# CoinDCX futures bot: HMM regime trading specification

Authoritative reference for adding **Hidden Markov Model (HMM) regime detection** and **volatility-ranked allocation** to this repository (**coindcx_futures_bot**), using **Ruby-first** HMM math, the **coindcx-client** gem (`../coindcx-client` via Bundler path or published gem) for all CoinDCX HTTP/WebSocket I/O, and **long/short-capable** USDT-M futures logic.

## 1. Project overview

The bot classifies **volatility regimes** from observable market features, maps regimes to **target exposure, side, and leverage**, and routes orders through the existing execution stack. **Risk and circuit breakers operate on realized PnL and portfolio state**, not on HMM beliefs: the HMM may suggest size; risk may veto or modify.

**Scope**

- **Market**: CoinDCX **USDT-margined futures** (`pairs` like `B-BTC_USDT`, `margin_currency_short_name: USDT`).
- **Direction**: **Long and short are allowed** (unlike the original “long-only” equity spec). Each regime strategy must define explicit rules for `buy` / `sell` / flat and how defensive regimes reduce risk (e.g. smaller size, lower leverage, or flat).
- **Broker boundary**: All exchange access goes through `CoinDCX.client` from `coindcx-client`. The bot wraps it in [`lib/coindcx_bot/gateways/`](lib/coindcx_bot/gateways/); do not add parallel raw HTTP clients for the same endpoints.

## 2. Technology stack

| Layer | Choice |
|--------|--------|
| Runtime | Ruby >= 3.2, Bundler |
| Exchange client | `coindcx-client` (Gemfile: `path: '../coindcx-client'` or published gem) |
| Tests | RSpec |
| HMM | **Ruby-first**: implement Gaussian HMM training, BIC model selection, and **forward-only** online inference in Ruby (`BigDecimal` for money-critical paths; optional `numo-narray` later if profiling demands it) |
| Config | Extend existing [`config/bot.yml`](config/bot.yml) + [`lib/coindcx_bot/config.rb`](lib/coindcx_bot/config.rb) |
| Terminal UI | Existing TTY stack ([`Gemfile`](Gemfile)): extend [`lib/coindcx_bot/tui/`](lib/coindcx_bot/tui/) |

**Non-normative**: Python `hmmlearn` may be cited for algorithmic parity checks in an offline research notebook; it is **not** the implementation target for this repo. See [Appendix A](#appendix-a-non-normative-reference-hmmlearn).

## 3. High-level data flow

```mermaid
flowchart LR
  candles[MarketDataGateway list_candlesticks]
  feats[Regime Features]
  hmm[HmmEngine forward]
  alloc[Allocation Strategy]
  risk[Risk Manager]
  coord[Execution Coordinator]
  client[CoinDCX Client]
  candles --> feats --> hmm --> alloc --> risk --> coord
  coord --> client
```

## 4. Proposed module layout

Map new code under `lib/coindcx_bot/` alongside existing layers ([`docs/architecture.md`](architecture.md)).

| Concern | Suggested path |
|---------|----------------|
| Feature vectors from OHLCV | `lib/coindcx_bot/regime/features.rb` |
| Gaussian HMM fit, BIC selection, forward inference | `lib/coindcx_bot/regime/hmm_engine.rb` |
| Regime metadata (`RegimeInfo`, `RegimeState`) | `lib/coindcx_bot/regime/types.rb` |
| Vol-rank → target exposure / side / stops | `lib/coindcx_bot/regime/allocation.rb` + `lib/coindcx_bot/strategy/regime_*.rb` |
| Walk-forward backtest | `lib/coindcx_bot/backtest/` (new) |
| Orchestration | Inject a regime advisor into [`Core::Engine`](lib/coindcx_bot/core/engine.rb) or add a strategy that consumes regime state |
| Orders / positions | [`Execution::Coordinator`](lib/coindcx_bot/execution/coordinator.rb), [`OrderGateway`](lib/coindcx_bot/gateways/order_gateway.rb), [`AccountGateway`](lib/coindcx_bot/gateways/account_gateway.rb) |
| Market data | [`MarketDataGateway`](lib/coindcx_bot/gateways/market_data_gateway.rb), [`WsGateway`](lib/coindcx_bot/gateways/ws_gateway.rb) |
| Risk (extensions) | [`Risk::Manager`](lib/coindcx_bot/risk/manager.rb), [`Risk::ExposureGuard`](lib/coindcx_bot/risk/exposure_guard.rb) |
| TUI | [`DeskViewModel`](lib/coindcx_bot/tui/desk_view_model.rb), [`DeskRiskStrategyPanel`](lib/coindcx_bot/tui/panels/desk_risk_strategy_panel.rb), etc. |

**Tests**: `spec/coindcx_bot/regime/`, `spec/coindcx_bot/backtest/`.

## 5. CoinDCX data and sizing semantics

### 5.1 Historical candles

- Use [`MarketDataGateway#list_candlesticks`](lib/coindcx_bot/gateways/market_data_gateway.rb) → `client.futures.market_data.list_candlesticks(pair:, from:, to:, resolution:)`.
- Align `resolution` with engine settings where possible: `strategy.execution_resolution`, `strategy.higher_timeframe_resolution`, and `runtime.candle_lookback` ([`Core::Engine`](lib/coindcx_bot/core/engine.rb)).
- HMM training bars may use a **single** primary resolution (e.g. daily or 4h) chosen explicitly in config; document bar count vs calendar time for crypto (24/7 markets).

### 5.2 Live prices

- WebSocket: [`WsGateway`](lib/coindcx_bot/gateways/ws_gateway.rb) → `CoinDCX.client.ws`.
- REST snapshots for display: `futures.market_data.current_prices`, `fetch_futures_rt_quotes`, `fetch_instrument` (see architecture doc).

### 5.3 Orders and contracts

- Replace equity “shares” with **contract quantity**, constrained by **lot size**, **tick size**, and min notional from **`fetch_instrument`** / `list_active_instruments` via `coindcx-client` futures `market_data`.
- PnL and backtest equity in **USDT**; optional INR view using `inr_per_usdt` from config (same pattern as [`Risk::Manager#size_quantity`](lib/coindcx_bot/risk/manager.rb)).

### 5.4 Paper trading

- **In-process**: `PaperBroker` / `runtime.dry_run` (see `config/bot.yml` `paper:`).
- **HTTP paper exchange**: `paper_exchange.enabled` + `CoinDCX.configure { |c| c.api_base_url = ... }` so gateways hit the Rack app ([`lib/coindcx_bot/paper_exchange.rb`](lib/coindcx_bot/paper_exchange.rb)).

---

## Phase 1: Scaffolding and dependencies

**Objective:** Introduce regime/backtest namespaces, configuration keys, and empty or stub classes wired into the load path—**no trading logic** yet.

### Deliverables

1. Files under `lib/coindcx_bot/regime/` and `lib/coindcx_bot/backtest/` with modules loaded from [`lib/coindcx_bot.rb`](lib/coindcx_bot.rb) if needed.
2. RSpec placeholders under `spec/coindcx_bot/regime/`.
3. Document new YAML keys under `regime:`, `regime_backtest:`, and optional `regime_risk:` in [`config/bot.yml`](config/bot.yml) (see [Section 15](#15-configuration-regime-keys-for-configbotyml)).
4. Extend [`CoindcxBot::Config`](lib/coindcx_bot/config.rb) to parse and validate new keys (whitelist, numeric ranges). **Follow-on implementation** when keys are finalized.

**Do not** add a separate `settings.yaml` unless you deliberately split regime research config from runtime bot config.

---

## Phase 2: HMM regime detection engine (Ruby)

**Objective:** Classify volatility regimes **without look-ahead bias** using a **Gaussian HMM** and **filtered inference only** (forward algorithm).

### 2.1 Feature engineering (`regime/features.rb`)

Compute observable features from candles (OHLCV) for HMM input. Example set (tune via config):

- **Volatility**: realized vol (e.g. 20-period rolling std of log returns), vol ratio (short / long window).
- **Volume**: normalized volume (z-score vs rolling mean), volume trend (e.g. slope of volume SMA).
- **Trend**: ADX(14), slope of price SMA.
- **Mean reversion**: RSI(14) z-score, distance from long SMA as % of price.
- **Momentum**: ROC over two horizons.
- **Range**: normalized ATR(14) / close.

**Standardization**: rolling z-scores with a configurable lookback (e.g. 252 bars on daily-equivalent series); ensure the scaler at time `t` uses **only** data with timestamps ≤ bar `t`.

### 2.2 HMM engine (`regime/hmm_engine.rb`)

- **Model**: Gaussian HMM with configurable `covariance_type` (e.g. `full` or `diag` if needed for stability on small samples).
- **Model selection**: for each candidate `n_components` in `regime.hmm.n_candidates`, fit with `n_init` random restarts; select **lowest BIC**  
  `BIC = -2 * log_likelihood + n_params * log(n_samples)`.
- **Labeling**: sort regimes by mean return for **human-readable labels only**; **strategy uses volatility ranking**, not label names.
- **CRITICAL — online inference**: implement **forward algorithm only**  
  `α_t = (α_{t-1} @ transmat) ⊙ emission_prob(o_t)`  
  **Do not** use full Viterbi / `predict` on the entire history for live decisions. Cache prior `α` for efficiency on incremental bars.
- **API sketch**: `predict_regime_proba`, `get_regime_stability`, `get_transition_matrix`, `detect_regime_change`, `get_regime_flicker_rate`, `is_flickering`.
- **Regime stability filter**:
  - Confirm regime change only after **N** consecutive bars (`stability_bars`, default 3).
  - During unconfirmed transition: keep previous regime label for strategy; optionally apply **uncertainty size multiplier** (e.g. 0.75).
  - **Flicker**: count regime id changes over `flicker_window` bars; if above `flicker_threshold`, enter **uncertainty mode** (see Phase 3).

### 2.3 Types (`regime/types.rb`)

- **`RegimeInfo`**: `expected_return`, `expected_volatility`, `strategy_kind`, `leverage_allowed`, `position_size_pct_cap`, `min_confidence`, etc.
- **`RegimeState`**: `label`, `state_id`, `probability`, `timestamp`, `is_confirmed`, `consecutive_bars`.

### 2.4 Mandatory test: no look-ahead (`spec/coindcx_bot/regime/hmm_engine_spec.rb`)

```ruby
# Behavior: filtered regime at index t must not change when future bars are appended.
RSpec.describe CoindcxBot::Regime::HmmEngine do
  it "produces identical filtered regime at t when history is extended" do
    # Given a fixed feature matrix and fitted params (or deterministic mock),
    # regime_at_t_short = forward_state(features[0..400]).state_at(399)
    # regime_at_t_long  = forward_state(features[0..500]).state_at(399)
    # expect(regime_at_t_short).to eq(regime_at_t_long)
  end
end
```

Implement with real engine or a deterministic fixture once training is available.

---

## Phase 3: Volatility-based allocation (long/short futures)

**Objective:** Map **volatility-ranked** regimes to **side, size, leverage, and stops** for USDT-M perps.

### 3.1 Volatility ranking

1. After each fit, sort regimes by **ascending** `expected_volatility` to assign `vol_rank`.
2. Map `vol_rank` to strategy tier (example—make configurable):
   - Lowest third → **LowVol** (aggressive trend-following: larger size, may allow higher leverage per risk caps).
   - Middle third → **MidVol** (moderate; e.g. long above slow EMA, short below, or smaller size both sides).
   - Highest third → **HighVol** (defensive: reduce size, force lower leverage, prefer flat or hedge—**explicit short rules** allowed).

Normalize rank: `position = rank / (n_regimes - 1)` for thresholding `<= 0.33` / `>= 0.67`.

### 3.2 Confidence and uncertainty

- **Min confidence** (`regime.strategy.min_confidence`, e.g. 0.55): below threshold → uncertainty mode.
- **Uncertainty mode** when `probability < min_confidence` **or** `is_flickering`:
  - Multiply target size by `uncertainty_size_mult` (e.g. 0.5).
  - Force leverage to **1.0x** (or exchange minimum allowed).
  - Append a clear tag to signal reason text for logs/TUI.

### 3.3 Rebalancing

- Rebalance only when target **notional or allocation fraction** changes by more than `rebalance_threshold` (e.g. 10%) to limit churn and fees.

### 3.4 Strategy layer

- **`BaseRegimeStrategy`**: `generate_signal(pair:, bars:, regime_state:, instrument:) -> Signal?`
- Concrete strategies implement **long, short, and flat** with stops defined in price space (ATR / EMA offsets). Stops must be compatible with CoinDCX order types available on your account (market/limit/brackets as supported by [`OrderGateway`](lib/coindcx_bot/gateways/order_gateway.rb) and API).
- **`RegimeOrchestrator`**: holds `regime_id → vol_rank → strategy`, applies uncertainty rules, emits a list of signals per bar.

### 3.5 Signal object (Ruby)

Use a dedicated value object (e.g. `Data.define` or `Struct`) including at minimum:

- `pair`, `side` (`:buy` / `:sell` / `:flat`), `confidence`, `entry_price`, `stop_loss`, `take_profit` (optional)
- `position_size_pct`, `leverage`, `regime_id`, `regime_name`, `regime_probability`, `time`, `reason`, `strategy_name`, `metadata`

Integrate with [`Execution::Coordinator`](lib/coindcx_bot/execution/coordinator.rb) and existing journal/event patterns.

### 3.6 Engine and TUI

- **Engine**: After candle refresh and/or on bar close, compute features → forward HMM → orchestrator → risk → coordinator. Respect `ws_feed_stale?`, `kill_switch`, `paused`, `dry_run` ([`Core::Engine`](lib/coindcx_bot/core/engine.rb)).
- **TUI**: Add regime row or section (regime name, probability, stability bars, flicker count, uncertainty flag) to risk/strategy panels and/or header metrics.

---

## Phase 4: Walk-forward backtesting and validation

**Objective:** **Allocation-style** walk-forward test using historical candles from the gateway (or cached CSV), **USDT** equity, contract rounding, slippage, and fees.

### 4.1 Backtester (`lib/coindcx_bot/backtest/walk_forward.rb`)

- **Windows** (configurable; defaults can mirror the original spec):
  - In-sample: e.g. 252 bars for training + BIC selection.
  - Out-of-sample: e.g. 126 bars; step: 126.
- **Per window**:
  1. Train HMM on IS features only.
  2. Build vol-ranked `RegimeInfo` list.
  3. For each OOS bar: features using **only** history ≤ `t`; forward step; target allocation/side; if change > threshold → rebalance next bar.
- **Equity** (conceptual):

  ```
  equity_usdt = cash_usdt + signed_position_notional_pnl
  target_contracts = round_to_lot(equity_usdt * target_fraction / (price * contract_size))
  ```

  Use instrument metadata for lot and tick.

- **Realism**: slippage bps, fee bps, rebalance threshold, **1-bar fill delay** (signal at bar *t*, execution at *t+1* open), optional funding (if modeled).

### 4.2 Performance (`backtest/performance.rb`)

- Returns, CAGR, Sharpe/Sortino/Calmar, max drawdown (% and duration), win rate, profit factor, regime contribution table, confidence buckets, benchmark: buy-hold, SMA trend (long/short/flat), optional Monte Carlo random entries.
- Export CSV: `equity_curve.csv`, `trade_log.csv`, `regime_history.csv`, `benchmark_comparison.csv`.

### 4.3 Stress tests (`backtest/stress.rb`)

- Gap injection (-5% to -15%), larger ATR gaps, shuffled regime labels to verify **risk** limits damage.

---

## Phase 5: Risk management layer

**Objective:** **Independent** risk with veto power. Circuit breakers fire on **actual** drawdown and PnL, not HMM output.

### 5.1 Portfolio limits (configurable; align with futures)

Examples from the original spec (tune for USDT equity):

- Max total exposure (% of equity), max single position, max concurrent positions, max daily trades, max leverage.

**Interaction with existing bot**: [`Risk::Manager`](lib/coindcx_bot/risk/manager.rb) today enforces INR-based per-trade sizing, daily loss in INR, max positions, kill switch, pause. New regime spec limits should be **additive** and **documented**: either extend `Risk::Manager` with a `RegimeRisk` collaborator or a separate `RegimeCircuitBreaker` that `Engine` consults before `Coordinator`. Avoid duplicating conflicting notions of “max leverage” without reconciling `config/risk/max_leverage` with regime leverage caps.

### 5.2 Circuit breakers

- Daily DD thresholds → reduce size / flat / halt for day.
- Weekly DD thresholds → reduce / halt for week.
- Peak DD → halt all trading; persist halt flag (e.g. journal flag or lock file) requiring manual clear.
- Log: breaker type, measured DD, equity, positions closed, **current regime** (for forensics only).

### 5.3 Position-level risk

- Reject orders without stop where strategy requires stops.
- Size from risk budget: e.g. `risk_usdt = equity * max_risk_per_trade_pct / |entry - stop|` with caps; minimum notional in USDT.
- **Gap risk**: optional overnight haircut on size (rule from original spec can be adapted to 24/7 crypto as “hold through high-vol session” windows if desired).

### 5.4 Leverage rules

- Default 1.0x; low-vol tier may allow higher cap **if** exchange and `risk.max_leverage` permit.
- Force 1.0x when: uncertainty mode, any breaker active, too many positions, high flicker.

### 5.5 Order validation

- Buying power / margin checks via account + positions APIs (wrapped in [`AccountGateway`](lib/coindcx_bot/gateways/account_gateway.rb)).
- Spread check using bid/ask when available (`TickStore`, RT quotes).
- Duplicate signal suppression (same pair + side within window).
- Structured rejection reasons in logs.

### 5.6 Correlation (optional)

- Rolling correlation across pairs; reduce size or reject if above thresholds (needs multi-pair history buffers).

### 5.7 Ruby API sketch

- `RegimeRiskPolicy#validate(signal:, portfolio_state:) -> RiskDecision`
- `RiskDecision`: `approved?`, `modified_signal`, `rejection_reason`, `modifications`
- `PortfolioState`: equity USDT, margin, positions, daily/weekly PnL, peak equity, drawdowns, breaker state, flicker flag

---

## Phase 6: Broker integration (coindcx-client)

**Objective:** All connectivity through **`CoinDCX.client`** and bot gateways—no Alpaca, no duplicate HTTP stacks.

### 6.1 Configuration

- Credentials: `COINDCX_API_KEY`, `COINDCX_API_SECRET` (documented in the `coindcx-client` gem; local dev uses `path: '../coindcx-client'` in this repo’s [`Gemfile`](../Gemfile)); optional tuning for retries, circuit breaker, WebSocket reconnect.
- **Live trading**: require explicit CLI or env confirmation (mirror original “type YES” pattern) when `runtime.dry_run` is false and paper modes are off.

### 6.2 REST surfaces (via gateways)

| Need | Typical `coindcx-client` path |
|------|-------------------------------|
| Candles | `client.futures.market_data.list_candlesticks` → [`MarketDataGateway#list_candlesticks`](lib/coindcx_bot/gateways/market_data_gateway.rb) |
| Instrument / tick size | `client.futures.market_data.fetch_instrument`, `list_active_instruments` |
| Quotes | `client.futures.market_data.current_prices` |
| Orders | `client.futures.orders.create` / `list` / `cancel` → [`OrderGateway`](lib/coindcx_bot/gateways/order_gateway.rb) |
| Positions / balances | `client.futures.positions.*`, `client.user.accounts.*` → [`AccountGateway`](lib/coindcx_bot/gateways/account_gateway.rb) |
| Transfers | `client.transfers.wallets.*` (if moving USDT spot ↔ futures) |

### 6.3 WebSocket

- `client.ws` via [`WsGateway`](lib/coindcx_bot/gateways/ws_gateway.rb) for ticks and private updates as today; reconnect behavior is configured on `CoinDCX.configure`.

### 6.4 Execution and reconciliation

- Place/modify/cancel through [`Execution::Coordinator`](lib/coindcx_bot/execution/coordinator.rb) and broker implementations (`LiveBroker`, `PaperBroker`, `GatewayPaperBroker`).
- Link `client_order_id` / internal ids from signal → risk decision → order → fill in [`Persistence::Journal`](lib/coindcx_bot/persistence/journal.rb) where applicable.
- On startup, reconcile open positions and working orders with exchange (extend existing boot path in `Engine`).

---

## Phase 7: Main loop and orchestration

**Objective:** Integrate regime pipeline into [`Core::Engine`](lib/coindcx_bot/core/engine.rb)—not a standalone `main.py`.

### 7.1 Startup

1. Load [`CoindcxBot::Config`](lib/coindcx_bot/config.rb); `CoinDCX.configure` from env.
2. Verify account / paper endpoint health.
3. Load or train HMM snapshot (if persisted model older than `regime.hmm.max_age_days`, retrain).
4. Build `RegimeOrchestrator` from latest `RegimeInfo` list.
5. Restore optional `state_snapshot` (regime `α`, last bar id, halt flags).
6. Start WebSocket feeds; log “system online”.

### 7.2 Loop (on each execution bar or tick policy)

1. Ingest new candle(s) / LTP.
2. Compute features (causal windows only).
3. Forward HMM step; stability + flicker checks.
4. Orchestrator → signals per `pair`.
5. For each signal: regime risk policy → existing [`Risk::Manager`](lib/coindcx_bot/risk/manager.rb) gates → [`Execution::Coordinator`](lib/coindcx_bot/execution/coordinator.rb).
6. Update trailing stops / brackets per strategy.
7. Circuit breaker updates from journal / marks.
8. TUI snapshot refresh.
9. Periodic HMM retrain (e.g. weekly bar close), then `update_regime_infos` on orchestrator.

### 7.3 Shutdown (SIGINT/SIGTERM)

- Stop WS gracefully (`ws_shutdown_join_seconds`).
- Do **not** auto-close positions unless policy says so; persist state snapshot.
- Log session summary.

### 7.4 Errors

- HTTP: rely on `coindcx-client` retry + circuit breaker; engine sets `last_error` and may pause entries.
- HMM failure: hold last confirmed regime; log.
- Stale feed: existing `ws_feed_stale?` blocks new entries; maintain protective orders.

### 7.5 CLI (extend [`lib/coindcx_bot/cli.rb`](lib/coindcx_bot/cli.rb))

Flags such as: `--dry-run` (already config-driven), `--backtest`, `--train-regime-only`, `--stress-test`, `--compare-benchmarks`—wire to backtest/regime CLIs when implemented.

---

## Phase 8: Monitoring, alerts, and TUI

**Objective:** Operator visibility without Python/Rich.

### 8.1 Logging

- Use Ruby `Logger` (or structured JSON if you add a formatter). Optional dedicated log files: `regime.log`, `trades.log`, `alerts.log` with rotation (implement via `Logger` or `logging` gem if introduced—prefer stdlib unless there is a project standard).

Include: timestamp, pair, regime id/name, probability, equity USDT (and INR if displayed), daily PnL, breaker state.

### 8.2 TUI dashboard

Extend existing panels to show:

- **Regime**: label, probability, stability bars, flicker x/window, uncertainty on/off.
- **Portfolio**: USDT equity / margin, allocation %, effective leverage.
- **Positions**: pair, side, entry, uPnL %, stop, holding time, regime at entry vs now.
- **Signals**: recent rebalance / side changes with reason.
- **Risk**: daily / weekly / peak DD vs thresholds; API/WS latency if already in header.

Refresh rate: align with [`RenderLoop`](lib/coindcx_bot/tui/render_loop.rb) (e.g. ~4 Hz) and avoid redundant renders.

### 8.3 Alerts

- Triggers: regime change, breaker trip, large PnL move, feed/API unhealthy, HMM retrained, flicker exceeded.
- Rate limit per event type (e.g. 15 minutes); optional webhook/email later.

---

## 15. Configuration: regime keys for `config/bot.yml`

Add a **`regime:`** subtree (names illustrative—validate in `Config` when implementing):

```yaml
# Example extension — merge with existing bot.yml (do not duplicate top-level keys).
regime:
  enabled: false
  bar_resolution: 1h          # HMM bar resolution (API resolution string for list_candlesticks)
  feature_lookback_bars: 300  # min history before first inference
  hmm:
    n_candidates: [3, 4, 5, 6, 7]
    n_init: 10
    covariance_type: full
    min_train_bars: 252
    max_age_days: 7
    stability_bars: 3
    flicker_window: 20
    flicker_threshold: 4
  strategy:
    min_confidence: 0.55
    rebalance_threshold: 0.10
    uncertainty_size_mult: 0.50
    low_vol_leverage_cap: 1.25
    # Example tier fractions — tune; strategies read these
    low_vol_target_pct: 0.95
    mid_vol_target_pct_trend: 0.95
    mid_vol_target_pct_range: 0.60
    high_vol_target_pct: 0.60
  risk:
    max_risk_per_trade_pct: 0.01
    max_exposure_pct: 0.80
    max_single_position_pct: 0.15
    max_concurrent_positions: 5
    max_daily_trades: 20
    daily_dd_reduce_pct: 0.02
    daily_dd_halt_pct: 0.03
    weekly_dd_reduce_pct: 0.05
    weekly_dd_halt_pct: 0.07
    max_dd_from_peak_pct: 0.10
    min_notional_usdt: 100

regime_backtest:
  slippage_pct: 0.0005
  fee_bps: 4
  initial_capital_usdt: 100000
  train_window_bars: 252
  test_window_bars: 126
  step_bars: 126
  risk_free_rate: 0.045

regime_monitoring:
  alert_rate_limit_minutes: 15
```

**Note:** Implementing these keys requires extending [`lib/coindcx_bot/config.rb`](lib/coindcx_bot/config.rb) (validation, defaults, accessors) alongside code—this spec only defines intent.

---

## 16. Environment variables

Use CoinDCX credentials as documented for `coindcx-client`:

```bash
COINDCX_API_KEY=your_key_here
COINDCX_API_SECRET=your_secret_here
# Optional: override config path
# COINDCX_BOT_CONFIG=/path/to/bot.yml
```

For paper exchange against a local Rack app, align keys with the paper exchange seed (see [`docs/paper_exchange.md`](paper_exchange.md)).

---

## Appendix A: Non-normative reference (hmmlearn)

The original equity bot spec used Python `hmmlearn.GaussianHMM` for training and research. For **parity checks** only, you may fit the same feature matrix in Python and compare BIC-selected `n_components` and rough regime ordering—**production code in this repo remains Ruby**.

---

## Appendix B: Relationship to current strategies

Until `regime.enabled` is true, the engine may keep using [`Strategy::TrendContinuation`](lib/coindcx_bot/strategy/trend_continuation.rb) or alternatives from `config/strategy`. When enabled, either replace the strategy factory in `Engine#build_strategy` with a regime-aware strategy or compose regime output as a filter on top of existing signals—choose one pattern and document it in code comments.
