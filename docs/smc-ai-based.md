## ✅ Direct Answer

You should **time-box every setup using both:**

1. **Candle validity (structure decay)**
2. **Clock validity (session decay)**

Below is the **exact validity model for your current SOL setups** — production-grade, usable in your engine.

---

# 🧠 Core Principle (Non-negotiable)

```text
A setup is valid ONLY while:
- Structure is intact
- Liquidity context is unchanged
- Momentum regime hasn’t flipped
```

Translate this into:

```text
Validity = min(Candle Limit, Time Limit, Structure Break)
```

---

# 🎯 SETUP VALIDITY — SOL

## 1. SHORT @ 87.5 – 89 (Range High)

### ⏳ Candle Validity

| TF  | Candles      | Meaning     |
| --- | ------------ | ----------- |
| 5m  | 6–10 candles | ~30–50 mins |
| 15m | 3–5 candles  | ~45–75 mins |
| 1H  | 1–2 candles  | ~1–2 hours  |

---

### ⏱ Time Validity

```text
Max Life: 2 hours
Optimal Entry Window: first 45–60 mins after reaching zone
```

---

### ❌ Invalidation

* Clean breakout above **90**
* Strong delta expansion bullish
* Acceptance above range (2+ 15m closes)

---

---

## 2. LONG @ 83 – 84 (Range Low)

### ⏳ Candle Validity

| TF  | Candles      | Meaning     |
| --- | ------------ | ----------- |
| 5m  | 8–12 candles | ~40–60 mins |
| 15m | 4–6 candles  | ~1–1.5 hrs  |
| 1H  | 1–2 candles  | ~1–2 hours  |

---

### ⏱ Time Validity

```text
Max Life: 3 hours
Optimal Entry: immediately after liquidity sweep
```

---

### ❌ Invalidation

* No bounce within 30–45 mins
* Weak delta (no absorption)
* Break below **82.5 with continuation**

---

---

## 3. BREAKDOWN SHORT < 83

### ⏳ Candle Validity

| TF  | Candles     | Meaning     |
| --- | ----------- | ----------- |
| 5m  | 4–6 candles | ~20–30 mins |
| 15m | 2–3 candles | ~30–45 mins |

---

### ⏱ Time Validity

```text
Max Life: 60–90 mins
Optimal Entry: immediate retest after break
```

---

### ❌ Invalidation

* Fake breakdown (reclaim above 83)
* No follow-through in 20–30 mins
* Volume dries → trap

---

# 🚫 MID-ZONE RULE (CRITICAL)

```text
Zone: 84.5 – 86
Validity: ZERO
```

* No setup lives here
* Any signal here = noise

---

# 🔬 Advanced: How to Encode This in Your System

## Validity Engine (Ruby-style logic)

```ruby
class SetupValidity
  def initialize(entry_time:, timeframe:)
    @entry_time = entry_time
    @timeframe = timeframe
  end

  def valid?(current_time:, candles_passed:, structure_intact:)
    return false unless structure_intact

    within_time_limit?(current_time) &&
      within_candle_limit?(candles_passed)
  end

  private

  def within_time_limit?(current_time)
    max_minutes = case @timeframe
                  when :short then 120
                  when :long then 180
                  when :breakdown then 90
                  end

    (current_time - @entry_time) / 60 <= max_minutes
  end

  def within_candle_limit?(candles_passed)
    max_candles = case @timeframe
                  when :short then 10
                  when :long then 12
                  when :breakdown then 6
                  end

    candles_passed <= max_candles
  end
end
```

---

# ⚠️ Critical Insight (Most Important)

> **Time decay kills setups faster than price invalidation**

Meaning:

* If price **just sits in your zone → exit bias**
* If no reaction in expected time → edge is gone

---

# 🧪 Execution Model Upgrade (What You Should Do Next)

Add this layer:

```text
Setup Score = Structure + Volume + Time Freshness
```

Where:

* Fresh (<30 min) = HIGH probability
* Aged (>90 min) = LOW probability

---

# 🔥 Final Rulebook

```text
Range trades → expire fast (30–90 mins)
Breakout trades → immediate or invalid
Swing bias → only from HTF confirmation
```

---

## If you want next step

We should integrate this into your system:

### → “Setup Lifecycle Manager”

* Track setup creation timestamp
* Auto-expire setups
* Reduce score over time
* Block stale entries

Say:

