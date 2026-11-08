# Smart Reversal EA v5.7

**File:** `SmartHedgeEA_v5.7.mq5` / `SmartHedgeEA_v5.7.ex5`
**Platform:** MetaTrader 5, MQL5
**Copyright:** Sachin Dev Bots

> **DEMO ACCOUNTS ONLY.** The EA refuses to start on a live or contest account, and that check
> can never be removed, weakened, or bypassed by any input. This is an experiment, not a money
> machine — **no profit is promised or guaranteed.**

---

## What it does

A single-symbol, basket-based EA. It opens a fixed-size basket of same-direction positions with a
**stop-loss and take-profit attached to every order**, manages the basket as one unit, closes it on
SL/TP/time-stop, and then waits for a genuinely fresh signal. v5.7 does **not** reverse after a loss.

The signal side is the same dual-regime classifier as v5.0-v5.6, with the 8-component weighted
score removed:

- **MODE A — Trend Continuation**: H1 + M15 + M5 EMA agreement (ADX confirms trend strength),
  an RSI momentum gate, a hard anti-chase gate (last close must be within `InpMaxChaseATR` of the
  fast EMA — no timer, no forced entry), and a closed-candle confirmation.
- **MODE B — Range Mean Reversion**: swing-based support/resistance zones, price within
  `InpRangeZoneATR` of the near boundary, and an RSI extreme **or** a rejection candle at it.
- **MODE C — No-Trade**: the deliberate default whenever regime, data, spread, session or risk
  checks don't clear. Logged like any other decision, never silently skipped.

**Exits are a fixed 0.5 R shape**: SL = `InpStopATRMult` × ATR (default 1.50), TP =
`InpTargetATRMult` × ATR (default 0.75), both sent with the order so they survive an EA or
terminal outage, plus an optional break-even arm at `InpBreakEvenR` and a time stop. That shape
needs a **66.7% win rate to break even** — the old USD-denominated trail (-$0.50 loss vs +$0.25
arm, breakeven 66.7%) ran at 56.8% over the account's whole history.

## What's preserved from earlier versions, unchanged

The execution/reconciliation core that earlier versions already got right was **not** rewritten:
- The state machine and its explicit transition table (fails safe into an `ERROR` state on any
  illegal transition).
- Position truth by symbol+magic scan, reconciled every tick/timer/transaction against the real
  broker positions.
- Completed-trade truth rebuilt from deal history — never assumed from a boolean return.
- Retcode-aware execution: every order checks the real result code; uncertain outcomes are
  reconciled against real broker positions before any retry.
- GlobalVariable persistence with a forced daily-halt reset on every fresh init.
- Single-instance lock, demo-only guard (first thing on startup, no side effects before it).

## New in v5.0

### Bugs fixed (vs. v4.8)

1. **Entry signal quality.** v4.8 could enter on the current EMA trend with no fresh crossover,
   the pullback filter defaulted off, and RSI confirmation was a weak 50-line gate. Replaced by
   `EvaluateEntry()`: closed-candle-only confirmation, H1/M15/M5 direction validation, a
   mandatory-by-default pullback/anti-chase check, ADX regime validation, ATR volatility
   validation, extended-entry rejection, and the weighted score threshold. One closed bar can
   trigger at most one entry.
2. **Random basket sizing removed from the code**, not just disabled — basket size is always the
   fixed `InpBasketMax`.
3. **Uncontrolled exposure growth removed** — lot is always the fixed `InpFixedLotSize`, no
   growth after wins, no increase after losses (no martingale), total basket volume capped by
   `InpMaxBasketVolume`.
4. **Independent risk engine added**: per-basket $ and %-equity risk caps, account
   equity-drawdown guard, daily floating-drawdown guard, margin-usage guard — all pre-entry gates
   that block new entries/reversals only, never force-close an open basket (same philosophy as
   the existing daily realized-loss limit, which is kept and now **on by default**).
5. **Reversal logic reworked.** A reversal now requires: the original basket confirmed fully
   flat, a cooldown fully elapsed, a complete market re-evaluation through the same scoring/regime
   engine a fresh entry uses, higher-timeframe support, the score threshold, and spread/risk
   checks — not just "the trend hasn't flipped back yet." `InpMaxConsecutiveReversals` default
   lowered from 20 to 2.
