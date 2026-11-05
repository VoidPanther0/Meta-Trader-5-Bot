# Input Guide — Smart Reversal EA v5.0

All inputs have safe defaults matching the master spec's "STRICT USER CONFIGURATION". Values in
**bold** are the shipped defaults.

## Strategy Model
- `InpSignalModel` (**HYBRID** / TREND_ONLY / RANGE_ONLY) — which regime(s) may trade.

## Multi-Timeframe Trend
- `InpEntryTimeframe` (**M5**), `InpConfirmTimeframe` (**M15**), `InpTrendTimeframe` (**H1**) —
  trend direction on each is fast-EMA-vs-slow-EMA, closed bars only.
- `InpFastMA` (**10**), `InpSlowMA` (**30**), `InpMAMethod` (**EMA**), `InpMAPrice` (**Close**).

## Regime Classifier
- `InpADXPeriod` (**14**), `InpADXTrendMin` (**22.0**) — ADX ≥ this + 3-TF agreement ⇒ TREND.
- `InpADXRangeMax` (**18.0**) — ADX ≤ this ⇒ RANGE. Between the two = ambiguous ⇒ no-trade.

## ATR Volatility Intelligence
- `InpATRPeriod` (**14**), `InpATRNormalLookback` (**50**) bars for the rolling average.
- `InpATRMinRatio` (**0.4**) / `InpATRMaxRatio` (**3.0**) — current ATR outside
  `[min, max] × average` ⇒ abnormal ⇒ no-trade.

## RSI Momentum
- `InpRSIPeriod` (**14**).
- `InpRSIBuyMin` (**50**) / `InpRSISellMax` (**50**) — MODE A hard gate.
- `InpRSIOversold` (**30**) / `InpRSIOverbought` (**70**) — MODE B extreme gate.

## MODE A — Pullback / Anti-Chase
- `InpUsePullbackFilter` (**true**), `InpMaxChaseATR` (**1.0**) — max ATRs beyond the fast EMA.
- `InpRequireCandleConfirm` (**true**).
- `InpMaxPullbackWaitMin` (**75**) — bounded wait before entering with the trend anyway (0 = wait
  forever).

## MODE B — Range Mean Reversion
- `InpSwingLookback` (**50**) bars, `InpZoneClusterATR` (**0.5**) — swing-point clustering
  tolerance.
- `InpRangeZoneATR` (**0.6**) — how close to a zone counts as "at the boundary".
- `InpMinRewardRiskRatio` (**1.5**) — space to the far boundary vs. the near one.

## Weighted Scoring
- `InpWeightH1/M15/M5/RSI/ADX/ATR/Candle/Pullback` (**20/15/15/10/10/10/10/10**, sums to 100 but
  is re-normalized by its actual sum if changed).
- `InpMinSignalScore` (**80**).

## Basket Exits (per 0.01 lot, scaled by basket volume)
- `InpLossThresholdUSD` (**0.10**), `InpProfitMinUSD` (**0.05**), `InpProfitTargetUSD` (**1.00**),
  `InpTrailGivebackUSD` (**0.05**), `InpMaxConsecutiveReversals` (**2**).

## Adaptive Profit Manager
- `InpBreakEvenTriggerUSD` (**0.20**) — once reached, the trail floor never goes below 0/unit.
- `InpUseATRTrailing` (**true**), `InpATRTrailMultiple` (**1.5**).
- `InpMaxHoldingMinutes` (**240**, 0 = no limit).
- `InpPartialCloseEnabled` (**false**), `InpPartialCloseFraction` (**0.5**),
  `InpPartialCloseTriggerUSD` (**0.30**).

## Basket Size & Lot — FIXED, no growth
- `InpBasketMax` (**5**), `InpFixedLotSize` (**0.01**), `InpMaxLotSize` (**0.50**),
  `InpMaxBasketVolume` (**0.05**).

## Independent Risk Engine (pre-entry gates, never force-close an open basket)
- `InpMaxBasketRiskUSD` (**5.00**), `InpMaxBasketRiskPctEquity` (**2.0**).
- `InpMaxDailyFloatingDrawdownUSD` (**20.00**).
- `InpMaxAccountDrawdownPct` (**20.0**).
- `InpMaxMarginUsagePct` (**50.0**).

## Protective Stop
- `InpProtectiveStopPoints` (**500**) — a wide backstop, not a fixed-money guarantee.

## Daily Risk Protections
- `InpDailyLossLimitEnabled` (**true**, ON by default in v5.0), `InpDailyLossLimitUSD` (**5.00**)
  — realized loss only, sticky for the rest of the broker day.
- `InpMaxSpreadPoints` (**30**), `InpSlippagePoints` (**10**), `InpMaxExecutionRetries` (**3**),
  `InpMinSecondsBetweenRequests` (**2**), `InpEmergencyStop` (**false**).

## Session Filter
- `InpUseSessionFilter` (**false**) — enable only after confirming your broker's server-time
  offset (see `CLAUDE.md`: this PC's server time is ~3h45m behind local time).
- `InpSessionStartHour` (**7**), `InpSessionEndHour` (**21**) — server time.

## Economic Calendar Filter
- `InpUseCalendarFilter` (**false**) — native MQL5 Calendar API only; fails open if unavailable.
- `InpCalendarBlockMinutesBefore`/`After` (**15/15**), `InpCalendarMinImportance` (**2**).

## Reversal Logic
- `InpReversalCooldownSeconds` (**10**) — must fully elapse before re-evaluation starts.
- `InpEntryConfirmSeconds` (**4**), `InpReversalConfirmSeconds` (**4**).

## Timing / Misc / Logging / Dashboard
- `InpStartDelaySeconds` (**3**), `InpPostProfitWaitSeconds` (**3**),
  `InpOperationTimeoutSeconds` (**30**).
- `InpMagicNumber` (**20261103**), `InpTradeComment` (**SmartReversalEA**).
- `InpLogToCSV` (**true**), `InpLogCommonFolder` (**false**), `InpLogAlsoToExpertsTab` (**true**),
  `InpLogSubFolder` (**SachinDevBotsLog**), `InpLogDecisions` (**true**).
- `InpShowDashboard` (**true**).

## Running your own tests (not done as part of this delivery)

- **Backtest**: Strategy Tester, EURUSD, every-tick-based-on-real-ticks, variable spread,
  realistic costs, M5/M15/H1 as above. Compare `InpSignalModel` = TREND_ONLY, RANGE_ONLY, HYBRID,
  and the old v4.8 (from `Old Verson\`) as a baseline. Use chronological in-sample/out-of-sample
  splits, not the same period twice.
- **Forward test**: attach to a demo chart for 2-4 weeks, monitor the dashboard and both CSV
  files, and only then decide whether default thresholds need adjusting.
