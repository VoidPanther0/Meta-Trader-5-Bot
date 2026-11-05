# Smart Reversal EA v5.0

**File:** `SmartHedgeEA_v5.00.mq5` / `SmartHedgeEA_v5.00.ex5`
**Platform:** MetaTrader 5, MQL5
**Copyright:** Sachin Dev Bots

> **DEMO ACCOUNTS ONLY.** The EA refuses to start on a live or contest account, and that check
> can never be removed, weakened, or bypassed by any input. This is an experiment, not a money
> machine — **no profit is promised or guaranteed.**

---

## What it does

A single-symbol, basket-based reversal EA. It opens a fixed-size basket of same-direction
positions, manages it as one unit (trailing, break-even, max holding time, optional partial
close), closes it, and may open an opposite-direction basket afterward — but only after a full
re-evaluation of the market, never a blind reversal.

v5.0 replaces the old single EMA-cross signal (v4.8 and earlier) with a dual market-regime
engine:

- **MODE A — Trend Continuation**: H1 + M15 + M5 EMA trend agreement, ADX trend-strength
  confirmation, a pullback/anti-chase filter, and closed-candle confirmation.
- **MODE B — Range Mean Reversion**: swing-based support/resistance zones, RSI extremes or a
  rejection candle at the boundary, and a minimum reward:risk space check to the opposite
  boundary.
- **MODE C — No-Trade**: the deliberate default whenever regime, data, risk, or score checks
  don't clear the bar. Logged like any other decision, never silently skipped.

A weighted 0-100 score (8 components, minimum 80 by default) gates every entry **and** every
reversal — the reversal path runs through the exact same evaluation function used for a fresh
entry, so a reversal requires a genuinely re-confirmed opposite setup, not just "the old signal
hasn't been cancelled yet."

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

## Default configuration (controlled risk mode)

| Setting | Default |
|---|---|
| Entry / Confirm / Trend timeframe | M5 / M15 / H1 |
| Basket size (fixed) | 5 positions |
| Lot per position (fixed) | 0.01 |
| Max basket volume | 0.05 lots |
| Automatic growth / random sizing / martingale | all disabled |
| Max consecutive reversals | 2 |
| Minimum signal score | 80 / 100 |
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

**ATR volatility intelligence** — `InpATRPeriod` (**14**), `InpATRNormalLookback` (**50**),
`InpATRMinRatio` (**0.4**), `InpATRMaxRatio` (**3.0**).

**RSI momentum** — `InpRSIPeriod` (**14**); `InpRSIBuyMin`/`InpRSISellMax` (**50/50**, MODE A
hard gate); `InpRSIOversold`/`InpRSIOverbought` (**30/70**, MODE B extreme gate).

**MODE A pullback/anti-chase** — `InpUsePullbackFilter` (**true**), `InpMaxChaseATR` (**1.0**),
`InpRequireCandleConfirm` (**true**), `InpMaxPullbackWaitMin` (**75**, 0 = wait forever).

**MODE B range mean reversion** — `InpSwingLookback` (**50**), `InpZoneClusterATR` (**0.5**),
`InpRangeZoneATR` (**0.6**), `InpMinRewardRiskRatio` (**1.5**).

**Weighted scoring** — `InpWeightH1/M15/M5/RSI/ADX/ATR/Candle/Pullback`
(**20/15/15/10/10/10/10/10**, re-normalized to 0-100 if changed); `InpMinSignalScore` (**80**).

**Basket exits** (per 0.01 lot, scaled by basket volume) — `InpLossThresholdUSD` (**0.10**),
`InpProfitMinUSD` (**0.05**), `InpProfitTargetUSD` (**1.00**), `InpTrailGivebackUSD` (**0.05**),
`InpMaxConsecutiveReversals` (**2**).