6. **Profit management upgraded**: break-even protection, optional ATR-based trailing distance,
   a maximum holding-time close, and an optional one-time partial close, on top of the existing
   basket-shrink-safe peak-tracking trail. The basket's logged **outcome** (WIN/LOSS/BREAKEVEN)
   is always computed from the actual completed deal-history net sum, stored separately from the
   close **trigger** name — a basket closed on a "PROFIT" trigger that nets negative after
   commission/swap/slippage is logged as LOSS, not WIN.
7. **Execution instrumentation added**: close-request timestamps, per-order latency, and
   basket-level close latency (request → confirmed flat), all logged to the CSV. The underlying
   guarantees (never trust a boolean return, reconcile before retry, never reverse until
   confirmed flat) were already correct and are unchanged.

### New features (20+)

Multi-timeframe trend intelligence (H1/M15/M5) · ADX market-regime detection · ATR volatility
intelligence · advanced RSI momentum filter · candlestick pattern recognition (engulfing, hammer,
shooting star, pin bar, strong momentum, inside bar, breakout) · swing high/low detection ·
support/resistance zones · weighted signal scoring (0-100, normalized) · trend pullback entry
engine · breakout-candle confirmation · sideways-market avoidance · signal expiry/invalidation ·
London/New York session filter · fixed exposure engine · equity drawdown guard · adaptive basket
stop · break-even manager · ATR adaptive trailing · maximum holding-time manager · smart reversal
cooldown · execution latency monitor · partial close reconciliation · signal performance
analytics (via the decision log) · persistent lifetime statistics · expanded
SYSTEM/MARKET/TRADING/PERFORMANCE/EXECUTION dashboard · detailed decision logging · optional
economic-calendar filter (native MQL5 only, off by default, fails open if unavailable).

### Removed entirely

`RandomBasketBaseline`, `g_basketBaseline`, `InpBasketMin`, `InpGrowthEnabled`,
`InpWinsPerStep`, `InpLotStep`, `g_winStreak` — the whole growth/randomness mechanism — and the
single EMA-cross/trend signal (`g_lastSignal`, `g_lastSignalCrossBar`, `HasFreshUnusedSignal`),
superseded by the regime/score engine.

## New in v5.1

Cosmetic/usability fixes only — no signal, risk, or execution logic changed from v5.00:

1. **Dashboard text size is now fixed and readable** — 9pt body / 11pt title, on every machine,
   every time. (An earlier build of this version tried to *shrink* text to fit small chart
   windows; on a small chart it became unreadably tiny, so that approach was dropped. Legibility
   always wins over compactness now.)
2. **Panel width adapts a little to the chart** (400-480px, via `ComputeDashboardSizing()`,
   computed from `CHART_WIDTH_IN_PIXELS` at `OnInit`) so it looks right on both a small chart
   window and a wide monitor, without ever touching font size. The panel is taller than v5.00's
   (31 fixed-height rows) — if it runs past the bottom of a short chart window, resize/maximize the
   chart rather than shrinking the dashboard; that's a deliberate trade-off for readability.
3. **Long text no longer gets cut off mid-word.** The "last rejection reason" and "last
   action/error" lines wrap onto a second row instead of being truncated — these are exactly the
   lines you need in full to understand *why* the EA isn't trading right now.
4. **One log file by default, not two.** `InpLogDecisions` now defaults to **false**, so a fresh
   run writes a single trade-log CSV. The per-evaluation decision CSV (every accepted/rejected
   entry attempt with its full score breakdown) is still there — turn `InpLogDecisions` back on
   when you specifically need that level of entry-rejection detail.
5. **Version string corrected.** `#property version` / `EA_VERSION` now read `"5.1"` (a short-lived
   intermediate build briefly used `"5.01"`, which reads as a patch release of a nonexistent
   `"5.0"` rather than the actual next version after `5.00`).
6. **Nothing machine-specific.** The EA was already portable (account/symbol/magic-scoped
   GlobalVariables, demo-mode detected generically via `ACCOUNT_TRADE_MODE`, no hard-coded paths
   or account numbers) — v5.1's dashboard auto-sizing is the one remaining piece that now also
   adapts, so the same compiled `.ex5` behaves and displays correctly on a different tester's PC,
   broker and screen size, not just the machine it was built on.

## New in v5.2

One behavior change, reported straight from a first fresh run on a demo account:

- **`InpRequireCandleConfirm` now defaults to `false`.** MODE A already requires H1+M15+M5 trend
  agreement; requiring the *most recent closed candle* to also close with the trend, on top of
  that, could leave a fresh attach sitting out for hours waiting for one specific candle even
  while the broader trend was clearly aligned — which looked indistinguishable from "stuck."
  Turn it back to `true` (Inputs tab, no recompile needed) if you want the stricter/slower entry
  filter back; nothing else about MODE A changed.

## New in v5.3 — real bug fix

Confirmed directly from `MQL5\Logs\<date>.log` (the Experts-tab log, not the terminal journal —
see "Logs" below): fired **16 times in one session**.

- **Root cause:** `g_state` is a global variable. MQL5 does **not** reset global variables on a
  "soft" reinit — `OnDeinit`/`OnInit` triggered by changing the chart's symbol or **timeframe**
  (`REASON_CHARTCHANGE`), changing an input (`REASON_PARAMETERS`), or MetaEditor hot-reloading an
  already-attached EA after a recompile (`REASON_RECOMPILE`). Only a genuine remove-and-reattach
  resets globals. `OnInit` unconditionally transitioned into `STATE_START_DELAY` without first
  resetting `g_state`, so if the EA was still sitting in `WAITING_INITIAL_SIGNAL` (or, worse,
  already in `ERROR`) from a moment before the reinit, that transition was **illegal** per the
  state table and failed safe into `STATE_ERROR` — which is terminal, so the EA then needed a
  manual remove+reattach to recover.
- **Trigger in practice:** switching the chart's displayed timeframe (M1/M5/M15/...) on the SAME
  chart the EA is attached to has always caused this kind of reinit in MT5 — it is standard
  platform behavior, not something this EA's code controls. If you want to look at a different
  timeframe without disturbing the running bot, open a **second, separate chart** for that symbol
  instead of changing the period on the EA's own chart.
- **Fix:** `OnInit` now sets `g_state = STATE_INITIALIZING` as the very first thing it does (right
  after the mandatory demo-account guard), so every reinit — soft or cold — starts the state
  machine from a known-clean state. No other logic changed.

## New in v5.4

`InpMinSignalScore` default lowered **80.0 → 70.0**. The scoring *formula* is unchanged — a
borderline live setup (H1+M15+M5 all agreed, but RSI 52.1 and ADX 24.8 were both only just past
neutral/threshold) scored 68.9 and got rejected, and was traced component-by-component to confirm
it was an accurate "aligned but weak" read, not a bug.

A request to recalibrate the 8 component weights so plain multi-timeframe alignment alone would
score 82-88 regardless of momentum/ADX strength was **declined** — that would make direction
agreement nearly sufficient by itself, which is a real change to trade quality/frequency dressed
up as a fix, and conflicts with this file's own stated principle that no code change should force
a particular outcome. Lowering the existing, purpose-built threshold input is the transparent,
reversible way to admit more setups; raise it back toward 80 for a stricter/slower filter.

Also checked against the same report and confirmed **not bugs**: `CurrentSpreadPoints()` (correct
`(ask-bid)/_Point`; a 0.0pt reading can be real on a liquid pair at a tight moment), "Daily P/L vs
SESSION vs Account DD look inconsistent" (intentionally different scopes — see "Dashboard" below),
and "the score looks stale" (`UpdateSignal()`/`DetectRegime()` already re-run every tick; there is
no cached value to force-refresh).

## New in v5.5 — the dominant bug all day

