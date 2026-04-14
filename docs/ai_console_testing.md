# AI Console Testing Guide

The trading engine provides an Interactive Ruby (IRB) console environment via `bin/console`. This console automatically prioritizes `.env` credentials over `bot.yml` configurations, mimicking the exact runtime behavior of the main bot, which makes it the ultimate environment to safely audit, debug, and trace AI prompt-response behaviors.

## Starting the Console

Run the console from the root of the project:

```bash
./bin/console
```

The script will automatically attempt to connect to your configured `OLLAMA_BASE_URL` and `OLLAMA_API_KEY` settings dynamically. You'll see a prompt verifying which keys have been loaded.

## Live CoinDCX OHLCV (SOL / BTC / ETH futures)

For `Regime::AiBrain` and `SmcSetup::PlannerBrain`, prompts are built from **execution-resolution** candlesticks (same REST path the engine uses). The console preloads a `context` hash when `COINDCX_API_KEY` and `COINDCX_API_SECRET` are set:

- **Pairs:** `B-SOL_USDT`, `B-BTC_USDT`, `B-ETH_USDT` (overridable; see below).
- **Bar count:** `regime.ai.bars_per_pair` from `config/bot.yml` (same clamp as production: minimum 8, maximum 96).
- **Window:** `runtime.candle_lookback` bars of history, aligned with `Engine#candle_window`.
- **Positions:** Open rows from your SQLite journal (same shape as `Engine#build_regime_ai_context`). Pass `positions: []` if you want an empty book.
- **Planner:** `open_count` is set from the resolved positions list so `SmcSetup::PlannerBrain` matches `smc-setup plan-once`.

If credentials are missing or REST returns no rows, `context` is left unset and the banner prints a one-liner to load manually.

### Reload or customize

```ruby
# Default: SOL + BTC + ETH, journal positions
context = CoindcxBot::Console::RegimeAiContextLoader.fetch!(config: config)

# Only two symbols, flat book
context = CoindcxBot::Console::RegimeAiContextLoader.fetch!(
  config: config,
  pairs: %w[B-BTC_USDT B-ETH_USDT],
  positions: []
)

# Use the same pairs as bot.yml (still capped by regime.ai.max_pairs)
context = CoindcxBot::Console::RegimeAiContextLoader.fetch!(
  config: config,
  pairs: config.pairs
)
```

## Testing the AI Regime Brain

```ruby
# `config` and (when keys are present) `context` are already defined
brain = CoindcxBot::Regime::AiBrain.new(config: config)
res = brain.analyze!(context)
puts res.inspect
```

### Inspecting Raw Prompts

Because the AI modules build dynamic text context containing your positions and candles, you can inspect the exact prompt string being sent to Ollama prior to evaluation:

```ruby
puts brain.send(:build_user_message, context)
```

## Testing the SMC Planner AI

The planner uses the same `candles_by_pair` tail shape as `bin/bot smc-setup plan-once`.

```ruby
planner = CoindcxBot::SmcSetup::PlannerBrain.new(config: config)
setup_res = planner.plan!(context)

puts setup_res.payload.inspect
```

## Synthetic scenarios (optional)

For edge cases (wick spikes, gaps, synthetic stress), build a `context` hash by hand with the same keys (`exec_resolution`, `htf_resolution`, `pairs`, `candles_by_pair`, `positions`) and the same per-bar shape: `{ o:, h:, l:, c:, v: }` (BigDecimal-friendly numerics).
