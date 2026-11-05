# SmartHedgeEA v4.8 - Smart Reversal Basket EA (MetaTrader 5)

> **DEMO ACCOUNTS ONLY.** The EA refuses to start on a live or contest account, and that check must never be removed.
> This is an experiment, not a money machine. **No profit is promised.** Test on demo only.

## What it does (simple)
1. Reads an EMA trend (fast EMA 10 vs slow EMA 30) on **closed candles only** (default timeframe **M5** = calmer) - the original v3.07 algorithm, unchanged.
2. **RSI confirmation (new in v4.0):** on top of the EMA signal, a BUY only fires if RSI(14) on the last closed bar is `>= 50`, a SELL only if it's `<= 50` (`InpUseRSIConfirm`). This is an extra agreement gate, not a second signal - the EMA cross/trend itself, and whether a cross stays valid until used, is unchanged.
3. **Entry confirmation:** once a signal (and RSI) agree, the EA waits `InpEntryConfirmSeconds` (default 4s) and re-checks the direction still holds before actually opening the basket.
4. **Reversal confirmation (new in v4.0):** after a loss, instead of reversing instantly, the EA first checks whether the EMA trend has already flipped back away from the reversal direction - if so the reversal is **cancelled** (waits for a fresh signal instead of chasing). Otherwise it holds for `InpReversalConfirmSeconds` (default 4s) before actually opening the reversal basket. This targets the EA's known weakness of repeated losses in a choppy/sideways market.
5. Opens a **basket** of same-direction positions in the signal direction. Basket size starts from a **randomized 5-10 baseline** (was 10-20) each time it resets (see point 7), then grows with wins.
6. Watches the **whole basket's** profit/loss as one number, re-tuned in v4.0 to trail up and lock in on a pullback across a wider band:
   - **Loss of -0.10 per 0.01 lot** -> closes the whole basket and **reverses** to the opposite direction (subject to the reversal confirmation above). Unchanged.
   - Trailing now **arms as soon as profit reaches +0.05 per 0.01 lot** (was +0.15) and **closes at once at +1.00** (was +0.30, the previous hard cap). Once armed, it closes if profit falls 0.05 back from its peak - so a modest move followed by even a small pullback usually banks a small win (0.05-0.30), while a strong move is still allowed to run all the way to the 1.00 cap before being forced closed.
   - All `$` values are **per 0.01 lot** and scale with the basket's total volume (e.g. a 5-position basket reverses around -0.50, a 10-position basket around -1.00).
7. Basket size and lot grow **only after winning baskets** (+1 position per win, +0.01 lot per 3 wins in a row, cap 0.50). Any losing basket resets the lot to the minimum and re-rolls the basket-size baseline to a new random value in `[InpBasketMin, InpBasketMax]` (5-10) - no martingale (the re-roll is random, never a reaction to the loss).
8. Optional anti-chase filter (`InpUsePullbackFilter`, off by default): wait for a small pullback before a trend entry.

**On win rate:** nothing here can force a fixed win rate (e.g. 80/20). That outcome depends on how the real market actually moves after each entry, not on an EA setting - no code change can guarantee it. What v4.0 changes, and why it should plausibly bank more frequent (but smaller) wins: trailing now **arms at just +0.05 per 0.01 lot** instead of +0.15, so a basket only needs a small favorable move before a pullback locks something in - most wins should land in the $0.05-$0.30 range. The hard ceiling was also raised to +1.00 (was +0.30) so a strong move is still allowed to run further before being forced closed, rather than being capped early. The loss threshold is unchanged at -0.10, so the risk per basket is the same as before - only how profit is taken changed. Whether the net result is better has to be measured on demo, not assumed.

All `$` values are **per 0.01 lot** and scale with the basket's total volume, so a 5-position basket reverses at about -0.50 total and a 10-position basket at about -1.00 - the same price move (about 1 pip).

## Features (full list)