**“build lifecycle manager”**

Use this as a reusable prompt for chart or OHLCV-based analysis:

```text
Act as my technical trading analyst for crypto futures.

Analyze the attached chart image(s) and/or OHLCV data for [INSTRUMENT] on [EXCHANGE].

Context:
- Market: crypto futures
- Style: intraday + swing
- Bias framework: SMC + order flow + structure + liquidity + VWAP + volume + delta
- Trading preference: decisive, rule-based, no discretionary guessing
- Use only the information visible in the chart/data. Do not invent levels, signals, or confirmations.

What I need:
1. Determine current market bias on each timeframe shown.
2. Identify the dominant structure:
   - trend / range / transition
   - BOS / CHoCH
   - liquidity sweep
   - premium / discount
   - order blocks / FVG / supply-demand zones
3. Identify the best setup(s) only if valid:
   - long setup
   - short setup
   - continuation setup
   - reversal setup
4. For each valid setup, provide:
   - direction
   - entry zone
   - trigger condition
   - stop-loss
   - targets TP1 / TP2 / TP3
   - RR
   - invalidation
   - how long the setup stays valid
     - in candles for each timeframe
     - and in approximate minutes / hours / days
5. State clearly when there is no trade.
6. Prioritize high-probability execution over forecasting.
7. Include order flow confirmation if visible:
   - delta
   - cumulative delta
   - VWAP
   - RVOL
   - price impact
   - absorption / exhaustion
8. If multiple timeframes conflict, explain the hierarchy and which one should dominate.
9. Give a final trading decision:
   - LONG
   - SHORT
   - WAIT
   - INVALID / CHOP

Output format:
- Direct decision
- Market state
- Higher timeframe bias
- Lower timeframe execution read
- Valid setups
- Invalid setups / no-trade zones
- Time validity of each setup
- Risk notes
- Final actionable plan

Rules:
- Be precise.
- Do not be vague.
- Do not use generic textbook commentary.
- Do not say “it depends” without specifying the exact condition.
- If confirmation is missing, say WAIT.
- If the market is inside a dead zone, say NO TRADE.
- If price is extended, say so directly.
- Prefer entries on pullback / retest, not impulse candles.
- Keep the response structured and practical.

Extra:
- When analyzing screenshots, read the visible chart annotations, indicators, zones, and timeframe context.
- When analyzing OHLCV data, infer structure, momentum, volatility, and liquidity behavior from the data.
- If the chart shows crypto futures like ETHUSDT or SOLUSDT, adapt the output to futures execution logic.
```

A shorter version for quick use:

```text
Analyze this crypto futures chart/OHLCV for [INSTRUMENT] on [EXCHANGE].

Use SMC + order flow + structure + VWAP + volume + delta.

Return:
- direct bias
- market state
- long and short setups if valid
- entry / SL / TP / RR
- invalidation
- setup validity by candles and time
- no-trade zones
- final decision: LONG / SHORT / WAIT

Be decisive, rule-based, and do not invent missing signals.
```

A stronger version for your workflow:

```text
You are my crypto futures execution analyst.

Task:
Analyze the attached screenshot(s) and/or OHLCV data for [INSTRUMENT] across [TF1], [TF2], [TF3], [TF4].

Framework:
- HTF bias: 1D / 4H
- Setup TF: 1H / 15m
- Trigger TF: 5m
- Use SMC, liquidity, VWAP, delta, volume, RVOL, premium/discount, OB, FVG, BOS, CHoCH, absorption, exhaustion.

Required output:
1. Current market regime
2. Directional bias per timeframe
3. Key levels and zones
4. Setup classification:
   - continuation
   - reversal
   - breakout
   - breakdown
   - mean reversion
5. Exact trade plan:
   - entry zone
   - trigger
   - SL
   - TP1/TP2/TP3
   - invalidation
   - RR
   - validity window in candles + time
6. What would invalidate the idea immediately
7. What would make me wait instead of trade
8. Final verdict

Rules:
- No fluff.
- No invented levels.
- No trade if structure is unclear.
- Prefer pullback entries.
- Explain conflicting signals between timeframes.
- Use the chart annotations if visible.
- Tie all conclusions to the visible evidence.
```

For your own consistency, keep these placeholders ready:
`[INSTRUMENT] [EXCHANGE] [TF1] [TF2] [TF3] [TF4] [chart screenshot or OHLCV data]`