**Adaptive profit manager** — `InpBreakEvenTriggerUSD` (**0.20**), `InpUseATRTrailing`
(**true**), `InpATRTrailMultiple` (**1.5**), `InpMaxHoldingMinutes` (**240**, 0 = no limit),
`InpPartialCloseEnabled` (**false**), `InpPartialCloseFraction` (**0.5**),
`InpPartialCloseTriggerUSD` (**0.30**).

**Basket size & lot (fixed, no growth)** — `InpBasketMax` (**5**), `InpFixedLotSize` (**0.01**),
`InpMaxLotSize` (**0.50**), `InpMaxBasketVolume` (**0.05**).

**Independent risk engine** (pre-entry gates, never force-close an open basket) —
`InpMaxBasketRiskUSD` (**5.00**), `InpMaxBasketRiskPctEquity` (**2.0**),
`InpMaxDailyFloatingDrawdownUSD` (**20.00**), `InpMaxAccountDrawdownPct` (**20.0**),
`InpMaxMarginUsagePct` (**50.0**).

**Protective stop** — `InpProtectiveStopPoints` (**500**) — a wide backstop, not a fixed-money
guarantee.

**Daily risk protections** — `InpDailyLossLimitEnabled` (**true**), `InpDailyLossLimitUSD`
(**5.00**, realized loss only, sticky for the rest of the broker day); `InpMaxSpreadPoints`
(**30**), `InpSlippagePoints` (**10**), `InpMaxExecutionRetries` (**3**),
`InpMinSecondsBetweenRequests` (**2**), `InpEmergencyStop` (**false**).

