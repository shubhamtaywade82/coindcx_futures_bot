# SMC Detector Extraction + Test Suite — Design Spec

**Date:** 2026-04-14
**Branch:** `smc_eventdriven`
**Status:** Approved — ready for implementation planning

---

## Context

The `SmcConfluence::Engine` is a monolithic class (~480 lines) with all eight SMC detection
layers inlined as private methods sharing a single mutable `State` object. This makes
individual layer behaviour impossible to test in isolation: every test must warm up the full
engine with enough synthetic candles to exercise the target layer, and any refactor risks
silently breaking adjacent layers.

This spec describes:
1. A prerequisite fix for the one failing test in the suite.
2. Extraction of every detection layer into an independent stateful detector object.
3. A comprehensive RSpec suite — one file per detector — that tests each layer in isolation.
4. Engine rewiring to delegate to the new detectors.

Out of scope: execution layer (Coordinator, PaperBroker, RiskManager) — covered by existing
specs that are not changed here.

---

## Decision Log

| Question | Decision | Rationale |
|---|---|---|
| Test approach | Extract modules first, then test | Black-box tests through Engine.run are hard to isolate per layer |
| Module interface | Stateful detector objects | Bar-by-bar `push(candle)` API matches real usage; easy to unit-test |
| Composition model | Engine-mediated (detectors are leaves) | Upstream results passed as kwargs — detectors stay independent, no hidden deps |
| Scope | SMC modules + fix failing test only | Execution layer gaps are a separate spec |

---

## Prerequisite: Fix Failing `tick_evaluator_spec`

**Failure:**
```
SQLite3::ReadOnlyException: attempt to write a readonly database
  trade_setup_store.rb:49 persist_record!
  tick_evaluator_spec.rb:76
```

**Root cause:** The journal in the spec points at a path that is read-only in the test
environment (likely resolving to `./data/bot_journal.sqlite3`).

**Fix — two files, no production code changes:**

1. Add `spec/support/tmp_journal.rb`:

```ruby
shared_context 'with tmp journal' do
  let(:journal_path) do
    require 'tempfile'
    f = Tempfile.new(['journal', '.sqlite3'])
    f.close
    f.path
  end
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }
  after { File.delete(journal_path) if File.exist?(journal_path) }
end
```

2. Update `tick_evaluator_spec.rb` to `include_context 'with tmp journal'` and pass
   `journal:` from the shared let to `TickEvaluator.new(...)`. Three-line change.

---

## File Layout

### New files

```
lib/coindcx_bot/smc_confluence/detectors/
  pivots.rb            # Detectors::Pivots
  structure.rb         # Detectors::Structure
  order_block.rb       # Detectors::OrderBlock
  liquidity_sweep.rb   # Detectors::LiquiditySweep
  market_structure.rb  # Detectors::MarketStructure
  trendline.rb         # Detectors::Trendline
  session_tracker.rb   # Detectors::SessionTracker
  volume_profile.rb    # Detectors::VolumeProfile

spec/support/
  smc_candle_factory.rb   # shared candle builder helper
  tmp_journal.rb          # shared context for writable journal

spec/coindcx_bot/smc_confluence/detectors/
  pivots_spec.rb
  structure_spec.rb
  order_block_spec.rb
  liquidity_sweep_spec.rb
  market_structure_spec.rb
  trendline_spec.rb
  session_tracker_spec.rb
  volume_profile_spec.rb
```

### Modified files

```
lib/coindcx_bot/smc_confluence/engine.rb   # delegate to detectors; remove private methods
lib/coindcx_bot/smc_confluence/state.rb    # deleted once all detectors own their state
spec/coindcx_bot/smc_setup/tick_evaluator_spec.rb  # fix (prerequisite)
```

### Unchanged files