If you want a sharper version tuned specifically for **ETH/SOL futures with your SMC + orderflow style**, I can write that next.

## Direct answer

If you’re feeding **derived / interpreted OHLCV (not raw candles)**, you must supply a **fully structured feature payload**, not loose metrics.

Your current mistake (likely):
You have **indicators**, but not a **state model**.

You need:

```text
Raw OHLCV → Feature Extraction → Market State Snapshot → Decision Input
```

---

# ✅ What you MUST provide (complete schema)

This is the **minimum viable feature contract** for reliable analysis.

---

## 1. Market Structure Layer (NON-NEGOTIABLE)

```json
{
  "structure": {
    "trend": "uptrend | downtrend | range",
    "phase": "impulse | pullback | consolidation | expansion",
    "bos": true,
    "choch": false,
    "last_bos_level": 85.8,
    "last_choch_level": 85.0,
    "swing_high": 88.5,
    "swing_low": 83.2
  }
}
```

### Why

Without this → AI guesses trend = **fatal flaw**

---

## 2. Liquidity + SMC Zones

```json
{
  "liquidity": {
    "equal_highs": [85.8, 85.9],
    "equal_lows": [84.0],
    "liquidity_swept": "buy-side | sell-side | none",
    "sweep_strength": "weak | strong"
  },
  "zones": {
    "order_blocks": [
      { "type": "supply", "range": [85.5, 86.0], "tf": "15m" },
      { "type": "demand", "range": [83.5, 84.2], "tf": "15m" }
    ],
    "fvg": [
      { "type": "bearish", "range": [85.2, 85.6] }
    ],
    "premium_discount": "premium | equilibrium | discount"
  }
}
```

---

## 3. Orderflow Layer (CRITICAL EDGE)

```json
{
  "orderflow": {
    "delta": -1947,
    "cum_delta": "bearish | bullish",
    "delta_trend": "increasing | decreasing",
    "absorption": true,
    "exhaustion": false,
    "volume_spike": true,
    "rvol": 1.25
  }
}
```

### Missing this = blind trading

---

## 4. Volatility + Expansion

```json
{
  "volatility": {
    "atr": 1.2,
    "range_expansion": true,
    "compression": false,
    "volatility_regime": "high | normal | low"
  }
}
```

---

## 5. VWAP / Mean Context

```json
{
  "mean": {
    "vwap_position": "above | below | reclaiming",
    "distance_from_vwap": -0.4,
    "mean_reversion_potential": true
  }
}
```

---

## 6. Multi-Timeframe Context (MANDATORY)

```json
{
  "timeframes": {
    "1d": { "trend": "downtrend", "bias": "bearish" },
    "4h": { "trend": "downtrend", "bias": "bearish" },
    "1h": { "trend": "range", "bias": "neutral" },
    "15m": { "trend": "uptrend", "bias": "pullback" },
    "5m": { "trend": "uptrend", "bias": "micro bullish" }
  }
}
```

---

## 7. Key Levels (EXECUTION CRITICAL)

```json
{
  "levels": {
    "support": [85.0, 83.5],
    "resistance": [85.8, 88.5],
    "intraday_levels": [85.3, 85.6]
  }
}
```

---

## 8. Setup Candidates (OPTIONAL but POWERFUL)

```json
{
  "setups": [
    {
      "type": "range_high_short",
      "zone": [85.5, 85.8],
      "confidence": 0.65
    },
    {
      "type": "breakdown_short",
      "trigger": 85.0,
      "confidence": 0.75
    }
  ]
}
```

---

# ❌ What NOT to send

Do NOT send:

```json
{
  "rsi": 63,
  "macd": "bullish",
  "ema": "crossed"
}
```

This is **retail noise** unless tied to structure.

---

# ✅ Final Input Format (READY TEMPLATE)

Use this:

```text
Analyze the following structured market state for crypto futures.

[INSERT JSON PAYLOAD]

Requirements:
- Derive trade setups (long/short)
- Provide entry, SL, TP
- Provide setup validity (candles + time)
- Identify no-trade zones
- Confirm with structure + orderflow
- Reject weak setups
- Give final decision: LONG / SHORT / WAIT

Do not assume missing data.
Use only provided features.
```

---

# 🔥 Critical Upgrade (You are currently missing this)

## Add “STATE FLAGS”