**Session filter** — `InpUseSessionFilter` (**false** — verify your broker's server-time offset
before enabling; this PC's server time is ~3h45m behind local time), `InpSessionStartHour`
(**7**), `InpSessionEndHour` (**21**), server time.

**Economic calendar filter** — `InpUseCalendarFilter` (**false**, native MQL5 Calendar API
only, fails open if unavailable), `InpCalendarBlockMinutesBefore`/`After` (**15/15**),
`InpCalendarMinImportance` (**2**).

**Reversal logic** — `InpReversalCooldownSeconds` (**10**), `InpEntryConfirmSeconds` (**4**),
`InpReversalConfirmSeconds` (**4**).

**Timing / misc / logging / dashboard** — `InpStartDelaySeconds` (**3**),
`InpPostProfitWaitSeconds` (**3**), `InpOperationTimeoutSeconds` (**30**); `InpMagicNumber`
(**20261103**), `InpTradeComment` (**SmartReversalEA**); `InpLogToCSV` (**true**),
`InpLogCommonFolder` (**false**), `InpLogAlsoToExpertsTab` (**true**), `InpLogSubFolder`
(**SachinDevBotsLog**), `InpLogDecisions` (**true**); `InpShowDashboard` (**true**).

## Install

1. In MT5: **File → Open Data Folder → MQL5 → Experts**, and copy `SmartHedgeEA_v5.00.mq5`
   there (or just copy the already-compiled `.ex5`).
2. If you copied the `.mq5`: open **MetaEditor** (`F4`), open the file, press **F7** to compile.
   You should see `0 errors, 0 warnings`.
3. Open a **demo account** chart (e.g. EURUSD) — one chart per symbol, one EA instance per
   chart.
4. Drag **SmartHedgeEA_v5.00** from the Navigator onto the chart (remove any older instance
   first). On the **Common** tab tick **Allow Algo Trading**. Check the **Inputs** tab, then OK.
5. Make sure the **Algo Trading** button in the top toolbar is green.

## Demo-testing instructions

1. Run it on a demo account for at least a few trading days before trusting any dashboard
   number — session stats intentionally start at zero every attach (lifetime stats persist
   across restarts).
2. Watch the Experts log and the two CSV files (trade log + decision log) in
   `MQL5\Files\SachinDevBotsLog\` (junctioned to this folder on this PC).
3. Confirm the demo-only guard, the 0.05-lot basket cap, and the daily-loss halt behave as
   documented before leaving it unattended.
4. A 2-4 week demo forward test is recommended before trusting this version with anything —
   see `TEST_REPORT_v5.0.md` for exactly what has and hasn't been verified so far (short version:
   compiles clean, 0 errors/0 warnings; no backtest or forward test has been run yet).

## Logs

- **Trade CSV:** `MQL5\Files\SachinDevBotsLog\SmartReversalEA_v5_<symbol>_<magic>_<date>.csv` —
  one row per closed position: basket id, direction, volume, entry/exit price & time, H1/M15/M5
  trend, RSI/ADX/ATR, signal score, regime, spread at entry/exit, basket risk, max floating
  loss/profit, peak profit, close trigger & reason, request/final close timestamps, execution
  latency, retcode, commission/swap/fee, net P/L, reversal status, final basket outcome.
- **Decision CSV:** `..._Decisions.csv` — every entry/reversal evaluation, accepted or rejected,
  with its full 8-component score breakdown and the exact rejection reason.
- **Experts tab / log:** all `[INFO] [WARNING] [ERROR]` lines (keep `InpLogAlsoToExpertsTab` on).

## Dashboard

On-chart panel (display-only), rebuilt for v5.0 into five sections:
- **SYSTEM** — symbol, account mode, timeframes, EA state, running time.
- **MARKET** — regime, H1/M15/M5 trend, RSI/ADX/ATR, spread, BUY/SELL score, last rejection
  reason.
- **TRADING** — basket direction/size/volume, average entry, floating P/L and peak, stop-loss,
  trailing status, the basket's score/mode/regime.
- **PERFORMANCE** — session baskets (win/loss/win-rate), net/gross/profit-factor, average
  winner/loser, expected value per basket, max consecutive wins/losses, today's and lifetime
  basket totals, account drawdown.
- **EXECUTION** — last order, last retcode, latency, partial-close status, last action or error.

## Honest limitations

- Trend-following with reversals can **lose repeatedly in a sideways market** — MODE B exists to
  reduce this, but it is not a guarantee.
- "Breakout and retest confirmation" is implemented as a breakout-candle pattern check only, not
  a full multi-bar retest state machine.
- The optional economic-calendar filter is not reliably populated in the Strategy Tester; it
  fails open (never blocks trading) rather than guess.
- **No backtest or live forward-test results exist for v5.0 yet.** `TEST_REPORT_v5.0.md` lists
  exactly what was verified (clean compile, static/logic review) and what wasn't (any backtest,
  any forward test, any win-rate/profit-factor claim). Run your own before trusting it with
  anything.
- If the loss threshold is smaller than the current spread cost, baskets reverse immediately —
  the EA warns about this in the Experts log at startup.
- An `ERROR` state is deliberate: it stops trading and waits for manual review. Emergency stop
  cannot open a new position while in `ERROR`, it can only close a stray one.

## How to backtest it yourself

1. In MT5 press `Ctrl+R` (Strategy Tester). Expert: **SmartHedgeEA_v5.00**, Symbol **EURUSD**,
   Period **M5**.
2. Model: **Every tick based on real ticks** (or *1-minute OHLC* for a quick run). Pick a
   chronological in-sample period, then a separate out-of-sample period — never the same dates
   twice. Deposit 2000 USD, leverage 1:500 is a reasonable starting point.
3. Click **Start**. Check the Results/Backtest tabs and the CSV + decision log the EA wrote.
4. Compare `InpSignalModel = TREND_ONLY` vs `RANGE_ONLY` vs `HYBRID` on the same dates, and
   against the old v4.8 (from `Old Verson\`) as a baseline.

## Files

- `SmartHedgeEA_v5.00.mq5` / `.ex5` — the EA (the latest version — this folder holds only the
  latest version per project convention).
- `Old Verson\` — every older version (v3.02 → v4.8) kept as backups, never edited or deleted.
- `TEST_REPORT_v5.0.md` — exactly what has and hasn't been verified for this version.

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