```
lib/coindcx_bot/smc_confluence/fvg.rb
lib/coindcx_bot/smc_confluence/premium_discount.rb
lib/coindcx_bot/smc_confluence/bar_result.rb
lib/coindcx_bot/smc_confluence/configuration.rb
lib/coindcx_bot/smc_confluence/candles.rb
spec/coindcx_bot/smc_confluence/engine_spec.rb   # regression guard — never modified
spec/coindcx_bot/smc_confluence/fvg_spec.rb
spec/coindcx_bot/smc_confluence/premium_discount_spec.rb
```

---

## Shared Test Helper

`spec/support/smc_candle_factory.rb` — included in all detector specs via `RSpec.configure`:

```ruby
module SmcCandleFactory
  def candle(open:, high:, low:, close:, volume: 100.0, hour: 10, minute: 0)
    ts = Time.utc(2024, 1, 2, hour, minute, 0).to_i
    { open: open.to_f, high: high.to_f, low: low.to_f,
      close: close.to_f, volume: volume.to_f, timestamp: ts }
  end

  def flat(n, price: 100.0, volume: 100.0)
    Array.new(n) do
      candle(open: price, high: price + 0.5, low: price - 0.5,
             close: price, volume: volume)
    end
  end
end
```

---

## Detector Interfaces

All detectors live under `CoindcxBot::SmcConfluence::Detectors`.
Each result struct uses `keyword_init: true`. All boolean fields default false, numeric
fields default nil unless stated.

### 1. Pivots

Instantiated **three times** in the Engine — one per swing parameter:
- `@smc_pivots` (swing = `cfg.smc_swing`) → feeds Structure, OrderBlock
- `@ms_pivots`  (swing = `cfg.ms_swing`)  → feeds MarketStructure
- `@tl_pivots`  (swing = `cfg.tl_pivot_len`) → feeds Trendline

```ruby
Detectors::Pivots.new(swing: Integer)
push(candle) → PivotResult

PivotResult = Struct.new(
  :confirmed_high,       # Float | nil  — pivot high confirmed this bar
  :confirmed_high_bar,   # Integer | nil — bar index of confirmed pivot
  :confirmed_low,        # Float | nil
  :confirmed_low_bar,    # Integer | nil
  :last_ph,              # Float | nil  — most recent confirmed pivot high
  :last_pl,              # Float | nil
  :last_ph_bar,          # Integer (-999 until first pivot)
  :last_pl_bar,          # Integer
  :ph_age,               # Integer — bars since last confirmed pivot high
  :pl_age,               # Integer
  keyword_init: true
)
```

**Internal state:** rolling buffer of last `swing * 2 + 1` candles; absolute bar counter;
`last_ph`, `last_pl`, ages.

**Pivot confirmation rule (preserved from engine):**
- Left bars (indices 0 to mid-1): all highs strictly less than center high
- Right bars (indices mid+1 to end): all highs less-than-or-equal to center high

### 2. Structure (BOS / CHOCH)

```ruby
Detectors::Structure.new(ob_expire: Integer)
push(candle, pivot:) → StructureResult

StructureResult = Struct.new(
  :bos_bull, :bos_bear,
  :choch_bull, :choch_bear,
  :structure_bias,       # Integer: -1 | 0 | 1
  keyword_init: true
)
```

**Internal state:** `@structure_bias`, `@prev_close`.

**Rules:**
- `bos_bull = ph_valid && close > last_ph && prev_close <= last_ph`
- `choch_bull = bos_bull && structure_bias == -1`
- `ph_valid = last_ph && ph_age <= ob_expire`
- Both `bos_bull` and `choch_bull` can be true simultaneously on the same bar.
- Only close-based crosses count — wick-only touches do not trigger BOS/CHOCH.

### 3. OrderBlock

```ruby
Detectors::OrderBlock.new(body_pct_threshold: Float, expire_bars: Integer)
push(candle, structure:) → OBResult

OBResult = Struct.new(
  :in_bull_ob, :in_bear_ob,
  :bull_ob_hi, :bull_ob_lo,     # Float | nil
  :bear_ob_hi, :bear_ob_lo,     # Float | nil
  :bull_ob_valid, :bear_ob_valid,
  keyword_init: true
)
```

