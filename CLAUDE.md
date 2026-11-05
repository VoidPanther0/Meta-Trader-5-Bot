# CLAUDE.md - Meta Trader 5 Bot workspace

## Version control rule for `Meta Trader 5 Bot\` (MANDATORY)
- The folder `Meta Trader 5 Bot\` holds ONLY the latest EA version (`SmartHedgeEA_vX.YY.mq5` + its `.ex5`).
- Every older version lives in `Meta Trader 5 Bot\Old Verson\` (spelling is intentional - that is the folder name).
- **Before changing the EA, ALWAYS back up the current version into `Old Verson\` first.** Never edit the only copy.
- For every change, bump the version (file name, `#property version`, `EA_VERSION`, dashboard title) and move the previous
  file(s) into `Old Verson\`. Never overwrite or delete a backup.

## EA rules
- DEMO accounts only. The demo-account guard in `OnInit` must never be removed, weakened or bypassed.
- Basket engine (v3.05+): 10-20 same-direction positions open, trail, close and reverse as ONE unit. All $ exit values are per 0.01 lot and scale with basket volume.
- Lot starts at 0.01 and may grow up to a 0.50 per-position hard cap, but ONLY after winning baskets; any losing basket resets lot and basket size to the minimum. Never increase size after a loss (no martingale). The user explicitly lifted the old 0.01 cap on 2026-11-03.
- Single symbol per EA instance (`_Symbol`); one chart per symbol.
- Emergency stop must never trigger an opposite position and must block all entries.

## Build / verify
- Compile with MetaEditor: `D:\MetaTrader 5\MetaEditor64.exe /compile:"<file.mq5>" /log:"<log>"` (log is UTF-16).
- Only report a compile as successful after a real compile and reading its `Result: N errors, N warnings` line.
- Do not claim test results that were not actually run. Do not start a second MT5 terminal on the user's running data folder.

## Where the logs are
- Trade CSVs (written by the EA): `C:\Users\This PC\Desktop\Meta Trader 5 Bot\` (junction from `MQL5\Files\SachinDevBotsLog`).
- Terminal/Experts log: `C:\Users\This PC\AppData\Roaming\MetaQuotes\Terminal\8B052D0699A0083067EBF3A36123603B\logs\YYYYMMDD.log` (UTF-16).
- The EA's `[INFO]` lines only appear in the Experts log when `InpLogAlsoToExpertsTab = true`; errors always print.
- Server time is about 3h45m behind this PC's local time.
