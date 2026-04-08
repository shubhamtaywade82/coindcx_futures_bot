# Architecture Overview

This project is built using a **layered, event-driven architecture** centered on SOLID principles. Each component is decoupled to ensure the trading core can be extracted and embedded into a Rails application without modification.

## 1. Layers & Components

### A. Adapters (`lib/coindcx_bot/adapters/`)
The "I/O Layer." These classes wrap the `coindcx-client` gem.
- **MarketDataGateway**: Manages WebSocket connections and yields raw market ticks.
- **OrderGateway**: Translates internal `Signal` objects into CoinDCX API calls.
- **Benefit**: If you change exchanges, you only rewrite the adapters; the logic stays the same.

### B. Core Engine (`lib/coindcx_bot/core/`)
The "Orchestrator." It wires everything together.
- **Engine**: Listens to the `MarketDataGateway`, evaluates ticks via the `Strategy`, validates via `Risk::Manager`, and executes via `OrderGateway`.
- **Benefit**: Centralized control without logic "pollution."

### C. Strategy (`lib/coindcx_bot/strategy/`)
The "Brain." Pure Ruby logic.
- **TrendContinuation**: Analyzes price action (EMA, ATR, Volume) to find entries. It emits signals but never places orders itself.
- **Benefit**: 100% testable without network access.

### D. Risk Management (`lib/coindcx_bot/risk/`)
The "Gatekeeper."
- **Manager**: Enforces the ₹50k capital limit and ₹1k daily loss cap. It intercepts signals and rejects them if they violate risk rules.
- **Benefit**: Hard safety limits that can't be bypassed by strategy bugs.

### E. TUI (`lib/coindcx_bot/tui/`)
The "Observer." Terminal-based UI.
- **Dashboard**: Uses `tty-box` and `tty-table` to show live state.
- **Benefit**: Low-overhead monitoring without needing a web browser.

## 2. Rails-Ready Design
- **No Global State**: All dependencies are injected into the `Engine`.
- **Framework Agnostic**: The Core, Strategy, and Risk modules have zero dependencies on `tty` or Rails. 
- **Migration Path**: To move to Rails, you simply swap the `Tui::Dashboard` for a Rails View/Controller and use the same `Engine` instance in a background worker (like Sidekiq).
