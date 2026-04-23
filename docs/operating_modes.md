# Operating modes (paper vs live observe vs live trading)

The bot supports **three** distinct ways to run. They differ by **`runtime.dry_run`**, **`runtime.place_orders`** (live only), and which **broker** executes orders. Implementation: `CoindcxBot::Config` (`dry_run?`, `place_orders?`, `tui_exchange_mirror?`), `Core::Engine#build_broker`, `Execution::Coordinator`.

---

## 1. Full automated **paper** mode

| Setting | Value |
|--------|--------|
| `runtime.dry_run` | **`true`** |
| `runtime.place_orders` | Ignored — paper always behaves as if order placement is allowed for **simulated** fills only (no real CoinDCX order/exit REST). |
| Broker | **`PaperBroker`** (in-process SQLite simulator) **or** **`GatewayPaperBroker`** when `paper_exchange.enabled: true` (HTTP simulator — see [`paper_exchange.md`](paper_exchange.md)). |
| Exchange | No real futures `create` / exit calls. Market data still uses CoinDCX credentials where required. |
| Journal | Opens/closes and events go to **`runtime.journal_path`**. Daily INR PnL meta is updated from **paper** realized USDT × **`Engine#inr_per_usdt`** (CoinDCX conversions when `fx.enabled`, else `inr_per_usdt` in YAML). |
| TUI header | **`PAPER`**. **`paper_metrics`** drives **BAL** (capital + realized + unrealized in INR), **REAL / UNREAL USDT**, etc. |

**Use when:** validating strategy, risk, and payloads without capital at risk.

---

## 2. **Live** feeds + account mirror, **orders blocked** (observe / “exe off”)

| Setting | Value |
|--------|--------|
| `runtime.dry_run` | **`false`** |
| `runtime.place_orders` | **`false`** **or** env **`PLACE_ORDER=0`** / **`PLACE_ORDERS=0`** / **`false`** (overrides YAML when live; **`PLACE_ORDER`** wins if both env vars are set). |
| Broker | **`LiveBroker`** — but **`Coordinator`** skips **`place_order`**, **`close_position`**, and live **flatten** REST when `!place_orders?`. |
| Exchange | **Read-only** account paths used for TUI (e.g. `list_positions`, futures wallet) when **`runtime.tui_exchange_positions: true`**. |
| Journal | Still updated for **signals / events**; **no** automatic live fills. **`tui_exchange_mirror?`** is **`true`** when positions TUI is on and orders are off — execution grid and header **NET / REAL / UNREAL** align with **exchange** rows + **`Engine#inr_per_usdt`** (not static YAML alone). |
| TUI header | **`LIVE`** + **`EXE·OFF`**. |

**Use when:** you want the same live WebSocket and portfolio view as the mobile app, **without** the bot sending orders or exits.

---

## 3. Full automated **live** trading (orders on)

| Setting | Value |
|--------|--------|
| `runtime.dry_run` | **`false`** |
| `runtime.place_orders` | **`true`** (default if omitted) and **`PLACE_ORDER`** / **`PLACE_ORDERS`** not set to `0` / `false`. |
| Broker | **`LiveBroker`** — real CoinDCX futures order and exit REST. |
| Journal | Opens/closes book as fills/exits occur; daily INR from realized when the close path returns broker PnL (see coordinator). |
| TUI mirror | **`tui_exchange_mirror?`** is **`false`** by default when orders are **on** (grid shows **journal** positions). Set **`runtime.tui_exchange_mirror: true`** if you want exchange rows in the grid **while** still placing live orders. |
| TUI header | **`LIVE`** without **`EXE·OFF`**. |

**Use when:** you accept real execution and have completed risk checks (`capital_inr`, `max_daily_loss_*`, credentials, etc.).

---

## Quick reference

| Mode | `dry_run` | `place_orders` (live) | Header mode line |
|------|-----------|-------------------------|-------------------|
| 1 Paper | `true` | N/A (simulated only) | `PAPER` |
| 2 Live observe | `false` | `false` or `PLACE_ORDER=0` | `LIVE` + `EXE·OFF` |
| 3 Live trading | `false` | `true` (and env not blocking) | `LIVE` |

**USDT → INR for PnL and desk numbers:** use **`fx.enabled: true`** in `bot.yml` so **`Engine#inr_per_usdt`** refreshes from CoinDCX **`/derivatives/futures/data/conversions`** (cached); otherwise the static **`inr_per_usdt`** fallback is used (see `lib/coindcx_bot/fx/usdt_inr_rate.rb`).

**Risk manager daily loss halt** (`Risk::Manager`) still keys off **journal** `daily_pnl_inr`, not the exchange-only header **NET** in observe mode — keep that in mind if journal and exchange diverge.

**Related:** [`paper_exchange.md`](paper_exchange.md), [`architecture.md`](architecture.md), [`config/bot.yml.example`](../config/bot.yml.example), `bin/bot help` / `lib/coindcx_bot/cli.rb` (short mode hints).