**Internal state:** `@prev_candle`, `@bull_ob`, `@bear_ob`, ages.

**Bull OB registration:** triggers when `structure.bos_bull || structure.choch_bull`
AND `impulse_body_pct >= body_pct_threshold` AND `prev_candle` was bearish
(`prev_close < prev_open`). Coordinates = prev candle high/low.

**In-zone test:** `in_bull_ob = bull_ob_valid && low <= bull_ob_hi && high >= bull_ob_lo`

### 4. LiquiditySweep

```ruby
Detectors::LiquiditySweep.new(liq_lookback: Integer, liq_wick_pct: Float, memory_bars: Integer)
push(candle) → SweepResult

SweepResult = Struct.new(
  :liq_sweep_bull, :liq_sweep_bear,
  :recent_bull_sweep, :recent_bear_sweep,
  :liq_hi, :liq_lo,     # Float — rolling window high/low (exposed for downstream)
  keyword_init: true
)
```

**Internal state:** rolling buffer of `liq_lookback` candles; last sweep bar counters.

**Sweep rule:**
- `liq_sweep_bull = low < prev_liq_lo * (1 - wick_pct/100) && close > prev_liq_lo`
- `recent_bull_sweep = bars_since_bull_sweep <= memory_bars`

Note: rolling high/low computed from the *previous* bar's window (matching engine behaviour),
exposed as `liq_hi` / `liq_lo` so callers can use it for premium/discount calculations
without re-scanning.

### 5. MarketStructure

```ruby
Detectors::MarketStructure.new
push(pivot:) → MSResult

MSResult = Struct.new(
  :ms_hh, :ms_hl, :ms_lh, :ms_ll,
  :ms_trend,    # Integer: -1 | 0 | 1
  keyword_init: true
)
```

**Internal state:** `@prev_ms_ph`, `@prev_ms_pl`, `@last_ms_ph_val`, `@last_ms_pl_val`,
`@ms_trend`.

**Rules:** flags fire only when `pivot.confirmed_high` / `pivot.confirmed_low` is non-nil.
Comparison is against the *previous* confirmed pivot of the same type.

### 6. Trendline

```ruby
Detectors::Trendline.new(retest_pct: Float)
push(candle, pivot:, bar_index: Integer) → TLResult

TLResult = Struct.new(
  :tl_bear_break, :tl_bull_break,
  :tl_bear_retest, :tl_bull_retest,
  :tl_bear_val, :tl_bull_val,   # Float | nil — projected trendline value at bar_index
  keyword_init: true
)
```

**Internal state:** two pivot highs + bar indices for bear TL; two pivot lows + bar indices
for bull TL; break/retest flags and break bar indices; previous projected values.

**Slope:** `(ph1 - ph2) / (ph1_bar - ph2_bar)` (requires two confirmed TL pivots).
**Projection:** `ph1 + slope * (bar_index - ph1_bar)`.
**Break:** `close > tl_bear_val && prev_close <= prev_tl_bear_val`.
**Retest:** fires once after break when `(close - tl_bear_val).abs / close * 100 <= retest_pct`.
**New pivot:** resets `tl_bear_broken`, `tl_bear_retested`, and `tl_bear_break_bar`.

### 7. SessionTracker

```ruby
Detectors::SessionTracker.new(sess_liq_pct: Float)
push(candle) → SessionResult

SessionResult = Struct.new(
  :pdh, :pdl,
  :pdh_sweep, :pdl_sweep,
  :near_pdh, :near_pdl,
  :asia_hi, :asia_lo,
  :london_hi, :london_lo,
  :sess_level_bull, :sess_level_bear,
  keyword_init: true
)
```

**Internal state:** `@day_high`, `@day_low`, `@pdh`, `@pdl`, session hi/lo, session flags,
`@prev_calendar_date`.