**Signal / entry**
- EMA crossover (fast 10 / slow 30 by default, both configurable) on **closed candles only** - the forming candle is never read.
- `CROSS_OR_TREND` mode: a fresh cross always wins; otherwise enters with the current closed-bar trend instead of waiting (configurable timeframe, M5 default).
- RSI(14) confirmation gate on top of the EMA signal (`InpUseRSIConfirm`) - BUY needs RSI >= 50, SELL needs RSI <= 50.
- Optional anti-chase pullback filter (`InpUsePullbackFilter`): waits for price to pull back near the fast EMA, with a bounded max-wait timeout.
- Entry confirmation hold (`InpEntryConfirmSeconds`): a signal must keep pointing the same direction for a few seconds before it's acted on.
- Reversal confirmation hold (`InpReversalConfirmSeconds`): after a loss, cancels the reversal if the trend already flipped back instead of chasing it, otherwise holds before firing.

**Basket engine**
- Opens 5-10 (configurable) same-direction positions as **one basket**, trailed, closed and reversed together as a single unit.
- Basket size resets to a **random** baseline in `[InpBasketMin, InpBasketMax]` after every loss (never a reaction to the loss itself).
- Lot and basket size grow **only after winning baskets** - anti-martingale, size/lot never increase after a loss.
- Per-position lot hard cap (0.50) and a total-basket-volume ceiling (`InpMaxTotalLots`), both enforced regardless of input values.

**Exits**
- Loss threshold (`InpLossThresholdUSD`, default -0.10 per 0.01 lot) closes the basket and triggers a reversal.
- Profit trailing: arms early (`InpProfitMinUSD`), trails the peak, closes on a pullback (`InpTrailGivebackUSD`) or at a hard ceiling (`InpProfitTargetUSD`) - all **per 0.01 lot**, scaling automatically with basket volume.
- Broker-side protective stop-loss on every position (a wide backstop in case the monitoring loop misses a tick - not a guaranteed money limit).

**Risk protections**
- Demo-account-only guard in `OnInit` (refuses to run on live/contest accounts).
- Daily realized-loss limit (`InpDailyLossLimitEnabled`/`InpDailyLossLimitUSD`) - blocks new entries, never force-closes an open basket.
- Max-consecutive-reversal cap (`InpMaxConsecutiveReversals`) - halts new entries once hit, until the next trading day.
- Emergency stop (`InpEmergencyStop`) - closes the open basket and **never** opens the opposite one; blocks every new entry while active.
- Spread guard (`InpMaxSpreadPoints`), execution retry limit, and a minimum-seconds-between-requests throttle.

**Reliability / safety engineering**
- Reconciles against the real broker positions after every trade event - detects manual closes, partial closes, stray/duplicate positions.
- Single-instance lock per account + symbol + magic number (refuses to run twice on the same one).
- Full input validation on startup; fails safe into an `ERROR` state on any illegal condition instead of guessing.
- Netting-account foreign-position conflict detection.

**Reporting**
- On-chart dashboard (solid panel, display-only - background fix restored in v4.7): state, live basket, floating P/L and peak, exit levels, **basket-level, THIS-SESSION-ONLY** (restored in v4.8) total trades / wins+profit$ / losses+loss$ / net / win rate, daily/emergency status, last action or error - see the Dashboard section below.
- Trade CSV log (one row per closed position, with basket number, prices, times, commission/swap/fee, closing reason, retcode).
- Experts-tab log of every `[INFO]`/`[WARNING]`/`[ERROR]` event, including why every basket closed.
- Lifetime stats (both basket-level and position-level) persist across restarts and are rebuilt from broker deal history on first run.

