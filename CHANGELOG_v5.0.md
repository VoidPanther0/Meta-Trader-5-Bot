# CHANGELOG — v4.8 → v5.0

## Bugs / defects fixed (mapped to the master spec's FIX 1-7)

**FIX 1 — Entry signal quality.** v4.8's `ENTRY_ON_CROSS_OR_TREND` could enter on the current EMA
trend with no fresh crossover, the pullback filter defaulted off, and RSI confirmation was a weak
50-line gate. v5.0 replaces this with `EvaluateEntry()`: closed-candle-only confirmation (already
true in v4.8, kept), multi-timeframe (H1/M15/M5) direction validation, a mandatory-by-default
pullback/anti-chase check, ADX regime validation, ATR volatility validation, extended-entry
rejection, and a weighted 0-100 score threshold. One bar can trigger at most one entry
(`g_lastEntryBarConsumed`).

**FIX 2 — Random basket sizing.** `RandomBasketBaseline()`, `g_basketBaseline`, and the win-streak
basket-growth path (5→20 positions) are **removed from the code**, not just disabled.
`CurrentBasketSize()` always returns the fixed `InpBasketMax` (default 5).

**FIX 3 — Uncontrolled exposure growth.** `InpGrowthEnabled`/`InpWinsPerStep`/`InpLotStep` are
removed. `CurrentLot()` always returns the fixed `InpFixedLotSize` (default 0.01), clamped to the
broker's volume grid and the 0.50-lot hard ceiling exactly as before. `InpMaxBasketVolume`
(default 0.05) caps total basket volume; `ExecuteOpen` shrinks the basket to fit it, free margin,
and the new risk-engine checks. No size or lot increase after a loss exists anywhere in this
version.

**FIX 4 — Risk management.** A new independent risk engine (`EquityDrawdownOk`,
`DailyFloatingDrawdownOk`, `MarginUsageOk`, `BasketRiskOk`/`ComputeBasketRiskUSD`) adds: hard
monetary + %-equity basket risk caps, an account equity-drawdown guard, a daily floating-drawdown
guard, and a margin-usage guard — on top of v4.8's existing realized daily-loss halt, which is
kept unchanged (`InpDailyLossLimitEnabled` now defaults **true**, per the controlled risk mode).
All of these block new entries/reversals only; none of them force-close an open basket, same
philosophy v4.8 already used for its daily-loss limit. The daily halt's force-reset-on-init
behavior (no stale-halt inheritance) is unchanged. All `$` inputs are documented as account
currency — they already were, via `AccountInfoDouble`/deal `PROFIT`, no USD assumption existed to
fix.

**FIX 5 — Reversal logic.** v4.8 only cancelled a pending reversal if the EMA trend had already
flipped away; otherwise it opened the opposite basket on nothing more than "not yet cancelled."
v5.0's `STATE_REVERSAL_PENDING` now: (1) requires the original basket confirmed fully closed
(unchanged — this was already correct), (2) waits out a new `InpReversalCooldownSeconds`, (3)
calls the exact same `EvaluateEntry()` a fresh entry uses — full regime re-classification, score,
candle/pullback/range gates, spread/session/calendar checks, and every risk-engine gate — (4)
requires the higher timeframe to support the direction (part of the score), (5) requires the score
threshold, (6) requires spread/risk checks to pass, (7) only then re-confirms for
`InpReversalConfirmSeconds` before opening. `InpMaxConsecutiveReversals` default lowered from 20 to
2. A specific whipsaw guard remains: if the M5 trend has already flipped back toward the original
direction, the reversal is cancelled outright rather than endlessly re-evaluated.

**FIX 6 — Profit management.** The adaptive profit manager keeps v4.8's proven basket-shrink-safe
peak-tracking trail and adds: break-even protection (`InpBreakEvenTriggerUSD`), optional ATR-based
trailing distance (`InpUseATRTrailing`/`InpATRTrailMultiple`) instead of a fixed giveback, a
maximum holding duration close (`InpMaxHoldingMinutes`, new `CLOSE_REASON_MAX_HOLDING`), and an
optional one-time partial close (`InpPartialCloseEnabled`). Profit is still computed as
`POSITION_PROFIT + POSITION_SWAP` plus entry commission/fee from deal history (unchanged, already
correct). The basket's logged **outcome** (WIN/LOSS/BREAKEVEN) is now always derived from the
actual completed deal-history net sum and stored separately from the close **trigger** name, so a
basket closed on a "PROFIT" trigger that nets negative after commission/swap/slippage is logged as
LOSS, not WIN.

