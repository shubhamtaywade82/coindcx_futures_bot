I’m designing this as a closed-loop trading memory system, not a self-editing AI. The bot will log every signal, replay what happened, score the setup quality, and only promote rules when the evidence is strong enough.

Thought for 5s
Direct decision

Build a persistent learning loop, not an LLM that rewrites itself.

The correct architecture is:

Signal detected
→ snapshot everything
→ persist it
→ manage the live position
→ replay after each candle/tick
→ score prediction vs reality
→ update strategy weights / thresholds
→ keep versioned history

Your DTW + SMC engines already provide the right inputs: DTW gives whale-flow / delta / exhaustion / VWAP context, and SMC gives the structural map, entry zone, trigger, and confluence context .

What you actually want

Not “trade outcome logging”.

You want a memory-backed decision system that stores:

the exact setup
all levels
all confluence points
entry rationale
SL / TP / trailing plan
live progression
whether price followed the predicted path
how much profit was available before exit
whether the exit logic was optimal
whether the signal should be trusted more or less next time

That is a trade journal + evaluator + policy optimizer.

Critical invariant

Do not let the AI directly modify live execution rules.

Use this sequence:

Detect
Persist
Execute
Monitor
Evaluate
Adjust weights
Re-run on future signals

That keeps the bot deterministic and auditable.

Recommended architecture
1) Signal Snapshot Store

When a setup appears, save a full immutable snapshot.

Store:
symbol
timeframe
timestamp
SMC state
DTW state
entry
SL
TP1 / TP2 / TP3
trailing plan
regime
confidence
expected RR
expected net edge after fees
strategy version
Example payload
{
  signal_id: "BTCUSDT-20260423-001",
  symbol: "BTCUSDT",
  timeframe: "5m",
  strategy_version: "smc_dtw_v12",
  smc: {
    htf_bias: :bull,
    h1_bias: :bull,
    m15_zone: :bull,
    m5_trigger: :choch_bull,
    bos: true,
    choch: true,
    ob: true,
    liq_sweep: :bullish,
    vp_context: :near_poc
  },
  dtw: {
    whale_buy: true,
    whale_sell: false,
    exhaustion: false,
    rvol: 2.8,
    delta_bull: true,
    vwap_side: :below,
    delta_divergence: :none,
    score: 82
  },
  plan: {
    entry: 104250.5,
    stop_loss: 103980.0,
    targets: [104920.0, 105300.0, 105900.0],
    trailing: {
      activate_after_net_profit_pct: 15.0,
      trail_type: :structure_based,
      move_sl_to_breakeven_after_rr: 1.0
    }
  },
  economics: {
    estimated_fees_pct: 0.25,
    estimated_slippage_pct: 0.10,
    required_net_edge_pct: 15.0
  }
}
2) Position Journal

For every open position, keep a live event stream.

Events:
signal_detected
order_sent
order_filled
position_opened
price_update
trailing_armed
sl_moved
tp_hit
stop_hit
manual_exit
position_closed
post_review_completed

This is the memory the bot learns from.

3) Replay Engine

After each candle/tick, replay the position against stored expectations.

It should answer:
Did price reach the predicted entry zone?
Did it respect the predicted SL location?
Did it hit TP before reversal?
Did it give enough floating profit to trail safely?
Did it move the way the setup predicted within N candles?
Was the initial thesis correct but the management bad?
Was the thesis wrong?

This distinction matters.

A trade can be:

good setup, bad execution
bad setup, good luck
good setup, good execution
bad setup, bad execution

Your optimizer must learn that separation.

4) Learning Layer

Do not use the AI to “learn” by editing prompt text every time.

Use structured learning:

Learn these weights:
SMC gate importance
DTW gate importance
RVOL thresholds
exhaustion penalty
VWAP side penalty
trailing activation threshold
SL buffer size
minimum edge required for activation
Update them from history:
win rate by setup class
average MAE / MFE
net expectancy after fees
time-to-target
reversal frequency after +X%
trailing efficiency

This gives you policy improvement without unsafe self-modification.

The 15% rule you described

You said:

only closing a single position in +ve pnl and that should be activated only at some point where fees + pnl is >= 15% and move above only etc etc

That should be implemented as a profit activation gate.

Practical version

Only enable trailing / profit-lock logic after:

net_unrealized_profit_pct >= fee_buffer_pct + activation_buffer_pct

Where:

fee_buffer_pct = estimated round-trip fees + slippage
activation_buffer_pct = your minimum practical edge buffer, e.g. 15%
Example

If:

fees + slippage = 0.35%
activation buffer = 15.0%

Then trailing activates only after net open profit crosses 15.35%.

That is the right interpretation of your rule.

Single-position management rule

If your objective is “close only a single position in +ve pnl”, then your bot should enforce:

one active position per symbol
no pyramiding
no averaging down
no second entry while one is open
trailing only after profit activation threshold
forced exit only by invalidation / SL / trailing logic
Recommended persistence model

Use a durable event store. Simple and reliable options:

SQLite if local-only
PostgreSQL if multi-process / scalable
JSONL for append-only debugging
Redis only for live state, not history
Best setup
Postgres for canonical history
Redis for live state cache
JSONL for raw forensic logs
Ruby OOP design
Core objects
SignalSnapshot

Immutable trade setup record.

PositionJournal

Stores live events and state transitions.

TradeEvaluator

Compares expected vs actual after the fact.

PolicyLearner

Updates weights/thresholds from historical results.

TrailingManager

Activates and adjusts trailing only when profit gate is satisfied.

LearningRegistry

Keeps versioned strategy parameters.

Example Ruby skeleton
# frozen_string_literal: true