## Install (5 steps)
1. In MT5: **File -> Open Data Folder -> MQL5 -> Experts**, and copy `SmartHedgeEA_v4.8.mq5` there.
2. Open **MetaEditor** (press `F4`), open the file, press **`F7`** to compile. You should see `0 errors, 0 warnings`.
3. Open a **demo** account chart (e.g. **EURUSD**).
4. Drag **SmartHedgeEA_v4.8** from the Navigator onto the chart (remove the old instance first - replacing the file on disk does not hot-reload an EA that's already running on a chart). On the **Common** tab tick **Allow Algo Trading**. Check the **Inputs** tab, then OK.
5. Make sure the **Algo Trading** button in the top toolbar is green.

## Main inputs (defaults)
| Input | Default | Meaning |
|---|---|---|
| `InpSignalTimeframe` | M5 | EMA signals are computed on this timeframe (M1 = faster, noisier) |
| `InpEntryMode` | CROSS_OR_TREND | Enter on a fresh cross, otherwise with the current trend (fast start) |
| `InpUsePullbackFilter` | false | Trend entries wait for a pullback near the fast EMA |
| `InpMaxPullbackWaitMin` | 75 | With the filter on: enter anyway after this many minutes (~15 M5 candles) |
| `InpUseRSIConfirm` | true | Extra agreement gate: BUY needs RSI >= `InpRSIBuyMin`, SELL needs RSI <= `InpRSISellMax` |
| `InpRSIPeriod` / `InpRSIBuyMin` / `InpRSISellMax` | 14 / 50 / 50 | RSI period and the agreement thresholds above |
| `InpLossThresholdUSD` | 0.10 | Reverse the basket at this loss **per 0.01 lot** (unchanged) |
| `InpProfitMinUSD` | 0.05 | Profit trailing arms here (per 0.01 lot) - low, so small pullbacks bank small wins |
| `InpProfitTargetUSD` | 1.00 | Basket closes at once here (per 0.01 lot) - the max a strong move is allowed to reach |
| `InpTrailGivebackUSD` | 0.05 | Close if profit falls this far below its peak |
| `InpBasketMin` / `InpBasketMax` | 5 / 10 | Range for the randomized reset baseline; basket then grows +1 per winning basket, capped at Max |
| `InpEntryConfirmSeconds` | 4 | Signal must hold this many seconds (3-5s typical) before a basket is actually opened |
| `InpReversalConfirmSeconds` | 4 | After a loss, hold this many seconds (and require the trend still agrees) before firing the reversal - cancelled instead if the trend already flipped back |
| `InpFixedLotSize` | 0.01 | Base lot per position |
| `InpMaxLotSize` | 0.50 | Per-position lot ceiling (also capped at 0.50 in code) |
| `InpMaxTotalLots` | 5.00 | Ceiling on total basket volume |
| `InpGrowthEnabled` / `InpWinsPerStep` / `InpLotStep` | true / 3 / 0.01 | +0.01 lot after every 3 winning baskets in a row |
| `InpDailyLossLimitUSD` | 5.00 | Realized daily loss that stops new entries (closed trades only) |
| `InpEmergencyStop` | false | `true` = close everything, never reverse, never trade again until changed |
| `InpMagicNumber` | 20261103 | Must be unique per EA instance / symbol |

Even calmer test: set `InpLossThresholdUSD` 0.40, `InpProfitMinUSD` 0.40, `InpProfitTargetUSD` 0.80, `InpBasketMin/Max` 3 / 5.

## What the real demo logs showed (EURUSD, M5, 2026-11-03/04, v3.07, TIME-BASED mode)
49 completed baskets (505 closed positions) from the CSV log:
- **12 wins, 37 losses** (24.5% win rate). Average winning basket **+3.93**, average losing basket **-1.26**. Total net **+0.66** over the session - essentially break-even, with most of the gain concentrated in a few large wins.
- Basket size showed as "always 10" in almost every basket because growth resets to `InpBasketMin` (10) after every loss, and 3 out of 4 baskets lost - this is what v3.08's randomized 10-20 reset baseline addresses (varied basket size on reset, not loss-driven).
- The loss/profit asymmetry (many small losses, occasional large wins) matches the original 6-basket sample below; a win rate near 25% with a ~1:3 payoff is close to break-even before spread/commission, so there is little margin for error - this is still an experiment, not a proven edge.

## Earlier sample (EURUSD, M1, one evening, pre-v3.05)
Six baskets with the default exits (-0.10 / +1.00):
- **1 win, 5 losses.** The win was +1.00 per 0.01 lot (10 pips, held ~7 minutes). The losses averaged **-0.10 per 0.01 lot (about -1.1 pips, ~2.7 minutes)**.
- With a 1 : 10 payoff the strategy only needs roughly **10-11% of baskets to win** to break even (before spread). The sample's 1 in 6 is above that, but **6 baskets is far too few to conclude anything**.
- Winners need a ~10-pip move; most baskets are stopped out by a ~1-pip adverse move, which is normal M1 noise. Expect many small losses and occasional large wins.

## Safety built in
- Demo-only guard, input validation, hard lot ceiling, basket and margin caps.
- Daily realized-loss limit and a reversal-count limit (halts new entries until the next day).
- Emergency stop that closes the basket and **never** opens the opposite one.
- Broker-side protective stop on every position (a wide backstop, **not** a guaranteed money limit).
- It reconciles with the real broker positions after every trade event, detects manual closes, partial closes and duplicates, and refuses to run twice for the same account + symbol + magic.
- One chart = one symbol. For more symbols attach one EA per chart with a different magic number.

## Dashboard (top-left of the chart, display-only)
Running time, state, basket (direction x positions x lot), floating P/L and peak, exit levels, and the headline numbers - **total trades, winning trades + total profit $, losing trades + total loss $, net P/L and win rate** - plus daily/emergency status and the last action or error. These headline numbers are **BASKET-level** (one basket = one trade, not one per position, since v4.1) and, **as of v4.8, THIS SESSION ONLY again** - they reset to zero on every restart/attach, exactly like the "Running" time next to them, so the dashboard never looks "stuck" showing old numbers after a restart. (v4.6 had reverted to v4.1's lifetime-totals behavior and v4.7 didn't restore this part; v4.8 re-applied the original v4.3 fix.) Lifetime totals (across every restart) are unchanged under the hood and are written in full to the Experts log on `OnDeinit`, plus the CSV has every individual position. The panel background is a solid, fully opaque color (v4.2's fix, lost in v4.6, restored in v4.7).

## Logs
- **Trade CSV:** `MQL5\Files\SachinDevBotsLog\SmartReversalEA_<symbol>_<magic>_<date>.csv` - one row per closed position with `BasketNo`, entry/exit price and time, commission, swap, net P/L, closing reason, close deal ticket, execution retcode.
- **Experts tab / log:** all `[INFO] [WARNING] [ERROR]` lines (keep `InpLogAlsoToExpertsTab` on). Every basket close now logs *why* it closed.

## Honest limitations
- Trend-following with reversals can **lose repeatedly in a sideways market**.
- **No backtest has been completed yet.** The only results so far are a few hours of live demo trading, which is **not** proof the bot is profitable. Run the Strategy Tester yourself (see below) and share the report.
- If the loss limit is smaller than the spread cost, baskets reverse immediately (the EA warns about this at start).
- `ERROR` state is deliberate: it stops trading and waits for you. An emergency stop cannot close positions while in `ERROR`.

## Fixed/changed in v4.8
- **Re-applied the v4.3 this-session-only dashboard fix**, which v4.6 had lost by reverting to v4.1 (v4.7 only restored the background fix, not this one). New non-persisted session counters (`g_sessionBasketWins`/`g_sessionBasketLosses`/`g_sessionBasketRealizedProfit`/`g_sessionBasketRealizedLoss`/`g_sessionTrades`) always start at zero on a fresh attach, exactly like "Running" does, and now drive the dashboard again - so right after a restart it no longer shows totals from days of prior trading next to a running time of a few seconds. Lifetime totals are unchanged under the hood and still logged in full on `OnDeinit`. Nothing else changed from v4.7 - `InpBasketMax` (10) and `InpMaxLotSize` (0.50) stay as v4.6 set them.

## Fixed/changed in v4.7
- **Re-applied the v4.2 dashboard background fix**, which v4.6 had lost by reverting to v4.1. `CreateRect()`/`CreateLabel()` now reapply their background/border/color properties on every call instead of only the first time an object is created, and `CreateDashboard()` wipes any leftover `SRE_DASH_*` objects from an older session first; the panel is a fully opaque solid near-black with a brighter border again. Nothing else changed - `InpBasketMax` (10), `InpMaxLotSize` (0.50), and the dashboard still showing lifetime (not this-session) totals all stay exactly as v4.6 left them; only the background rendering was fixed.

## Fixed/changed in v4.6
- **Explicit request to revert to v4.1's parameters/behavior**, with no specific evidence identified for the reason (no particular session/screenshot with a verifiable "54%" figure could be pinned down - a general feeling, not a data-backed change like v4.2-v4.5 were). This REINTRODUCES, on purpose:
  - `InpMaxLotSize` back to **0.50** (was tightened to 0.03 in v4.5 after a live basket at lot 0.04 lost -5.96, by itself worse than that session's entire net result).
  - `InpBasketMax` back to **10** (was tightened to 12 in v4.4 after a live basket at 13 positions/lot 0.02 lost -5.10 against a -2.60 nominal risk).
  - The dashboard showing **lifetime** totals again instead of this-session-only (v4.3's fix, reported directly by the user as confusing, is not present here).
  - Possible dashboard background staleness on some setups (v4.2's fix is not present here either).
- If large-lot or large-basket losses, or dashboard confusion, recur: the fix is to re-apply the v4.2-v4.5 changes described below on top of this version.

## Fixed/changed in v4.5
- **`InpMaxLotSize` 0.50 -> 0.03** (per request, data-driven): same root cause as v4.4, this time via LOT instead of basket size - a live session showed a basket at lot 0.04 (grown from a long win streak) lose -5.96, by itself worse than the session's entire net result. Lot and basket size both grow from the same win streak, so the biggest lot is always active right before the loss that resets it. With `InpWinsPerStep`=3 / `InpLotStep`=0.01 unchanged, lot now steps 0.01 -> 0.02 -> 0.03 and stays capped there regardless of how long the win streak runs, bounding the worst-case loss size.

## Fixed/changed in v4.4
- **`InpBasketMax` 20 -> 12** (per request, data-driven): a live session showed one basket (13 positions, lot already grown to 0.02 from a win streak) lose -5.10 against a nominal -2.60 risk - about 68% of that session's total loss came from this single basket. Basket size and lot grow from the same win streak, so the largest basket+lot combination (and the worst execution-drag exposure during a fast sequential multi-position close) always lands right before the loss that resets it. Shrinking the max basket size reduces that worst case. `InpBasketMin` stays 5, so the reset baseline is now random 5-12 (was 5-20).

## Fixed/changed in v4.3
- **Dashboard headline numbers are now THIS-SESSION-ONLY, not lifetime.** The "Running" time has always reset to zero on every restart/attach, but `TOTAL TRADES`/`WINNING`/`LOSING`/`NET` were lifetime totals persisted across restarts - so right after a fresh attach, "Running: 00h 00m 37s" sat next to numbers from days of prior trading, which looked like stale/old data. New non-persisted `g_sessionBasketWins`/`g_sessionBasketLosses`/`g_sessionBasketRealizedProfit`/`g_sessionBasketRealizedLoss`/`g_sessionTrades` always start at zero on a fresh attach and now drive the dashboard. Lifetime totals are unchanged and still persisted/logged in full on `OnDeinit` (Experts log) for history - nothing is lost, only what the dashboard highlights changed.

## Fixed/changed in v4.2
- **`InpBasketMax` 10 -> 20** (per request): a basket may grow up to 20 positions again; `InpBasketMin` stays 5, so the reset baseline is random 5-20.
- **Dashboard now also shows the raw total position count** next to the basket count (`TOTAL TRADES: N baskets (M positions)`).
- **Fixed a dashboard transparency/stale-style bug:** `CreateRect()`/`CreateLabel()` only applied their background/border/color properties the FIRST time an object was created; a same-named panel object left over from an earlier EA session (the terminal does not always clean these up when an EA is removed/replaced) kept its OLD properties forever after, which could make a newer version's panel look wrong (e.g. see-through) even though the code specified a solid color. `CreateDashboard()` now wipes any leftover `SRE_DASH_*` objects first and all properties are reapplied unconditionally every time; the panel is a fully opaque solid near-black with a brighter border.

## Fixed/changed in v4.1
- **Dashboard/stats are now BASKET-level, not position-level.** A 10-position losing basket used to show as "10 losing trades" even though it was one decision - this made the win/loss counts look far worse than actual performance (e.g. a real session showed 946 winning vs 1936 losing *positions*, 32.8% "win rate", while the same session was 28 winning vs 11 losing *baskets*, ~72% win rate, net positive). New `g_basketWins`/`g_basketLosses`/`g_basketRealizedProfit`/`g_basketRealizedLoss` (persisted) drive the dashboard; the old position-level totals are unchanged and still logged (`OnDeinit`, CSV) for detail. No change to entry/exit/signal logic - reporting accuracy only. Basket-level stats start counting from when v4.1 first runs (cannot be reconstructed retroactively from older deal history).

## Fixed/changed in v4.0
- **Basket reset range shrunk from random 10-20 to random 5-10** (`InpBasketMin`/`InpBasketMax`). Same growth/reset mechanics, smaller baskets.
- **Profit band widened and re-tuned to trail up / lock in on a pullback**: trailing now arms at +0.05 per 0.01 lot (was +0.15) and the hard close-at-once ceiling is now +1.00 (was +0.30); giveback stays 0.05. `InpLossThresholdUSD` is unchanged at -0.10. This banks small wins ($0.05-$0.30) most of the time on a quick pullback, while still letting a strong move run up to the $1.00 cap.
- **New RSI momentum filter** (`InpUseRSIConfirm`, default on): an extra agreement gate on top of the unchanged EMA cross/trend signal - a BUY only fires if RSI(14) >= 50, a SELL only if RSI <= 50, on the last closed bar.
- **New reversal re-confirmation** (`InpReversalConfirmSeconds`, default 4s): after a loss, the reversal is cancelled instead of fired if the EMA trend has already flipped back away from it, and otherwise held (like the entry confirmation) before opening - aims to reduce the whipsaw losses the "Honest limitations" section below has always flagged for choppy/sideways markets.
- **Dashboard rebuilt** with dedicated rows for total trades, winning trades + profit $, losing trades + loss $, net P/L and win rate (the daily realized-P/L-vs-limit line and the streak/baseline/spread line were folded into fewer rows to make room).

## Fixed/changed in v3.09 (superseded by v4.0 above - kept for history)
- QUICK mode and the dashboard mode button (v3.08) were removed completely, per request. Back to a single signal path: the original v3.07 EMA cross/trend algorithm, unchanged.
- New entry-confirmation hold (`InpEntryConfirmSeconds`, default 4s): once a signal (cross or trend) appears, the EA waits this long and requires the signal still point the same direction before actually opening the basket.
- Exits recalibrated to a 1:3 risk:reward (was ~1:10) - **re-tuned again in v4.0 above**.

## Fixed/changed in v3.08 (superseded by v3.09 above - kept for history)
- Randomized basket-size reset baseline 10-20 (kept in v3.09).
- Added a QUICK trading mode and a dashboard mode-switch button - both **removed in v3.09**.

## Fixed/changed in v3.07
- **GV_PREFIX bumped** (`SRE3_` -> `SRE37_`): any stale `DAILY_HALTED` / reversal-cap flag left over from earlier testing on a demo account is dropped instead of silently carrying over (lifetime trade stats are unaffected - they are always rebuilt from broker deal history, not from the global variables).
- **Default signal timeframe is now M5** (was M1); `InpMaxPullbackWaitMin` default scaled from 15 to 75 minutes to keep the same ~15-candle wait.
- Minor dead-code cleanup (a couple of write-only tracking variables that were never read).

## Fixed in v3.06
- **Fake "PROFIT" close when the basket shrinks.** If some positions of a basket disappeared (stop-out or manual close), the trailing peak stayed in old dollars and the remaining positions were closed at once for a tiny profit. The peak is now tracked per 0.01 lot.
- Dashboard run-time display fixed; every close now writes its reason to the Experts log.

## How to backtest it yourself (2 minutes)
1. In MT5 press `Ctrl+R` (Strategy Tester). Expert: **SmartHedgeEA_v4.8**, Symbol **EURUSD**, Period **M5**.
2. Model: **Every tick based on real ticks** (or *1 minute OHLC* for a quick run). Dates: pick 2-3 months. Deposit 2000 USD, leverage 1:500.
3. Click **Start**. Check the Results / Backtest tabs and the CSV the EA wrote.
4. Compare with `InpSignalTimeframe = M1` on the **same dates** to see the difference calmer signals make.

## Helping improve it
Run it on demo for a few hours, then send the **trade CSV**, the **Experts log** and a **screenshot** to whoever maintains it.
`PROMPT_FOR_CLAUDE.md` is a ready-made prompt that lets Claude read those logs, fix the bot, compile and backtest it.

## Files
- `SmartHedgeEA_v4.8.mq5` - the EA source (the latest version).
- `Old Verson\` - every older version (v3.02 to v4.7) kept as backups.
- `PROMPT_FOR_CLAUDE.md` - universal "test and fix my bot" prompt.