**Session UTC hours (preserved from engine):**
- Asia: 00:00–07:59, London: 08:00–15:59, NY: 13:00–20:59
- `sess_level_bull = near_pdl || near_sess_lo || pdl_sweep`
- `sess_level_bear = near_pdh || near_sess_hi || pdh_sweep`

### 8. VolumeProfile

```ruby
Detectors::VolumeProfile.new(vp_bars: Integer, poc_zone_pct: Float)
push(candle, atr: Float) → VPResult

VPResult = Struct.new(
  :poc, :vah, :val_line,
  :near_poc, :near_vah, :near_val,
  :vp_bull_conf, :vp_bear_conf,
  :vp_ok,
  keyword_init: true
)
```

**Internal state:** rolling buffer of `vp_bars` candles.

**Computation (preserved from engine):**
- POC = typical price of the highest-volume candle in window
- VWAP = `Σ(tp × vol) / Σ(vol)`
- σ = `sqrt(Σ(tp² × vol) / Σ(vol) - VWAP²)`
- VAH = VWAP + σ,  VAL = VWAP − σ
- When `vol_total == 0`: σ falls back to `atr` parameter; `vp_ok` remains true if
  enough bars are present, false otherwise.
- `vp_bull_conf = near_poc || near_val`
- `vp_bear_conf = near_poc || near_vah`

---

## Engine Refactor

`State` is deleted. `Engine#initialize` creates all detector instances from `Configuration`:

```ruby
def initialize(candles, configuration)
  @candles = candles
  @cfg     = configuration

  @smc_pivots    = Detectors::Pivots.new(swing: cfg.smc_swing)
  @ms_pivots     = Detectors::Pivots.new(swing: cfg.ms_swing)
  @tl_pivots     = Detectors::Pivots.new(swing: cfg.tl_pivot_len)
  @structure_det = Detectors::Structure.new(ob_expire: cfg.ob_expire)
  @ob_det        = Detectors::OrderBlock.new(
                     body_pct_threshold: cfg.ob_body_pct,
                     expire_bars:        cfg.ob_expire
                   )
  @sweep_det     = Detectors::LiquiditySweep.new(
                     liq_lookback: cfg.liq_lookback,
                     liq_wick_pct: cfg.liq_wick_pct,
                     memory_bars:  cfg.smc_swing * 2
                   )
  @ms_det        = Detectors::MarketStructure.new
  @tl_det        = Detectors::Trendline.new(retest_pct: cfg.tl_retest_pct)
  @session_det   = Detectors::SessionTracker.new(sess_liq_pct: cfg.sess_liq_pct)
  @vp_det        = Detectors::VolumeProfile.new(
                     vp_bars:      cfg.vp_bars,
                     poc_zone_pct: cfg.poc_zone_pct
                   )
  @atr_prev      = nil
  @last_sig_bar  = -999
  @active_fvgs   = []
end
```

`Engine#step_bar` wiring order (tier-based to respect dependencies):

```ruby
def step_bar(i)
  candle = @candles[i]

  # Tier 0 — standalone detectors
  atr_val = update_atr(i)          # inline: simple EMA smoothing, no state extraction
  session = @session_det.push(candle)
  sweep   = @sweep_det.push(candle)
  vp      = @vp_det.push(candle, atr: atr_val.to_f)

  # Tier 1 — three independent pivot streams
  smc_piv = @smc_pivots.push(candle)
  ms_piv  = @ms_pivots.push(candle)
  tl_piv  = @tl_pivots.push(candle)

  # Tier 2 — depends on pivot results
  structure = @structure_det.push(candle, pivot: smc_piv)
  ms        = @ms_det.push(pivot: ms_piv)
  tl        = @tl_det.push(candle, pivot: tl_piv, bar_index: i)

  # Tier 3 — depends on structure
  ob = @ob_det.push(candle, structure: structure)

  # Already-extracted optional layers
  fvg_result = compute_fvg(i)
  pd_result  = compute_premium_discount(i)

  build_bar_result(smc_piv, structure, ob, sweep, ms, tl, session, vp,
                   fvg_result, pd_result, atr_val, i)
end
```

