# Institutional-Grade Signal & Trade Framework for a CoinDCX Spot + Perpetual Bot

## TL;DR
- **Build the bot as a confluence-gated state machine, not an indicator-stack.** A trade fires only when microstructure (orderbook + tape), intraday momentum (1m–15m), and HTF structure (1H–4H–1D) all agree above a regime-adjusted score (≥75/100), with leverage hard-capped at 10x and structural-invalidation stops placed so the liquidation buffer is ≥2× the stop distance — this is what operationalises your "no closing in negative PnL" rule.
- **CoinDCX's documented surface is asymmetric:** Spot REST + Spot Sockets are fully and verbatim documented at `docs.coindcx.com` (HMAC-SHA256, `X-AUTH-APIKEY`/`X-AUTH-SIGNATURE` headers, base `api.coindcx.com` and public `public.coindcx.com`, socket.io v2.4.0 at `wss://stream.coindcx.com`). Futures REST/WS sections exist as named endpoints in the same docs, but the exact URL strings under `/exchange/v1/derivatives/futures/...` and the futures socket channel formats can only be confirmed against your authenticated API dashboard or by capturing wire traffic from the official client — third-party gists (e.g., the "Quantaindew" GitHub gist) are paraphrased and contain enum mismatches (e.g., `limit` vs CoinDCX's documented `limit_order`) and must not be treated as canonical. Mark price = last price (CoinDCX's stated marking method); funding occurs at 09:30 / 17:30 / 01:30 IST every 8 hours (4h cadence for some pairs like BLZUSDT); **dedicated funding-rate, mark-price, open-interest, and liquidation-price endpoints/streams are not surfaced as named items in the public docs sidebar** — treat these as gaps to fill via spot-vs-futures basis computation and "Get Pair Stats" inference.
- **The architecture you should build** is a thin Node.js socket sidecar (because CoinDCX mandates socket.io-client@2.4.0 — the docs state verbatim: "Socket.io: Please note only version 2.4.0 of this module would work with our Websockets… `npm install [email protected]`") feeding a Rails core via Redis Streams; Rails owns the SignalEngine, RegimeClassifier, ConfluenceScorer, RiskManager, OrderRouter, and PositionStateMachine; Sidekiq runs candle-close jobs and the breakeven-protection ticker; PostgreSQL persists `signals`, `trades`, `positions`, and `risk_events`; backtests use the `/market_data/candles` endpoint (1m–1M intervals, max 1000 bars/call) plus reconstructed orderbook from `depth-snapshot` + `depth-update` replay.

---

## Key Findings

### 1. CoinDCX surface area, in one paragraph
CoinDCX runs three logical environments that you must treat as separate concerns:
1. **Spot/Margin/Lend trading** — base `https://api.coindcx.com`, public market data at `https://public.coindcx.com`, fully Slate-documented at `docs.coindcx.com`.
2. **Perpetual Futures (USDT-margined)** — same base host, paths under `/exchange/v1/derivatives/futures/...`, named in the docs sidebar but the body is harder to retrieve verbatim. Per the official CoinDCX Futures product page, "On CoinDCX, you can select leverage based on your risk tolerance, ranging up to 100x on BTC and ETH and 50x on 300+ pairs" (you will hard-cap at 10x). Mark Price = Last Price by CoinDCX policy; liquidation triggers off Last Price.
3. **Sockets** — single endpoint `wss://stream.coindcx.com`, socket.io **v2.4.0 only**, single private channel name `"coindcx"` for account streams (auth via HMAC of `{"channel":"coindcx"}`), pair-scoped public channels with `pair` strings of form `B-BTC_USDT`, `I-BTC_INR`, `KC-XYZ_USDT` (ecode prefix from Markets Details).

### 2. The "no closing in negative PnL" rule, formally
Interpret it as: **every position is engineered, before entry, to have ≥80% historical conditional probability of reaching breakeven-after-fees-and-funding before it can hit its structural stop**. Three mechanisms, all required:
1. **High-confluence entry filter** (the score gate at 75) keeps you out of low-edge contexts.
2. **Asymmetric R sizing** — entry placed at the confluence pocket so initial R is small (1× ATR(14) typical), TP1 at 1R bumps stop to BE+fees+accrued funding; TP2 at 3R; TP3 trails by Chandelier(22, 3×ATR) or HTF structure.
3. **Liquidation buffer constraint** — leverage chosen such that `liq_price` is at least `2 × |entry − stop|` away from entry, so a wick-induced liquidation cannot precede a stop-out. The only allowed negative close is the **time-stop kill-switch**: position has not reached +0.5R within N candles AND HTF structure invalidates → forced exit (logged as `RISK_EVENT: time_stop_kill`).

### 3. Regime detection drives everything downstream
Without regime adaptation, a single fixed weight scheme will overfit to one market type. Use the four-state classifier in §C (Trending / Ranging / Volatile / Compressed) to switch which signal layers are weighted heaviest and which strategy template is loaded.

---

## Details

### A. CoinDCX API Reference — Verbatim, with gaps explicitly flagged

#### A.1 Auth (applies to all private REST + private socket joins)
- Headers: `X-AUTH-APIKEY: <key>`, `X-AUTH-SIGNATURE: HMAC_SHA256(secret, JSON.stringify(body)).hex`
- Body must include `timestamp` (epoch ms). Server clock skew rejects stale requests.
- All private REST is `POST` (parameters JSON in body). Public market data is `GET`.
- IP binding optional but strongly recommended.

#### A.2 Spot REST (base `https://api.coindcx.com` unless noted)

| Purpose | Method | Path | Notes |
|---|---|---|---|
| Ticker (all markets, 1s cadence) | GET | `/exchange/ticker` | bid/ask/high/low/volume/last_price/timestamp |
| Markets list | GET | `/exchange/v1/markets` | array of strings |
| Markets details | GET | `/exchange/v1/markets_details` | gives `pair`, `ecode`, precision, step, `order_types`, `max_leverage`, `min_notional` |
| Trade history (public) | GET | `https://public.coindcx.com/market_data/trade_history?pair=<pair>&limit=<n>` | max 500 |
| Order book (REST snapshot) | GET | `https://public.coindcx.com/market_data/orderbook?pair=<pair>` | full book |
| Candles | GET | `https://public.coindcx.com/market_data/candles?pair=<pair>&interval=<i>` | intervals: `1m,5m,15m,30m,1h,2h,4h,6h,8h,1d,3d,1w,1M`; default 500, **max 1000** |
| Balances | POST | `/exchange/v1/users/balances` | returns balance + locked_balance |
| User info | POST | `/exchange/v1/users/info` | |
| New order | POST | `/exchange/v1/orders/create` | `market`, `side`, `order_type` (`market_order`/`limit_order`), `price_per_unit`, `total_quantity`, `client_order_id` |
| Multiple orders (INR markets only, ecode `I`) | POST | `/exchange/v1/orders/create_multiple` | |
| Order status | POST | `/exchange/v1/orders/status` | by `id` or `client_order_id` |
| Multiple order status | POST | `/exchange/v1/orders/status_multiple` | |
| Active orders | POST | `/exchange/v1/orders/active_orders` | requires `market` |
| Active orders count | POST | `/exchange/v1/orders/active_orders_count` | |
| Account trade history | POST | `/exchange/v1/orders/trade_history` | pagination, symbol filter |
| Cancel | POST | `/exchange/v1/orders/cancel` | by id or client_order_id |
| Cancel all (per market) | POST | `/exchange/v1/orders/cancel_all` | rate-limited 30/60s |
| Cancel by ids | POST | `/exchange/v1/orders/cancel_by_ids` | |
| Edit price | POST | `/exchange/v1/orders/edit` | |
| Wallet transfer (spot↔futures) | POST | `/exchange/v1/wallets/transfer` | `source_wallet_type`, `destination_wallet_type` ∈ `{spot, futures}` |
| Sub-account transfer | POST | `/exchange/v1/wallets/sub_account_transfer` | Per docs verbatim: "For security reasons, this endpoint would only be available to users who have created an API key post 12th August, 2024." |
| Margin (`ecode: B`) — place | POST | `/exchange/v1/margin/create` | bracket-order shape with `target_price`, `sl_price`, `trailing_sl`, `leverage` |
| Margin — exit / cancel / edit_target / edit_sl / edit_trailing_sl / add_margin / remove_margin / fetch_orders / order | POST | `/exchange/v1/margin/{exit,cancel,edit_target,edit_price_of_target_order,edit_sl,edit_trailing_sl,add_margin,remove_margin,fetch_orders,order}` | |
| Lend — fetch / lend / settle | POST | `/exchange/v1/funding/{fetch_orders,lend,settle}` | |

**Spot rate limits (verbatim from docs, per 60s window):** Create Order 2000, Create Order Multiple 2000, Order Status 2000, Multiple Order Status 2000, Cancel 2000, Edit Price 2000, Active Orders 300, Cancel Multiple by ID 300, Cancel All 30. Max 25 open orders per market.

#### A.3 Futures REST (paths under `/exchange/v1/derivatives/futures/...`)
The docs sidebar at `docs.coindcx.com` enumerates these futures endpoints by name (in this exact order). The exact URL strings could not be retrieved verbatim from the public docs in this research session due to a 200 KB body cap on the rendered page, but the section names below are confirmed verbatim from the docs TOC:

- Get active instruments
- Get instrument details
- Get instrument Real-time trade history
- Get instrument orderbook
- Get instrument candlesticks
- List Orders / Create Order / Cancel Order / Edit Order
- List Positions / Get Positions By pairs or positionid / Update position leverage
- Add Margin / Remove Margin
- Cancel All Open Orders / Cancel All Open Orders for Position / Exit Position
- Create Take Profit and Stop Loss Orders (`untriggered` is a documented status that **only applies to futures TP/SL orders**)
- Get Transactions / Get Trades
- Get Current Prices RT / Get Pair Stats
- Get Cross Margin Details
- Wallet Transfer / Wallet Details / Wallet Transactions
- Change Position Margin Type
- Get Currency Conversion

**Implementation note (do this once, save to a YAML in your repo):** open the docs in a browser, expand each section, and copy the literal `POST /exchange/v1/derivatives/futures/...` paths and full parameter tables into `config/coindcx_futures_endpoints.yml`. Treat any third-party gist (notably the "Quantaindew" gist) as a hint, not a source — it has been observed to use unofficial enum values such as bare `limit` instead of CoinDCX's documented `limit_order`.

**Explicitly NOT exposed by the public docs sidebar (treat as gaps):**
- Dedicated mark-price REST endpoint or stream (CoinDCX uses Last Price as mark; derive from `Get Current Prices RT` / candles `close`).
- Dedicated funding-rate REST endpoint (infer from spot-vs-futures basis or scrape from `coindcx.com/futures/<pair>` page; treat as best-effort).
- Open interest field on any documented response.
- Liquidation price field — likely returned in the position object but not confirmed in the public sidebar; capture it from a real position response when you go live.

#### A.4 Spot Sockets (`wss://stream.coindcx.com`, socket.io v2.4.0)

Connect → `emit('join', {channelName, [authSignature, apiKey if private]})` → listen on the documented event name. To leave, `emit('leave', {channelName})`. The same connection can multiplex many channels.

| Purpose | Channel | Event | Auth |
|---|---|---|---|
| Balance update | `coindcx` | `balance-update` | private (HMAC of `{"channel":"coindcx"}`) |
| Order update | `coindcx` | `order-update` | private |
| Trade update (your fills) | `coindcx` | `trade-update` | private |
| Candlestick | `<pair>_<interval>` e.g. `B-BTC_USDT_1m` | `candlestick` | public |
| Order book snapshot | `<pair>@orderbook@<depth>` e.g. `B-BTC_USDT@orderbook@20` (depth ∈ {10,20,50}) | `depth-snapshot` | public |
| Order book delta | same channel as snapshot | `depth-update` | public |
| Current prices (batch) | `currentPrices@spot@<n>s` (n ∈ {1, 10}) | `currentPrices@spot#update` | public |
| 24h price stats | `priceStats@spot@60s` | `priceStats@spot#update` | public |
| New trades (tape) | `<pair>@trades` | `new-trade` | public |
| LTP (price-change ticks) | `<pair>@prices` | `price-change` | public |

**Critical socket.io quirk:** Per docs verbatim, "Socket.io: Please note only version 2.4.0 of this module would work with our Websockets… `npm install [email protected]`." Newer 4.x clients will hand-shake and silently fail to receive events. Pin `socket.io-client@2.4.0` in your sidecar's `package.json`.

#### A.5 Futures Sockets (same `wss://stream.coindcx.com`)
Sidebar TOC confirms the section contains: ACCOUNT (private), Get Position Update, Get Order Update, Get Balance Update, Get Candlestick Data, Get Orderbook, Get Current Prices, Get New Trade, Get LTP Data. Channel formats and event names mirror the spot section pattern (likely `currentPrices@futures@<n>s`, `<pair>@orderbook@<depth>`, etc., scoped to the futures product `pr:"futures"`), but **exact strings must be confirmed against the docs body in your authenticated browser**. There is **no dedicated mark-price or funding-rate stream named in the sidebar**.

### B. Signal Component Catalog

All formulas below assume a `Bar` struct `{o, h, l, c, v, t}` and `Tick` struct `{p, q, m, T}` (using CoinDCX's wire field names `p`, `q`, `m`, `T`).

#### B.1 Layer 1 — Microstructure (sub-minute)

```ruby
# Orderbook imbalance over top N levels
def book_imbalance(snapshot, n: 10)
  bids = snapshot.bids.sort_by { |p, _| -p.to_f }.first(n)
  asks = snapshot.asks.sort_by { |p, _| p.to_f }.first(n)
  bv = bids.sum { |_, q| q.to_f }
  av = asks.sum { |_, q| q.to_f }
  (bv - av) / (bv + av).to_f          # range [-1, +1]
end

# Cumulative Volume Delta from tape
class CVD
  def initialize; @cum = 0.0; end
  def push(tick)
    signed = tick.m ? -tick.q : +tick.q  # m=true means buyer is maker → seller aggressed
    @cum += signed
  end
  def value; @cum; end
end

# Tape-speed acceleration (trades/sec EWMA, then z-score over 5-min)
# Aggressor ratio = market-buy volume / total volume in rolling W
# Sweep detection: a market order that consumes >K levels of the book in one trade burst (<=200ms cluster)
# Iceberg/spoof: persistent reposting at same price after fills/pulls; track per-level half-life
```

The CVD signal is the strongest single sub-minute predictor for the breakeven-rule because it identifies aggressive flow *before* price prints — entries timed to CVD reversals at HTF levels routinely reach 1R within a handful of bars.

#### B.2 Layer 2 — Intraday (1m–15m)
- VWAP (anchored to session open, daily, swing-high, swing-low) — entries on first retest of anchored VWAP after deviation > 1.5σ
- TTM Squeeze: `BB(20,2)` inside `KC(20,1.5×ATR)` for ≥6 bars → set `armed=true`; fire on first close outside KC with volume > 1.5× SMA(volume,20)
- EMA stack 9/21/50: bullish if `ema9 > ema21 > ema50` and `c > ema9` for last 3 closes
- RSI(14) divergence: regular bull = price LL, RSI HL; hidden bull = price HL, RSI LL — implement as a peak-tracker with a 30-bar look-back
- ATR percentile rank over 200 bars → maps to volatility regime
- Order-flow imbalance over rolling W on tape: `Σ aggressor_buy_vol − Σ aggressor_sell_vol` normalised by total

#### B.3 Layer 3 — Swing (1H–4H–1D)
- Market-structure shift: maintain a fractal swing-point list; flag `MSS_BULL` when price closes above the most recent confirmed lower-high with volume > 1.2× SMA
- Daily/weekly pivots (classic floor-trader): `P=(H+L+C)/3`, `R1=2P−L`, `S1=2P−H`, `R2=P+(H−L)`, `S2=P−(H−L)`
- 200/50 EMA bias filter: only longs allowed when `c > ema200_4h` AND `ema50_4h > ema200_4h`
- Funding-rate extremes: when 8h funding > +0.08% (annualised >87%), treat as crowd-long → contrarian short bias on bearish microstructure
- OI delta vs price (4-state truth table): rising OI + rising price = trend continuation (long-friendly); rising OI + falling price = bear trend; falling OI + rising price = short-cover, fade; falling OI + falling price = long-unwind
- Spot-futures basis: `(fut_mark − spot_last)/spot_last` — premia >0.3% during a rally signal froth
- BTC-dominance / BTC-correlation filter for altcoin trades: only take alt longs when BTC 1h trend is up or neutral and BTC 1m realised vol < 90th percentile

### C. Regime Classifier

Classify every 5 minutes (or on every 5m candle close) into one of four states using three numeric inputs:

```
ADX_4H        = ADX(14) on 4H bars
ATR_PCTL      = percentile rank of ATR(14)/close over last 200 4H bars
BB_WIDTH_PCTL = percentile rank of (BB_upper − BB_lower)/BB_mid over last 200 4H bars
MSS_4H        = boolean: market-structure shift in last 6 4H bars
```

| Regime | ADX_4H | ATR_PCTL | BB_WIDTH_PCTL | MSS_4H | Strategy template |
|---|---|---|---|---|---|
| **Trending** | ≥ 25 | ≥ 50 | ≥ 60 | true (in trend direction) | Pullback-to-EMA-21 longs with TP3 trailing |
| **Ranging** | < 20 | 20–60 | 30–70 | false | Range fade at S/R + VWAP, TP at opposite band |
| **Volatile** | any | ≥ 85 | ≥ 85 | mixed | Stand-aside default; allow scalp only with tightened ATR-stop and reduced size |
| **Compressed** | < 18 | < 25 | < 25 | false | TTM-Squeeze breakout setup; pre-positioned limits at squeeze edges |

If two regimes tie, pick by HTF priority: Trending > Compressed > Ranging > Volatile. A regime change forces a cancel-all on pending entries (existing positions are not touched; their stops respect the breakeven lock).

### D. Confluence Scoring Engine

Compute `long_score` and `short_score` independently, each in [0, 100]. Components and base weights:

| Component | Weight (Trending) | Weight (Ranging) | Weight (Compressed) | Weight (Volatile) |
|---|---|---|---|---|
| HTF structure (MSS, EMA bias) | 25 | 10 | 15 | 10 |
| Intraday momentum (EMA stack, MACD, RSI div) | 20 | 15 | 20 | 15 |
| Volatility/squeeze (BB+KC, ATR pct) | 5 | 10 | 25 | 5 |
| VWAP/anchored VWAP context | 10 | 20 | 10 | 15 |
| Microstructure (book imbalance, CVD, tape) | 15 | 15 | 10 | 25 |
| Order-flow imbalance window | 10 | 10 | 5 | 15 |
| Funding-rate / OI confirmation | 10 | 10 | 10 | 10 |
| Spot-futures basis sanity | 5 | 10 | 5 | 5 |
| **Total** | 100 | 100 | 100 | 100 |

**Trade fires** when:
- `max(long_score, short_score) ≥ 75` AND
- `|long_score − short_score| ≥ 25` (conflict guard) AND
- regime ≠ Volatile OR microstructure component alone ≥ 20

Each component returns a `[-1, +1]` continuous value; long contribution = `max(0, value) × weight`, short contribution = `max(0, −value) × weight`.

**Probability-of-profit estimation:** maintain a SQL view of the last 1 000 historical signals grouped by `(regime, score_bucket_5)` and store `p_hit_1R`, `p_hit_3R`, `p_hit_stop`, `expected_R`. At fire time, look up the row matching `(current_regime, floor(score/5)*5)` and attach. Bayesian-update with the last 50 trades using a Beta(α, β) conjugate prior on `p_hit_1R`.

### E. Entry, Stop, Target, Sizing

```ruby
class TradePlan
  def self.compute(signal, bar, atr14, leverage_cap: 10, risk_pct: 0.005, fees_bps: 7.5, funding_buffer_bps: 5)
    direction = signal.long_score > signal.short_score ? :long : :short
    swing      = signal.htf_invalidation_level     # last confirmed swing low (long) / high (short)
    atr_buffer = 0.5 * atr14
    stop       = direction == :long ? swing - atr_buffer : swing + atr_buffer
    entry      = signal.confluence_zone_mid        # limit at zone, market on confirmation candle close

    risk_per_unit = (entry - stop).abs
    raise "zero risk" if risk_per_unit.zero?

    risk_capital = signal.equity * risk_pct
    qty_by_risk  = risk_capital / risk_per_unit

    # Leverage cap: actual leverage = (notional)/(margin); we enforce both leverage AND liq buffer
    notional       = qty_by_risk * entry
    max_notional_lev = signal.equity * leverage_cap
    qty_by_lev     = max_notional_lev / entry
    qty            = [qty_by_risk, qty_by_lev].min

    # Liquidation buffer: expected liq must be ≥ 2× stop distance away
    liq_distance_required = 2 * risk_per_unit
    effective_lev_for_buffer = (entry / liq_distance_required).floor
    qty_by_liq = (signal.equity * [leverage_cap, effective_lev_for_buffer].min) / entry
    qty        = [qty, qty_by_liq].min

    tp1 = entry + (direction == :long ? +1 : -1) * 1 * risk_per_unit   # 1R
    tp2 = entry + (direction == :long ? +1 : -1) * 3 * risk_per_unit   # 3R
    # tp3 trails via Chandelier(22, 3*ATR) once tp2 hits

    fees_buffer    = entry * (fees_bps / 10_000.0) * 2     # round-turn maker+taker conservative
    funding_buffer = entry * (funding_buffer_bps / 10_000.0)
    breakeven_plus = entry + (direction == :long ? +1 : -1) * (fees_buffer + funding_buffer)

    {direction:, entry:, stop:, tp1:, tp2:, qty:, breakeven_plus:,
     leverage: [leverage_cap, effective_lev_for_buffer].min}
  end
end
```

### F. "No Negative Close" State Machine

```
IDLE
  ↓ on regime ∈ {Trending, Compressed, Ranging}
SCANNING
  ↓ on signal.score ≥ 75 && conflict_guard_passes
SIGNAL_DETECTED
  ↓ TradePlan.compute valid (qty > min_notional, liq buffer ok)
ENTRY_VALIDATED
  ↓ POST /orders/create (limit_order at confluence zone with client_order_id)
ORDER_PLACED ─── on cancel/timeout (N=3 candles unfilled) ──→ IDLE
  ↓ on filled (via WS order-update / trade-update)
POSITION_OPEN
  ↓ on (price moves +X*ATR favorably) where X = 0.8
BREAKEVEN_PROTECTED         (modify SL → entry + fees + accrued_funding)
  ↓ on TP1 hit
PARTIAL_TP_HIT              (close 40% qty, move SL to BE+, arm trailing)
  ↓ on TP2 hit
TRAILING                    (close 40% more, SL = Chandelier or HTF swing)
  ↓ on trailing-stop hit OR TP3 OR HTF invalidation
POSITION_CLOSED
  ↑ side path: TIME_STOP_KILL (only allowed negative close)
        triggered when: position open ≥ N_max candles (e.g. 24 × 5m bars)
        AND best_excursion < 0.5R AND HTF MSS reversed
```

**Idempotency:** every transition is keyed on `client_order_id` + `event_id`; replays from socket reconnects are deduped by Postgres unique index. On restart, the state machine reconciles by querying `/orders/active_orders` (spot) or `List Positions` (futures) and snapping to the highest-numbered state that matches the live exchange state.

### G. Implementation Architecture (Rails-flavoured)

```
                       ┌────────────────────────────────┐
                       │  Node.js sidecar (ws-bridge)   │
                       │  socket.io-client@2.4.0        │
                       │  • spot + futures socket joins │
                       │  • normalised JSON events      │
                       └──────────────┬─────────────────┘
                                      │ Redis Streams (XADD market.*, account.*)
                                      ▼
┌─────────────────┐   ┌───────────────────────────────────────────┐   ┌──────────┐
│ Public REST     │   │ Rails core                                │   │ Postgres │
│ public.coindcx  │──▶│  • MarketDataIngestor (Karafka consumer)  │◀─▶│ TimescaleDB│
│ /candles, /orderbook │  • SignalEngine (Layer 1/2/3 modules)    │   │ optional │
│  Faraday + cache│   │  • RegimeClassifier (5m cron)             │   └──────────┘
└─────────────────┘   │  • ConfluenceScorer (event-driven)        │
┌─────────────────┐   │  • RiskManager (position sizing, kill-sw) │
│ Private REST    │◀─▶│  • OrderRouter (signed POSTs, idempotent) │   ┌──────────┐
│ api.coindcx     │   │  • PositionStateMachine (AASM)            │◀─▶│ Redis    │
│ HMAC signed     │   │  • Sidekiq workers (BreakevenTicker etc.) │   │ hot LTP, │
└─────────────────┘   └───────────────────────────────────────────┘   │ books    │
                                      │                               └──────────┘
                                      ▼
                            React/TS Operator Console
                            (read-only KPIs, kill-switch)
```

**Why a Node sidecar:** CoinDCX's pin on `[email protected]` is incompatible with `socket.io-client` 4.x and with most Ruby socket.io clients (`em-socketio-client`, `rb-socketio` are unmaintained against 2.x semantics). A 200-line Node process is the path of least resistance; it does no business logic — only normalises event names and pushes JSON to Redis Streams `market.candles`, `market.depth`, `market.trades`, `market.prices`, `account.orders`, `account.positions`, `account.balances`. Karafka or a plain `redis-rb` consumer reads from Rails.

### H. Database Schema (essentials)

```sql
CREATE TABLE markets (
  id            BIGSERIAL PRIMARY KEY,
  pair          TEXT NOT NULL UNIQUE,           -- B-BTC_USDT
  symbol        TEXT NOT NULL,                  -- BTCUSDT
  ecode         TEXT NOT NULL,                  -- B / I / KC / HB
  product       TEXT NOT NULL,                  -- spot / futures
  base_ccy      TEXT, target_ccy TEXT,
  precision_b   INT, precision_t INT, step NUMERIC,
  min_notional  NUMERIC, max_leverage INT,
  status        TEXT, payload JSONB, refreshed_at TIMESTAMPTZ
);

CREATE TABLE candles (
  pair TEXT, interval TEXT, t BIGINT,
  o NUMERIC, h NUMERIC, l NUMERIC, c NUMERIC, v NUMERIC,
  PRIMARY KEY (pair, interval, t)
);  -- consider TimescaleDB hypertable on t

CREATE TABLE signals (
  id BIGSERIAL PRIMARY KEY,
  pair TEXT, regime TEXT, direction TEXT,
  long_score NUMERIC, short_score NUMERIC,
  components JSONB, p_hit_1r NUMERIC, p_hit_3r NUMERIC,
  expected_r NUMERIC, fired_at TIMESTAMPTZ,
  trade_plan JSONB
);
CREATE INDEX ON signals (pair, fired_at DESC);

CREATE TABLE trades (
  id BIGSERIAL PRIMARY KEY,
  signal_id BIGINT REFERENCES signals(id),
  pair TEXT, side TEXT, leverage INT,
  entry_price NUMERIC, entry_qty NUMERIC,
  stop_price NUMERIC, tp1 NUMERIC, tp2 NUMERIC,
  exchange_order_id TEXT, client_order_id TEXT UNIQUE,
  state TEXT,             -- AASM mirror
  opened_at TIMESTAMPTZ, closed_at TIMESTAMPTZ,
  realized_r NUMERIC, realized_pnl NUMERIC, fees NUMERIC, funding NUMERIC
);

CREATE TABLE positions (
  id BIGSERIAL PRIMARY KEY,
  trade_id BIGINT REFERENCES trades(id),
  pair TEXT, qty NUMERIC, avg_entry NUMERIC,
  unrealized_pnl NUMERIC, liq_price NUMERIC,
  margin_type TEXT, leverage INT,
  updated_at TIMESTAMPTZ
);

CREATE TABLE risk_events (
  id BIGSERIAL PRIMARY KEY,
  trade_id BIGINT, kind TEXT,            -- time_stop_kill, ws_disconnect, partial_fill_warning
  payload JSONB, occurred_at TIMESTAMPTZ
);

CREATE TABLE order_book_snapshots (
  pair TEXT, ts BIGINT, vs BIGINT,
  bids JSONB, asks JSONB,
  PRIMARY KEY (pair, ts)
);
```

### I. Backtesting & Validation

1. **Data acquisition:** loop over `/market_data/candles` for each `(pair, interval)` pulling 1000-bar pages, walking `endTime` backward. Persist into `candles`.
2. **Tape & book replay:** for high-fidelity microstructure backtests, you must record live in real time — historical depth/trades are not available via REST. Run a 30-day shadow recorder before serious backtesting; store raw `depth-snapshot`/`depth-update` events to Parquet on S3.
3. **Engine:** event-driven simulator (don't use vectorbt-style alignment for orderbook strategies). Each tick advances the clock; SignalEngine pure functions are reused.
4. **Metrics:** win rate, avg R, profit factor, max drawdown %, Calmar = CAGR/maxDD, Sharpe (5min returns × √(252×288)), median time-to-1R, **% of trades that ever went into negative PnL after BE-lock** (this is the critical KPI for your rule — target ≥99%).
5. **Walk-forward:** 6-month in-sample → 1-month out-of-sample, rolling. Reject any parameter set whose OOS Sharpe is < 0.5× IS.
6. **Paper-trade harness:** identical OrderRouter but `dry_run=true`; emits to a `paper_trades` table. Run minimum 30 calendar days post-backtest before live capital.

### J. Probability-of-Profit Output Schema

```json
{
  "pair": "B-BTC_USDT",
  "direction": "long",
  "regime": "trending",
  "score": 82,
  "components": {
    "htf": 0.9, "intraday": 0.7, "vwap": 0.4,
    "micro": 0.6, "ofi": 0.5, "funding_oi": 0.3, "basis": 0.1
  },
  "p_hit_1r": 0.74, "p_hit_3r": 0.31, "p_hit_stop": 0.18,
  "expected_r": 0.58,
  "plan": {
    "entry": 67120.5, "stop": 66780.0, "tp1": 67461.0, "tp2": 68142.0,
    "qty": 0.073, "leverage": 6,
    "breakeven_plus": 67137.3, "atr_used": 425.2
  }
}
```

### K. CoinDCX-Specific Gotchas

1. **Symbol vs pair confusion.** `market` field used in spot order endpoints is the concatenated symbol (`SNTBTC`, `BTCINR`). The `pair` field used in public market data, sockets, and futures is the prefixed form (`B-BTC_USDT`, `I-BTC_INR`, `KC-XYZ_USDT`). Resolve once via `/exchange/v1/markets_details` and cache in Postgres.
2. **Socket.io version pin** — non-negotiable, must be 2.4.0 (verbatim from docs); newer clients silently fail.
3. **Cancel-all is rate-limited at 30/60s** — do not use as a reset mechanism in tight loops; use targeted `cancel_by_ids`.
4. **JSON serialisation must be canonical** — the docs samples use `JSON.stringify(body)` (JS) and `json.dumps(body, separators=(',', ':'))` (Python). Mismatched key order or whitespace will invalidate the HMAC; in Ruby use `body.to_json` after a fixed key order or `Oj.dump(body, mode: :compat)`.
5. **Funding events at 09:30, 17:30, 01:30 IST** — schedule a `FundingTickerJob` 60s before each timestamp to recompute breakeven price (BE+ must rise by accrued funding) for any open position; if accrued funding would push BE+ past TP1, exit early.
6. **Partial fills** — `remaining_quantity` on `order-update` is your source of truth; do not treat the first `trade-update` as full-fill confirmation.
7. **Low-liquidity altcoin pairs** — book depth at 20 levels can be < 10 USDT in some `KC-` (KuCoin-routed) pairs; force a notional floor of 50 USDT for INR pairs and gate altcoin entries on a min `book_depth_USD_top20 ≥ 5 × intended_notional`.
8. **WS disconnect semantics** — socket.io 2.x does not auto-resync state. On reconnect, resubscribe all channels and IMMEDIATELY pull `/orders/active_orders` and futures `List Positions` to reconcile. Treat any WS gap >5s as a `risk_event` and pause new entries until next clean candle.
9. **Mark price = Last price** (CoinDCX policy). This means a single bad tick or thin book can cause liquidations on otherwise-fine positions; this is exactly why your liq-buffer rule (`liq_distance ≥ 2× stop_distance`) is mandatory, not optional.
10. **No documented funding-rate REST/stream** — implement basis-derived synthetic funding: `synthetic_funding ≈ ((mark − spot) / spot) × (24 / 8)` clamped, and reconcile against the UI value daily.
11. **Indian regulatory context** — the docs' Ts&Cs require Indian citizenship/entity for API use, retention of API records for 5 years post-termination, and impose total liability cap of INR 1,00,000. Per India's Finance Act 2022 (Section 115BBH), VDA gains incur a flat 30% tax + 4% Health & Education Cess; per Section 194S, 1% TDS applies on all crypto transfers exceeding ₹10,000 per financial year (₹50,000 for specified persons) — the TDS applies on transfers, not only on conversion to INR. Futures gains may fall under PGBP (business income) — keep trade logs export-ready in a tax-friendly schema.

---

## Recommendations

**Stage 0 — Foundations (week 1–2)**
1. Lock socket.io-client at 2.4.0 in your Node sidecar and stand up Redis Streams. Test with public channels (`B-BTC_USDT@trades`, `B-BTC_USDT_1m`) before any auth.
2. Build `MarketCatalog` from `/exchange/v1/markets_details` and snapshot `pair ↔ symbol ↔ ecode ↔ precision`.
3. Implement HMAC signer with canonical JSON; verify against the `Get Balances` endpoint as a smoke test.
4. **Capture the Futures docs body manually** by opening `docs.coindcx.com` while logged in and copying the verbatim `/exchange/v1/derivatives/futures/...` paths and parameters into `config/coindcx_futures_endpoints.yml`. Do not trust third-party gists.

**Stage 1 — Read-only data plane (week 3–4)**
5. Stream + persist 1m, 5m, 15m, 1h, 4h, 1d candles for top 20 USDT-pairs and top 5 INR-pairs.
6. Stand up the orderbook snapshot+delta merge with version-number `vs` reconciliation (drop and re-snapshot on any gap).
7. Begin a 30-day depth/trade recorder for backtest fidelity.

**Stage 2 — Signal engine, paper trading (week 5–8)**
8. Implement Layer 2 + Layer 3 components first (they're calibratable from the candle history you already have); Layer 1 microstructure plugs in as the orderbook recorder fills.
9. Wire the RegimeClassifier and ConfluenceScorer; emit `signals` rows with full component breakdown and zero side-effects.
10. Run paper trading via the dry-run OrderRouter for ≥30 days. Stop-criteria for going live: (a) ≥99% of paper trades reached BE-lock before stop, (b) realised expectancy ≥ +0.4R, (c) max drawdown < 8% of paper equity.

**Stage 3 — Live, gated capital (week 9+)**
11. Begin live with **0.25% risk per trade and 3x leverage cap** for the first 30 trades, regardless of paper performance. Only after 30 trades meet the BE-rule, expand to 0.5% / 10x.
12. Run the operator console with a hard kill-switch (cancel_all + flatten) bound to the WS-disconnect risk event.

**Threshold-based escalation/de-escalation:**
- Bump risk to 1% per trade if 100-trade rolling expectancy > +0.6R AND BE-rule compliance ≥ 99.5%.
- Drop to 0.1% / disable new entries automatically if BE-rule compliance falls below 97% over any 20-trade window.
- Force regime-only Trending entries if Sharpe over the last 200 trades falls below 1.0 in any non-Trending regime.

---

## Caveats

- **Futures REST/WS verbatim strings.** The docs sidebar at `docs.coindcx.com` confirms futures section names (Get active instruments, Create Order, List Positions, etc.) but the rendered page exceeded retrievable size in this research. Confirm exact paths and parameter names from your authenticated docs view; do not rely on the third-party "Quantaindew" gist (it uses non-canonical enum values).
- **No documented mark-price stream / funding-rate REST / open-interest field / liquidation-price field** in the public docs sidebar. The framework treats these as best-effort inferences (mark price = last price; funding from basis or UI scrape; OI not available; liquidation price captured opportunistically from position responses).
- **Leverage advertising vs reality.** The CoinDCX Futures product page states verbatim: "On CoinDCX, you can select leverage based on your risk tolerance, ranging up to 100x on BTC and ETH and 50x on 300+ pairs." Per-instrument max leverage is in `markets_details.max_leverage`. Your hard cap is 10x.
- **Liquidation policy.** CoinDCX uses Last Price marking (per their support docs), which is unusual relative to most global venues using mark price = index/EMA. This raises wick-liquidation risk; the `liq ≥ 2× stop` buffer in §E is the mitigation.
- **Regulatory and platform risk.** API access is restricted to Indian citizens/entities. On 19 July 2025, attackers drained $44.3 million from CoinDCX's internal operational hot wallet (used for liquidity provisioning on a partner exchange) via Solana, then bridged funds to Ethereum; the breach went unannounced for ~17 hours until blockchain researcher ZachXBT disclosed it on Telegram, after which CEO Sumit Gupta confirmed it on X. Per CoinDCX's own incident report (coindcx.com/blog/announcements/incident-report-july-19-2025/): "On 19th July, one of our internal operational accounts, used solely for liquidity provisioning on a partner exchange, was compromised due to a sophisticated server breach." Treat this as a reminder to keep API keys IP-bound, withdrawal addresses whitelisted, and futures-wallet balances minimised to working capital.
- **Backtest fidelity.** Microstructure-level backtests require live-recorded book/tape — historical depth is not available via REST. Until 30+ days of recorded data exist, treat Layer-1 weights in backtests as upper bounds, not point estimates.
- **The "no negative PnL close" rule is probabilistic, not absolute.** A structural-stop or time-stop hit in adversarial conditions will close negative; the design target is ≥99% of trades reaching BE-lock, not 100%.