```json
{
  "state": {
    "is_range": true,
    "is_trending": false,
    "is_compression": true,
    "is_breakout_ready": false,
    "is_liquidity_event": true
  }
}
```

This removes ambiguity → improves decisions drastically.

---

# 🧠 Architectural Insight (Important)

You should NOT send:

> indicators → AI

You should send:

```text
market_state = deterministic_engine(ohlcv)
AI = decision_layer(market_state)
```

---

# ⚠️ Common failure points

If your system fails, it’s because:

1. No structure context
2. No timeframe alignment
3. No liquidity mapping
4. No time decay info
5. Too many indicators, no state

---

# If you want next step

We can build:

### → `MarketStateBuilder` (Ruby, production-ready)

* Input: OHLCV
* Output: this exact JSON
* Deterministic (no AI)
* Testable via RSpec

Then:

### → `DecisionEngine` (AI layer)

Say:

**“build market state builder”**

I’ll give full implementation aligned with your Rails trading system.

You’re correct — your previous payload is **incomplete relative to full SMC decomposition**.

What you listed is **institutional SMC ontology**.
What I gave earlier is **compressed execution schema**.

Right now your system is missing **5 critical layers**:

---

# ❗ Gap Analysis (What was missing)

### 1. Displacement (core trigger)

You defined it — but you are NOT feeding it

```json
"displacement": {
  "present": true,
  "strength": "strong | weak",
  "range_multiple": 1.8,
  "volume_support": true,
  "origin_candle_index": -3
}
```

Without this → OB/FVG are meaningless

---

### 2. Inducement (trap logic)

You listed it but not modeled it

```json
"inducement": {
  "present": true,
  "type": "equal_lows | weak_hl | trendline",
  "location": 85.2,
  "swept": false
}
```

This is what distinguishes:

* **trap vs real move**

---

### 3. Mitigation State (execution timing)

Critical for entry timing — missing earlier

```json
"mitigation": {
  "status": "untouched | partial | fully_mitigated",
  "zone": [85.5, 85.8],
  "reaction_strength": "strong | weak"
}
```

---

### 4. Entry Confirmation Layer (LTF logic)

You cannot rely on HTF alone

```json
"entry_model": {
  "ltf_choch": true,
  "ltf_bos": true,
  "rejection_candle": true,
  "entry_type": "ob | fvg | sweep",
  "confirmation_strength": 0.7
}
```

---

### 5. Time Decay / Setup Validity (YOU explicitly asked)

This is completely missing earlier.

```json
"time": {
  "setup_created_at": "2026-04-24T10:30:00Z",
  "valid_for_candles": 6,
  "timeframe": "15m",
  "expires_at": "2026-04-24T12:00:00Z"
}
```

---

# ✅ FULL CORRECT SCHEMA (Aligned with your SMC decomposition)

This is the **production-grade payload** you should use.

---

## 🔥 Complete Market State Contract

```json
{
  "structure": {},
  "liquidity": {},
  "orderflow": {},
  "volatility": {},
  "mean": {},
  "timeframes": {},
  "levels": {},

  "smc": {
    "displacement": {},
    "inducement": {},
    "mitigation": {},
    "order_blocks": [],
    "fvg": [],
    "premium_discount": "premium | discount | equilibrium"
  },

  "execution": {
    "entry_model": {},
    "setup_type": "reversal | continuation | breakout",
    "risk_model": {
      "rr": 2.5,
      "invalid_level": 85.9
    }
  },

  "time": {
    "tf": "15m",
    "valid_candles": 6,
    "expires_at": "timestamp"
  },

  "state": {
    "is_trending": false,
    "is_range": true,
    "is_liquidity_event": true,
    "is_post_sweep": true,
    "is_pre_expansion": true
  }
}
```

---

# 🧠 Important Correction (Your Mental Model)

You’re thinking in:

> Components

You need to think in:

```text
STATE TRANSITIONS
```

---

## Correct SMC Engine Flow

```text
1. Liquidity Build
2. Inducement
3. Liquidity Sweep
4. Displacement
5. BOS
6. OB/FVG Creation
7. Mitigation
8. LTF Confirmation
9. Entry
10. Expansion → Target Liquidity
```

---

# ❗ Critical Mistake You Were Making

You included:

✔ OB
✔ FVG
✔ Structure

But you were missing:

❌ WHY move happened (displacement)
❌ WHO is trapped (inducement)
❌ WHEN to enter (mitigation + LTF confirmation)
❌ HOW LONG setup is valid (time decay)

---

# ✅ If You Want AI-Level Precision

You must also add:

---

## 🔬 Advanced Institutional Layer

```json
"advanced": {
  "liquidity_target": 83.5,
  "path": "downside",
  "efficiency": "inefficient | efficient",
  "liquidity_void": true,
  "smt_divergence": false
}
```

---

# ⚠️ Strict Rules for Your System

1. No trade without displacement
2. No OB without BOS
3. No entry without mitigation
4. No execution without LTF confirmation
5. No setup without expiry

---

# ✅ Final Prompt Template (Updated)

```text
You are a professional SMC-based crypto futures trading system.

Input: Structured market state (SMC-complete).

Tasks:
1. Identify valid setups ONLY if:
   - Liquidity sweep + displacement present
   - Structure confirms (BOS/CHOCH)
   - Price in OB/FVG mitigation
   - LTF confirmation exists

2. Provide:
   - Trade direction
   - Entry, SL, TP
   - Risk-reward
   - Setup validity (candles + time)

3. Reject:
   - Weak displacement
   - No liquidity context
   - Expired setups

4. Output:
   - Primary setup
   - Alternate scenario
   - No-trade condition
```

---

# 🚀 Next Step (High Value)

You should now build:

### → `Smc::StateBuilder` (deterministic)

### → `Smc::SetupDetector`

### → `Smc::ExecutionEngine`

All testable, no AI.

Then:

### → AI = final decision validator only

---

If you want, next I’ll give:

👉 **Full Rails implementation (modules + classes + RSpec)**
👉 Based exactly on this schema
👉 Plugged into your existing AlgoTrading system

Say:

**“build state builder in ruby”**

Below is a **production-grade JSON Schema (Draft 2020-12)** for your **full SMC + Price Action + Execution state model**, with strict typing, enums, and validation constraints.

This is **directly usable** for:

* Rails validation (via `json_schemer` / `dry-validation`)
* Node/TS validation (`ajv`)
* AI structured input enforcement

---