All private methods removed from Engine after delegation is wired:
`pivot_high_confirmed`, `pivot_low_confirmed`, `update_calendar_and_sessions`,
`rolling_high_low`, `volume_profile_levels`, `bear_trendline_slope`,
`bull_trendline_slope`, `near_session_level?`.

`update_atr` and `compute_fvg` / `compute_premium_discount` remain inline (trivial, stateless).

Signal scoring (`long_score`, `short_score`, `long_signal`, `short_signal`) remains a private
method in Engine — it is pure arithmetic over detector results, no state.

---

## Test Strategy per Detector

### Pivots spec

| Test | Setup | Assert |
|---|---|---|
| warmup guard | push < swing\*2+1 candles | `confirmed_high` nil throughout |
| basic detection | center bar strictly highest, right bars equal or lower | `confirmed_high` == center value |
| equal-left blocks | adjacent left bar has same high as center | no confirmation |
| equal-right passes | adjacent right bar matches center high | confirms (right uses `<=`) |
| ph_age increments | push N candles with no new pivot | `ph_age` == N |
| ph_age resets | new pivot high confirmed | `ph_age` == 0 |
| last_ph sticky | push one more bar after confirmation | `last_ph` persists, `confirmed_high` nil |
| pivot_low | mirror of above cases with low field | symmetric |
| back-to-back pivots | two pivot highs in sequence | `last_ph` == second value |

### Structure spec

| Test | Setup | Assert |
|---|---|---|
| initial bias | fresh detector, any candle | `structure_bias == 0` |
| bos_bull only | bias 0, close crosses above last_ph | `bos_bull true`, `choch_bull false` |
| choch_bull | bias -1, close crosses above last_ph | both `bos_bull` and `choch_bull` true |
| no wick trigger | high > last_ph but close < last_ph | no BOS |
| pivot expiry | ph_age > ob_expire | no BOS even on close cross |
| bias persistence | N bars after BOS with no new pivot | `structure_bias == 1` |
| bear symmetric | same cases for `bos_bear` / `choch_bear` | — |

### OrderBlock spec

| Test | Setup | Assert |
|---|---|---|
| no prev candle | first push | `in_bull_ob: false` |
| bull OB created | bearish prev + bos_bull + body_pct >= threshold | OB coords match prev candle H/L |
| threshold gate | bearish prev + bos_bull + body_pct < threshold | no OB registered |
| bullish prev | bullish prev + bos_bull + body_pct ok | no bull OB |
| in_bull_ob true | candle overlaps OB zone | `in_bull_ob: true` |
| in_bull_ob false | candle entirely above OB | `in_bull_ob: false` |
| OB expiry | expire_bars+1 pushes after OB creation | `in_bull_ob: false` |
| OB overwrite | second BOS registers new OB | coords updated |
| bear symmetric | — | — |

### LiquiditySweep spec

| Test | Setup | Assert |
|---|---|---|
| rolling window | push liq_lookback+2 candles with known lows | `liq_lo` == min of last N |
| sweep fires | wick below threshold, close above | `liq_sweep_bull: true` |
| no close above | wick below but close stays below | `liq_sweep_bull: false` |
| recent window | N bars after sweep where N <= memory_bars | `recent_bull_sweep: true` |
| window expires | memory_bars+1 bars after sweep | `recent_bull_sweep: false` |
| timer reset | second sweep resets countdown | `recent_bull_sweep: true` for another memory_bars |
| bear symmetric | — | — |

### MarketStructure spec

