# Trading Lifecycle

The bot operates in a continuous, reactive loop. It does not "poll" the exchange; it waits for events.

## 1. The Startup Sequence
1. **Load Config**: `tty-config` reads `settings.yml` (e.g., ₹50k capital, `SOLUSDT.P`).
2. **Inject Dependencies**: The `Engine` is booted with gateways and strategy modules.
3. **Connect**: `MarketDataGateway` opens a WebSocket to CoinDCX.
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
- **Symbol Whitelist**: Only `SOLUSDT.P` and `ETHUSDT.P`.
- **Capital Cap**: Total exposure never exceeds the ₹50k INR limit defined in `settings.yml`.
- **Daily Loss**: If the total realized loss for the day hits the limit (e.g., ₹1,000), the bot halts all new entries.
