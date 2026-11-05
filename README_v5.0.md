# Smart Reversal EA v5.0

**File:** `SmartHedgeEA_v5.00.mq5` / `SmartHedgeEA_v5.00.ex5`
**Platform:** MetaTrader 5, MQL5, demo accounts only
**Copyright:** Sachin Dev Bots

## What this is

A single-symbol, basket-based reversal EA. It opens a fixed-size basket of same-direction
positions, manages it as one unit (trailing, break-even, max holding time, optional partial
close), closes it, and may open an opposite-direction basket afterward — but only after a full
re-evaluation of the market, never a blind reversal.

v5.0 replaces v4.8's single EMA-cross signal with a dual market-regime engine:

- **MODE A — Trend Continuation**: H1 + M15 + M5 EMA trend agreement, ADX trend-strength
  confirmation, a pullback/anti-chase filter, and closed-candle confirmation.
- **MODE B — Range Mean Reversion**: swing-based support/resistance zones, RSI extremes or a
  rejection candle at the boundary, and a minimum reward:risk space check to the opposite
  boundary.
- **MODE C — No-Trade**: the deliberate default whenever regime, data, risk, or score checks
  don't clear the bar. Logged like any other decision, never silently skipped.

A weighted 0-100 score (8 components, `InpMinSignalScore` = 80 by default) gates every entry
**and** every reversal — the reversal path runs through the exact same evaluation function used
for a fresh entry, so a reversal requires a genuinely re-confirmed opposite setup, not just "the
old signal hasn't been cancelled yet."

## What is preserved from v4.8, unchanged

The execution/reconciliation core that v4.8 already got right is **not** rewritten:
- The state machine and its explicit transition table (fails safe into `STATE_ERROR` on any
  illegal transition).
- Position truth by symbol+magic scan (`ScanManagedFull`), reconciled every tick/timer/transaction.
- Completed-trade truth rebuilt from deal history (`BuildTradeSummary`), never assumed from a
  boolean return.
- Retcode-aware execution: every order checks `ResultRetcode()`; uncertain outcomes are
  reconciled against real broker positions before any retry.
- GlobalVariable persistence with a forced daily-halt reset on every fresh init.
- Instance lock, demo-only guard (first thing in `OnInit`, no side effects before it).

## What's new

See `CHANGELOG_v5.0.md` for the full bug-fix and feature list, and `INPUT_GUIDE_v5.0.md` for
every input and its default. In short: fixed basket sizing (no growth, no randomness, no
martingale), an independent risk engine (per-basket $ / %-equity risk, equity drawdown, daily
floating drawdown, margin usage — all pre-entry gates, none of them force-close an open basket),
an adaptive profit manager (break-even, optional ATR trailing, max holding time, optional
one-time partial close), execution-latency instrumentation, a versioned CSV schema plus a
separate decision log, and a rebuilt SYSTEM/MARKET/TRADING/PERFORMANCE/EXECUTION dashboard.

## Installation

1. Copy `SmartHedgeEA_v5.00.mq5`/`.ex5` into your terminal's `MQL5\Experts\` folder (or compile
   the `.mq5` yourself in MetaEditor).
2. Attach to **one chart per symbol**, on a **DEMO account only** — the EA refuses to run on
   anything else and that guard cannot be bypassed by any input.
3. Review `INPUT_GUIDE_v5.0.md` before changing any default, especially `InpUseSessionFilter`
   (server time — see `CLAUDE.md` for this PC's known server/local offset) and the risk-engine
   limits.
4. Enable "Allow Algo Trading" in the terminal and in the EA's own properties.

## Demo-testing instructions

1. Run it on a demo account for at least a few trading days before trusting any dashboard
   number — the first session's stats start at zero by design (session stats are intentionally
   not persisted, lifetime stats are).
2. Watch the Experts log and the two CSV files (trade log + decision log) in
   `MQL5\Files\SachinDevBotsLog\` (junctioned to this folder on this PC).
3. Confirm the demo-only guard, the 0.05-lot basket cap, and the daily-loss halt behave as
   documented before leaving it unattended.
4. The master spec calls for a 2-4 week demo forward test before any release decision — that
   has **not** been run as part of this change; see `TEST_REPORT_v5.0.md` for exactly what was
   and wasn't verified.

## Known limitations

- "Breakout and retest confirmation" is implemented as a breakout-candle pattern check only
  (no multi-bar retest state machine).
- The optional economic-calendar filter uses MQL5's native Calendar API, which is not reliably
  populated in the Strategy Tester; it fails open (never blocks trading) if no data is returned.
- No multi-month backtest or live forward-test results are included in this delivery — see
  `TEST_REPORT_v5.0.md`.