module Trading
  class SignalSnapshot
    attr_reader :data

    def initialize(data)
      @data = deep_freeze(data)
    end

    private

    def deep_freeze(obj)
      case obj
      when Hash
        obj.each { |k, v| deep_freeze(v) }
        obj.freeze
      when Array
        obj.each { |v| deep_freeze(v) }
        obj.freeze
      else
        obj.freeze
      end
    end
  end

  class PositionJournal
    def initialize(store:)
      @store = store
    end

    def record_signal(snapshot)
      @store.append("signal_detected", snapshot.data)
    end

    def record_event(position_id:, type:, payload:)
      @store.append(type, { position_id: position_id, payload: payload })
    end
  end

  class TrailingManager
    def initialize(activation_net_profit_pct:, fee_buffer_pct:)
      @activation_net_profit_pct = activation_net_profit_pct
      @fee_buffer_pct = fee_buffer_pct
    end

    def trailing_active?(position)
      position.unrealized_net_profit_pct >= (@activation_net_profit_pct + @fee_buffer_pct)
    end

    def next_stop(position, market_price)
      return position.stop_loss unless trailing_active?(position)

      if position.direction == :long
        [position.stop_loss, market_price - position.trailing_distance].max
      else
        [position.stop_loss, market_price + position.trailing_distance].min
      end
    end
  end

  class TradeEvaluator
    def evaluate(snapshot:, candles:, exit_price:)
      entry = snapshot.data.dig(:plan, :entry).to_f
      sl    = snapshot.data.dig(:plan, :stop_loss).to_f
      targets = snapshot.data.dig(:plan, :targets) || []

      direction = snapshot.data.dig(:smc, :htf_bias) == :bull ? :long : :short

      mae, mfe = excursion_metrics(direction, entry, candles)

      {
        direction: direction,
        mfe: mfe,
        mae: mae,
        target_hit: targets.any? { |t| direction == :long ? candles.any? { |c| c.high >= t } : candles.any? { |c| c.low <= t } },
        stop_hit: direction == :long ? candles.any? { |c| c.low <= sl } : candles.any? { |c| c.high >= sl },
        net_result_pct: pnl_pct(direction, entry, exit_price)
      }
    end

    private

    def pnl_pct(direction, entry, exit_price)
      raw =
        if direction == :long
          (exit_price - entry) / entry * 100.0
        else
          (entry - exit_price) / entry * 100.0
        end
      raw
    end

    def excursion_metrics(direction, entry, candles)
      max_favorable = 0.0
      max_adverse = 0.0

      candles.each do |c|
        if direction == :long
          max_favorable = [max_favorable, (c.high - entry) / entry * 100.0].max
          max_adverse   = [max_adverse, (entry - c.low) / entry * 100.0].max
        else
          max_favorable = [max_favorable, (entry - c.low) / entry * 100.0].max
          max_adverse   = [max_adverse, (c.high - entry) / entry * 100.0].max
        end
      end

      [max_adverse, max_favorable]
    end
  end

  class PolicyLearner
    def initialize(store:)
      @store = store
    end

    def update_from_review(review)
      # review example:
      # { setup_class: "bull_whale_accumulation", win: true, mfe: 3.2, mae: 0.8, net_pct: 1.4 }

      current = @store.load("policy_weights") || default_weights
      updated = current.dup

      if review[:win]
        updated["dtw_weight"] = clamp(current["dtw_weight"] + 0.02, 0.1, 0.9)
      else
        updated["dtw_weight"] = clamp(current["dtw_weight"] - 0.02, 0.1, 0.9)
      end

      @store.save("policy_weights", updated)
      updated
    end

    private

    def default_weights
      { "smc_weight" => 0.55, "dtw_weight" => 0.45, "trail_activate_pct" => 15.0 }
    end

    def clamp(v, lo, hi)
      [[v, lo].max, hi].min
    end
  end
end
How the learning loop should work
At signal time

Persist:

every feature
every level
all SL/TP candidates
trailing logic
confidence
version
While position is open

On every update:

store current price
compute unrealized pnl
compute MFE / MAE
detect if trailing should activate
move stop if rules allow
On exit

Store:

exit reason
realized pnl
fees
slippage
max favorable excursion
max adverse excursion
whether TP/SL/trail was optimal
On review

Aggregate by setup class:

bullish accumulation
bearish distribution
exhaustion reversal
breakout continuation
sweep + CHoCH
OB tap + VWAP

Then adjust:

score thresholds
activation buffers
trailing distances
confidence cutoffs
conflict penalties
What the AI should do in this system

Not decide the whole thing alone.

It should:

summarize the current setup
explain the reason for the signal
classify the setup type
propose SL / TP / trail logic
compare current live behavior against the original thesis
rank whether the trade is still valid

The AI is the analyst.
Your engine is the executor.
Your journal is the memory.

Hard rule for your “15%+ only” objective

If you want the bot to only keep a trade until it has a meaningful positive edge, then enforce this gate:

def should_arm_trailing?(position)
  net_profit_pct = position.unrealized_gross_pct - position.estimated_fees_pct - position.estimated_slippage_pct
  net_profit_pct >= 15.0
end

You can also require:

price above entry by a minimum structure distance
no opposite-side DTW exhaustion
no invalidation of SMC bias

That prevents premature trailing on weak noise.

Final recommendation

Build it as four persistent layers:

Signal Snapshot
Live Position Journal
Replay Evaluator
Policy Learner

That is the correct way to make the bot improve continuously without becoming unstable.

If you want, I will convert this into a complete Ruby folder structure with concrete classes, JSON schema, and SQLite/Postgres storage layer next.

What other things we have based on ohlcv data which is data and we need to build information for the ai
Direct answer

You already extract ~80% of useful signal space (SMC + DTW).
What’s missing is systematically structuring the remaining OHLCV-derived information into machine-consumable features.

The goal is:

Raw OHLCV → Derived Features → Structured Information → AI Decision

Not:

OHLCV → AI guessing
Full OHLCV → Information Taxonomy (what you should build)

This is the complete feature surface you can extract without external data.

1. Market Structure (you already have, but extend it)
Add:
Structure strength (weak vs strong trend)
Pullback depth (% retracement)
Swing velocity (time between swings)
Structural inefficiency (fast vs slow moves)
Feature example
{
  "structure": {
    "trend": "bull",
    "strength": "strong",
    "last_bos_distance_pct": 1.8,
    "pullback_depth_pct": 38.2,
    "swing_velocity": "fast"
  }
}
2. Liquidity Intelligence (upgrade this)

You already detect sweeps, but add:

Add:
Liquidity density (how many equal highs/lows)
Untapped liquidity zones
Distance to nearest liquidity
Liquidity taken recently (recency score)
Feature
{
  "liquidity": {
    "nearest_liq_distance_pct": 0.6,
    "equal_highs_count": 3,
    "recent_sweep": "sell_side",
    "untapped_liquidity_above": true
  }
}
3. Imbalance / Efficiency (FVG + displacement)
Add:
FVG size
FVG fill percentage
Displacement strength
Efficiency ratio (move vs noise)
Feature
{
  "imbalance": {
    "fvg_active": true,
    "fvg_fill_pct": 40,
    "displacement_strength": "high",
    "efficiency_ratio": 0.78
  }
}
4. Volatility Regime (critical missing)

You only use ATR — not enough.

Add:
Volatility regime: low / normal / high
Expansion phase vs compression phase
Volatility shift detection
Feature
{
  "volatility": {
    "regime": "expansion",
    "atr_percentile": 82,
    "compression_breakout": true
  }
}
5. Volume Intelligence (you have partially via DTW)

