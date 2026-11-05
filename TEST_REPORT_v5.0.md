# Test Report — Smart Reversal EA v5.0

This report states exactly what was verified and what was not. Nothing here is a profitability
claim; per `CLAUDE.md` and the master spec, no test result is reported unless it was actually run.

## Compilation — VERIFIED

Compiled with MetaEditor:
```
D:\MetaTrader 5\MetaEditor64.exe /compile:"SmartHedgeEA_v5.00.mq5" /log:"_build\compile_v5.log"
```
Log result (read directly, not assumed):
```
Result: 0 errors, 0 warnings, 4175 ms elapsed, cpu='X64 Regular'
```
This was the result of the **first** compile attempt — no iteration was needed. `SmartHedgeEA_v5.00.ex5`
(184,470 bytes) was produced in the main project folder.

## Static / logic verification — VERIFIED (by re-reading the code, not by execution)

- Demo-only guard is still the first check in `OnInit`, before any other side effect, and has no
  bypass input (unchanged from v4.8).
- Emergency stop is still enforced centrally in `TransitionTo`/`HandleEmergency` — no state from
  which an order could be sent is reachable while it's active; `RouteAfterClose` always routes an
  `CLOSE_REASON_EMERGENCY` basket to `STATE_EMERGENCY_HALTED`, never to a reversal.
  `HandleEmergency` never opens a position; it only ever calls `ExecuteClose`.
  `TransitionTo` refuses to enter any entry-capable state while emergency is active unless no
  position is open, in which case it redirects to `STATE_EMERGENCY_HALTED` instead of blocking the
  transition outright.
- A reversal cannot fire before the original basket is confirmed completely flat: `RouteAfterClose`
  (which sets `STATE_REVERSAL_PENDING`) is only ever called from `OnBasketClosed`, which is only
  ever called from `OnPositionAbsent` — i.e. only once `ScanManagedFull` has returned zero managed
  positions and the closing deal history has been read. This is the same mechanism v4.8 used; it
  was not changed.
- Division-by-zero guards checked in every new function that divides: `ComputeBasketRiskUSD`
  (`tickSize`/`tickValue`/`price` all checked > 0 first), `EquityDrawdownOk`/`MarginUsageOk`
  (equity/peakEquity checked > 0 first), `ComputeSignalScore`'s ATR-ratio and pullback-ratio terms
  (all denominators checked > 0 first), `EstimateBasketVolume` (lot checked > 0 first).
- All 9 indicator handles (`maFastHandleM5/M15/H1`, `maSlowHandleM5/M15/H1`, `atrHandle`,
  `rsiHandle`, `adxHandle`) are validated in `OnInit` and released in `OnDeinit`.
- Fixed basket sizing/lot: `CurrentLot()` and `CurrentBasketSize()` contain no reference to any
  win/loss history — confirmed by reading both functions, which are each one line.
- `InpMaxBasketVolume` default 0.05 with `InpBasketMax` 5 and `InpFixedLotSize` 0.01 → 5 × 0.01 =
  0.05, matching the spec exactly; `ExecuteOpen` additionally shrinks `n` to
  `floor(InpMaxBasketVolume/lot)`, so the cap holds even if those inputs are changed inconsistently.

## What was NOT run, and why

- **No backtest was run** (Strategy Tester, single-pass or optimization). Running it from this
  session would mean either scripting the terminal's tester via a `.ini`/command line against
  this PC's live configuration, or driving the MetaTrader GUI — both carry a real risk of
  colliding with the user's already-configured terminal/data folder, which `CLAUDE.md` explicitly
  says not to risk ("do not start a second MT5 terminal on the user's running data folder"). This
  was a deliberate decision to not run it rather than an oversight.
- **No 2-4 week demo forward test was run.** That requires real elapsed time on a live demo
  account and is the user's to run and observe, not something this session can fabricate or
  compress.
- **No win rate, profit factor, drawdown, or expectancy numbers are reported** for this version,
  because none of the above were run. Any such number right now would be invented, which both
  `CLAUDE.md` and the master spec explicitly prohibit.
- **The real trade-log CSV supplied by the user**
  (`SmartReversalEA_EURUSD_20261103_20261104_165744.csv`, 3002 rows) is v4.8 output, not v5.0 — it
  was read and used to confirm the EA's existing internal "SmartReversalEA" identity and CSV
  schema (informing the v5 CSV design), not as a performance baseline for v5.0, since v5.0's
  signal engine is entirely different from what produced those rows.

## Master-spec section 16 checklist — reported honestly

| Item | Status |
|---|---|
| Original v4.8 source preserved | **Yes** — untouched copy in `Old Verson\SmartHedgeEA_v4.8.mq5`/`.ex5` |
| Demo-only protection intact | **Yes** — verified by re-reading `OnInit`, unchanged guard, no bypass input |
| No automatic lot growth remains enabled | **Yes** — the growth code path was deleted, not disabled |
| Basket volume cannot exceed 0.05 lots by default | **Yes** — `InpMaxBasketVolume=0.05`, enforced in `ExecuteOpen` |
| Random basket sizing removed | **Yes** — `RandomBasketBaseline`/`g_basketBaseline` deleted |
| Signal engine uses real closed-candle data | **Yes** — verified by re-reading `UpdateSignal`/`GetClosedCandles`, all reads use shift ≥ 1 |
| Risk management cannot be bypassed by reversal logic | **Yes** — reversal re-runs `EvaluateEntry`, which includes every risk-engine gate |
| Completed basket statistics use actual net results | **Yes** — `OnBasketClosed` computes `outcome` from the deal-history net sum, independent of the close-trigger name |
| Clean compilation (0/0) | **Yes** — see above, actually run |
| Backtest campaign (trend/range/hybrid, v4.8 baseline) | **Not run** — see above |
| 2-4 week demo forward test | **Not run** — see above |

## Recommended next step for the user

1. Attach v5.0 to a demo chart, confirm it initializes (watch the Experts log for "EA initialized
   successfully" and the dashboard's SYSTEM section).
2. Let it run through at least a handful of complete basket cycles and read the decision log —
   confirm MODE A/B/C selection and rejection reasons look sane for the actual market conditions at
   the time.
3. Only then consider a longer unattended forward test.
