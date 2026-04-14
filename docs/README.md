# Documentation

| Document | Purpose |
|----------|---------|
| [`architecture.md`](architecture.md) | Layers, engine, gateways, TUI, paper exchange overview |
| [`paper_exchange.md`](paper_exchange.md) | **HTTP paper exchange:** `bin/paper-exchange`, config, routes, bot wiring |
| [`paper_exchange_socketio.md`](paper_exchange_socketio.md) | Socket.IO private-channel spike for the simulator |
| [`paper_broker_simulation.md`](paper_broker_simulation.md) | In-process **`PaperBroker`** roadmap (phases, working orders) |
| [`trading_lifecycle.md`](trading_lifecycle.md) | Startup, tick loop, execution modes |
| [`operating_modes.md`](operating_modes.md) | **Paper vs live observe vs live trading** (`dry_run`, `place_orders`, TUI mirror) |
| [`new_improvements.md`](new_improvements.md) | What the repo implements today vs obsolete drafts |
| [`hmm_regime_trading_spec.md`](hmm_regime_trading_spec.md) | HMM regime detection + allocation spec (Ruby HMM + optional Ollama narrative; see **Implementation status** in doc) |

Project changelog: [`../CHANGELOG.md`](../CHANGELOG.md).