Found live, in `MQL5\Logs\`: `InpMaxBasketRiskUSD` defaulted to **5.00**, which is *less than the
risk of a single position* at the default protective stop. The default basket (`InpBasketMax=5` ×
`InpFixedLotSize=0.01` = 0.05 lots, at `InpProtectiveStopPoints=500`) computes to about **$25** of
worst-case/gap risk — so under default settings, **no basket could ever legally open**, regardless
of signal score. Confirmed directly: a signal that scored 75.3 (comfortably above
`InpMinSignalScore`) was rejected with `basket risk 25.00 exceeds InpMaxBasketRiskUSD 5.00`. This,
not the score threshold, was the actual reason nothing had traded all day.

- **Fix:** raised the default to **30.00** (headroom over the ~$25 baseline for the current
  basket size/stop). This is a **tail/gap-risk ceiling only** — the wide 500-point stop is rarely
  hit in normal operation, which is still governed by the much tighter `InpLossThresholdUSD`
  (baskets normally reverse around -$0.50 for this basket size, not -$25). Raising this cap does
  **not** make normal losses bigger.
- **Also fixed:** the Experts-tab `[DECISION]` line was printing on every tick — `EvaluateEntry()`
  runs every tick while indicators are unchanged between closed bars, so it logged the identical
  decision over and over (937 near-identical lines in under 6 minutes, confirmed live). It now
  prints only when the decision actually changes, plus a 30-second heartbeat. The CSV decision-log
  content/schema is unchanged.

## New in v5.6

Cosmetic only: the MARKET section's "Last rejection" line now also refreshes when regime goes
ambiguous/`NONE` (MODE C), instead of possibly keeping a stale MODE A/B reason from before the
regime changed. No trading logic changed.

## New in v5.7

A deliberate de-scoping. The execution core is untouched; everything measured to be dead weight or
actively harmful is gone. 3092 lines → **2682 lines**.

### Fixed

- **Exit shape is now a real 0.5 R.** `SL = InpStopATRMult × ATR`, `TP = InpTargetATRMult × ATR`,
  both sent **with the order**, so the shape survives an EA/terminal outage. Breakeven WR for 0.5 R
  is 66.7%; the old shape (-0.50 loss vs +0.25 trail arm) also needed 66.7% but never got there —
  the account's lifetime history ran **56.8% baskets / 52.0% positions, net -24.53, PF 0.95**.
- **Lifetime basket stats are rebuilt on first run** (`ReconstructLifetimeFromHistory()`), so the
  dashboard's LIFETIME position line and basket line finally agree — v5.6 only ever rebuilt
  positions, never baskets.
- **Close reason for broker-side exits comes from the closing deal's `DEAL_REASON`**
  (`DEAL_REASON_SL`/`DEAL_REASON_TP`), not from guessing at prices — a break-even stop would
  otherwise be mislabelled.

### Removed

- **The 8-component weighted 0-100 score** and `InpMinSignalScore`/`InpWeight*`. Two stacked
  gates per regime replace it. Measured: v5.0-v5.6 evaluated **21,332 times and accepted 2
  (0.009%)**; the score gate alone was 42.1% of all rejections (8,981), and 85.1% of evaluations
  passed at threshold 70 while only 18.9% passed at 80.
- **The entire reversal engine**: `STATE_REVERSAL_PENDING`, reversal cooldown, reversal confirm
  hold, `InpMaxConsecutiveReversals`, `InpReversalCooldownSeconds`, `CLOSE_REASON_LOSS_REVERSAL`,
  `InpMaxRevHalt`. A loss close now always returns to `STATE_WAITING_SIGNAL` for a fresh signal.
  `LOSS_REVERSAL` was the single most frequent loss reason in the v3.x/v4.x history.
- **The pullback wait timer** (`InpUsePullbackFilter`, `InpMaxPullbackWaitMin`,
  `g_pullbackWaitSince`). It was dead code: the timer globals were never written to
  `SavePersistentState()` (every reattach wiped the 75-minute clock) and any single tick back
  inside the zone zeroed it — **zero "Pullback wait timed out" releases exist in the whole log
  history**. Replaced by a plain hard gate, `InpMaxChaseATR` (**0.75**): too far from the fast EMA
  = no trade, no timer, no forced entry.
- **The adaptive profit manager**: `InpLossThresholdUSD`, `InpProfitMinUSD`,
  `InpProfitTargetUSD`, `InpTrailGivebackUSD`, `InpBreakEvenTriggerUSD`, `InpUseATRTrailing`,
  `InpATRTrailMultiple`, peak/trough per unit, `InpPartialClose*`.
- **The economic-calendar filter** (`InpUseCalendarFilter` and friends) — native MQL5 API, never
  reliably populated, failed open anyway.
- **The score columns in the decision CSV** (schema is now direction/regime/mode/TF
  directions/RSI/ADX/ATR/spread/accepted/reason).

### Kept, unchanged

Demo guard first in `OnInit` (then `g_state = STATE_INITIALIZING`), state machine + transition
table, symbol+magic position scan reconciled against real broker positions, retcode-aware orders,
`InpMaxBasketRiskUSD = 30.00`, the daily realized-loss halt, `InpLogDecisions = false` (one CSV
per run by default), the `[DECISION]` print throttle, the 9pt/11pt fixed dashboard fonts, the
instance lock.

### Not changed by any of this

No code change can force a specific win rate. The ATR multiples are starting values, not
statistically proven optima, and **no backtest or forward test has ever been run for v5.0+** —
including this version.

## Default configuration (controlled risk mode)

| Setting | Default |
|---|---|
| Entry / Confirm / Trend timeframe | M5 / M15 / H1 |
| Basket size (fixed) | 5 positions |
| Lot per position (fixed) | 0.01 |
| Max basket volume | 0.05 lots |
| Automatic growth / random sizing / martingale | all disabled |
| Stop / target | 1.50 × ATR / 0.75 × ATR (0.5 R, placed with the order) |
| Break-even arm | 0.30 R |
| Max holding time | 240 minutes |
| Daily realized-loss limit | ON, 5.00 |
| Demo-only execution | mandatory, cannot be bypassed |

## Inputs guide

All inputs have safe defaults; **bold** = shipped default.

**Strategy model** — `InpSignalModel` (**HYBRID** / TREND_ONLY / RANGE_ONLY).

**Multi-timeframe trend** — `InpEntryTimeframe` (**M5**), `InpConfirmTimeframe` (**M15**),
`InpTrendTimeframe` (**H1**); `InpFastMA` (**10**), `InpSlowMA` (**30**), `InpMAMethod`
(**EMA**), `InpMAPrice` (**Close**).

**Regime classifier** — `InpADXPeriod` (**14**), `InpADXTrendMin` (**22.0**), `InpADXRangeMax`
(**18.0**) — ADX between the two thresholds is ambiguous and falls through to no-trade.

**ATR volatility band** — `InpATRPeriod` (**14**), `InpATRNormalLookback` (**50**),
`InpATRMinRatio` (**0.4**), `InpATRMaxRatio` (**3.0**).

**RSI** — `InpRSIPeriod` (**14**); `InpRSIBuyMin`/`InpRSISellMax` (**50/50**, MODE A hard gate);
`InpRSIOversold`/`InpRSIOverbought` (**30/70**, MODE B extreme gate).

**MODE A pullback gate (hard, no timer)** — `InpMaxChaseATR` (**0.75**): the last closed entry-TF
close may be at most this many ATRs beyond the fast EMA, or the candidate is rejected.

**MODE B range boundaries** — `InpSwingLookback` (**50**), `InpZoneClusterATR` (**0.5**),
`InpRangeZoneATR` (**0.6**).

**Exits: fixed 0.5 R (SL and TP placed with the order)** — `InpStopATRMult` (**1.50**),
`InpTargetATRMult` (**0.75**), `InpBreakEvenR` (**0.30**, 0 = off — moves SL to entry once price
is this fraction of the risk distance in favour), `InpMaxHoldingMinutes` (**240**, 0 = no limit).

**Basket size & lot (fixed, no growth)** — `InpBasketMax` (**5**), `InpFixedLotSize` (**0.01**),
`InpMaxLotSize` (**0.50**), `InpMaxBasketVolume` (**0.05**).

**Independent risk engine** (pre-entry gates, never force-close an open basket) —
`InpMaxBasketRiskUSD` (**30.00**), `InpMaxBasketRiskPctEquity` (**2.0**),
`InpMaxDailyFloatingDrawdownUSD` (**20.00**), `InpMaxAccountDrawdownPct` (**20.0**),
`InpMaxMarginUsagePct` (**50.0**). **Whenever `InpBasketMax`, `InpFixedLotSize` or the ATR stop
multiplier change, re-check that `InpMaxBasketRiskUSD` still comfortably covers the resulting
basket risk** — a cap lower than the thing it gates fails silently, looking like a normal
risk-engine decline (this was the v5.5 bug).

**Daily risk protections** — `InpDailyLossLimitEnabled` (**true**), `InpDailyLossLimitUSD`
(**5.00**, realized loss only, sticky for the rest of the broker day); `InpMaxSpreadPoints`
(**30**), `InpSlippagePoints` (**10**), `InpMaxExecutionRetries` (**3**),
`InpMinSecondsBetweenRequests` (**2**), `InpEmergencyStop` (**false**).

**Session filter** — `InpUseSessionFilter` (**false** — verify your broker's server-time offset
before enabling; this PC's server time is ~3h45m behind local time), `InpSessionStartHour`
(**7**), `InpSessionEndHour` (**21**), server time.

**Timing** — `InpStartDelaySeconds` (**3**), `InpEntryConfirmSeconds` (**4**, a signal must hold
this long before a basket opens), `InpOperationTimeoutSeconds` (**30**).

**Misc / logging / dashboard** — `InpMagicNumber` (**20261103**), `InpTradeComment`
(**SmartReversalEA**); `InpLogToCSV` (**true**), `InpLogCommonFolder` (**false**),
`InpLogAlsoToExpertsTab` (**true**), `InpLogSubFolder` (**SachinDevBotsLog**), `InpLogDecisions`
(**false**, turn on only for the extra per-evaluation decision CSV); `InpShowDashboard` (**true**).

## Install

1. In MT5: **File → Open Data Folder → MQL5 → Experts**, and copy `SmartHedgeEA_v5.7.mq5`
   there (or just copy the already-compiled `.ex5`).
2. If you copied the `.mq5`: open **MetaEditor** (`F4`), open the file, press **F7** to compile.
   You should see `0 errors, 0 warnings`.
3. Open a **demo account** chart (e.g. EURUSD) — one chart per symbol, one EA instance per
   chart. Works on any broker/account number and any screen size — nothing in the EA is tied to
   the machine it was built on (see "New in v5.1" through "New in v5.7" above).
4. Drag **SmartHedgeEA_v5.7** from the Navigator onto the chart (remove any older instance
   first). On the **Common** tab tick **Allow Algo Trading**. Check the **Inputs** tab, then OK.
5. Make sure the **Algo Trading** button in the top toolbar is green.

## Demo-testing instructions

1. Run it on a demo account for at least a few trading days before trusting any dashboard
   number — session stats intentionally start at zero every attach (lifetime stats persist
   across restarts).
2. Watch the Experts log and the trade-log CSV in `MQL5\Files\SachinDevBotsLog\` (junctioned to
   this folder on this PC). Turn on `InpLogDecisions` if you also want the second,
   per-evaluation decision CSV (useful for debugging "why didn't it trade").
3. Confirm the demo-only guard, the 0.05-lot basket cap, and the daily-loss halt behave as
   documented before leaving it unattended.
4. A 2-4 week demo forward test is recommended before trusting this version with anything —
   see `TEST_REPORT_v5.0.md` for exactly what has and hasn't been verified so far (short version:
   compiles clean, 0 errors/0 warnings; no backtest or forward test has been run yet).
5. **"It's not trading" is usually not a bug.** Check the dashboard's MARKET section — "Last
   rejection" shows the exact reason the most recent candidate was turned down (e.g. the closed
   candle didn't confirm the trend, price was too far beyond the fast EMA, or the risk engine
   declined). MODE A needs H1+M15+M5 trend agreement **and** a confirming closed candle at the
   same time; that combination can take hours to line up, not minutes — a quiet dashboard for a
   while is the EA correctly waiting, not a sign it's stuck. Turn on `InpLogDecisions` to get a
   CSV row for every single evaluation if you want the full picture.

## Logs

- **Trade CSV (always on by default):**
  `MQL5\Files\SachinDevBotsLog\SmartReversalEA_v57_<symbol>_<magic>_<date>.csv` — one row per
  closed position: basket id, direction, volume, entry/exit price & time, entry-TF/confirm-TF/
  trend-TF direction, RSI/ADX/ATR, regime and mode captured at open, spread at entry/exit, basket
  risk, close trigger & reason (from the closing deal's `DEAL_REASON`), request/final close
  timestamps, execution latency, retcode, commission/swap/fee, net P/L, final basket outcome.
- **Decision CSV (`..._Decisions.csv`, OFF by default — `InpLogDecisions`):** every entry
  evaluation, accepted or rejected, with the regime, mode, the three TF directions, RSI/ADX/ATR,
  spread and the exact rejection reason. Turn this on when you need to debug *why* the EA isn't
  entering; leave it off for normal running so the log folder only ever has one CSV per run.
- **Experts tab / log:** all `[INFO] [WARNING] [ERROR]` lines (keep `InpLogAlsoToExpertsTab` on).
  This is written to `MQL5\Logs\<YYYYMMDD>.log` **under the terminal's data folder**, e.g.
  `...\Terminal\<ID>\MQL5\Logs\<date>.log` — a **different file** from
  `...\Terminal\<ID>\logs\<date>.log` (no `MQL5\` in the path), which is the terminal/Journal tab
  (connections, broker trade fills, EA attach/remove) and does NOT contain the EA's own
  `[INFO]`/`[WARNING]`/`[ERROR]` lines. Check `MQL5\Logs\` when debugging anything the EA itself
  printed (this is how the v5.3 state-reset bug and the v5.4 score investigation were actually
  diagnosed, not guessed from the
  dashboard).

## Dashboard

On-chart panel (display-only), five sections, fixed readable text (9pt body / 11pt title) on every
machine, panel width adapting a little to the chart (see "New in v5.1"):
- **SYSTEM** — symbol, account mode, timeframes, EA state, model, running time.
- **MARKET** — regime, H1/M15/M5 trend, RSI/ADX/ATR, spread, last rejection reason (wraps to a
  2nd line if long, never cut off mid-word).
- **TRADING** — basket direction/size/volume, average entry, basket risk, floating P/L, live
  SL/TP prices, the 0.5 R exit shape and break-even status, and the regime/mode/RSI/ADX captured
  when the basket opened.
- **PERFORMANCE** — session baskets (win/loss/win-rate), net/gross/profit-factor, average
  winner/loser, expected value per basket, max consecutive wins/losses, today's and lifetime
  basket totals, account drawdown, daily/emergency status.
- **EXECUTION** — last order, last retcode, latency, last action or error (also wraps to a 2nd
  line if long).

## Honest limitations

- Trend-following can **lose repeatedly in a sideways market** — MODE B exists to reduce this,
  but it is not a guarantee.
- A 0.5 R shape needs a **66.7% win rate to break even**. Nothing in this code makes that happen;
  it only makes the shape honest and identical on every trade.
- **No backtest or live forward-test results exist for v5.7** (or any v5.x). `TEST_REPORT_v5.0.md`
  lists exactly what was verified (clean compile, static/logic review) and what wasn't (any
  backtest, any forward test, any win-rate/profit-factor claim). Run your own before trusting it
  with anything.
- The stop-loss is a price distance, not a fixed money amount: gaps, slippage, spread and tick
  value all move the realized number away from the intended risk.
- An `ERROR` state is deliberate: it stops trading and waits for manual review. Emergency stop
  cannot open a new position while in `ERROR`, it can only close a stray one.

## How to backtest it yourself

1. In MT5 press `Ctrl+R` (Strategy Tester). Expert: **SmartHedgeEA_v5.7**, Symbol **EURUSD**,
   Period **M5**.
2. Model: **Every tick based on real ticks** (or *1-minute OHLC* for a quick run). Pick a
   chronological in-sample period, then a separate out-of-sample period — never the same dates
   twice. Deposit 2000 USD, leverage 1:500 is a reasonable starting point.
3. Click **Start**. Check the Results/Backtest tabs and the CSV + decision log the EA wrote.
4. Compare `InpSignalModel = TREND_ONLY` vs `RANGE_ONLY` vs `HYBRID` on the same dates, and
   against the old v4.8 (from `Old Verson\`) as a baseline. Then vary `InpStopATRMult` /
   `InpTargetATRMult` — the 0.5 R shape is the thing to test, not a score threshold that no
   longer exists.

## Files

- `SmartHedgeEA_v5.7.mq5` / `.ex5` — the EA (the latest version — this folder holds only the
  latest version per project convention).
- `Old Verson\` — every older version (v3.02 → v5.6) kept as backups, never edited or deleted.
- `TEST_REPORT_v5.0.md` — exactly what has and hasn't been verified for the v5.0x signal/risk
  engine. v5.7 replaced the exit and signal-gate layers on top of that engine; the verification
  status (clean compile, no backtest, no forward test) is unchanged, see "New in v5.7".

---

## Version history (v3.02 → v4.8) — kept for reference

Everything below describes the single-signal (EMA cross/trend) basket engine that v5.0 replaced.
Kept here so the reasoning behind each earlier change isn't lost.

### v4.8
Re-applied the v4.3 this-session-only dashboard fix, which v4.6 had lost by reverting to v4.1
(v4.7 only restored the background fix, not this one). New non-persisted session counters always
started at zero on a fresh attach, exactly like "Running" does, and drove the dashboard again —
so right after a restart it no longer showed totals from days of prior trading next to a running
time of a few seconds. Lifetime totals were unchanged under the hood and still logged in full on
`OnDeinit`.

### v4.7
Re-applied the v4.2 dashboard background fix, which v4.6 had lost by reverting to v4.1.
`CreateRect()`/`CreateLabel()` reapplied their background/border/color properties on every call
instead of only the first time an object was created, and `CreateDashboard()` wiped any leftover
dashboard objects from an older session first; the panel went back to a fully opaque solid
near-black with a brighter border.

### v4.6
Explicit request to revert to v4.1's parameters/behavior, with no specific evidence pinned down
for the reason. This reintroduced, on purpose: `InpMaxLotSize` back to 0.50 (was tightened to
0.03 in v4.5), `InpBasketMax` back to 10 (was tightened to 12 in v4.4), the dashboard showing
lifetime totals again instead of this-session-only, and possible dashboard background staleness.

### v4.5
`InpMaxLotSize` 0.50 → 0.03 (data-driven): a live session showed a basket at lot 0.04 (grown from
a long win streak) lose -5.96, by itself worse than that session's entire net result. Lot and
basket size both grow from the same win streak, so the biggest lot is always active right before
the loss that resets it; capping it bounded the worst-case loss size.

### v4.4
`InpBasketMax` 20 → 12 (data-driven): a live session showed one 13-position basket (lot already
grown to 0.02) lose -5.10 against a nominal -2.60 risk — about 68% of that session's total loss
came from this single basket.

### v4.3
Dashboard headline numbers became THIS-SESSION-ONLY, not lifetime — "Running" had always reset
to zero on every restart, but the totals next to it were lifetime, which looked like stale data
right after a fresh attach. Lifetime totals stayed persisted/logged in full for history.

### v4.2
`InpBasketMax` 10 → 20 (basket could grow up to 20 positions again). Dashboard also showed the
raw total position count next to the basket count. Fixed a dashboard transparency/stale-style
bug: a same-named panel object left over from an earlier EA session kept its OLD properties
forever after, even though the code specified new ones — properties are now reapplied
unconditionally every call.

### v4.1
Dashboard/stats became BASKET-level, not position-level. A 10-position losing basket used to
show as "10 losing trades" even though it was one decision — a real session showed 946 winning
vs. 1936 losing *positions* (32.8% "win rate") while the same session was 28 winning vs. 11
losing *baskets* (~72% win rate, net positive). No change to entry/exit/signal logic — reporting
accuracy only.

### v4.0
Basket reset range shrunk from random 10-20 to random 5-10. Profit band widened and re-tuned:
trailing armed at +0.05 per 0.01 lot (was +0.15), hard ceiling raised to +1.00 (was +0.30),
giveback stayed 0.05, loss threshold unchanged at -0.10. New RSI momentum filter as an extra
agreement gate on top of the EMA signal. New reversal re-confirmation: cancel instead of firing
if the EMA trend already flipped back away from the reversal direction.

### v3.09 (superseded by v4.0)
Removed the QUICK trading mode and dashboard mode button added in v3.08, back to a single EMA
cross/trend signal path. New entry-confirmation hold before opening a basket. Exits recalibrated
to a 1:3 risk:reward (later re-tuned again in v4.0).

### v3.08 (superseded by v3.09)
Randomized basket-size reset baseline 10-20. Added (then removed) a QUICK trading mode and a
dashboard mode-switch button.

### v3.07
GV prefix bumped (`SRE3_` → `SRE37_`) so any stale halt/reversal-cap flag from earlier testing
was dropped instead of silently carrying over. Default signal timeframe changed to M5 (was M1).

### v3.06
Fixed a fake "PROFIT" close when the basket shrank: if some positions disappeared (stop-out or
manual close), the trailing peak stayed in old dollars and the remaining positions were closed at
once for a tiny profit. The peak is tracked per 0.01 lot ever since.

### Earlier (v3.02 → v3.05)
Original basket-engine buildout: EMA crossover signal on closed candles, basket open/trail/close
as one unit, reversal on loss, demo-only guard, instance lock, CSV/Experts logging, on-chart
dashboard. All of it superseded in behavior by later versions above, kept as backups in
`Old Verson\`.