Extend beyond anomaly:

Add:
Volume trend (increasing/decreasing)
Volume confirmation vs price
Climax detection
Absorption zones persistence
Feature
{
  "volume": {
    "trend": "increasing",
    "price_volume_alignment": true,
    "climax": false,
    "absorption_zone_active": true
  }
}
6. Candle Microstructure

This is underused but powerful.

Add:
Wick dominance
Body efficiency
Rejection zones
Compression candles
Feature
{
  "candle": {
    "upper_wick_pct": 65,
    "lower_wick_pct": 10,
    "body_efficiency": 0.7,
    "rejection": "bearish"
  }
}
7. Time & Session Context

You already track sessions — extend:

Add:
Session phase (open / mid / close)
Session expansion likelihood
Killzone classification
Time-based bias
Feature
{
  "session": {
    "current": "london",
    "phase": "open",
    "expansion_expected": true
  }
}
8. Range & Positioning

Critical for entries.

Add:
Range percentile (0–100)
Premium / discount % (not just boolean)
Distance from VWAP
Distance from mean
Feature
{
  "positioning": {
    "range_percentile": 72,
    "premium_discount": 0.68,
    "distance_from_vwap_pct": -0.4
  }
}
9. Momentum & Impulse

Derived from candles, not RSI.

Add:
Momentum bursts
Consecutive candle strength
Deceleration detection
Feature
{
  "momentum": {
    "impulse": "strong",
    "consecutive_bull_candles": 4,
    "decelerating": false
  }
}
10. Statistical Context (VERY IMPORTANT)

This is what makes the system adaptive.

Add:
Historical win rate of similar setups
Average RR
Probability of TP hit
Time-to-target distribution
Feature
{
  "statistics": {
    "setup_class": "bull_ob_sweep",
    "win_rate": 0.62,
    "avg_rr": 2.1,
    "tp1_hit_prob": 0.78
  }
}
11. Trade Quality Metrics (missing)
Add:
Expected edge after fees
Risk-to-reward ratio
SL tightness vs volatility
Feature
{
  "trade_quality": {
    "rr": 2.5,
    "expected_edge_pct": 18.2,
    "sl_volatility_ratio": 1.2
  }
}
12. Conflict Matrix (CRITICAL FOR AI)

Instead of letting AI guess conflicts, provide them.

Example
{
  "conflicts": {
    "smc_bull_vs_dtw_distribution": false,
    "momentum_vs_structure": false,
    "volume_vs_price": true
  }
}
Final Feature Packet (what AI should see)
{
  "smc": { ... },
  "dtw": { ... },
  "structure": { ... },
  "liquidity": { ... },
  "imbalance": { ... },
  "volatility": { ... },
  "volume": { ... },
  "candle": { ... },
  "session": { ... },
  "positioning": { ... },
  "momentum": { ... },
  "statistics": { ... },
  "trade_quality": { ... },
  "conflicts": { ... },
  "risk": { ... }
}
Critical insight

Right now your AI prompt is:

SMC + DTW → decision

That’s good but incomplete.

What you should move to:

SMC (structure)
+ DTW (participation)
+ Regime (volatility + session)
+ Positioning (range + VWAP)
+ Statistics (historical edge)
+ Trade quality (RR + fees)
→ AI decision
What this unlocks
AI stops hallucinating
Decisions become consistent
You can debug every decision
You can evolve strategy using real data
You move toward quant-grade system
Next step (recommended)

Build:

FeatureEnricher layer in your Ruby bot
features = FeatureEnricher.call(
  candles: candles,
  smc: smc_data,
  dtw: dtw_data,
  history: past_trades
)

Then send only enriched features to AI.

Final note

You don’t need more indicators.

You need:

better feature engineering
structured information
feedback loop

That’s the difference between:

retail bot ❌
institutional system ✅

If you want, I can build a complete Ruby FeatureEnricher implementation next that plugs directly into your current bot.

Yes

Direct answer

You already extract ~80% of useful signal space (SMC + DTW).
What’s missing is systematically structuring the remaining OHLCV-derived information into machine-consumable features.

The goal is:

Raw OHLCV → Derived Features → Structured Information → AI Decision

Not:

OHLCV → AI guessing


---

Full OHLCV → Information Taxonomy (what you should build)

This is the complete feature surface you can extract without external data.


---

1. Market Structure (you already have, but extend it)

Add:

Structure strength (weak vs strong trend)

Pullback depth (% retracement)

Swing velocity (time between swings)

Structural inefficiency (fast vs slow moves)


Feature example

{
  "structure": {
    "trend": "bull",
    "strength": "strong",
    "last_bos_distance_pct": 1.8,
    "pullback_depth_pct": 38.2,
    "swing_velocity": "fast"
  }
}


---

2. Liquidity Intelligence (upgrade this)

You already detect sweeps, but add:

Add:

Liquidity density (how many equal highs/lows)

Untapped liquidity zones

Distance to nearest liquidity

Liquidity taken recently (recency score)


Feature

{
  "liquidity": {
    "nearest_liq_distance_pct": 0.6,
    "equal_highs_count": 3,
    "recent_sweep": "sell_side",
    "untapped_liquidity_above": true
  }
}


---

3. Imbalance / Efficiency (FVG + displacement)

Add:

FVG size

FVG fill percentage

Displacement strength

Efficiency ratio (move vs noise)


Feature

{
  "imbalance": {
    "fvg_active": true,
    "fvg_fill_pct": 40,
    "displacement_strength": "high",
    "efficiency_ratio": 0.78
  }
}


---

4. Volatility Regime (critical missing)

You only use ATR — not enough.

Add:

Volatility regime: low / normal / high

Expansion phase vs compression phase

Volatility shift detection


Feature

{
  "volatility": {
    "regime": "expansion",
    "atr_percentile": 82,
    "compression_breakout": true
  }
}


---

5. Volume Intelligence (you have partially via DTW)

Extend beyond anomaly:

Add:

Volume trend (increasing/decreasing)

Volume confirmation vs price

Climax detection

Absorption zones persistence


Feature

{
  "volume": {
    "trend": "increasing",
    "price_volume_alignment": true,
    "climax": false,
    "absorption_zone_active": true
  }
}


---

6. Candle Microstructure

This is underused but powerful.

Add:

Wick dominance

Body efficiency

Rejection zones

Compression candles


Feature

{
  "candle": {
    "upper_wick_pct": 65,
    "lower_wick_pct": 10,
    "body_efficiency": 0.7,
    "rejection": "bearish"
  }
}


---

7. Time & Session Context

