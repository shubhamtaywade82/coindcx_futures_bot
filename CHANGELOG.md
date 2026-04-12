# Changelog

All notable changes to this project are documented here. The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **TUI:** Optional **`runtime.tui_exchange_positions`** — throttled read-only **`futures.positions.list`**; shows non-zero **`active_pos`** rows as an **`EXCH …`** sidebar line (no order/exit side effects).
- **CoinDCX-shaped paper exchange (HTTP):** Rack app under `lib/coindcx_bot/paper_exchange/` with SQLite store, double-entry `Ledger`, futures-style wallet/order/position routes, rate limiting, and HMAC auth aligned with `coindcx-client` signing. Entrypoint: `bin/paper-exchange` (WEBrick, configurable host/port via `PAPER_EXCHANGE_BIND` / `PAPER_EXCHANGE_PORT`).
- **`Execution::GatewayPaperBroker`:** Paper mode that keeps using `OrderGateway` / `AccountGateway` against a configurable `api_base_url`, and posts **signed** simulation ticks to `POST /exchange/v1/paper/simulation/tick` so the local matcher can advance working orders.
- **Config:** `paper_exchange.enabled`, `paper_exchange.api_base_url`, `paper_exchange.tick_path` (optional); enabled only when `Config#dry_run?` is true. Documented in `config/bot.yml.example`.
- **Dependencies:** `rack`, `rackup` (Rack 3 moved WEBrick out of core), and `webrick` for the local simulator server.
- **Docs:** `docs/paper_exchange.md` (operator guide), `docs/paper_exchange_socketio.md` (Socket.IO spike); this changelog.
- **Specs:** `spec/paper_exchange/` (ledger, Rack app), `config_spec` and `market_data_gateway` / `tick_store` additions.

### Changed

- **Config:** Paper vs live is controlled only by **`runtime.dry_run`**. The former **`runtime.paper`** key is no longer read; if it is still present under `runtime:`, config load raises **`ConfigurationError`** with instructions to use `dry_run` only (avoids silent behaviour change).
- **`Core::Engine`:** When `paper_exchange.enabled`, sets `CoinDCX.configure { api_base_url }` to the simulator and builds `GatewayPaperBroker`. **`mirror_tracker_into_tick_store`** skips overwriting `TickStore` when the existing row’s `updated_at` is newer than the tracker tick’s `received_at`, so REST-driven TUI LTP/age is not hidden by slower WS/candle mirrors.
- **`Execution::Coordinator`:** Places orders with `client_order_id` (`coindcx-bot-<uuid>`) and `order_type: 'market_order'` where applicable. On **live-style** closes that return a paper-exchange-shaped result with `realized_pnl_usdt`, books daily INR via the same path as other paper closes.
- **`Gateways::MarketDataGateway`:** `fetch_futures_rt_quotes(pairs:)` for batch public RT quotes (`ls` / `pc` parsing shared with `WsGateway`).
- **`Tui::LtpRestPoller`:** Prefers batch RT quotes per cycle; falls back to per-pair `fetch_instrument_display_quote`.
- **`Tui::TickStore`:** Normalizes symbol keys with `to_s`; if `change_pct` is omitted on update, **reuses** the previous tick’s value; `stale?` uses the same keying.

### Documentation

- **`docs/architecture.md`**, **`docs/paper_broker_simulation.md`**, **`docs/new_improvements.md`**, **`README.md`:** Cross-links and notes for the HTTP paper exchange vs in-process `PaperBroker`, TUI polling, and tick mirroring.