**FIX 7 — Execution and close reliability.** v4.8's core guarantees (never trust `CTrade`'s
boolean, reconcile before retry, never reverse until confirmed flat, partial-fill detection,
timeout/retry, broker reconciliation, final flat confirmation) were already correct and are
unchanged. v5.0 adds instrumentation on top: a close-request timestamp captured once per close
cycle, order-level latency (`GetTickCount64` around every `trade.Buy/Sell/PositionClose` call),
and basket-level close latency (request → confirmed-flat) logged to the v5 CSV.

## New features (20+)

1. Multi-Timeframe Trend Intelligence (H1/M15/M5 EMA trend via dedicated handles).
2. ADX Market Regime Detection (`DetectRegime`).
3. ATR Volatility Intelligence (rolling-average sanity check, abnormal ATR → no-trade).
4. Advanced RSI Momentum Filter (hard gate in MODE A, extreme-based scoring + MODE B gate).
5. Candlestick Pattern Recognition (engulfing, hammer, shooting star, pin bar, strong momentum,
   inside bar, breakout candle — pure OHLC, closed candles only).
6. Swing High/Low Detection (fractal scan, `FindSwings`).
7. Support and Resistance Zones (`ClusterPoints`/`UpdateSwingZones`).
8. Market Structure Analysis (folded into the swing/zone module).
9. Weighted Signal Scoring (`ComputeSignalScore`, normalized 0-100).
10. Trend Pullback Entry Engine (ATR-distance anti-chase, bounded wait timeout kept from v4.8).
11. Breakout and Retest Confirmation (breakout-candle pattern; see README limitations).
12. Sideways Market Avoidance (MODE A is never selected while regime == RANGE, and vice versa
    for RANGE_ONLY/TREND_ONLY models).
13. Signal Expiry and Invalidation (`g_lastEntryBarConsumed`; scores are only ever computed from
    the current closed bar, never cached).
14. London/New York Session Filter (`InpUseSessionFilter`, off by default).
15. Fixed Exposure Engine (`EstimateBasketVolume`, `InpMaxBasketVolume`).
16. Equity Drawdown Guard (`EquityDrawdownOk`).
17. Adaptive Basket Stop (loss threshold unchanged, now alongside the risk engine's own gates).
18. Break-Even Manager (`InpBreakEvenTriggerUSD`).
19. ATR Adaptive Trailing Manager (`InpUseATRTrailing`).
20. Maximum Holding-Time Manager (`InpMaxHoldingMinutes`).
21. Smart Reversal Cooldown (`InpReversalCooldownSeconds`, distinct from the confirm hold).
22. Execution Latency Monitor (`g_lastOrderLatencyMs`, per-basket close latency in the CSV).
23. Partial Close Reconciliation (`DoPartialClose`, whole-ticket + partial-volume handling).
24. Signal Performance Analytics (every decision — accepted or rejected — logged with its full
    score breakdown to the decision CSV; this is file-based analytics, not extra dashboard rows).
25. Persistent Lifetime Statistics (unchanged mechanism from v4.8, extended fields).
26. Expanded Dashboard (SYSTEM/MARKET/TRADING/PERFORMANCE/EXECUTION sections, ~30 rows).
27. Detailed Decision Logging (separate `_Decisions.csv`).
28. Optional Economic Calendar Filter (`InpUseCalendarFilter`, off by default, fails open).

## Removed

- `RandomBasketBaseline`, `g_basketBaseline`, `InpBasketMin`, `InpGrowthEnabled`,
  `InpWinsPerStep`, `InpLotStep`, `g_winStreak` — the entire growth/randomness mechanism.
- The single EMA-cross/trend signal (`g_lastSignal`, `g_lastSignalCrossBar`,
  `HasFreshUnusedSignal`) — superseded by the regime/score engine.