You already track sessions — extend:

Add:

Session phase (open / mid / close)

Session expansion likelihood

Killzone classification

Time-based bias


Feature

{
  "session": {
    "current": "london",
    "phase": "open",
    "expansion_expected": true
  }
}


---

8. Range & Positioning

Critical for entries.

Add:

Range percentile (0–100)

Premium / discount % (not just boolean)

Distance from VWAP

Distance from mean


Feature

{
  "positioning": {
    "range_percentile": 72,
    "premium_discount": 0.68,
    "distance_from_vwap_pct": -0.4
  }
}


---

9. Momentum & Impulse

Derived from candles, not RSI.

Add:

Momentum bursts

Consecutive candle strength

Deceleration detection


Feature

{
  "momentum": {
    "impulse": "strong",
    "consecutive_bull_candles": 4,
    "decelerating": false
  }
}


---

10. Statistical Context (VERY IMPORTANT)

This is what makes the system adaptive.

Add:

Historical win rate of similar setups

Average RR

Probability of TP hit

Time-to-target distribution


Feature

{
  "statistics": {
    "setup_class": "bull_ob_sweep",
    "win_rate": 0.62,
    "avg_rr": 2.1,
    "tp1_hit_prob": 0.78
  }
}


---

11. Trade Quality Metrics (missing)

Add:

Expected edge after fees

Risk-to-reward ratio

SL tightness vs volatility


Feature

{
  "trade_quality": {
    "rr": 2.5,
    "expected_edge_pct": 18.2,
    "sl_volatility_ratio": 1.2
  }
}


---

12. Conflict Matrix (CRITICAL FOR AI)

Instead of letting AI guess conflicts, provide them.

Example

{
  "conflicts": {
    "smc_bull_vs_dtw_distribution": false,
    "momentum_vs_structure": false,
    "volume_vs_price": true
  }
}


---

Final Feature Packet (what AI should see)

{
  "smc": { ... },
  "dtw": { ... },
  "structure": { ... },
  "liquidity": { ... },
  "imbalance": { ... },
  "volatility": { ... },
  "volume": { ... },
  "candle": { ... },
  "session": { ... },
  "positioning": { ... },
  "momentum": { ... },
  "statistics": { ... },
  "trade_quality": { ... },
  "conflicts": { ... },
  "risk": { ... }
}


---

Critical insight

Right now your AI prompt is:

SMC + DTW → decision

That’s good but incomplete.

What you should move to:

SMC (structure)
+ DTW (participation)
+ Regime (volatility + session)
+ Positioning (range + VWAP)
+ Statistics (historical edge)
+ Trade quality (RR + fees)
→ AI decision


---

What this unlocks

AI stops hallucinating

Decisions become consistent

You can debug every decision

You can evolve strategy using real data

You move toward quant-grade system



---

Next step (recommended)

Build:

FeatureEnricher layer in your Ruby bot

features = FeatureEnricher.call(
  candles: candles,
  smc: smc_data,
  dtw: dtw_data,
  history: past_trades
)

Then send only enriched features to AI.


---

Final note

You don’t need more indicators.

You need:

better feature engineering

structured information

feedback loop


That’s the difference between:

retail bot ❌

institutional system ✅



---

If you want, I can build a complete Ruby FeatureEnricher implementation next that plugs directly into your current bot.

I’m turning the feature taxonomy into a concrete Ruby enricher with deterministic calculations and a single entrypoint. It will emit one structured packet your AI can consume directly, while preserving the same SMC and DTW primitives already present in your scripts

Thought for 18s

This is the right next layer. Your DTW script already extracts whale-volume, delta proxy, absorption, exhaustion, and VWAP context, while the SMC script already provides the multi-timeframe structure stack, OB/sweep logic, sessions, and volume-profile confluence . The missing piece is a deterministic feature enricher that converts raw OHLCV into stable machine-consumable information before the AI sees it.

lib/feature_enricher.rb
# frozen_string_literal: true

require "time"

