# Paper exchange — Socket.IO private channel (Phase 5 spike)

CoinDCX’s private streams use **Socket.IO over Engine.IO v3** (`EIO=3`), matching `coindcx-client` defaults. A Ruby-native Socket.IO server with full protocol parity is uncommon; practical options:

1. **Small Node sidecar** (recommended for fidelity): an EIO3-compatible server subscribes to an internal queue (Redis, HTTP long-poll, or UNIX socket) fed by this simulator’s `pe_internal_events` / future pub-sub, and emits CoinDCX-shaped payloads.
2. **Ruby spike**: evaluate gems that implement the Socket.IO protocol against EIO3; verify handshake and payload framing against `wss://stream.coindcx.com` captures before committing.

Internal events are already appended in SQLite (`pe_internal_events`). `CoindcxBot::PaperExchange::Ws::EventMapper` normalizes payload shapes for balance, order, position, and transfer events.

Until WS lands, use **signed REST** (`POST /exchange/v1/paper/simulation/tick`) for fill simulation and poll private endpoints through `coindcx-client` with `api_base_url` pointed at the paper exchange.
