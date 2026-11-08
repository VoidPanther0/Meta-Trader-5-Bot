# CLAUDE.md - Meta Trader 5 Bot workspace

## Version control rule for `Meta Trader 5 Bot\` (MANDATORY)
- The folder `Meta Trader 5 Bot\` holds ONLY the latest EA version (`SmartHedgeEA_vX.Y.mq5` + its `.ex5`).
- **Version numbering: `vX.Y`, no leading zero in the decimal part** - `v5.1`, `v5.2`, not `v5.01`/`v4.09`.
  (If a major series ever needs a 10th+ minor release, `v5.10` etc. is fine - the point is never pad a
  single digit with a leading zero, which reads as a patch of a version that doesn't exist, e.g. `v5.01`
  misreads as "a patch of 5.0" instead of "the release after 5.00".) Fixed in v5.1 on 2026-11-05.
- Every older version lives in `Meta Trader 5 Bot\Old Verson\` (spelling is intentional - that is the folder name).
- **Before changing the EA, ALWAYS back up the current version into `Old Verson\` first.** Never edit the only copy.
- For every change, bump the version (file name, `#property version`, `EA_VERSION`, dashboard title) and move the previous
  file(s) into `Old Verson\`. Never overwrite or delete a backup.
- Files already sitting in `Old Verson\` (e.g. `v3.02`-`v3.09`'s two-digit minor numbers) are historical
  record of what was actually running at the time - do not rename or edit them to "fix" the numbering
  convention; the rule above only governs versions going forward.
- **README.md is the full changelog/spec** - keep its version-history section, inputs guide, and "New in
  vX.Y" section in sync with every version bump made here. This file (CLAUDE.md) stays the short
  operating-rules summary; put the actual detail (what changed, why, defaults) in README.md.

## EA rules
- DEMO accounts only. The demo-account guard in `OnInit` must never be removed, weakened or bypassed.
- Basket engine (v3.05+): 10-20 same-direction positions open, trail, close and reverse as ONE unit. All $ exit values are per 0.01 lot and scale with basket volume.
- Lot starts at 0.01 and may grow up to a 0.50 per-position hard cap, but ONLY after winning baskets; any losing basket resets lot and basket size to the minimum. Never increase size after a loss (no martingale). The user explicitly lifted the old 0.01 cap on 2026-11-03.
- Single symbol per EA instance (`_Symbol`); one chart per symbol.
- Emergency stop must never trigger an opposite position and must block all entries.
- The EA must stay portable to other testers' machines: no hard-coded paths/account numbers/broker
  names; demo-mode detection stays generic (`ACCOUNT_TRADE_MODE`); the user plans to hand this out to
  2-3 other people to demo-test, not run it only on this laptop.
- Logging: ONE CSV file per run by default (`InpLogDecisions = false`). The per-evaluation decision CSV
  is opt-in only, for debugging "why didn't it trade" - don't flip that default back to `true`.
- `InpRequireCandleConfirm` defaults to `false` as of v5.2 (user's explicit ask after a first live run sat
  out for hours with H1/M15/M5 already aligned). MODE A's H1+M15+M5 trend-agreement requirement is
  unchanged and still the main entry gate.
- `InpMinSignalScore` defaults to `70.0` as of v5.4 (was 80.0). **Do not reweight the 8 scoring
  components to hit a target score for a specific example** - a v5.4 request asked for weights
  recalibrated so plain H1+M15+M5 alignment alone would score 82-88 regardless of RSI/ADX strength;
  declined, since that makes direction agreement nearly sufficient by itself and conflicts with "no
  code change can force a specific win rate." If a score feels too strict, the threshold input is the
  right lever, not the weights - confirmed as the user's own preference when asked directly.
- **`InpMaxBasketRiskUSD` defaults to `30.00` as of v5.5 (was `5.00` since v5.00 - this was THE
  dominant bug all day).** The default basket (`InpBasketMax=5` x `InpFixedLotSize=0.01` @
  `InpProtectiveStopPoints=500`) computes to ~$25 of tail/gap risk, so the old 5.00 default made
  every basket illegal under default settings regardless of signal score - confirmed live via
  `MQL5\Logs\`: a 75.3-scored signal (above threshold) was rejected on "basket risk 25.00 exceeds
  InpMaxBasketRiskUSD 5.00". **Whenever `InpBasketMax`, `InpFixedLotSize`, or
  `InpProtectiveStopPoints` change, sanity-check that `InpMaxBasketRiskUSD` still comfortably
  covers `ComputeBasketRiskUSD()` for the new defaults** - this class of bug (a risk cap lower than
  the thing it's supposed to gate) is silent in testing because the rejection reason looks like a
  normal risk-engine decline, not a config error, and only shows up by actually reading
  `MQL5\Logs\` for an accepted-score-but-rejected-by-risk-engine line.
- `LogDecisionRow`'s Experts-tab `[DECISION]` print is throttled (de-dupe + 30s heartbeat, slot 25
  in `ThrottleOk`) as of v5.5 - `EvaluateEntry()` runs every tick, so an unthrottled print spammed
  hundreds of identical lines per minute (confirmed: 937 in under 6 minutes). Keep this throttle if
  touching that function again; the CSV decision log itself is unthrottled (every row, by design).
- Dashboard: keep text at a FIXED readable size (9pt body / 11pt title as of v5.1) on every machine -
  never shrink font/row-height to make the panel "fit"; only the panel width may adapt a little to the
  chart. An earlier v5.1 draft auto-shrank text to fit small chart windows and the user reported it
  became unreadable - don't repeat that.
- **`OnInit` must always force `g_state = STATE_INITIALIZING`** (right after the demo guard, as of v5.3).
  MQL5 does NOT reset global variables on a "soft" reinit - chart symbol/period change, input change, or
  a MetaEditor recompile hot-reloading an already-attached EA - only a true remove+reattach does. Without
  this, `g_state` carries over stale and `OnInit`'s unconditional transition into `STATE_START_DELAY` can
  be illegal per the state table, failing safe into terminal `STATE_ERROR` (confirmed from `MQL5\Logs\`:
  fired 16x in one session, every time the user switched the chart's timeframe or a recompile hot-reloaded
  the EA). Keep this reset whenever OnInit is touched - it's easy to lose in a future refactor since
  nothing about it looks special at a glance.

## Build / verify
- Compile with MetaEditor: `D:\MetaTrader 5\MetaEditor64.exe /compile:"<file.mq5>" /log:"<log>"` (log is UTF-16).
- Only report a compile as successful after a real compile and reading its `Result: N errors, N warnings` line.
- Do not claim test results that were not actually run. Do not start a second MT5 terminal on the user's running data folder.

## Where the logs are
- Trade CSVs (written by the EA): `C:\Users\This PC\Desktop\Meta Trader 5 Bot\` (junction from `MQL5\Files\SachinDevBotsLog`).
- **The EA's own `[INFO]`/`[WARNING]`/`[ERROR]` Print() output** (the Experts tab): `C:\Users\This PC\AppData\Roaming\MetaQuotes\Terminal\8B052D0699A0083067EBF3A36123603B\MQL5\Logs\YYYYMMDD.log`
  (UTF-16) - note the `MQL5\Logs\` in the path. This is the one to read when debugging what the EA itself
  did/decided.
- **Terminal/Journal log** (connections, broker fills, EA attach/remove events - NOT the EA's own Print()
  output): `C:\Users\This PC\AppData\Roaming\MetaQuotes\Terminal\8B052D0699A0083067EBF3A36123603B\logs\YYYYMMDD.log`
  (UTF-16, no `MQL5\`). These are two different files that are easy to conflate - confirmed the hard way
  while diagnosing the v5.3 state-reset bug (the first one checked, `logs\`, had no `[ERROR]` lines at
  all even though the dashboard showed one).
- The EA's `[INFO]` lines only appear in the Experts log when `InpLogAlsoToExpertsTab = true`; errors always print.
- Server time is about 3h45m behind this PC's local time.