module TradingAI
  Candle = Struct.new(:timestamp, :open, :high, :low, :close, :volume, keyword_init: true) do
    def range
      high - low
    end

    def body
      (close - open).abs
    end

    def bullish?
      close > open
    end

    def bearish?
      close < open
    end

    def body_efficiency
      return 0.0 if range <= 0.0
      body / range
    end

    def upper_wick
      high - [open, close].max
    end

    def lower_wick
      [open, close].min - low
    end

    def wick_dominance
      r = range
      return 0.0 if r <= 0.0
      [upper_wick, lower_wick].max / r
    end

    def tp
      (high + low + close) / 3.0
    end
  end

  class FeatureEnricher
    DEFAULTS = {
      swing_lookback: 3,
      structure_lookback: 50,
      liquidity_lookback: 50,
      imbalance_lookback: 30,
      volatility_lookback: 50,
      volume_short: 5,
      volume_long: 20,
      momentum_lookback: 10,
      position_lookback: 100,
      atr_period: 14,
      equal_level_tolerance_pct: 0.15,
      max_target_count: 3,
      fees_buffer_pct: 0.35,
      trailing_activation_pct: 15.0
    }.freeze

    def self.call(candles:, smc:, dtw:, history: [], entry: nil, stop_loss: nil, targets: [], symbol: nil, timeframe: nil, tz_offset_minutes: 0, options: {})
      new(
        candles: candles,
        smc: smc,
        dtw: dtw,
        history: history,
        entry: entry,
        stop_loss: stop_loss,
        targets: targets,
        symbol: symbol,
        timeframe: timeframe,
        tz_offset_minutes: tz_offset_minutes,
        options: options
      ).call
    end

    def initialize(candles:, smc:, dtw:, history:, entry:, stop_loss:, targets:, symbol:, timeframe:, tz_offset_minutes:, options:)
      @candles = normalize_candles(candles)
      @smc = deep_symbolize(smc || {})
      @dtw = deep_symbolize(dtw || {})
      @history = Array(history)
      @entry = entry
      @stop_loss = stop_loss
      @targets = Array(targets).compact.first(DEFAULTS[:max_target_count])
      @symbol = symbol
      @timeframe = timeframe
      @tz_offset_minutes = tz_offset_minutes
      @options = DEFAULTS.merge(options || {})
    end

    def call
      raise ArgumentError, "candles cannot be empty" if @candles.empty?

      atr_series = atr_series(@candles, @options[:atr_period])
      vwap_series = vwap_series(@candles)
      volume_series = @candles.map(&:volume)
      close_series = @candles.map(&:close)
      high_series = @candles.map(&:high)
      low_series = @candles.map(&:low)
      body_series = @candles.map(&:body)
      range_series = @candles.map(&:range)

      pivots = detect_pivots(@candles, lookback: @options[:swing_lookback])

      structure = structure_features(
        candles: @candles,
        pivots: pivots,
        atr_series: atr_series,
        close_series: close_series,
        high_series: high_series,
        low_series: low_series
      )

      liquidity = liquidity_features(
        candles: @candles,
        pivots: pivots,
        tolerance_pct: @options[:equal_level_tolerance_pct],
        atr_series: atr_series
      )

      imbalance = imbalance_features(
        candles: @candles,
        lookback: @options[:imbalance_lookback]
      )

      volatility = volatility_features(
        candles: @candles,
        atr_series: atr_series,
        lookback: @options[:volatility_lookback]
      )

      volume = volume_features(
        candles: @candles,
        volume_series: volume_series,
        close_series: close_series,
        high_series: high_series,
        low_series: low_series
      )

      candle = candle_features(@candles.last, atr_series.last, volume_series)

      session = session_features(@candles.last.timestamp, @tz_offset_minutes)

      positioning = positioning_features(
        candles: @candles,
        vwap_series: vwap_series,
        lookback: @options[:position_lookback]
      )

      momentum = momentum_features(
        candles: @candles,
        atr_series: atr_series,
        lookback: @options[:momentum_lookback]
      )

      statistics = statistics_features

      risk = risk_features(
        atr: atr_series.last,
        entry: @entry,
        stop_loss: @stop_loss,
        targets: @targets,
        structure: structure,
        volatility: volatility
      )

      trade_quality = trade_quality_features(
        entry: @entry,
        stop_loss: @stop_loss,
        targets: @targets,
        statistics: statistics,
        risk: risk
      )

      conflicts = conflict_matrix(
        structure: structure,
        momentum: momentum,
        volume: volume,
        dtw: @dtw
      )

      {
        symbol: @symbol,
        timeframe: @timeframe,
        price: @candles.last.close,
        smc: @smc,
        dtw: @dtw,
        structure: structure,
        liquidity: liquidity,
        imbalance: imbalance,
        volatility: volatility,
        volume: volume,
        candle: candle,
        session: session,
        positioning: positioning,
        momentum: momentum,
        statistics: statistics,
        trade_quality: trade_quality,
        conflicts: conflicts,
        risk: risk,
        meta: {
          candle_count: @candles.size,
          last_timestamp: @candles.last.timestamp,
          enriched_at: Time.now.utc.iso8601
        }
      }
    end

    private

    def normalize_candles(candles)
      Array(candles).map do |c|
        if c.is_a?(Candle)
          c
        else
          h = deep_symbolize(c)
          Candle.new(
            timestamp: normalize_time(h[:timestamp]),
            open: h[:open].to_f,
            high: h[:high].to_f,
            low: h[:low].to_f,
            close: h[:close].to_f,
            volume: h[:volume].to_f
          )
        end
      end
    end

    def normalize_time(value)
      return value if value.is_a?(Time)
      return Time.at(value).utc if value.is_a?(Integer)
      return Time.parse(value.to_s).utc if value.respond_to?(:to_s)

      Time.now.utc
    rescue StandardError
      Time.now.utc
    end

    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = deep_symbolize(v)
        end
      when Array
        obj.map { |v| deep_symbolize(v) }
      else
        obj
      end
    end

    def mean(values)
      return 0.0 if values.empty?
      values.sum.to_f / values.size
    end

    def stddev(values)
      return 0.0 if values.size < 2
      m = mean(values)
      variance = values.sum { |v| (v - m)**2 } / values.size.to_f
      Math.sqrt(variance)
    end

    def ema_series(values, period)
      return [] if values.empty?

      k = 2.0 / (period + 1.0)
      out = []
      values.each_with_index do |v, i|
        out << (i.zero? ? v.to_f : (v * k) + (out[-1] * (1.0 - k)))
      end
      out
    end

    def sma_series(values, period)
      return [] if values.empty?

      out = []
      values.each_index do |i|
        window = values[[0, i - period + 1].max..i]
        out << mean(window)
      end
      out
    end

    def atr_series(candles, period)
      trs = candles.each_with_index.map do |c, i|
        if i.zero?
          c.high - c.low
        else
          prev = candles[i - 1]
          [c.high - c.low, (c.high - prev.close).abs, (c.low - prev.close).abs].max
        end
      end

      sma_series(trs, period)
    end

    def vwap_series(candles)
      cum_tp_vol = 0.0
      cum_vol = 0.0

      candles.map do |c|
        cum_tp_vol += c.tp * c.volume
        cum_vol += c.volume
        cum_vol.positive? ? (cum_tp_vol / cum_vol) : c.close
      end
    end

    def percentile_rank(series, value)
      return 0.0 if series.empty?

      less_or_equal = series.count { |v| v <= value }
      (less_or_equal.to_f / series.size.to_f) * 100.0
    end

    def clamp(x, lo, hi)
      [[x, lo].max, hi].min
    end

    def detect_pivots(candles, lookback:)
      highs = []
      lows = []

      return { highs: highs, lows: lows } if candles.size < (lookback * 2 + 1)

      (lookback...(candles.size - lookback)).each do |i|
        window = candles[(i - lookback)..(i + lookback)]
        center = candles[i]

        if window.all? { |c| center.high >= c.high }
          highs << { index: i, price: center.high, timestamp: center.timestamp }
        end

        if window.all? { |c| center.low <= c.low }
          lows << { index: i, price: center.low, timestamp: center.timestamp }
        end
      end

      { highs: highs, lows: lows }
    end

    def structure_features(candles:, pivots:, atr_series:, close_series:, high_series:, low_series:)
      recent = candles.last(50)
      recent_closes = recent.map(&:close)
      recent_high = recent.map(&:high).max
      recent_low = recent.map(&:low).min

      ema_fast = ema_series(close_series, 9).last.to_f
      ema_slow = ema_series(close_series, 21).last.to_f

      trend =
        if ema_fast > ema_slow && close_series.last >= ema_fast
          "bull"
        elsif ema_fast < ema_slow && close_series.last <= ema_fast
          "bear"
        else
          "neutral"
        end

      strength =
        if trend == "neutral"
          "weak"
        else
          spread = ((ema_fast - ema_slow).abs / [atr_series.last.to_f, 0.0001].max) * 100.0
          spread >= 80.0 ? "strong" : "moderate"
        end

      last_high_pivot = pivots[:highs].last
      last_low_pivot = pivots[:lows].last
      last_close = close_series.last.to_f

      last_bos_distance_pct =
        case trend
        when "bull"
          if last_high_pivot && last_close > last_high_pivot[:price]
            ((last_close - last_high_pivot[:price]).abs / last_close) * 100.0
          else
            0.0
          end
        when "bear"
          if last_low_pivot && last_close < last_low_pivot[:price]
            ((last_low_pivot[:price] - last_close).abs / last_close) * 100.0
          else
            0.0
          end
        else
          0.0
        end

      pullback_depth_pct =
        if trend == "bull" && (recent_high - recent_low) > 0
          ((recent_high - last_close) / (recent_high - recent_low)) * 100.0
        elsif trend == "bear" && (recent_high - recent_low) > 0
          ((last_close - recent_low) / (recent_high - recent_low)) * 100.0
        else
          0.0
        end

      swing_velocity =
        if pivots[:highs].size >= 2 || pivots[:lows].size >= 2
          last_a = (pivots[:highs].last || pivots[:lows].last)
          prev_a = (pivots[:highs][-2] || pivots[:lows][-2])

          if last_a && prev_a
            bars_between = (last_a[:index] - prev_a[:index]).abs
            bars_between <= 8 ? "fast" : bars_between <= 20 ? "normal" : "slow"
          else
            "unknown"
          end
        else
          "unknown"
        end

      structural_inefficiency =
        case swing_velocity
        when "fast" then "high"
        when "normal" then "medium"
        when "slow" then "low"
        else "unknown"
        end

      {
        trend: trend,
        strength: strength,
        last_bos_distance_pct: last_bos_distance_pct.round(2),
        pullback_depth_pct: pullback_depth_pct.round(2),
        swing_velocity: swing_velocity,
        structural_inefficiency: structural_inefficiency
      }
    end

    def liquidity_features(candles:, pivots:, tolerance_pct:, atr_series:)
      tolerance = tolerance_pct / 100.0
      pivot_highs = pivots[:highs]
      pivot_lows = pivots[:lows]
      last_close = candles.last.close

      equal_highs_count = count_clustered_levels(pivot_highs.map { |p| p[:price] }, tolerance)
      equal_lows_count  = count_clustered_levels(pivot_lows.map { |p| p[:price] }, tolerance)

      nearest_high = pivot_highs.map { |p| p[:price] }.min_by { |p| (p - last_close).abs }
      nearest_low  = pivot_lows.map  { |p| p[:price] }.min_by { |p| (p - last_close).abs }

      nearest_liq =
        [nearest_high, nearest_low].compact.min_by { |p| (p - last_close).abs }

      nearest_liq_distance_pct =
        if nearest_liq
          ((nearest_liq - last_close).abs / last_close) * 100.0
        else
          0.0
        end

      last = candles.last
      recent_high = candles.last(20).map(&:high).max
      recent_low = candles.last(20).map(&:low).min

      recent_sweep =
        if pivot_highs.any? && last.high > pivot_highs.last[:price] && last.close < pivot_highs.last[:price]
          "buy_side"
        elsif pivot_lows.any? && last.low < pivot_lows.last[:price] && last.close > pivot_lows.last[:price]
          "sell_side"
        else
          "none"
        end

      untapped_liquidity_above = nearest_high && last_close < nearest_high
      untapped_liquidity_below = nearest_low && last_close > nearest_low

      recency_score =
        if recent_sweep == "none"
          0.0
        elsif last.range > 0 && atr_series.last.to_f > 0
          clamp((last.range / atr_series.last.to_f) * 100.0, 0.0, 100.0)
        else
          0.0
        end

      {
        nearest_liq_distance_pct: nearest_liq_distance_pct.round(2),
        equal_highs_count: equal_highs_count,
        equal_lows_count: equal_lows_count,
        recent_sweep: recent_sweep,
        untapped_liquidity_above: !!untapped_liquidity_above,
        untapped_liquidity_below: !!untapped_liquidity_below,
        recency_score: recency_score.round(2),
        recent_range_high: recent_high,
        recent_range_low: recent_low
      }
    end

    def count_clustered_levels(levels, tolerance)
      levels = levels.compact.sort
      return 0 if levels.size < 2

      clusters = 0
      i = 0

      while i < levels.size - 1
        j = i + 1
        cluster_count = 1

        while j < levels.size && levels[j] <= levels[i] * (1.0 + tolerance)
          cluster_count += 1
          j += 1
        end

        clusters += 1 if cluster_count >= 2
        i = j
      end

      clusters
    end

    def imbalance_features(candles:, lookback:)
      gaps = []

      candles.each_cons(3).with_index do |(c1, c2, c3), idx|
        if c1.high < c3.low
          gaps << {
            type: "bullish",
            start_index: idx,
            end_index: idx + 2,
            lower: c1.high,
            upper: c3.low,
            width: (c3.low - c1.high).abs
          }
        elsif c1.low > c3.high
          gaps << {
            type: "bearish",
            start_index: idx,
            end_index: idx + 2,
            lower: c3.high,
            upper: c1.low,
            width: (c1.low - c3.high).abs
          }
        end
      end

      active = gaps.last(lookback).reverse.find do |gap|
        last = candles.last
        case gap[:type]
        when "bullish"
          last.low <= gap[:upper]
        when "bearish"
          last.high >= gap[:lower]
        else
          false
        end
      end

      fill_pct =
        if active.nil?
          0.0
        elsif active[:type] == "bullish"
          last = candles.last
          overlap = [last.high, active[:upper]].min - active[:lower]
          clamp((overlap / [active[:width], 0.0001].max) * 100.0, 0.0, 100.0)
        else
          last = candles.last
          overlap = active[:upper] - [last.low, active[:lower]].max
          clamp((overlap / [active[:width], 0.0001].max) * 100.0, 0.0, 100.0)
        end

      displacement_strength =
        if active.nil?
          "none"
        elsif active[:width] > candles.last.range * 0.75
          "high"
        elsif active[:width] > candles.last.range * 0.35
          "medium"
        else
          "low"
        end

      efficiency_ratio =
        if candles.last.range > 0.0
          candles.last.body / candles.last.range
        else
          0.0
        end

      {
        fvg_active: !active.nil?,
        fvg_type: active&.dig(:type),
        fvg_fill_pct: fill_pct.round(2),
        fvg_width: active&.dig(:width)&.round(6),
        displacement_strength: displacement_strength,
        efficiency_ratio: efficiency_ratio.round(4)
      }
    end

    def volatility_features(candles:, atr_series:, lookback:)
      atrs = atr_series.last(lookback).compact
      current_atr = atr_series.last.to_f

      atr_percentile = percentile_rank(atrs, current_atr)
      regime =
        if atr_percentile >= 75.0
          "high"
        elsif atr_percentile <= 25.0
          "low"
        else
          "normal"
        end

      recent_atr_mean = mean(atrs.last([5, atrs.size].min))
      prior_atr_mean = mean(atrs.first([atrs.size - 5, 1].max))

      compression_breakout =
        prior_atr_mean.positive? &&
        recent_atr_mean > prior_atr_mean * 1.25 &&
        candles.last.close > candles.last(lookback).map(&:high).max

      {
        regime: regime,
        atr: current_atr.round(6),
        atr_percentile: atr_percentile.round(2),
        compression_breakout: compression_breakout,
        atr_trend: current_atr > prior_atr_mean ? "expanding" : "contracting"
      }
    end

    def volume_features(candles:, volume_series:, close_series:, high_series:, low_series:)
      short_avg = mean(volume_series.last([@options[:volume_short], volume_series.size].min))
      long_avg  = mean(volume_series.last([@options[:volume_long], volume_series.size].min))

      volume_trend =
        if short_avg > long_avg * 1.05
          "increasing"
        elsif short_avg < long_avg * 0.95
          "decreasing"
        else
          "flat"
        end

      price_trend =
        if close_series.last > close_series.first
          "up"
        elsif close_series.last < close_series.first
          "down"
        else
          "flat"
        end

      price_volume_alignment =
        (price_trend == "up" && volume_trend == "increasing") ||
        (price_trend == "down" && volume_trend == "increasing") ||
        volume_trend == "flat"

      last = candles.last
      vol_percentile = percentile_rank(volume_series.last(50), last.volume)
      range_percentile = percentile_rank(candles.last(50).map(&:range), last.range)

      climax = vol_percentile >= 90.0 && range_percentile >= 80.0
      absorption_zone_active = vol_percentile >= 80.0 && last.body_efficiency <= 0.25

      {
        trend: volume_trend,
        price_trend: price_trend,
        price_volume_alignment: price_volume_alignment,
        climax: climax,
        absorption_zone_active: absorption_zone_active,
        volume_percentile: vol_percentile.round(2),
        range_percentile: range_percentile.round(2),
        short_avg: short_avg.round(6),
        long_avg: long_avg.round(6)
      }
    end

    def candle_features(last, atr_value, volume_series)
      last_atr = [atr_value.to_f, 0.0001].max
      upper_wick_pct = (last.upper_wick / [last.range, 0.0001].max) * 100.0
      lower_wick_pct = (last.lower_wick / [last.range, 0.0001].max) * 100.0
      body_eff = last.body_efficiency

      rejection =
        if upper_wick_pct >= 55.0 && last.bearish?
          "bearish"
        elsif lower_wick_pct >= 55.0 && last.bullish?
          "bullish"
        else
          "none"
        end

      compression = body_eff <= 0.25 && last.range < last_atr * 0.5
      momentum = body_eff >= 0.65 && last.range > last_atr * 0.75

      {
        upper_wick_pct: upper_wick_pct.round(2),
        lower_wick_pct: lower_wick_pct.round(2),
        body_efficiency: body_eff.round(4),
        rejection: rejection,
        compression: compression,
        momentum_candle: momentum
      }
    end

    def session_features(timestamp, tz_offset_minutes)
      local_time = timestamp.utc + (tz_offset_minutes * 60)
      minutes = (local_time.hour * 60) + local_time.min

      current =
        if minutes >= 0 && minutes < 8 * 60
          "asia"
        elsif minutes >= 8 * 60 && minutes < 16 * 60
          "london"
        elsif minutes >= 13 * 60 && minutes < 21 * 60
          "ny"
        else
          "off_session"
        end

      phase =
        case current
        when "asia"
          minutes < 2 * 60 ? "open" : minutes < 6 * 60 ? "mid" : "close"
        when "london"
          minutes < 10 * 60 ? "open" : minutes < 14 * 60 ? "mid" : "close"
        when "ny"
          minutes < 15 * 60 ? "open" : minutes < 19 * 60 ? "mid" : "close"
        else
          "inactive"
        end

      expansion_expected = %w[london ny].include?(current) && phase == "open"

      {
        current: current,
        phase: phase,
        expansion_expected: expansion_expected,
        timestamp_utc: timestamp.utc.iso8601
      }
    end

    def positioning_features(candles:, vwap_series:, lookback:)
      recent = candles.last([lookback, candles.size].min)
      highest = recent.map(&:high).max
      lowest  = recent.map(&:low).min
      last = candles.last
      vwap = vwap_series.last.to_f

      range_percentile =
        if (highest - lowest) > 0.0
          ((last.close - lowest) / (highest - lowest)) * 100.0
        else
          50.0
        end

      premium_discount =
        if (highest - lowest) > 0.0
          (last.close - lowest) / (highest - lowest)
        else
          0.5
        end

      distance_from_vwap_pct =
        if vwap > 0.0
          ((last.close - vwap) / vwap) * 100.0
        else
          0.0
        end

      mean_close = mean(recent.map(&:close))
      distance_from_mean_pct =
        if mean_close > 0.0
          ((last.close - mean_close) / mean_close) * 100.0
        else
          0.0
        end

      {
        range_percentile: range_percentile.round(2),
        premium_discount: premium_discount.round(4),
        distance_from_vwap_pct: distance_from_vwap_pct.round(4),
        distance_from_mean_pct: distance_from_mean_pct.round(4)
      }
    end

    def momentum_features(candles:, atr_series:, lookback:)
      recent = candles.last([lookback, candles.size].min)
      last = candles.last
      atr = [atr_series.last.to_f, 0.0001].max

      body_to_atr = last.body / atr
      impulse =
        if body_to_atr >= 1.0
          "strong"
        elsif body_to_atr >= 0.6
          "moderate"
        else
          "weak"
        end

      consecutive_bull = 0
      consecutive_bear = 0

      candles.reverse_each do |c|
        break unless c.bullish?
        consecutive_bull += 1
      end

      candles.reverse_each do |c|
        break unless c.bearish?
        consecutive_bear += 1
      end

      recent_bodies = recent.map(&:body)
      recent_vols = recent.map(&:volume)

      decelerating =
        if recent_bodies.size >= 6
          first_half = mean(recent_bodies.first(recent_bodies.size / 2))
          second_half = mean(recent_bodies.last(recent_bodies.size / 2))
          first_vol_half = mean(recent_vols.first(recent_vols.size / 2))
          second_vol_half = mean(recent_vols.last(recent_vols.size / 2))

          second_half < first_half * 0.9 && second_vol_half < first_vol_half * 0.9
        else
          false
        end

      {
        impulse: impulse,
        consecutive_bull_candles: consecutive_bull,
        consecutive_bear_candles: consecutive_bear,
        decelerating: decelerating,
        body_to_atr: body_to_atr.round(4)
      }
    end

    def setup_class
      if @smc[:htf_bias] == "bull" && @dtw[:whale_buy]
        "bull_accumulation"
      elsif @smc[:htf_bias] == "bear" && @dtw[:whale_sell]
        "bear_distribution"
      elsif @dtw[:exhaustion]
        "exhaustion"
      elsif @dtw[:iceberg]
        "absorption"
      else
        "neutral"
      end
    end

    def statistics_features
      relevant = @history.select do |h|
        h = deep_symbolize(h)
        h[:setup_class].to_s == setup_class
      end

      wins = relevant.count { |h| deep_symbolize(h)[:win] == true }
      total = relevant.size
      win_rate = total.positive? ? wins.to_f / total.to_f : 0.0

      rr_values = relevant.map { |h| deep_symbolize(h)[:rr] }.compact.map(&:to_f)
      tp1_hits = relevant.count { |h| deep_symbolize(h)[:tp1_hit] == true }

      avg_rr = rr_values.any? ? mean(rr_values) : 0.0
      tp1_hit_prob = total.positive? ? tp1_hits.to_f / total.to_f : 0.0

      {
        setup_class: setup_class,
        sample_size: total,
        win_rate: win_rate.round(4),
        avg_rr: avg_rr.round(4),
        tp1_hit_prob: tp1_hit_prob.round(4)
      }
    end

    def risk_features(atr:, entry:, stop_loss:, targets:, structure:, volatility:)
      atr = atr.to_f
      entry = entry&.to_f
      stop_loss = stop_loss&.to_f
      first_target = targets.first&.to_f

      sl_distance_pct =
        if entry && stop_loss && entry > 0.0
          ((entry - stop_loss).abs / entry) * 100.0
        else
          0.0
        end

      sl_volatility_ratio =
        if atr > 0.0 && entry && stop_loss
          (entry - stop_loss).abs / atr
        else
          0.0
        end

      target_distance_pct =
        if entry && first_target && entry > 0.0
          ((first_target - entry).abs / entry) * 100.0
        else
          0.0
        end

      {
        atr: atr.round(6),
        stop_loss_distance_pct: sl_distance_pct.round(4),
        sl_volatility_ratio: sl_volatility_ratio.round(4),
        first_target_distance_pct: target_distance_pct.round(4),
        suggested_trailing_activation_pct: @options[:trailing_activation_pct],
        fees_buffer_pct: @options[:fees_buffer_pct]
      }
    end

    def trade_quality_features(entry:, stop_loss:, targets:, statistics:, risk:)
      entry = entry&.to_f
      stop_loss = stop_loss&.to_f
      first_target = targets.first&.to_f

      rr =
        if entry && stop_loss && first_target && (entry - stop_loss).abs > 0.0
          (first_target - entry).abs / (entry - stop_loss).abs
        else
          0.0
        end

      expected_edge_pct =
        begin
          win_rate = statistics[:win_rate].to_f
          avg_rr = statistics[:avg_rr].to_f
          (win_rate * avg_rr - (1.0 - win_rate)) * 100.0
        end

      {
        rr: rr.round(4),
        expected_edge_pct: expected_edge_pct.round(4),
        sl_volatility_ratio: risk[:sl_volatility_ratio],
        quality:
          if rr >= 2.0 && statistics[:win_rate] >= 0.55 && expected_edge_pct > 0.0
            "strong"
          elsif rr >= 1.5
            "moderate"
          else
            "weak"
          end
      }
    end

    def conflict_matrix(structure:, momentum:, volume:, dtw:)
      bull_structure = structure[:trend] == "bull"
      bear_structure = structure[:trend] == "bear"

      dtw_bull = !!dtw[:whale_buy] || dtw[:delta_bull] == true
      dtw_bear = !!dtw[:whale_sell] || dtw[:delta_bear] == true

      {
        smc_bull_vs_dtw_distribution: bull_structure && dtw_bear,
        smc_bear_vs_dtw_accumulation: bear_structure && dtw_bull,
        momentum_vs_structure: (
          (bull_structure && momentum[:impulse] == "weak" && momentum[:decelerating]) ||
          (bear_structure && momentum[:impulse] == "weak" && momentum[:decelerating])
        ),
        volume_vs_price: volume[:price_volume_alignment] == false,
        exhaustion_vs_bias: dtw[:exhaustion] == true,
        divergence_vs_direction:
          (bull_structure && dtw[:delta_divergence].to_s == "bearish") ||
          (bear_structure && dtw[:delta_divergence].to_s == "bullish")
      }
    end
  end
