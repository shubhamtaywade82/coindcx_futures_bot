# Trading Lifecycle

The bot runs a **reactive** market-data path (WebSocket ticks on the bus) and a **scheduled** `tick_cycle` (candles, stale recovery, paper **`process_tick`**). The TUI may **poll** public REST quotes for display LTP/CHG% (`LtpRestPoller`).

## 0. Execution mode (config)

- **Live:** `LiveBroker` — production REST for orders and exits.
- **Paper (default):** `PaperBroker` — `PaperStore` SQLite; no production order API.
- **Paper exchange:** `GatewayPaperBroker` when **`paper_exchange.enabled`** — REST targets **`bin/paper-exchange`**; see [`paper_exchange.md`](paper_exchange.md).

## 1. The Startup Sequence

1. **Load Config**: `config/bot.yml` (pairs, risk, `runtime`, optional `paper` / `paper_exchange`).
2. **Inject Dependencies**: The `Engine` is booted with gateways, broker, coordinator, and strategy.
3. **Connect**: WebSocket to CoinDCX for public ticks (and private order updates when configured).
4. **Synchronize**: TUI renders the initial dashboard frame.

## 2. The Live Event Loop

For every "Tick" (market update) received:

1. **Ingest**: `Engine` receives the tick (Symbol, Price, Volume).
2. **Evaluate**: `Strategy::TrendContinuation` checks for a breakout or pullback pattern.
3. **Signal**: If a setup exists, it generates a `Signal` (e.g., `Long SOLUSDT.P`).
4. **Intercept**: `Risk::Manager` calculates potential loss.
   - *Example*: "Will this trade risk > ₹500? Is our daily loss > ₹1,000?"
5. **Execute**: If approved, `OrderGateway` places the limit/market order on the exchange.
6. **Track**: The `Execution::TrailManager` begins monitoring the position for an exit.

## 3. "Capture the Rally" (Trailing Exit)

To capture a full trend instead of just a small profit:

- **No Fixed Take-Profit**: The bot does not use a "Profit Target."
- **Trailing Stop**: The stop-loss is moved upward as the price increases.
- **Trend Exit**: Exit only occurs when the market regime shifts (e.g., price closes below the 20 EMA), ensuring you ride the extension as long as it remains active.

## 4. Safety Constraints

- **Instruments**: Only pairs listed under `pairs:` in `config/bot.yml` (CoinDCX instrument codes, e.g. `B-SOL_USDT`).
- **Risk budget**: Per-trade and daily loss limits are resolved from `risk` and `capital_inr` in `config/bot.yml` (see `config/bot.yml.example`).
- **Daily loss**: When realized loss for the UTC day exceeds the configured cap, new entries are blocked (`Risk::Manager#daily_loss_breached?`); optional flatten/pause if `flatten_on_daily_loss_breach` is set.