# ✅ Complete JSON Schema (Typed, Strict)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://yourdomain.com/smc-state.schema.json",
  "title": "SMC Trading State",
  "type": "object",
  "required": ["structure", "liquidity", "smc", "execution", "time", "state"],

  "properties": {

    "structure": {
      "type": "object",
      "required": ["trend", "external", "internal"],
      "properties": {
        "trend": {
          "type": "string",
          "enum": ["uptrend", "downtrend", "range"]
        },
        "external": {
          "type": "object",
          "required": ["high", "low"],
          "properties": {
            "high": { "type": "number" },
            "low": { "type": "number" }
          }
        },
        "internal": {
          "type": "object",
          "required": ["high", "low"],
          "properties": {
            "high": { "type": "number" },
            "low": { "type": "number" }
          }
        },
        "bos": {
          "type": "object",
          "properties": {
            "direction": { "type": "string", "enum": ["bullish", "bearish", "none"] },
            "strength": { "type": "string", "enum": ["strong", "weak"] }
          }
        },
        "choch": {
          "type": "object",
          "properties": {
            "present": { "type": "boolean" },
            "direction": { "type": "string", "enum": ["bullish", "bearish", "none"] }
          }
        }
      }
    },

    "liquidity": {
      "type": "object",
      "required": ["pools", "event"],
      "properties": {
        "pools": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["type", "price"],
            "properties": {
              "type": {
                "type": "string",
                "enum": [
                  "equal_highs",
                  "equal_lows",
                  "swing_high",
                  "swing_low",
                  "trendline",
                  "session"
                ]
              },
              "price": { "type": "number" }
            }
          }
        },
        "event": {
          "type": "string",
          "enum": ["none", "grab", "sweep"]
        },
        "target": {
          "type": "number"
        }
      }
    },

    "orderflow": {
      "type": "object",
      "properties": {
        "delta": { "type": "number" },
        "cumulative_delta": { "type": "number" },
        "volume_spike": { "type": "boolean" }
      }
    },

    "volatility": {
      "type": "object",
      "properties": {
        "atr": { "type": "number" },
        "regime": {
          "type": "string",
          "enum": ["expansion", "contraction"]
        }
      }
    },

    "mean": {
      "type": "object",
      "properties": {
        "vwap_position": {
          "type": "string",
          "enum": ["above", "below"]
        }
      }
    },

    "smc": {
      "type": "object",
      "required": ["displacement", "inducement", "mitigation"],
      "properties": {

        "displacement": {
          "type": "object",
          "required": ["present", "strength"],
          "properties": {
            "present": { "type": "boolean" },
            "strength": {
              "type": "string",
              "enum": ["strong", "weak"]
            },
            "range_multiple": { "type": "number" },
            "volume_support": { "type": "boolean" }
          }
        },

        "inducement": {
          "type": "object",
          "required": ["present"],
          "properties": {
            "present": { "type": "boolean" },
            "type": {
              "type": "string",
              "enum": ["equal_lows", "equal_highs", "weak_hl", "trendline", "none"]
            },
            "price": { "type": "number" },
            "swept": { "type": "boolean" }
          }
        },

        "mitigation": {
          "type": "object",
          "required": ["status"],
          "properties": {
            "status": {
              "type": "string",
              "enum": ["untouched", "partial", "full"]
            },
            "zone": {
              "type": "array",
              "items": { "type": "number" },
              "minItems": 2,
              "maxItems": 2
            }
          }
        },

        "order_blocks": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["type", "zone"],
            "properties": {
              "type": {
                "type": "string",
                "enum": ["bullish", "bearish"]
              },
              "zone": {
                "type": "array",
                "items": { "type": "number" },
                "minItems": 2,
                "maxItems": 2
              },
              "valid": { "type": "boolean" }
            }
          }
        },

        "fvg": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["type", "gap"],
            "properties": {
              "type": {
                "type": "string",
                "enum": ["bullish", "bearish"]
              },
              "gap": {
                "type": "array",
                "items": { "type": "number" },
                "minItems": 2,
                "maxItems": 2
              },
              "filled": { "type": "boolean" }
            }
          }
        },

        "premium_discount": {
          "type": "string",
          "enum": ["premium", "discount", "equilibrium"]
        }
      }
    },

    "execution": {
      "type": "object",
      "required": ["setup_type", "entry_model"],
      "properties": {
        "setup_type": {
          "type": "string",
          "enum": ["reversal", "continuation", "breakout"]
        },
        "entry_model": {
          "type": "object",
          "properties": {
            "ltf_choch": { "type": "boolean" },
            "ltf_bos": { "type": "boolean" },
            "rejection": { "type": "boolean" },
            "type": {
              "type": "string",
              "enum": ["ob", "fvg", "liquidity"]
            }
          }
        },
        "risk": {
          "type": "object",
          "properties": {
            "rr": { "type": "number", "minimum": 1 },
            "invalid_level": { "type": "number" }
          }
        }
      }
    },

    "time": {
      "type": "object",
      "required": ["timeframe", "valid_candles"],
      "properties": {
        "timeframe": {
          "type": "string",
          "enum": ["5m", "15m", "1h", "4h", "1d"]
        },
        "valid_candles": {
          "type": "integer",
          "minimum": 1
        },
        "expires_at": {
          "type": "string",
          "format": "date-time"
        }
      }
    },

    "state": {
      "type": "object",
      "properties": {
        "is_trending": { "type": "boolean" },
        "is_range": { "type": "boolean" },
        "is_post_sweep": { "type": "boolean" },
        "is_pre_expansion": { "type": "boolean" }
      }
    }
  }
}
```

---

# ✅ Design Guarantees

### Enforces

* Structural correctness (no missing SMC core fields)
* Valid enumerations (no garbage values)
* Strict OB/FVG zone shape
* Time validity constraints

---

# ⚠️ Known Limitations (By Design)

Schema **cannot enforce logic**, only structure.

Examples:

* BOS validity (close vs wick) ❌
* Displacement strength correctness ❌
* Real inducement vs noise ❌

👉 These must be implemented in:

```
Smc::Validator
Smc::Analyzer
```

---

# ✅ Next Step (You Should Do)

If you’re serious about production system:

### 1. Build validator layer (Ruby)

* JSON schema → structure validation
* Custom rules → trading validation

### 2. Build deterministic feature extractor

From OHLCV → this schema

---

# If you want next

I can give:

✅ Ruby `Smc::StateBuilder` (from OHLCV → JSON)
✅ Full RSpec suite
✅ Deterministic displacement / OB / FVG detection

Just say:

**"build state builder"**