end
Example usage
require_relative "lib/feature_enricher"

candles = [
  { timestamp: Time.now.utc - 300, open: 100, high: 102, low: 99, close: 101, volume: 1200 },
  { timestamp: Time.now.utc - 240, open: 101, high: 103, low: 100, close: 102.5, volume: 1400 },
  { timestamp: Time.now.utc - 180, open: 102.5, high: 104, low: 102, close: 103.8, volume: 1800 },
  { timestamp: Time.now.utc - 120, open: 103.8, high: 105, low: 103.2, close: 104.6, volume: 2100 },
  { timestamp: Time.now.utc - 60, open: 104.6, high: 105.4, low: 104.1, close: 105.0, volume: 2400 }
]

smc = {
  htf_bias: "bull",
  h1_bias: "bull",
  m15_zone: "bull",
  m5_trigger: "choch_bull",
  bos: true,
  choch: true,
  bull_ob: true,
  bear_ob: false,
  liq_sweep: "bullish",
  smc_score: 7
}

dtw = {
  whale_buy: true,
  whale_sell: false,
  exhaustion: false,
  rvol: 2.8,
  delta_bull: true,
  delta_bear: false,
  vwap_side: "below",
  delta_divergence: "none",
  dtw_score: 82
}

features = TradingAI::FeatureEnricher.call(
  candles: candles,
  smc: smc,
  dtw: dtw,
  history: [],
  entry: 104.9,
  stop_loss: 103.9,
  targets: [106.2, 107.4, 108.8],
  symbol: "BTCUSDT",
  timeframe: "5m"
)

puts features
What this gives you

This enricher produces exactly the AI-facing packet you described:

structure
liquidity
imbalance
volatility
volume
candle microstructure
session context
positioning
momentum
statistics
trade quality
conflicts
risk

That is the layer your AI should consume; raw OHLCV should never go directly into the model.