| Test | Setup | Assert |
|---|---|---|
| first pivot | push PivotResult with confirmed_high | no HH/LH (nothing to compare) |
| ms_hh | second confirmed high > first | `ms_hh: true`, `ms_trend: 1` |
| ms_lh | second confirmed high < first | `ms_lh: true`, `ms_trend: -1` |
| ms_hl | second confirmed low > first | `ms_hl: true`, `ms_trend: 1` |
| ms_ll | second confirmed low < first | `ms_ll: true`, `ms_trend: -1` |
| nil pivot | push with no confirmed pivot | all flags false, `ms_trend` persists |
| trend persistence | no new pivot for N bars | `ms_trend` unchanged |

### Trendline spec

| Test | Setup | Assert |
|---|---|---|
| single pivot | one TL pivot high only | `tl_bear_val: nil` |
| slope correct | two PHs at known bar indices | `tl_bear_val == ph1 + slope*(i-ph1_bar)` |
| break detection | close > tl_bear_val, prev_close <= prev_val | `tl_bear_break: true` |
| break once | next bar still above | `tl_bear_break: false` (already broke) |
| retest detection | close returns within retest_pct % after break | `tl_bear_retest: true` |
| retested once | second return inside tolerance | `tl_bear_retest: false` |
| new pivot resets | new TL pivot high pushed | break/retest state cleared |
| bull symmetric | — | — |

### SessionTracker spec

| Test | Setup | Assert |
|---|---|---|
| pdh nil first day | only first-day candles | `pdh: nil`, `pdl: nil` |
| day boundary | candle with next UTC date | `pdh == prev day_high` |
| asia session | candles in 00:00-07:59 UTC | `asia_hi`/`asia_lo` track |
| asia freeze | first candle outside Asia | `asia_hi`/`asia_lo` frozen |
| london session | candles in 08:00-15:59 UTC | `london_hi`/`london_lo` track |
| pdl_sweep | low < pdl*(1-pct), close > pdl | `pdl_sweep: true`, `sess_level_bull: true` |
| near_pdl | close within pct% of pdl | `near_pdl: true`, `sess_level_bull: true` |
| sess_level_bull | any of: near_pdl, near_sess_lo, pdl_sweep | `sess_level_bull: true` |

### VolumeProfile spec

| Test | Setup | Assert |
|---|---|---|
| warmup guard | push < vp_bars candles | `vp_ok: false` |
| poc correct | one candle at 10× volume | `poc == its typical_price` |
| vwap formula | known volumes and prices | verify against hand-computed value |
| VAH/VAL | known inputs | `vah ≈ vwap + σ` to 6 decimal places |
| near_poc | close within poc_zone_pct | `near_poc: true` |
| vp_bull_conf | near_poc or near_val | `vp_bull_conf: true` |
| zero volume | all vol == 0 | sigma falls back to `atr` param; `vp_ok: true` |
| rolling window | push vp_bars+1; check POC shift | POC reflects new dominant candle |

---

## Implementation Order

Execute in this sequence. Each detector's spec must be green before wiring into Engine.
`engine_spec.rb` is run after every wiring step as a regression gate — it is never modified.

```
0. Add smc_candle_factory support   (create file + wire into spec_helper; needed by all detector specs)
1. Fix tick_evaluator_spec          (prerequisite; no production code change)
2. Pivots                           (spec → implement → wire → engine_spec green)
3. Structure                        (spec → implement → wire → engine_spec green)
4. OrderBlock                       (spec → implement → wire → engine_spec green)
5. LiquiditySweep                   (spec → implement → wire → engine_spec green)
6. MarketStructure                  (spec → implement → wire → engine_spec green)
7. Trendline                        (spec → implement → wire → engine_spec green)
8. SessionTracker                   (spec → implement → wire → engine_spec green)
9. VolumeProfile                    (spec → implement → wire → engine_spec green)
10. Delete State class              (engine_spec green confirms no regressions)
```

---

## Success Criteria

- `bundle exec rspec` passes with 0 failures (fixes the 1 current failure).
- Every detector has at least the tests listed in the table for its spec.
- `engine_spec.rb` passes unchanged after each wiring step.
- `State` class is deleted; no references remain.
- Each detector file is ≤ 120 lines (single clear purpose).
