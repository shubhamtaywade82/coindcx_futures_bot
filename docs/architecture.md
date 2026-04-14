# Architecture Overview

This project is built using a **layered, event-driven architecture** centered on SOLID principles. Each component is decoupled to ensure the trading core can be extracted and embedded into a Rails application without modification.

## 1. Layers & Components

### A. Adapters (`lib/coindcx_bot/adapters/` and `lib/coindcx_bot/gateways/`)
The "I/O Layer." These classes wrap the `coindcx-client` gem.
- **MarketDataGateway**: REST + WebSocket market data; batch **`fetch_futures_rt_quotes`** for public RT snapshots (`ls` / `pc`) used by the TUI poller.
- **OrderGateway** / **AccountGateway**: CoinDCX REST calls. When **`paper_exchange.enabled`** is true, **`CoinDCX.configure { api_base_url }`** targets the local **paper exchange** Rack app instead of production.
- **Benefit**: If you change exchanges, you only rewrite the adapters; the logic stays the same.

### B. Core Engine (`lib/coindcx_bot/core/`)
The "Orchestrator." It wires everything together.
- **Engine**: Subscribes to market ticks, runs the strategy loop, validates via **`Risk::Manager`**, and executes via a **`Execution::Broker`** (**`LiveBroker`**, **`PaperBroker`**, or **`GatewayPaperBroker`**). In paper modes it runs **`run_paper_process_tick`** so **`process_tick`** can advance simulators. **`mirror_tracker_into_tick_store`** feeds the TUI without clobbering fresher REST updates in **`TickStore`**.
- **Benefit**: Centralized control without logic "pollution."

### C. Strategy (`lib/coindcx_bot/strategy/`)
The "Brain." Pure Ruby logic.
- **TrendContinuation**: Analyzes price action (EMA, ATR, Volume) to find entries. It emits signals but never places orders itself.
- **RegimeVolTier**: Wraps an inner strategy (`inner_strategy:`) and can block **new** entries when the HMM reports high volatility or uncertainty (`regime.strategy` keys).
- **Benefit**: 100% testable without network access.

### C2. Regime (`lib/coindcx_bot/regime/`)
Quantitative + optional narrative layer (see [`hmm_regime_trading_spec.md`](hmm_regime_trading_spec.md)).
- **Features** / **GaussianHmmDiag** / **HmmEngine**: causal feature matrix, diagonal Gaussian HMM (Baum–Welch training, BIC selection, forward-only filtering).
- **HmmRuntime**: per-pair or `scope: global` lifecycle, persistence under `regime.hmm.persistence_path`, merges **`quant_display`** into `Engine#snapshot` `:regime` for the TUI.
- **AiBrain** (`ollama-client`, optional `ollama_agent` retries): advisory JSON analyst; when `regime.ai.include_hmm_context` is true, the prompt includes HMM summaries. **Does not place orders.**

### D. Risk Management (`lib/coindcx_bot/risk/`)
The "Gatekeeper."
- **Manager**: Enforces the ₹50k capital limit and ₹1k daily loss cap. It intercepts signals and rejects them if they violate risk rules.
- **RegimeSizer** (optional, `regime.risk.enabled`): scales entry quantity by daily drawdown vs `capital_inr` (halt / reduce tiers).
- **Benefit**: Hard safety limits that can't be bypassed by strategy bugs.

### E. TUI (`lib/coindcx_bot/tui/`)
The "Observer." Terminal-based UI (TTY cursor + **`RenderLoop`**, ~4 Hz).
- **Layout**: **`DeskViewModel`** maps **`Engine#snapshot`** + **`TickStore`** into row data; panels stay render-only. **`HeaderPanel`** (mode, engine, kill, WS/LAT, feed, balances, DD/risk tier, POS/ORD/LAST event), **`DeskExecutionOrderPanel`** (execution matrix + order flow), **`DeskMarketDepthPanel`** (L1-style bid/ask/spread when the feed provides them), **`DeskRiskStrategyPanel`**, **`EventLogPanel`**, **`KeybarPanel`**.
- **TickStore** + **`LtpRestPoller`**: Fast REST refresh of LTP / CHG% (and optional **bid/ask** when present on instrument or RT quotes); **`TickStore`** can retain the last **`change_pct`** and last top-of-book when a source omits those fields. **`RenderLoop`** skips stdout writes when a panel’s captured frame is unchanged. Strategy and risk still read **`Engine#snapshot`** / **`PositionTracker`**.
- **Benefit**: Low-overhead monitoring without needing a web browser.

### F. Paper exchange (`lib/coindcx_bot/paper_exchange/`)
Optional **Rack** app: SQLite ledger, HMAC auth, futures-shaped wallet/order/position routes, and a **signed simulation tick** endpoint. Run with **`bin/paper-exchange`**. See [`paper_exchange.md`](paper_exchange.md).

## 2. Rails-Ready Design
- **No Global State**: All dependencies are injected into the `Engine`.
- **Framework Agnostic**: The Core, Strategy, and Risk modules have zero dependencies on `tty` or Rails. 
- **Migration Path**: To move to Rails, you simply swap the `Tui::Dashboard` for a Rails View/Controller and use the same `Engine` instance in a background worker (like Sidekiq).
