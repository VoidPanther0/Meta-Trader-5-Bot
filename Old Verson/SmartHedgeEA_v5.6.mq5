//+------------------------------------------------------------------+
//|                                           SmartHedgeEA_v5.6.mq5  |
//|                   Smart Reversal EA v5.6 - state-driven BASKET   |
//|                   engine with a dual market-regime signal core:  |
//|                   TREND CONTINUATION + RANGE MEAN REVERSION +    |
//|                   NO-TRADE, weighted 0-100 scoring, an           |
//|                   independent risk engine, and an adaptive       |
//|                   profit manager. N same-direction positions are |
//|                   opened, trailed, closed and reversed together  |
//|                   as ONE unit.                                   |
//|                                                                  |
//|  DEMO ACCOUNTS ONLY.  One chart symbol per EA instance - this EA  |
//|  is NOT multi-symbol. To trade several symbols attach one EA      |
//|  instance (with its own magic number) to one chart per symbol.   |
//|                                                                  |
//|  v5.00 (this version) - upgrade from v4.8. Preserves v4.8's       |
//|  proven core UNCHANGED: state machine + transition table,         |
//|  symbol+magic position scanning reconciled against deal          |
//|  history, retcode-aware execution that never trusts a boolean     |
//|  return, GlobalVariable persistence with a force-reset daily      |
//|  halt on init, instance lock, demo-only guard enforced first in   |
//|  OnInit with no side effects before it.                           |
//|                                                                  |
//|  REPLACED / ADDED in v5.00:                                       |
//|  - Signal engine: v4.8's single EMA(10/30) cross/trend signal is  |
//|    replaced by a genuine dual-regime engine - MODE A (trend       |
//|    continuation: H1+M15+M5 trend agreement, pullback, candle      |
//|    confirm, ADX strength) and MODE B (range mean reversion:       |
//|    swing-based S/R zones, RSI extremes, rejection candles,        |
//|    reward:risk space) - picked by a regime classifier (ADX vs     |
//|    two thresholds, cross-checked against multi-TF trend           |
//|    agreement). Anything that doesn't qualify is MODE C: NO-TRADE, |
//|    a deliberate, logged decision.                                 |
//|  - Weighted 0-100 signal score (8 components) gates every entry   |
//|    AND every reversal - the reversal path now calls the exact     |
//|    same EvaluateEntry() used for a fresh entry instead of only    |
//|    checking the EMA trend hasn't flipped, so a reversal requires  |
//|    a genuinely re-confirmed opposite setup, not just "not yet      |
//|    cancelled".                                                    |
//|  - Independent risk engine: per-basket $ and %-equity risk caps   |
//|    (from tick value/size and the real stop distance), account     |
//|    equity-drawdown guard, daily floating-drawdown guard, margin-   |
//|    usage guard - all additional pre-entry gates, same philosophy   |
//|    as v4.8's existing daily realized-loss limit (block NEW         |
//|    entries/reversals, never force-close an open basket).          |
//|  - Basket growth and random basket sizing are REMOVED (not just    |
//|    disabled): fixed InpBasketMax positions of fixed                |
//|    InpFixedLotSize every time, hard-capped at InpMaxBasketVolume   |
//|    lots total. No automatic lot increase exists in this version.  |
//|  - Adaptive profit manager: break-even protection, optional        |
//|    ATR-based trailing distance, maximum holding duration, optional |
//|    partial close - layered on top of v4.8's proven peak-tracking   |
//|    trail (which is already basket-shrink-safe).                   |
//|  - Versioned CSV (v5 schema, new file) + a separate decision log   |
//|    recording every accepted AND rejected signal evaluation with    |
//|    its full score breakdown.                                      |
//|  - Dashboard rebuilt with SYSTEM / MARKET / TRADING / PERFORMANCE / |
//|    EXECUTION sections.                                             |
//|                                                                    |
//|  v5.1 - cosmetic/usability fixes on top of v5.00, no signal/risk/   |
//|  execution logic changed:                                          |
//|  - Dashboard size (width/row height/font) is now computed at        |
//|    runtime from the chart's actual pixel size, so it fits fully on  |
//|    any monitor/chart window instead of only the one it was tuned    |
//|    on; long text (last rejection reason, last action/error) wraps   |
//|    onto a 2nd line instead of being cut off mid-word.                |
//|  - InpLogDecisions now defaults to false, so a fresh run writes a   |
//|    SINGLE CSV (the trade log); the per-evaluation decision CSV is   |
//|    still available by turning that input back on.                  |
//|  - Version string fixed to "5.1" (previously briefly "5.01").       |
//|                                                                    |
//|  v5.2 - one behavior change: InpRequireCandleConfirm now defaults   |
//|  to false. With H1+M15+M5 trend agreement already mandatory in      |
//|  MODE A, this extra "last closed candle must also close with the    |
//|  trend" gate could leave a fresh attach sitting out MODE A for      |
//|  hours waiting for one specific candle. Turn it back on (Inputs     |
//|  tab) for stricter/slower entries.                                  |
//|                                                                    |
//|  v5.3 - REAL BUG FIX (confirmed from today's MQL5\Logs, fired 16x): |
//|  g_state is a global variable, and MQL5 does NOT reset globals on   |
//|  a "soft" reinit - OnDeinit/OnInit triggered by a chart symbol/     |
//|  period change, an input change, or a recompile hot-reloading an    |
//|  already-attached EA (only a true remove+reattach resets globals).  |
//|  OnInit unconditionally transitioned into STATE_START_DELAY without |
//|  first resetting g_state, so if the EA happened to still be in      |
//|  WAITING_INITIAL_SIGNAL (or worse, ERROR) from before the reinit,   |
//|  that transition was ILLEGAL per the state table and failed safe    |
//|  into STATE_ERROR - which is terminal, so the EA then needed a      |
//|  manual remove+reattach to recover. Switching chart timeframe on    |
//|  the SAME chart the EA is attached to has always triggered this     |
//|  kind of reinit in MT5; it now sets g_state = STATE_INITIALIZING as |
//|  the first thing OnInit does (after the demo-account guard), so     |
//|  every reinit - soft or cold - starts the state machine cleanly.    |
//|                                                                    |
//|  v5.4 - InpMinSignalScore default lowered 80.0 -> 70.0. A review    |
//|  request asked to recalibrate the 8 component weights so a plain   |
//|  H1+M15+M5 alignment alone would score 82-88 regardless of RSI/ADX  |
//|  strength - declined: that would make direction agreement nearly   |
//|  sufficient by itself, defeating the point of a momentum/strength-  |
//|  aware score (and the "no code change can force a specific win     |
//|  rate" rule below). The scoring FORMULA is unchanged; only the bar |
//|  moved, via the input that already exists for exactly this. Also   |
//|  checked and found NOT bugs: CurrentSpreadPoints() (correct, a      |
//|  0.0pt reading can be real on a liquid pair), Daily P/L vs SESSION  |
//|  vs Account DD (intentionally different scopes - SESSION resets on  |
//|  attach, Daily P/L persists across restarts so the daily-loss halt  |
//|  can't be bypassed by restarting, DD is peak-to-current equity),    |
//|  and "stale score" (UpdateSignal/DetectRegime already re-run every  |
//|  tick - nothing to force-refresh).                                 |
//|                                                                    |
//|  v5.5 - REAL BUG FIX, the dominant one all day: InpMaxBasketRiskUSD |
//|  default (5.00) was LESS than the risk of even one position at the |
//|  default protective stop, so the DEFAULT basket (5 x 0.01 lot @     |
//|  500-point stop = ~$25 worst-case/gap risk) could never legally     |
//|  open under default settings - confirmed live in MQL5\Logs: a       |
//|  signal that scored 75.3 (above InpMinSignalScore) was rejected     |
//|  with "basket risk 25.00 exceeds InpMaxBasketRiskUSD 5.00". Raised  |
//|  default to 30.00 (headroom over the ~$25 baseline). This is a      |
//|  TAIL/gap-risk ceiling only - normal-operation loss-cut is still    |
//|  governed by the much tighter InpLossThresholdUSD, unchanged.       |
//|  Also: LogDecisionRow's Experts-tab print now de-duplicates and     |
//|  throttles to a 30s heartbeat instead of printing on every tick     |
//|  (937 near-identical lines in under 6 minutes, confirmed live) -    |
//|  CSV decision-log content/schema unchanged.                         |
//|                                                                    |
//|  v5.6 - cosmetic only: the MARKET section's "Last rejection" line   |
//|  now also refreshes when regime goes ambiguous/NONE (MODE C) - it   |
//|  previously only updated inside EvaluateEntry(), so it could keep   |
//|  showing a stale MODE A/B reason from before the regime changed,    |
//|  even though EXECUTION's "Last" line was already showing the        |
//|  current MODE C status. No trading logic changed.                   |
//|                                                                    |
//|  IMPORTANT: no code change can force a specific win rate or        |
//|  guarantee profit. That depends on real market behavior, not a     |
//|  setting. Weights and thresholds below are initial research        |
//|  values, not statistically proven optimal values.                  |
//+------------------------------------------------------------------+
#property copyright "Sachin Dev Bots"
#property version   "5.6"
#property strict
#property description "DEMO-ONLY Smart Reversal EA v5.6 - dual regime (trend+range) basket engine. One chart symbol per EA instance."

#include <Trade\Trade.mqh>

#define EA_VERSION            "5.6"
#define HARD_MAX_LOT          0.50       // absolute per-position lot ceiling, enforced in code regardless of inputs
#define REF_LOT               0.01       // all $ thresholds are defined PER this volume and scale with the basket volume
#define MAX_BASKET_HARD        50        // absolute ceiling on positions in one basket
#define GV_PREFIX             "SRE50_"   // v5.00: bumped from SRE37_ so stale flags from older versions never carry over
#define LOCK_STALE_SEC         15        // a duplicate-instance heartbeat older than this is considered dead
#define FINALIZE_WAIT_SEC      10        // how long to wait for close deals to show up in history
#define HISTORY_LOOKBACK_SEC   (60*86400)// look-back used to associate manual/SL close deals with our positions
#define SWING_FRACTAL_K        2         // bars each side a swing high/low must beat to count

//================================= INPUTS ====================================
enum ENUM_SIGNAL_MODEL
{
   SIGNAL_MODEL_TREND_ONLY = 0,   // only MODE A (trend continuation) may trade; range regime = no-trade
   SIGNAL_MODEL_RANGE_ONLY = 1,   // only MODE B (range mean reversion) may trade; trend regime = no-trade
   SIGNAL_MODEL_HYBRID     = 2    // MODE A in a trend regime, MODE B in a range regime (default)
};

enum ENUM_MARKET_REGIME { REGIME_NONE = 0, REGIME_TREND = 1, REGIME_RANGE = 2 };

input group "=== Strategy Model ==="
input ENUM_SIGNAL_MODEL InpSignalModel = SIGNAL_MODEL_HYBRID;

input group "=== Multi-Timeframe Trend (EMA fast/slow on each timeframe, closed candles only) ==="
input ENUM_TIMEFRAMES InpEntryTimeframe   = PERIOD_M5;   // entry / MODE A-B evaluation timeframe
input ENUM_TIMEFRAMES InpConfirmTimeframe = PERIOD_M15;  // confirmation timeframe
input ENUM_TIMEFRAMES InpTrendTimeframe   = PERIOD_H1;   // higher timeframe trend
input int    InpFastMA            = 10;
input int    InpSlowMA            = 30;
input ENUM_MA_METHOD InpMAMethod  = MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== Regime Classifier (ADX Market Regime Detection) ==="
input int    InpADXPeriod       = 14;
input double InpADXTrendMin     = 22.0;  // ADX >= this AND multi-TF trend agreement -> MODE A (trend) eligible
input double InpADXRangeMax     = 18.0;  // ADX <= this -> MODE B (range) eligible. Between the two thresholds = ambiguous -> no-trade.

input group "=== ATR Volatility Intelligence ==="
input int    InpATRPeriod            = 14;
input int    InpATRNormalLookback    = 50;   // bars averaged to define "normal" ATR
input double InpATRMinRatio          = 0.4;  // reject as abnormally quiet if ATR < this x the rolling average
input double InpATRMaxRatio          = 3.0;  // reject as abnormally volatile if ATR > this x the rolling average

input group "=== Advanced RSI Momentum Filter ==="
input int    InpRSIPeriod       = 14;
input double InpRSIBuyMin       = 50.0;   // MODE A: BUY requires RSI >= this on the entry timeframe
input double InpRSISellMax      = 50.0;   // MODE A: SELL requires RSI <= this
input double InpRSIOversold     = 30.0;   // MODE B: BUY near support requires RSI <= this
input double InpRSIOverbought   = 70.0;   // MODE B: SELL near resistance requires RSI >= this

input group "=== MODE A: Trend Continuation - Pullback / Anti-Chase ==="
input bool   InpUsePullbackFilter    = true;  // require price to have pulled back near the fast EMA before entering (anti-chase)
input double InpMaxChaseATR          = 1.0;   // max distance, in ATRs, that the last close may be beyond the fast EMA in the trade direction
input bool   InpRequireCandleConfirm = false; // the last closed candle must close in the trade direction (or a recognized
                                               // bullish/bearish pattern). OFF by default as of v5.2: with H1+M15+M5 trend
                                               // agreement already required, this extra gate could sit MODE A out for hours
                                               // waiting for one specific candle. Turn back on for stricter/slower entries.
input int    InpMaxPullbackWaitMin   = 75;    // enter anyway after waiting this many minutes for a pullback (0 = wait forever)

input group "=== MODE B: Range Mean Reversion ==="
input int    InpSwingLookback        = 50;    // closed bars scanned for swing highs/lows
input double InpZoneClusterATR       = 0.5;   // swing points within this many ATRs of each other are one S/R zone
input double InpRangeZoneATR         = 0.6;   // price must be within this many ATRs of a zone to be "at the boundary"
input double InpMinRewardRiskRatio   = 1.5;   // space to the opposite boundary must be >= this x space to the near boundary

input group "=== Weighted Signal Scoring (initial research weights, not proven optimal; normalized to 0-100) ==="
input double InpWeightH1       = 20.0;
input double InpWeightM15      = 15.0;
input double InpWeightM5       = 15.0;
input double InpWeightRSI      = 10.0;
input double InpWeightADX      = 10.0;
input double InpWeightATR      = 10.0;
input double InpWeightCandle   = 10.0;
input double InpWeightPullback = 10.0;
input double InpMinSignalScore = 70.0;   // a basket is never opened/reversed below this normalized 0-100 score
                                          // (lowered from 80.0 in v5.4 - the scoring formula itself is
                                          // unchanged; 80 was rejecting directionally-aligned trend setups
                                          // whose momentum/ADX were merely moderate rather than extreme.
                                          // This does not guarantee any particular win rate - raise it back
                                          // toward 80 for a stricter/slower filter, lower it further for more
                                          // frequent, lower-conviction entries.)

input group "=== Basket Exits: wide trail, small-wins-most-of-the-time (every $ value is PER 0.01 LOT, scaled by the basket's total volume; all $ amounts are in ACCOUNT CURRENCY) ==="
input double InpLossThresholdUSD    = 0.10;  // reverse the WHOLE basket when its floating net loss reaches -(this x volume/0.01)
input double InpProfitMinUSD        = 0.05;  // profit trailing arms once basket profit reaches +(this x volume/0.01)
input double InpProfitTargetUSD     = 1.00;  // basket closes at once at +(this x volume/0.01) (the maximum)
input double InpTrailGivebackUSD    = 0.05;  // once armed, close if profit falls this far below its peak (never below the minimum)
input int    InpMaxConsecutiveReversals = 2; // no further reversal once this many CONFIRMED reversals happened in a row

input group "=== Adaptive Profit Manager (additions on top of the trail above) ==="
input double InpBreakEvenTriggerUSD  = 0.20;  // once basket profit/REF_LOT reaches this, the floor will never close the basket below break-even (0.0 per unit)
input bool   InpUseATRTrailing       = true;  // trail distance = InpATRTrailMultiple x ATR (in $ per REF_LOT) instead of the fixed giveback once armed
input double InpATRTrailMultiple     = 1.5;
input int    InpMaxHoldingMinutes    = 240;   // close the basket regardless of P/L after this long (0 = no limit)
input bool   InpPartialCloseEnabled  = false; // close a fraction of the basket once an intermediate profit is reached, let the rest run
input double InpPartialCloseFraction = 0.5;   // fraction (0..1) of basket volume closed at the partial trigger
input double InpPartialCloseTriggerUSD = 0.30; // per-REF_LOT profit that arms the one-time partial close

input group "=== Basket Size & Lot (FIXED - no growth, no random sizing, no martingale) ==="
input int    InpBasketMax       = 5;     // fixed number of positions per basket (also the hard maximum)
input double InpFixedLotSize    = 0.01;  // fixed lot per position - never grows automatically
input double InpMaxLotSize      = 0.50;  // per-position lot ceiling (also capped at 0.50 in code)
input double InpMaxBasketVolume = 0.05;  // ceiling on basket volume (positions x lot); the basket is shrunk to fit. 5 x 0.01 = 0.05 by default.

input group "=== Independent Risk Engine (pre-entry gates only - never force-closes an open basket) ==="
input double InpMaxBasketRiskUSD      = 30.00; // reject a new basket if its computed stop-distance risk exceeds this (account currency)
                                                // (raised from 5.00 in v5.4 - the DEFAULT basket (InpBasketMax=5 x
                                                // InpFixedLotSize=0.01 = 0.05 lots) at the DEFAULT protective stop
                                                // (InpProtectiveStopPoints=500) computes to ~$25 of tail/gap risk,
                                                // so the old 5.00 cap made every basket illegal under default
                                                // settings - confirmed live: a qualifying 75.3-scored signal was
                                                // rejected with "basket risk 25.00 exceeds InpMaxBasketRiskUSD
                                                // 5.00". This is the WORST-CASE/gap risk ceiling (the 500-point
                                                // hard stop is a wide backstop, rarely hit) - it does NOT change
                                                // normal-operation behavior, which is still governed by the much
                                                // tighter InpLossThresholdUSD (reverses around -0.50 for this
                                                // basket size under normal conditions, not -25).
input double InpMaxBasketRiskPctEquity= 2.0;   // reject a new basket if its risk exceeds this % of current equity
input double InpMaxDailyFloatingDrawdownUSD = 20.00; // block new entries if (today's start-of-day equity - current equity) exceeds this while a basket floats
input double InpMaxAccountDrawdownPct = 20.0;  // block new entries if equity has fallen this % below its recorded peak
input double InpMaxMarginUsagePct     = 50.0;  // block new entries if margin/equity would exceed this %

input group "=== Broker-Side Protective Stop (hard backstop, NOT the $ trigger) ==="
input int    InpProtectiveStopPoints = 500; // wide point-distance SL floor in case the monitoring loop misses a tick (NOT a fixed-money loss guarantee)

input group "=== Daily Risk Protections ==="
input bool   InpDailyLossLimitEnabled = true;  // enabled by default in v5.0 per the controlled risk mode
input double InpDailyLossLimitUSD     = 5.00;  // REALIZED (closed-deal) loss only, floating P/L excluded. Blocks NEW entries/reversals - never force-closes the open basket
input int    InpMaxSpreadPoints       = 30;
input int    InpSlippagePoints        = 10;
input int    InpMaxExecutionRetries   = 3;
input int    InpMinSecondsBetweenRequests = 2;
input bool   InpEmergencyStop          = false; // true = close the whole basket (if any), NEVER reverse, and block every entry

input group "=== Session Filter (server time; see CLAUDE.md for this PC's server/local offset) ==="
input bool   InpUseSessionFilter = false;  // OFF by default - verify server-time hours for your broker before enabling
input int    InpSessionStartHour = 7;      // server-time hour, inclusive
input int    InpSessionEndHour   = 21;     // server-time hour, exclusive

input group "=== Optional Economic Calendar Filter (native MQL5 only, disabled by default) ==="
input bool   InpUseCalendarFilter   = false;  // if the Calendar API is unavailable/errors, this filter no-ops (never blocks everything by accident)
input int    InpCalendarBlockMinutesBefore = 15;
input int    InpCalendarBlockMinutesAfter  = 15;
input int    InpCalendarMinImportance = 2;    // 0=none,1=low,2=moderate,3=high (ECONOMIC_CALENDAR importance)

input group "=== Reversal Logic (re-evaluation, not blind reversal) ==="
input int    InpReversalCooldownSeconds = 10;  // must fully elapse after the original basket is confirmed flat before reversal re-evaluation even starts
input int    InpEntryConfirmSeconds     = 4;   // once a signal appears, wait this many seconds and require it still holds before opening
input int    InpReversalConfirmSeconds  = 4;   // after a loss, wait this many seconds and require the reversal setup still scores and holds

input group "=== Timing ==="
input int    InpStartDelaySeconds   = 3;
input int    InpPostProfitWaitSeconds = 3;
input int    InpOperationTimeoutSeconds = 30; // max wait for broker confirmation of an open/close before reconciling against real positions

input group "=== Misc ==="
input int    InpMagicNumber       = 20261103;
input string InpTradeComment      = "SmartReversalEA";

input group "=== Trade Logging (v5 schema + decision log) ==="
input bool   InpLogToCSV            = true;
input bool   InpLogCommonFolder     = false;
input bool   InpLogAlsoToExpertsTab = true;
input string InpLogSubFolder        = "SachinDevBotsLog";
input bool   InpLogDecisions        = false;  // also log every rejected/accepted evaluation to a SECOND CSV file
                                               // (off by default so the folder gets just one CSV; turn this on
                                               // only when you need per-tick entry-rejection detail for debugging)

input group "=== On-Chart Dashboard (display-only) ==="
input bool   InpShowDashboard = true;

//================================= ENUMS ====================================
enum ENUM_EA_STATE
{
   STATE_INITIALIZING = 0,
   STATE_START_DELAY,
   STATE_WAITING_INITIAL_SIGNAL,
   STATE_OPENING_POSITION,
   STATE_POSITION_ACTIVE,
   STATE_CLOSING_LOSS,
   STATE_CLOSING_PROFIT,
   STATE_CLOSING_EMERGENCY,
   STATE_REVERSAL_PENDING,
   STATE_COOLDOWN,
   STATE_DAILY_HALTED,
   STATE_EMERGENCY_HALTED,
   STATE_ERROR
};

enum ENUM_CLOSE_REASON
{
   CLOSE_REASON_NONE = 0,
   CLOSE_REASON_LOSS_REVERSAL,   // loss threshold hit, a reversal will follow
   CLOSE_REASON_PROFIT,          // profit target / trailing hit, no reversal
   CLOSE_REASON_EMERGENCY,       // emergency stop, NEVER followed by anything
   CLOSE_REASON_DAILY_LIMIT,     // loss threshold hit while the daily halt is active, no reversal
   CLOSE_REASON_MAX_REVERSALS,   // loss threshold hit at the reversal cap, no reversal
   CLOSE_REASON_MAX_HOLDING,     // held open longer than InpMaxHoldingMinutes, no reversal
   CLOSE_REASON_EXTERNAL         // closed by broker SL / manual / unknown - not initiated by the EA
};

enum ENUM_OPEN_INTENT { INTENT_NONE = 0, INTENT_INITIAL, INTENT_REVERSAL };

enum ENUM_REQ_RESULT
{
   REQ_DEFERRED = 0,   // pre-check failed, NOTHING was sent to the broker
   REQ_REJECTED,       // broker definitively rejected the request
   REQ_ACCEPTED,       // at least one order executed (DONE / DONE_PARTIAL)
   REQ_UNCERTAIN       // timeout / connection / processing error - outcome unknown, must reconcile
};

string StateToString(ENUM_EA_STATE s)
{
   switch(s)
   {
      case STATE_INITIALIZING:           return "INITIALIZING";
      case STATE_START_DELAY:            return "START_DELAY";
      case STATE_WAITING_INITIAL_SIGNAL: return "WAITING_INITIAL_SIGNAL";
      case STATE_OPENING_POSITION:       return "OPENING_POSITION";
      case STATE_POSITION_ACTIVE:        return "POSITION_ACTIVE";
      case STATE_CLOSING_LOSS:           return "CLOSING_LOSS";
      case STATE_CLOSING_PROFIT:         return "CLOSING_PROFIT";
      case STATE_CLOSING_EMERGENCY:      return "CLOSING_EMERGENCY";
      case STATE_REVERSAL_PENDING:       return "REVERSAL_PENDING";
      case STATE_COOLDOWN:               return "COOLDOWN";
      case STATE_DAILY_HALTED:           return "DAILY_HALTED";
      case STATE_EMERGENCY_HALTED:       return "EMERGENCY_HALTED";
      case STATE_ERROR:                  return "ERROR";
   }
   return "UNKNOWN";
}

string CloseReasonToString(ENUM_CLOSE_REASON r)
{
   switch(r)
   {
      case CLOSE_REASON_NONE:          return "NONE";
      case CLOSE_REASON_LOSS_REVERSAL: return "LOSS_REVERSAL";
      case CLOSE_REASON_PROFIT:        return "PROFIT";
      case CLOSE_REASON_EMERGENCY:     return "EMERGENCY";
      case CLOSE_REASON_DAILY_LIMIT:   return "DAILY_LIMIT";
      case CLOSE_REASON_MAX_REVERSALS: return "MAX_REVERSALS";
      case CLOSE_REASON_MAX_HOLDING:   return "MAX_HOLDING";
      case CLOSE_REASON_EXTERNAL:      return "EXTERNAL";
   }
   return "UNKNOWN";
}

string DirToString(int d) { return (d == 1) ? "BUY" : (d == -1) ? "SELL" : "NONE"; }
string RegimeToString(ENUM_MARKET_REGIME r) { return (r == REGIME_TREND) ? "TREND" : (r == REGIME_RANGE) ? "RANGE" : "NONE"; }

//================================= STRUCTS ====================================
struct PosSnap            // aggregate of ALL live broker positions that belong to this EA (symbol + magic)
{
   bool     valid;
   int      count;        // number of positions (1 on a netting account, however large the volume)
   int      dir;
   bool     mixed;        // true if BUY and SELL positions are both present (never expected)
   double   volume;       // total volume
   double   avgPrice;     // volume-weighted open price
   datetime firstTime;
};

struct DealRec            // one trading deal of this symbol
{
   ulong    ticket;
   ulong    posId;        // DEAL_POSITION_ID
   long     entry;
   datetime time;
   bool     magicOK;
   double   net;          // profit + swap + commission + fee of THIS deal only (never double counted)
};

struct TradeSummary       // one completed position, rebuilt from its deal history
{
   ulong    ident;
   int      dir;
   double   volume;
   double   entryPrice;
   double   exitPrice;
   datetime entryTime;
   datetime exitTime;
   double   profit;
   double   commission;
   double   swap;
   double   fee;
   ulong    closeDeal;
};

struct CandleInfo
{
   double   o, h, l, c;
   double   body, upperWick, lowerWick, range;
   datetime t;
};

struct ScoreBreakdown
{
   double h1, m15, m5, rsi, adx, atr, candle, pullback;   // each 0..its own weight
   double total;                                           // normalized 0..100
   string  mode;                                            // "TREND" / "RANGE"
   string  rejectReason;                                    // "" if accepted
   bool    accepted;
};

//================================= GLOBALS ====================================
CTrade trade;

int maFastHandleM5  = INVALID_HANDLE;
int maSlowHandleM5  = INVALID_HANDLE;
int maFastHandleM15 = INVALID_HANDLE;
int maSlowHandleM15 = INVALID_HANDLE;
int maFastHandleH1  = INVALID_HANDLE;
int maSlowHandleH1  = INVALID_HANDLE;
int atrHandle       = INVALID_HANDLE;
int rsiHandle        = INVALID_HANDLE;
int adxHandle        = INVALID_HANDLE;

ENUM_EA_STATE g_state      = STATE_INITIALIZING;
datetime      g_stateSince = 0;
string        g_lastAction = "EA starting";
string        g_lastError  = "";

bool          g_isNetting     = false;
string        g_marginModeStr = "UNKNOWN";
bool          g_lockOwned     = false;
bool          g_inUpdate      = false;

// ---- tracked basket (always re-verified against the broker by Reconcile()) ----
ulong    g_idents[];                 // POSITION_IDENTIFIER of every position that ever belonged to the current basket
double   g_identCost[];              // entry commission + fee per ident
bool     g_identCostOk[];
int      g_posDir        = 0;
double   g_posVolume     = 0.0;      // total live volume
int      g_posCount      = 0;
double   g_posAvgPrice   = 0.0;
datetime g_posEntryTime  = 0;
double   g_peakPerUnit   = -1e18;    // highest basket profit seen PER 0.01 LOT (drives the trail; stays valid if the basket shrinks)
double   g_troughPerUnit =  1e18;    // lowest basket profit seen PER 0.01 LOT (feeds MaxFloatingLoss in the CSV)
double   g_basketLot     = 0.0;
bool     g_partialDone   = false;    // the one-time partial close has already fired for this basket

// ---- basket context captured at open, used for the v5 CSV columns ----
datetime g_basketOpenTime      = 0;
double   g_basketSignalScore   = 0.0;
ENUM_MARKET_REGIME g_basketRegime = REGIME_NONE;
string   g_basketMode           = "";
int      g_basketH1Trend        = 0;
int      g_basketM15Trend       = 0;
int      g_basketM5Trend        = 0;
double   g_basketRSI            = 0.0;
double   g_basketADX            = 0.0;
double   g_basketATR            = 0.0;
double   g_basketSpreadEntry    = 0.0;
double   g_basketInitialRiskUSD = 0.0;
datetime g_closeRequestTimeExact = 0;   // set the instant ExecuteClose first sends a request for this basket

// ---- pending request intent ----
ENUM_CLOSE_REASON g_pendingCloseReason = CLOSE_REASON_NONE;
string   g_pendingCloseDetail = "";
uint     g_closeRetcode       = 0;
datetime g_closeRequestTime   = 0;
bool     g_closePartial       = false;

ENUM_OPEN_INTENT g_openIntent = INTENT_NONE;
int      g_openDir            = 0;
int      g_reversalDir        = 0;
datetime g_openRequestTime    = 0;
datetime g_signalUsedBackup   = 0;

int      g_retryCounter       = 0;
datetime g_nextRequestAllowed = 0;
datetime g_finalizeWaitSince  = 0;
bool     g_emergencyLatched   = false;

// ---- signal / indicator state (only ever fed by FULLY CLOSED candles) ----
datetime g_lastEvalBar          = 0;    // last closed entry-TF bar that was evaluated
datetime g_lastEntryBarConsumed = 0;    // entry-TF bar already consumed by an open (never reused)
datetime g_pendingConsumeBar    = 0;    // the exact bar a just-sent open was triggered on, consumed only once that open is CONFIRMED
int      g_m5TrendDir           = 0;
int      g_m15TrendDir          = 0;
int      g_h1TrendDir           = 0;
double   g_rsiLast               = 50.0;
double   g_adxLast               = 0.0;
double   g_atrLast               = 0.0;
double   g_atrAvgLast            = 0.0;
bool     g_indicatorsReady       = false;
ENUM_MARKET_REGIME g_regimeLast  = REGIME_NONE;
datetime g_pullbackWaitSince     = 0;
int      g_pullbackWaitDir       = 0;
datetime g_eaStartTime           = 0;   // for the dashboard run-time display

// ---- latest score snapshot (both directions), for the dashboard ----
double   g_lastScoreBuy  = 0.0;
double   g_lastScoreSell = 0.0;
string   g_lastRejectReason = "";
string   g_lastDecisionKey  = "";   // v5.4: last Experts-tab [DECISION] line printed, to de-duplicate spam

// ---- swing / S-R zone snapshot ----
double   g_nearestResistance = 0.0;   // 0 = none found
double   g_nearestSupport    = 0.0;   // 0 = none found

// ---- timing ----
datetime g_startDelayBegin = 0;
datetime g_cooldownEnd     = 0;
datetime g_reversalCooldownEnd = 0;

// ---- daily protection / reversal chain (persisted) ----
datetime g_currentDay        = 0;
double   g_dailyRealizedPL   = 0.0;
bool     g_dailyHaltFlag     = false;
bool     g_maxRevHalt        = false;
int      g_consecutiveReversals = 0;
int      g_basketNo          = 0;

// ---- risk-engine reference points (persisted across restarts) ----
double   g_dayStartEquity    = 0.0;
double   g_peakEquity        = 0.0;

// ---- entry / reversal confirmation holds (NOT persisted - short live re-checks) ----
int      g_entryCandidateDir   = 0;
datetime g_entryCandidateSince = 0;
int      g_revConfirmDir       = 0;
datetime g_revConfirmSince     = 0;

// ---- lifetime totals, POSITION-level: every individual position is one row (persisted) ----
int      g_totalTrades = 0;
int      g_totalWins   = 0;
int      g_totalLosses = 0;
double   g_totalRealizedProfit = 0.0;
double   g_totalRealizedLoss   = 0.0;
int      g_tradeNumberCounter  = 0;

// ---- lifetime totals, BASKET-level (persisted) ----
int      g_basketWins           = 0;
int      g_basketLosses         = 0;
double   g_basketRealizedProfit = 0.0;
double   g_basketRealizedLoss   = 0.0;

// ---- THIS-SESSION totals, BASKET + position level (deliberately NOT persisted) ----
int      g_sessionBasketWins           = 0;
int      g_sessionBasketLosses         = 0;
double   g_sessionBasketRealizedProfit = 0.0;
double   g_sessionBasketRealizedLoss   = 0.0;
int      g_sessionTrades               = 0;
int      g_sessionCurConsecWins        = 0;
int      g_sessionCurConsecLosses      = 0;
int      g_sessionMaxConsecWins        = 0;
int      g_sessionMaxConsecLosses      = 0;

// ---- TODAY totals, BASKET-level (resets on new broker day, not persisted across restart mid-day beyond what daily realized P/L already rebuilds) ----
int      g_todayBasketWins   = 0;
int      g_todayBasketLosses = 0;

// ---- execution instrumentation ----
double   g_lastOrderLatencyMs = 0.0;
uint     g_lastRetcode        = 0;
string   g_lastErrorDetail    = "";
string   g_lastOrderLabel     = "";

// ---- CSV loggers ----
int    gLogHandle   = INVALID_HANDLE;
string gLogFileName = "";
int    gDecisionLogHandle = INVALID_HANDLE;
string gDecisionLogFileName = "";

//================================= SMALL HELPERS ====================================
// Broker-server clock. TimeTradeServer() keeps advancing without ticks, TimeCurrent() does not.
datetime Now()
{
   datetime t = TimeTradeServer();
   if(t == 0) t = TimeCurrent();
   return t;
}

datetime DayStart(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

bool IsDemoAccount()
{
   return ((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO);
}

bool EmergencyActive() { return (InpEmergencyStop || g_emergencyLatched); }
bool BlockedByHalt()   { return (g_dailyHaltFlag || g_maxRevHalt); }

bool ThrottleOk(const int slot, const int seconds)
{
   static datetime last[32];
   datetime t = Now();
   if(t - last[slot] < seconds) return false;
   last[slot] = t;
   return true;
}

void LogInfo(string details)    { if(InpLogAlsoToExpertsTab) PrintFormat("[INFO] %s", details); }
void LogWarning(string details) { if(InpLogAlsoToExpertsTab) PrintFormat("[WARNING] %s", details); }
void LogError(string details, int retcode = 0)
{
   // Errors are never silenced, regardless of InpLogAlsoToExpertsTab.
   PrintFormat("[ERROR] retcode=%d | %s", retcode, details);
   g_lastError = details;
}

string GVKey(string suffix)
{
   return StringFormat("%s%I64d_%s_%d_%s", GV_PREFIX, AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagicNumber, suffix);
}

//================================= INPUT VALIDATION ====================================
bool InputError(string msg)
{
   Print("INPUT ERROR: ", msg);
   return false;
}

bool ValidateInputs()
{
   bool ok = true;
   if(InpFastMA < 1)                 ok = InputError(StringFormat("InpFastMA must be >= 1 (got %d)", InpFastMA));
   if(InpSlowMA <= InpFastMA)        ok = InputError(StringFormat("InpSlowMA (%d) must be greater than InpFastMA (%d)", InpSlowMA, InpFastMA));
   if(InpFixedLotSize <= 0.0)        ok = InputError(StringFormat("InpFixedLotSize must be > 0 (got %.4f)", InpFixedLotSize));
   if(InpMaxLotSize <= 0.0)          ok = InputError(StringFormat("InpMaxLotSize must be > 0 (got %.4f)", InpMaxLotSize));
   if(InpMaxLotSize > HARD_MAX_LOT + 1e-9)
                                     ok = InputError(StringFormat("InpMaxLotSize (%.4f) exceeds the hard safety ceiling of %.2f lots per position", InpMaxLotSize, HARD_MAX_LOT));
   if(InpFixedLotSize > InpMaxLotSize + 1e-9)
                                     ok = InputError(StringFormat("InpFixedLotSize (%.4f) must not exceed InpMaxLotSize (%.4f)", InpFixedLotSize, InpMaxLotSize));
   if(InpMaxBasketVolume < InpFixedLotSize - 1e-9)
                                     ok = InputError(StringFormat("InpMaxBasketVolume (%.2f) must be at least one position of InpFixedLotSize (%.4f)", InpMaxBasketVolume, InpFixedLotSize));
   if(InpBasketMax < 1)              ok = InputError(StringFormat("InpBasketMax must be >= 1 (got %d)", InpBasketMax));
   if(InpBasketMax > MAX_BASKET_HARD)ok = InputError(StringFormat("InpBasketMax (%d) exceeds the hard ceiling of %d positions", InpBasketMax, MAX_BASKET_HARD));
   if(InpATRPeriod < 1)              ok = InputError(StringFormat("InpATRPeriod must be >= 1 (got %d)", InpATRPeriod));
   if(InpADXPeriod < 1)              ok = InputError(StringFormat("InpADXPeriod must be >= 1 (got %d)", InpADXPeriod));
   if(InpADXRangeMax >= InpADXTrendMin)
                                     ok = InputError(StringFormat("InpADXRangeMax (%.1f) must be less than InpADXTrendMin (%.1f)", InpADXRangeMax, InpADXTrendMin));
   if(InpATRNormalLookback < 5)      ok = InputError(StringFormat("InpATRNormalLookback must be >= 5 (got %d)", InpATRNormalLookback));
   if(InpATRMinRatio <= 0.0 || InpATRMinRatio >= 1.0)
                                     ok = InputError(StringFormat("InpATRMinRatio must be within (0,1) (got %.2f)", InpATRMinRatio));
   if(InpATRMaxRatio <= 1.0)         ok = InputError(StringFormat("InpATRMaxRatio must be > 1 (got %.2f)", InpATRMaxRatio));
   if(InpMaxChaseATR <= 0.0)         ok = InputError(StringFormat("InpMaxChaseATR must be > 0 (got %.4f)", InpMaxChaseATR));
   if(InpMaxPullbackWaitMin < 0)     ok = InputError(StringFormat("InpMaxPullbackWaitMin must be >= 0 (got %d)", InpMaxPullbackWaitMin));
   if(InpSwingLookback < 10)         ok = InputError(StringFormat("InpSwingLookback must be >= 10 (got %d)", InpSwingLookback));
   if(InpZoneClusterATR <= 0.0)      ok = InputError(StringFormat("InpZoneClusterATR must be > 0 (got %.2f)", InpZoneClusterATR));
   if(InpRangeZoneATR <= 0.0)        ok = InputError(StringFormat("InpRangeZoneATR must be > 0 (got %.2f)", InpRangeZoneATR));
   if(InpMinRewardRiskRatio <= 0.0)  ok = InputError(StringFormat("InpMinRewardRiskRatio must be > 0 (got %.2f)", InpMinRewardRiskRatio));
   if(InpWeightH1 < 0 || InpWeightM15 < 0 || InpWeightM5 < 0 || InpWeightRSI < 0 || InpWeightADX < 0 || InpWeightATR < 0 || InpWeightCandle < 0 || InpWeightPullback < 0)
                                     ok = InputError("All InpWeight* inputs must be >= 0");
   if((InpWeightH1 + InpWeightM15 + InpWeightM5 + InpWeightRSI + InpWeightADX + InpWeightATR + InpWeightCandle + InpWeightPullback) <= 0.0)
                                     ok = InputError("The sum of all InpWeight* inputs must be > 0");
   if(InpMinSignalScore < 0.0 || InpMinSignalScore > 100.0)
                                     ok = InputError(StringFormat("InpMinSignalScore must be within 0..100 (got %.1f)", InpMinSignalScore));
   if(InpLossThresholdUSD <= 0.0)    ok = InputError(StringFormat("InpLossThresholdUSD must be > 0 (got %.4f)", InpLossThresholdUSD));
   if(InpProfitMinUSD <= 0.0)        ok = InputError(StringFormat("InpProfitMinUSD must be > 0 (got %.4f)", InpProfitMinUSD));
   if(InpProfitTargetUSD < InpProfitMinUSD)
                                     ok = InputError(StringFormat("InpProfitTargetUSD (%.4f) must be >= InpProfitMinUSD (%.4f)", InpProfitTargetUSD, InpProfitMinUSD));
   if(InpTrailGivebackUSD < 0.0)     ok = InputError(StringFormat("InpTrailGivebackUSD must be >= 0 (got %.4f)", InpTrailGivebackUSD));
   if(InpBreakEvenTriggerUSD < 0.0)  ok = InputError(StringFormat("InpBreakEvenTriggerUSD must be >= 0 (got %.4f)", InpBreakEvenTriggerUSD));
   if(InpATRTrailMultiple <= 0.0)    ok = InputError(StringFormat("InpATRTrailMultiple must be > 0 (got %.4f)", InpATRTrailMultiple));
   if(InpMaxHoldingMinutes < 0)      ok = InputError(StringFormat("InpMaxHoldingMinutes must be >= 0 (got %d)", InpMaxHoldingMinutes));
   if(InpPartialCloseFraction <= 0.0 || InpPartialCloseFraction >= 1.0)
                                     ok = InputError(StringFormat("InpPartialCloseFraction must be within (0,1) (got %.2f)", InpPartialCloseFraction));
   if(InpPartialCloseTriggerUSD <= 0.0)
                                     ok = InputError(StringFormat("InpPartialCloseTriggerUSD must be > 0 (got %.4f)", InpPartialCloseTriggerUSD));
   if(InpMaxBasketRiskUSD <= 0.0)    ok = InputError(StringFormat("InpMaxBasketRiskUSD must be > 0 (got %.4f)", InpMaxBasketRiskUSD));
   if(InpMaxBasketRiskPctEquity <= 0.0 || InpMaxBasketRiskPctEquity > 100.0)
                                     ok = InputError(StringFormat("InpMaxBasketRiskPctEquity must be within (0,100] (got %.2f)", InpMaxBasketRiskPctEquity));
   if(InpMaxDailyFloatingDrawdownUSD <= 0.0)
                                     ok = InputError(StringFormat("InpMaxDailyFloatingDrawdownUSD must be > 0 (got %.4f)", InpMaxDailyFloatingDrawdownUSD));
   if(InpMaxAccountDrawdownPct <= 0.0 || InpMaxAccountDrawdownPct > 100.0)
                                     ok = InputError(StringFormat("InpMaxAccountDrawdownPct must be within (0,100] (got %.2f)", InpMaxAccountDrawdownPct));
   if(InpMaxMarginUsagePct <= 0.0 || InpMaxMarginUsagePct > 100.0)
                                     ok = InputError(StringFormat("InpMaxMarginUsagePct must be within (0,100] (got %.2f)", InpMaxMarginUsagePct));
   if(InpDailyLossLimitEnabled && InpDailyLossLimitUSD <= 0.0)
                                     ok = InputError(StringFormat("InpDailyLossLimitUSD must be > 0 when the daily limit is enabled (got %.4f)", InpDailyLossLimitUSD));
   if(InpMaxConsecutiveReversals < 0 || InpMaxConsecutiveReversals > 1000)
                                     ok = InputError(StringFormat("InpMaxConsecutiveReversals must be within 0..1000 (got %d)", InpMaxConsecutiveReversals));
   if(InpProtectiveStopPoints <= 0)  ok = InputError(StringFormat("InpProtectiveStopPoints must be > 0 (got %d)", InpProtectiveStopPoints));
   if(InpMaxSpreadPoints <= 0)       ok = InputError(StringFormat("InpMaxSpreadPoints must be > 0 (got %d)", InpMaxSpreadPoints));
   if(InpSlippagePoints < 0)         ok = InputError(StringFormat("InpSlippagePoints must be >= 0 (got %d)", InpSlippagePoints));
   if(InpMaxExecutionRetries < 1 || InpMaxExecutionRetries > 10)
                                     ok = InputError(StringFormat("InpMaxExecutionRetries must be within 1..10 (got %d)", InpMaxExecutionRetries));
   if(InpMinSecondsBetweenRequests < 0 || InpMinSecondsBetweenRequests > 3600)
                                     ok = InputError(StringFormat("InpMinSecondsBetweenRequests must be within 0..3600 (got %d)", InpMinSecondsBetweenRequests));
   if(InpUseSessionFilter && (InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 24 || InpSessionEndHour <= InpSessionStartHour))
                                     ok = InputError("InpSessionStartHour/InpSessionEndHour must be a valid 0..24 server-time range with End > Start when the session filter is enabled");
   if(InpUseCalendarFilter && (InpCalendarBlockMinutesBefore < 0 || InpCalendarBlockMinutesAfter < 0))
                                     ok = InputError("InpCalendarBlockMinutesBefore/After must be >= 0");
   if(InpReversalCooldownSeconds < 0 || InpReversalCooldownSeconds > 3600)
                                     ok = InputError(StringFormat("InpReversalCooldownSeconds must be within 0..3600 (got %d)", InpReversalCooldownSeconds));
   if(InpStartDelaySeconds < 0)      ok = InputError(StringFormat("InpStartDelaySeconds must be >= 0 (got %d)", InpStartDelaySeconds));
   if(InpPostProfitWaitSeconds < 0)  ok = InputError(StringFormat("InpPostProfitWaitSeconds must be >= 0 (got %d)", InpPostProfitWaitSeconds));
   if(InpOperationTimeoutSeconds < 5)ok = InputError(StringFormat("InpOperationTimeoutSeconds must be >= 5 (got %d)", InpOperationTimeoutSeconds));
   if(InpEntryConfirmSeconds < 0 || InpEntryConfirmSeconds > 60)
                                     ok = InputError(StringFormat("InpEntryConfirmSeconds must be within 0..60 (got %d)", InpEntryConfirmSeconds));
   if(InpReversalConfirmSeconds < 0 || InpReversalConfirmSeconds > 60)
                                     ok = InputError(StringFormat("InpReversalConfirmSeconds must be within 0..60 (got %d)", InpReversalConfirmSeconds));
   if(InpRSIPeriod < 1)              ok = InputError(StringFormat("InpRSIPeriod must be >= 1 (got %d)", InpRSIPeriod));
   if(InpRSIBuyMin < 0.0 || InpRSIBuyMin > 100.0)
                                     ok = InputError(StringFormat("InpRSIBuyMin must be within 0..100 (got %.2f)", InpRSIBuyMin));
   if(InpRSISellMax < 0.0 || InpRSISellMax > 100.0)
                                     ok = InputError(StringFormat("InpRSISellMax must be within 0..100 (got %.2f)", InpRSISellMax));
   if(InpRSIOversold < 0.0 || InpRSIOversold > 100.0)
                                     ok = InputError(StringFormat("InpRSIOversold must be within 0..100 (got %.2f)", InpRSIOversold));
   if(InpRSIOverbought < 0.0 || InpRSIOverbought > 100.0)
                                     ok = InputError(StringFormat("InpRSIOverbought must be within 0..100 (got %.2f)", InpRSIOverbought));
   if(InpRSIOversold >= InpRSIOverbought)
                                     ok = InputError(StringFormat("InpRSIOversold (%.1f) must be less than InpRSIOverbought (%.1f)", InpRSIOversold, InpRSIOverbought));
   if(InpMagicNumber <= 0)           ok = InputError(StringFormat("InpMagicNumber must be > 0 - magic 0 is the manual-trade magic and would hijack manual positions (got %d)", InpMagicNumber));
   if(StringLen(InpTradeComment) > 31)
                                     ok = InputError("InpTradeComment must be at most 31 characters");
   if(InpCalendarMinImportance < 0 || InpCalendarMinImportance > 3)
                                     ok = InputError(StringFormat("InpCalendarMinImportance must be within 0..3 (got %d)", InpCalendarMinImportance));
   return ok;
}

//================================= SYMBOL / ACCOUNT CHECKS ====================================
double CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || _Point <= 0.0) return -1.0;
   return (ask - bid) / _Point;
}

bool SpreadOK()
{
   double sp = CurrentSpreadPoints();
   if(sp < 0.0) return false;
   return (sp <= (double)InpMaxSpreadPoints);
}

// Direction-aware: SYMBOL_TRADE_MODE can allow long-only / short-only / close-only / disabled.
bool DirectionAllowed(int direction)
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   switch((ENUM_SYMBOL_TRADE_MODE)mode)
   {
      case SYMBOL_TRADE_MODE_DISABLED:  return false;
      case SYMBOL_TRADE_MODE_CLOSEONLY: return false;
      case SYMBOL_TRADE_MODE_LONGONLY:  return (direction == 1);
      case SYMBOL_TRADE_MODE_SHORTONLY: return (direction == -1);
      case SYMBOL_TRADE_MODE_FULL:      return true;
   }
   return false;
}

bool TradingPermitted(string &why)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { why = "terminal AutoTrading is OFF";           return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { why = "EA trading is not allowed (Algo Trading)"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   { why = "trading is disabled for this account";  return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    { why = "expert trading is disabled for this account"; return false; }
   return true;
}

// On a netting account a foreign position on this symbol would silently merge with ours.
bool NettingForeignConflict()
{
   if(!g_isNetting) return false;
   if(PositionSelect(_Symbol))
      return (PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber);
   return false;
}

//+------------------------------------------------------------------+
//| Clamps a lot to the broker's [min,max,step] and to the hard cap.  |
//| Returns 0.0 (reject) instead of silently exceeding the cap when   |
//| the broker minimum alone is above it.                             |
//+------------------------------------------------------------------+
double ClampLot(double lots)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   if(minVol <= 0.0) minVol = step;

   double hardCap = MathMin(MathMin(InpMaxLotSize, HARD_MAX_LOT), maxVol > 0.0 ? maxVol : HARD_MAX_LOT);
   if(minVol > hardCap + 1e-12) return 0.0;

   double norm = MathRound(lots / step) * step;
   norm = MathMax(minVol, MathMin(hardCap, norm));

   int stepDigits = 0;
   double s = step;
   while(s < 0.999999 && stepDigits < 8) { s *= 10.0; stepDigits++; }
   norm = NormalizeDouble(norm, stepDigits);

   if(norm < minVol - 1e-12 || norm > hardCap + 1e-12) return 0.0;
   return norm;
}

double CalcBaseLot() { return ClampLot(InpFixedLotSize); }

// v5.00: FIXED lot, no growth, no martingale - always the same lot regardless of win/loss history.
double CurrentLot() { return ClampLot(InpFixedLotSize); }

// v5.00: FIXED basket size, no random baseline, no growth - always InpBasketMax (further shrunk to
// fit InpMaxBasketVolume / free margin exactly like v4.8 did for its streak-based size).
int CurrentBasketSize() { return InpBasketMax; }

//+------------------------------------------------------------------+
//| Broker-side protective stop. A wide point-distance BACKSTOP only  |
//| - it does NOT guarantee any fixed monetary loss (gaps, slippage,  |
//| tick value and spread all move the real loss). Returns 0.0 when a|
//| valid stop cannot be placed.                                     |
//|  BUY  : SL below the BID (the price a long is closed at)          |
//|  SELL : SL above the ASK (the price a short is closed at)         |
//+------------------------------------------------------------------+
double ComputeProtectiveStop(int direction, string &why)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || ask < bid) { why = "no valid quote"; return 0.0; }

   double pt = _Point;
   if(pt <= 0.0) { why = "invalid point size"; return 0.0; }

   int stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = pt;

   double spreadPts = (ask - bid) / pt;
   double minPts    = (double)MathMax(stopsLevel, freezeLevel) + spreadPts + 2.0;
   double dist      = MathMax((double)InpProtectiveStopPoints, minPts) * pt;

   double sl;
   if(direction == 1) sl = MathFloor((bid - dist) / tick + 1e-9) * tick;   // round AWAY from price
   else               sl = MathCeil ((ask + dist) / tick - 1e-9) * tick;
   sl = NormalizeDouble(sl, _Digits);

   if(sl <= 0.0) { why = "computed stop is not positive"; return 0.0; }
   if(direction == 1 && (bid - sl) < stopsLevel * pt - 1e-12) { why = "stop inside broker stop level"; return 0.0; }
   if(direction == -1 && (sl - ask) < stopsLevel * pt - 1e-12) { why = "stop inside broker stop level"; return 0.0; }
   return sl;
}

//+------------------------------------------------------------------+
//| Monetary risk of ONE basket of 'volume' lots stopped out at 'sl'. |
//| Uses the symbol's real tick size/value - the same math v4.8 used  |
//| for its spread-cost warning, just generalized to the real stop.   |
//+------------------------------------------------------------------+
double ComputeBasketRiskUSD(int direction, double volume, double sl)
{
   if(volume <= 0.0 || sl <= 0.0) return 0.0;
   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || price <= 0.0) return 0.0;
   double distance = (direction == 1) ? (price - sl) : (sl - price);
   if(distance <= 0.0) return 0.0;
   return (distance / tickSize) * tickValue * volume;
}

//================================= PERSISTENCE ====================================
void SavePersistentState()
{
   GlobalVariableSet(GVKey("Day"),       (double)g_currentDay);
   GlobalVariableSet(GVKey("DailyHalt"), g_dailyHaltFlag ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("DailyLimit"),InpDailyLossLimitUSD);
   GlobalVariableSet(GVKey("MaxRevHalt"),g_maxRevHalt ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("ConsecRev"), (double)g_consecutiveReversals);
   GlobalVariableSet(GVKey("BasketNo"),  (double)g_basketNo);
   GlobalVariableSet(GVKey("EntryBarUsed"),(double)g_lastEntryBarConsumed);
   GlobalVariableSet(GVKey("TradeNo"),   (double)g_tradeNumberCounter);
   GlobalVariableSet(GVKey("TotTrades"), (double)g_totalTrades);
   GlobalVariableSet(GVKey("TotWins"),   (double)g_totalWins);
   GlobalVariableSet(GVKey("TotLosses"), (double)g_totalLosses);
   GlobalVariableSet(GVKey("TotProfit"), g_totalRealizedProfit);
   GlobalVariableSet(GVKey("TotLoss"),   g_totalRealizedLoss);
   GlobalVariableSet(GVKey("BWins"),     (double)g_basketWins);
   GlobalVariableSet(GVKey("BLosses"),   (double)g_basketLosses);
   GlobalVariableSet(GVKey("BProfit"),   g_basketRealizedProfit);
   GlobalVariableSet(GVKey("BLoss"),     g_basketRealizedLoss);
   GlobalVariableSet(GVKey("DayStartEq"),g_dayStartEquity);
   GlobalVariableSet(GVKey("PeakEq"),    g_peakEquity);
}

//================================= DEAL HISTORY ====================================
// Loads every trading (BUY/SELL) deal of this symbol from 'from' until now.
bool LoadDeals(datetime from, DealRec &out[])
{
   ArrayResize(out, 0);
   if(!HistorySelect(from, Now() + 86400)) return false;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;

      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

      DealRec r;
      r.ticket  = tk;
      r.posId   = (ulong)HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      r.entry   = HistoryDealGetInteger(tk, DEAL_ENTRY);
      r.time    = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
      r.magicOK = (HistoryDealGetInteger(tk, DEAL_MAGIC) == (long)InpMagicNumber);
      r.net     = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
                + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);

      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = r;
   }
   return true;
}

// A position is "ours" if ANY of its deals carries our magic. Manual closes have magic 0,
// so matching on the position id (not the close deal's magic) is what keeps them attributed.
void BuildOurPositionIds(const DealRec &recs[], ulong &ids[])
{
   ArrayResize(ids, 0);
   int n = ArraySize(recs);
   for(int i = 0; i < n; i++)
   {
      if(!recs[i].magicOK) continue;
      bool seen = false;
      int m = ArraySize(ids);
      for(int j = 0; j < m; j++) if(ids[j] == recs[i].posId) { seen = true; break; }
      if(!seen) { ArrayResize(ids, m + 1); ids[m] = recs[i].posId; }
   }
}

int IndexOfId(const ulong &ids[], ulong id)
{
   int m = ArraySize(ids);
   for(int j = 0; j < m; j++) if(ids[j] == id) return j;
   return -1;
}

//+------------------------------------------------------------------+
//| Realized P/L of the given broker-server day for this symbol+magic.|
//| Every deal (entry AND exit) contributes its OWN profit, swap,     |
//| commission and fee exactly once. Floating P/L is NOT included.    |
//+------------------------------------------------------------------+
bool ComputeDailyRealizedPL(datetime dayStart, double &pl)
{
   DealRec recs[];
   if(!LoadDeals(dayStart - HISTORY_LOOKBACK_SEC, recs)) return false;
   ulong ours[];
   BuildOurPositionIds(recs, ours);

   datetime dayEnd = dayStart + 86400;
   pl = 0.0;
   int n = ArraySize(recs);
   for(int i = 0; i < n; i++)
   {
      if(recs[i].time < dayStart || recs[i].time >= dayEnd) continue;
      if(IndexOfId(ours, recs[i].posId) < 0) continue;
      pl += recs[i].net;
   }
   return true;
}

// Authoritative rebuild of today's realized P/L and the daily halt flag from deal history.
bool RebuildDailyState()
{
   double pl;
   if(ComputeDailyRealizedPL(g_currentDay, pl))
   {
      g_dailyRealizedPL = pl;
      // The halt is STICKY for the rest of the broker day: it can be set here but is only ever cleared by a new day.
      if(InpDailyLossLimitEnabled && pl <= -InpDailyLossLimitUSD + 1e-9) g_dailyHaltFlag = true;
      return true;
   }
   LogWarning("Daily P/L history rebuild failed (HistorySelect) - keeping last known values.");
   return false;
}

// First-ever run only: rebuild lifetime stats + trade numbering from account history, one entry per closed position.
void ReconstructLifetimeFromHistory()
{
   g_totalTrades = 0; g_totalWins = 0; g_totalLosses = 0;
   g_totalRealizedProfit = 0.0; g_totalRealizedLoss = 0.0; g_tradeNumberCounter = 0;

   DealRec recs[];
   if(!LoadDeals(0, recs)) { LogWarning("Lifetime history reconstruction failed (HistorySelect)."); return; }
   ulong ours[];
   BuildOurPositionIds(recs, ours);

   int m = ArraySize(ours);
   double nets[]; bool closed[];
   ArrayResize(nets, m); ArrayResize(closed, m);
   ArrayInitialize(nets, 0.0); ArrayInitialize(closed, false);

   int n = ArraySize(recs);
   for(int i = 0; i < n; i++)
   {
      int idx = IndexOfId(ours, recs[i].posId);
      if(idx < 0) continue;
      nets[idx] += recs[i].net;
      if(recs[i].entry != DEAL_ENTRY_IN) closed[idx] = true;
   }
   for(int k = 0; k < m; k++)
   {
      if(!closed[k]) continue;
      g_totalTrades++;
      g_tradeNumberCounter++;
      if(nets[k] >= 0.0) { g_totalWins++;   g_totalRealizedProfit += nets[k]; }
      else               { g_totalLosses++; g_totalRealizedLoss   += (-nets[k]); }
   }
}

void LoadPersistentState()
{
   g_currentDay = DayStart(Now());

   if(GlobalVariableCheck(GVKey("Day")))
   {
      datetime savedDay       = (datetime)(long)GlobalVariableGet(GVKey("Day"));
      g_maxRevHalt            = GlobalVariableGet(GVKey("MaxRevHalt")) > 0.5;
      g_consecutiveReversals  = (int)GlobalVariableGet(GVKey("ConsecRev"));
      g_basketNo              = (int)GlobalVariableGet(GVKey("BasketNo"));
      g_lastEntryBarConsumed  = (datetime)(long)GlobalVariableGet(GVKey("EntryBarUsed"));
      g_tradeNumberCounter    = (int)GlobalVariableGet(GVKey("TradeNo"));
      g_totalTrades           = (int)GlobalVariableGet(GVKey("TotTrades"));
      g_totalWins             = (int)GlobalVariableGet(GVKey("TotWins"));
      g_totalLosses           = (int)GlobalVariableGet(GVKey("TotLosses"));
      g_totalRealizedProfit   = GlobalVariableGet(GVKey("TotProfit"));
      g_totalRealizedLoss     = GlobalVariableGet(GVKey("TotLoss"));
      g_basketWins             = (int)GlobalVariableGet(GVKey("BWins"));
      g_basketLosses           = (int)GlobalVariableGet(GVKey("BLosses"));
      g_basketRealizedProfit   = GlobalVariableGet(GVKey("BProfit"));
      g_basketRealizedLoss     = GlobalVariableGet(GVKey("BLoss"));
      g_dayStartEquity         = GlobalVariableCheck(GVKey("DayStartEq")) ? GlobalVariableGet(GVKey("DayStartEq")) : AccountInfoDouble(ACCOUNT_EQUITY);
      g_peakEquity             = GlobalVariableCheck(GVKey("PeakEq"))     ? GlobalVariableGet(GVKey("PeakEq"))     : AccountInfoDouble(ACCOUNT_EQUITY);

      if(savedDay != g_currentDay)
      {
         // The trading day rolled while the EA was off: yesterday's max-reversal halt and chain no longer apply.
         g_maxRevHalt = false;
         g_consecutiveReversals = 0;
         g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         LogInfo("Trading day changed while the EA was offline - max-reversal halt and reversal chain reset; day-start equity re-anchored.");
      }
   }
   else
   {
      ReconstructLifetimeFromHistory();
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
      LogInfo(StringFormat("First run for this account/symbol/magic - lifetime stats rebuilt from history (%d closed trades).", g_totalTrades));
   }

   // Force-reset the daily halt flag on init: a fresh attach must never inherit a stale DAILY_HALTED state
   // from persisted globals or from old deal history.
   g_dailyHaltFlag = false;

   bool freshAttach = !GlobalVariableCheck(GVKey("Day"));

   if(freshAttach)
   {
      g_dailyRealizedPL = 0.0;
      g_dailyHaltFlag = false;
   }
   else
   {
      RebuildDailyState();
      g_dailyHaltFlag = false;
   }
   SavePersistentState();
}

void CheckNewDay()
{
   datetime today = DayStart(Now());
   if(today == g_currentDay) return;

   g_currentDay = today;
   g_maxRevHalt = false;
   g_dailyHaltFlag = false;
   g_consecutiveReversals = 0;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_todayBasketWins = 0;
   g_todayBasketLosses = 0;
   RebuildDailyState();
   SavePersistentState();
   LogInfo("New broker-server trading day - daily realized P/L rebuilt, daily/max-reversal halts cleared, day-start equity re-anchored.");
}

//================================= TRADE EVENT LOGGER (v5 schema) ====================================
void OpenLogFile()
{
   if(!InpLogToCSV) return;

   if(InpLogSubFolder != "")
      FolderCreate(InpLogSubFolder, InpLogCommonFolder ? FILE_COMMON : 0);

   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   string baseName = StringFormat("SmartReversalEA_v5_%s_%d_%04d%02d%02d_%02d%02d%02d.csv",
                                   _Symbol, InpMagicNumber, dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   gLogFileName = (InpLogSubFolder != "") ? (InpLogSubFolder + "\\" + baseName) : baseName;

   int flags = FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ;
   if(InpLogCommonFolder) flags |= FILE_COMMON;

   gLogHandle = FileOpen(gLogFileName, flags, ',');
   if(gLogHandle == INVALID_HANDLE)
   {
      Print("LOGGER: failed to open log file '", gLogFileName, "', error=", GetLastError());
      return;
   }

   FileWrite(gLogHandle,
             "LoggedAt", "TradeNo", "BasketNo", "PositionID", "Symbol", "Magic", "Direction", "Volume",
             "EntryTF", "H1Trend", "M15Trend", "M5Trend", "RSI", "ADX", "ATR", "SignalScore", "Regime", "Mode",
             "SpreadAtEntry", "SpreadAtExit",
             "EntryTime", "EntryPrice", "ExitTime", "ExitPrice",
             "InitialBasketRiskUSD", "MaxFloatingLossUSD", "MaxFloatingProfitUSD", "PeakBasketProfitUSD",
             "GrossProfit", "Commission", "Swap", "Fee", "NetPL",
             "CloseTrigger", "CloseReason", "CloseRequestTime", "FinalCloseTime", "ExecutionLatencyMs",
             "CloseDealTicket", "ExecRetcode", "PartialClose",
             "ReversalCount", "ReversalStatus", "NextDirection", "FinalBasketOutcome", "Currency");
   FileFlush(gLogHandle);

   if(!InpLogDecisions) return;
   string decBase = StringFormat("SmartReversalEA_v5_%s_%d_%04d%02d%02d_%02d%02d%02d_Decisions.csv",
                                  _Symbol, InpMagicNumber, dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   gDecisionLogFileName = (InpLogSubFolder != "") ? (InpLogSubFolder + "\\" + decBase) : decBase;
   gDecisionLogHandle = FileOpen(gDecisionLogFileName, flags, ',');
   if(gDecisionLogHandle == INVALID_HANDLE)
   {
      Print("LOGGER: failed to open decision log file '", gDecisionLogFileName, "', error=", GetLastError());
      return;
   }
   FileWrite(gDecisionLogHandle,
             "LoggedAt", "Symbol", "CandidateDirection", "Regime", "Mode",
             "ScoreH1", "ScoreM15", "ScoreM5", "ScoreRSI", "ScoreADX", "ScoreATR", "ScoreCandle", "ScorePullback", "TotalScore",
             "H1Trend", "M15Trend", "M5Trend", "RSI", "ADX", "ATR", "Spread", "Accepted", "RejectionReason");
   FileFlush(gDecisionLogHandle);
}

void CloseLogFile()
{
   if(gLogHandle != INVALID_HANDLE) { FileClose(gLogHandle); gLogHandle = INVALID_HANDLE; }
   if(gDecisionLogHandle != INVALID_HANDLE) { FileClose(gDecisionLogHandle); gDecisionLogHandle = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| One row per COMPLETED position (all partial closes aggregated),   |
//| tagged with its BasketNo and the full v5 context captured at open |
//| (g_basket* globals) plus everything captured at close.            |
//+------------------------------------------------------------------+
void LogTradeRow(const TradeSummary &s, int basketNo, ENUM_CLOSE_REASON reason, uint execRetcode, int nextDir, double net,
                  double maxFloatLossUSD, double maxFloatProfitUSD, double peakProfitUSD,
                  datetime closeReqTime, datetime finalCloseTime, double latencyMs, string outcome)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);

   if(InpLogAlsoToExpertsTab)
   {
      PrintFormat("[TRADE #%d basket %d] pos=%I64u %s vol=%.2f entry=%s exit=%s gross=%.2f comm=%.2f swap=%.2f fee=%.2f net=%.2f %s reason=%s outcome=%s closeDeal=%I64u retcode=%u next=%s revCount=%d score=%.1f regime=%s",
                  g_tradeNumberCounter, basketNo, s.ident, DirToString(s.dir), s.volume,
                  DoubleToString(s.entryPrice, _Digits), DoubleToString(s.exitPrice, _Digits),
                  s.profit, s.commission, s.swap, s.fee, net, ccy,
                  CloseReasonToString(reason), outcome, s.closeDeal, execRetcode, DirToString(nextDir), g_consecutiveReversals,
                  g_basketSignalScore, RegimeToString(g_basketRegime));
   }

   if(gLogHandle == INVALID_HANDLE) return;

   string reversalStatus = (nextDir != 0) ? "REVERSAL_TRIGGERED" : "NO_REVERSAL";

   FileWrite(gLogHandle,
             TimeToString(Now(), TIME_DATE | TIME_SECONDS), g_tradeNumberCounter, basketNo, (string)s.ident, _Symbol, InpMagicNumber,
             DirToString(s.dir), DoubleToString(s.volume, 2),
             EnumToString(InpEntryTimeframe), DirToString(g_basketH1Trend), DirToString(g_basketM15Trend), DirToString(g_basketM5Trend),
             DoubleToString(g_basketRSI, 1), DoubleToString(g_basketADX, 1), DoubleToString(g_basketATR, 5),
             DoubleToString(g_basketSignalScore, 1), RegimeToString(g_basketRegime), g_basketMode,
             DoubleToString(g_basketSpreadEntry, 1), DoubleToString(CurrentSpreadPoints(), 1),
             TimeToString(s.entryTime, TIME_DATE | TIME_SECONDS), DoubleToString(s.entryPrice, _Digits),
             TimeToString(s.exitTime, TIME_DATE | TIME_SECONDS),  DoubleToString(s.exitPrice, _Digits),
             DoubleToString(g_basketInitialRiskUSD, 2), DoubleToString(maxFloatLossUSD, 2), DoubleToString(maxFloatProfitUSD, 2), DoubleToString(peakProfitUSD, 2),
             DoubleToString(s.profit, 2), DoubleToString(s.commission, 2), DoubleToString(s.swap, 2), DoubleToString(s.fee, 2),
             DoubleToString(net, 2), CloseReasonToString(reason), CloseReasonToString(reason),
             TimeToString(closeReqTime, TIME_DATE | TIME_SECONDS), TimeToString(finalCloseTime, TIME_DATE | TIME_SECONDS), DoubleToString(latencyMs, 0),
             (string)s.closeDeal, (string)execRetcode, g_closePartial ? "YES" : "NO",
             g_consecutiveReversals, reversalStatus, DirToString(nextDir), outcome, ccy);
   FileFlush(gLogHandle);
}

void LogDecisionRow(int dir, ENUM_MARKET_REGIME regime, const ScoreBreakdown &sb)
{
   if(InpLogAlsoToExpertsTab)
   {
      // v5.4: EvaluateEntry() runs on every tick (many times/second on a liquid pair) while indicators
      // are unchanged between closed bars, so printing unconditionally spammed the Experts log with
      // thousands of identical lines an hour for zero new information (confirmed: 937 lines in under
      // 6 minutes, all identical bar two). Print only when the decision actually changes, plus a once-
      // every-30s heartbeat so it's still visible that evaluation is live while stuck on one verdict.
      string key = StringFormat("%s|%s|%s|%.1f|%s|%s", DirToString(dir), RegimeToString(regime), sb.mode, sb.total, sb.accepted ? "YES" : "NO", sb.rejectReason);
      if(key != g_lastDecisionKey || ThrottleOk(25, 30))
      {
         PrintFormat("[DECISION] dir=%s regime=%s mode=%s score=%.1f accepted=%s reason=%s",
                     DirToString(dir), RegimeToString(regime), sb.mode, sb.total, sb.accepted ? "YES" : "NO", sb.rejectReason);
         g_lastDecisionKey = key;
      }
   }

   if(gDecisionLogHandle == INVALID_HANDLE) return;
   FileWrite(gDecisionLogHandle,
             TimeToString(Now(), TIME_DATE | TIME_SECONDS), _Symbol, DirToString(dir), RegimeToString(regime), sb.mode,
             DoubleToString(sb.h1, 1), DoubleToString(sb.m15, 1), DoubleToString(sb.m5, 1), DoubleToString(sb.rsi, 1),
             DoubleToString(sb.adx, 1), DoubleToString(sb.atr, 1), DoubleToString(sb.candle, 1), DoubleToString(sb.pullback, 1),
             DoubleToString(sb.total, 1),
             DirToString(g_h1TrendDir), DirToString(g_m15TrendDir), DirToString(g_m5TrendDir),
             DoubleToString(g_rsiLast, 1), DoubleToString(g_adxLast, 1), DoubleToString(g_atrLast, 5), DoubleToString(CurrentSpreadPoints(), 1),
             sb.accepted ? "YES" : "NO", sb.rejectReason);
   FileFlush(gDecisionLogHandle);
}

//================================= STATE MACHINE CORE ====================================
#define SM(x) (1 << (x))

// Explicit transition table. Anything not listed here is an illegal transition. Unchanged from v4.8 -
// no new states were needed for v5.0's new signal/risk/profit engines, only new CLOSE_REASON values.
int AllowedTargets(ENUM_EA_STATE from)
{
   switch(from)
   {
      case STATE_INITIALIZING:
         return SM(STATE_START_DELAY) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_START_DELAY:
         return SM(STATE_WAITING_INITIAL_SIGNAL) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_WAITING_INITIAL_SIGNAL:
         return SM(STATE_OPENING_POSITION) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_OPENING_POSITION:
         return SM(STATE_POSITION_ACTIVE) | SM(STATE_WAITING_INITIAL_SIGNAL) | SM(STATE_REVERSAL_PENDING) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_POSITION_ACTIVE:
         return SM(STATE_CLOSING_LOSS) | SM(STATE_CLOSING_PROFIT) | SM(STATE_CLOSING_EMERGENCY) | SM(STATE_WAITING_INITIAL_SIGNAL)
              | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_CLOSING_LOSS:
         return SM(STATE_REVERSAL_PENDING) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_POSITION_ACTIVE) | SM(STATE_ERROR);
      case STATE_CLOSING_PROFIT:
         return SM(STATE_COOLDOWN) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_POSITION_ACTIVE) | SM(STATE_ERROR);
      case STATE_CLOSING_EMERGENCY:
         return SM(STATE_EMERGENCY_HALTED) | SM(STATE_POSITION_ACTIVE) | SM(STATE_ERROR);
      case STATE_REVERSAL_PENDING:
         return SM(STATE_OPENING_POSITION) | SM(STATE_POSITION_ACTIVE) | SM(STATE_WAITING_INITIAL_SIGNAL) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_COOLDOWN:
         return SM(STATE_WAITING_INITIAL_SIGNAL) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_DAILY_HALTED:
         return SM(STATE_WAITING_INITIAL_SIGNAL) | SM(STATE_POSITION_ACTIVE) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_EMERGENCY_HALTED:
         return SM(STATE_CLOSING_EMERGENCY) | SM(STATE_ERROR);   // terminal for trading; may only close a stray managed position
      case STATE_ERROR:
         return 0;                                                // terminal
   }
   return 0;
}

// States from which a NEW order could eventually be sent.
bool IsEntryCapableState(ENUM_EA_STATE s)
{
   return (s == STATE_START_DELAY || s == STATE_WAITING_INITIAL_SIGNAL || s == STATE_OPENING_POSITION ||
           s == STATE_REVERSAL_PENDING || s == STATE_COOLDOWN);
}

int ScanManaged(PosSnap &out);

//+------------------------------------------------------------------+
//| EVERY state change goes through here. Illegal transitions are     |
//| refused and fail safe into STATE_ERROR. While the emergency stop  |
//| is active, no state from which an order could be sent can be      |
//| entered - the halt cannot be bypassed.                             |
//+------------------------------------------------------------------+
bool TransitionTo(ENUM_EA_STATE newState, string why)
{
   if(newState == g_state)
   {
      g_lastAction = why;
      return true;
   }

   if(EmergencyActive() && IsEntryCapableState(newState))
   {
      PosSnap s;
      if(ScanManaged(s) == 0 && g_state != STATE_ERROR)
      {
         LogWarning(StringFormat("Emergency stop active - %s refused, going to EMERGENCY_HALTED instead (%s)", StateToString(newState), why));
         why = "Emergency stop active: " + why;
         newState = STATE_EMERGENCY_HALTED;
      }
      else
      {
         LogWarning(StringFormat("Emergency stop active - transition to %s blocked (%s)", StateToString(newState), why));
         return false;
      }
   }

   if((AllowedTargets(g_state) & SM(newState)) == 0)
   {
      LogError(StringFormat("ILLEGAL STATE TRANSITION %s -> %s blocked (%s). Failing safe into ERROR.",
                            StateToString(g_state), StateToString(newState), why));
      if(g_state != STATE_ERROR)
      {
         g_state = STATE_ERROR;
         g_stateSince = Now();
         g_lastAction = "Illegal state transition blocked - halted for manual review";
      }
      return false;
   }

   LogInfo(StringFormat("STATE: %s -> %s (%s)", StateToString(g_state), StateToString(newState), why));
   g_state = newState;
   g_stateSince = Now();
   g_lastAction = why;
   if(newState == STATE_WAITING_INITIAL_SIGNAL) { g_entryCandidateDir = 0; g_entryCandidateSince = 0; }
   if(newState == STATE_REVERSAL_PENDING)       { g_revConfirmDir = 0; g_revConfirmSince = 0; g_reversalCooldownEnd = Now() + InpReversalCooldownSeconds; }
   return true;
}

void EnterError(string msg)
{
   LogError(msg);
   TransitionTo(STATE_ERROR, msg);
}

//================================= POSITION / BASKET TRACKING ====================================
//+------------------------------------------------------------------+
//| Finds ALL of this EA's live positions by SYMBOL + MAGIC only and  |
//| aggregates them into one basket snapshot.                         |
//+------------------------------------------------------------------+
int ScanManagedFull(PosSnap &out, ulong &tickets[], ulong &idents[], double &floating)
{
   out.valid = false; out.count = 0; out.dir = 0; out.mixed = false; out.volume = 0.0; out.avgPrice = 0.0; out.firstTime = 0;
   ArrayResize(tickets, 0);
   ArrayResize(idents, 0);
   floating = 0.0;
   double pxw = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(out.count == 0) out.dir = dir;
      else if(dir != out.dir) out.mixed = true;

      double v = PositionGetDouble(POSITION_VOLUME);
      out.volume += v;
      pxw += v * PositionGetDouble(POSITION_PRICE_OPEN);
      datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(out.firstTime == 0 || tm < out.firstTime) out.firstTime = tm;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      ArrayResize(idents, n + 1);
      tickets[n] = t;
      idents[n]  = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      out.count++;
   }
   out.valid = (out.count > 0);
   if(out.valid && out.volume > 0.0) out.avgPrice = pxw / out.volume;
   return out.count;
}

int ScanManaged(PosSnap &out)
{
   ulong tk[], id[];
   double fl;
   return ScanManagedFull(out, tk, id, fl);
}

int IdentIndex(ulong id)
{
   int n = ArraySize(g_idents);
   for(int i = 0; i < n; i++) if(g_idents[i] == id) return i;
   return -1;
}

// Entry-side commission/fee of one position, read from its deal history (POSITION_COMMISSION is deprecated).
bool LoadIdentCost(ulong ident, double &cost)
{
   cost = 0.0;
   if(ident == 0 || !HistorySelectByPosition(ident)) return false;
   bool found = false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      cost += HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      found = true;
   }
   return found;
}

// Adds any position not yet tracked and refreshes the basket aggregates.
void SyncTracking(const PosSnap &s, const ulong &idents[])
{
   int n = ArraySize(idents);
   for(int i = 0; i < n; i++)
   {
      if(IdentIndex(idents[i]) >= 0) continue;
      int m = ArraySize(g_idents);
      ArrayResize(g_idents, m + 1);
      ArrayResize(g_identCost, m + 1);
      ArrayResize(g_identCostOk, m + 1);
      g_idents[m] = idents[i];
      g_identCostOk[m] = LoadIdentCost(idents[i], g_identCost[m]);
   }
   g_posDir = s.dir;
   g_posVolume = s.volume;
   g_posCount = s.count;
   g_posAvgPrice = s.avgPrice;
   g_posEntryTime = s.firstTime;
}

void ClearTracking()
{
   ArrayResize(g_idents, 0);
   ArrayResize(g_identCost, 0);
   ArrayResize(g_identCostOk, 0);
   g_posDir = 0; g_posVolume = 0.0; g_posCount = 0; g_posAvgPrice = 0.0; g_posEntryTime = 0;
   g_peakPerUnit = -1e18;
   g_troughPerUnit = 1e18;
   g_basketLot = 0.0;
   g_closePartial = false;
   g_partialDone = false;
}

//+------------------------------------------------------------------+
//| Net floating P/L of the whole live basket (profit + swap + entry  |
//| commission/fee) and its size in REF_LOT units.                    |
//+------------------------------------------------------------------+
bool GetFloatingPL(double &pl, double &units)
{
   pl = 0.0; units = 0.0;
   PosSnap s;
   ulong tk[], id[];
   double fl;
   if(ScanManagedFull(s, tk, id, fl) == 0) return false;

   SyncTracking(s, id);
   double cost = 0.0;
   for(int i = 0; i < ArraySize(id); i++)
   {
      int idx = IdentIndex(id[i]);
      if(idx < 0) continue;
      if(!g_identCostOk[idx]) g_identCostOk[idx] = LoadIdentCost(id[i], g_identCost[idx]);
      cost += g_identCost[idx];
   }
   pl = fl + cost;
   units = s.volume / REF_LOT;
   return true;
}

//+------------------------------------------------------------------+
//| Rebuilds a completed position from its own deal history. Partial  |
//| closes, partial fills, SL closes and manual closes are all        |
//| aggregated here, so ONE position is ONE completed trade.          |
//+------------------------------------------------------------------+
bool BuildTradeSummary(ulong ident, TradeSummary &s, bool requireComplete)
{
   ZeroMemory(s);
   s.ident = ident;
   if(ident == 0) return false;
   if(!HistorySelectByPosition(ident)) return false;

   double volIn = 0.0, volOut = 0.0, pxIn = 0.0, pxOut = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY);
      double   v  = HistoryDealGetDouble(tk, DEAL_VOLUME);
      double   px = HistoryDealGetDouble(tk, DEAL_PRICE);
      datetime t  = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);

      s.profit     += HistoryDealGetDouble(tk, DEAL_PROFIT);
      s.commission += HistoryDealGetDouble(tk, DEAL_COMMISSION);
      s.swap       += HistoryDealGetDouble(tk, DEAL_SWAP);
      s.fee        += HistoryDealGetDouble(tk, DEAL_FEE);

      if(entry == DEAL_ENTRY_IN)
      {
         volIn += v; pxIn += v * px;
         if(s.entryTime == 0 || t < s.entryTime) s.entryTime = t;
         s.dir = (type == DEAL_TYPE_BUY) ? 1 : -1;
      }
      else
      {
         volOut += v; pxOut += v * px;
         if(t >= s.exitTime) { s.exitTime = t; s.closeDeal = tk; }
      }
   }

   if(volOut <= 0.0) return false;
   if(requireComplete && volOut + 1e-8 < volIn) return false;

   s.volume     = (volIn > 0.0) ? volIn : volOut;
   s.entryPrice = (volIn  > 0.0) ? pxIn  / volIn  : g_posAvgPrice;
   s.exitPrice  = pxOut / volOut;
   if(s.dir == 0)       s.dir = g_posDir;
   if(s.entryTime == 0) s.entryTime = g_posEntryTime;
   return true;
}

//================================= MULTI-TIMEFRAME SIGNAL ENGINE ====================================
double g_fastEmaM5Last = 0.0;

// Closed-bar-only trend direction on ANY timeframe's own fast/slow EMA pair: shift 1 of that handle is
// always that timeframe's last fully closed bar, regardless of how often this is called from the entry
// timeframe's tick stream - so H1/M15 values are correct even though they're read every entry-TF bar.
int GetTrendDir(int fastHandle, int slowHandle)
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
   if(CopyBuffer(fastHandle, 0, 1, 1, fast) != 1 || CopyBuffer(slowHandle, 0, 1, 1, slow) != 1) return 0;
   if(!MathIsValidNumber(fast[0]) || !MathIsValidNumber(slow[0]) || fast[0] == EMPTY_VALUE || slow[0] == EMPTY_VALUE) return 0;
   if(fast[0] > slow[0]) return 1;
   if(fast[0] < slow[0]) return -1;
   return 0;
}

// Last N CLOSED entry-timeframe candles, [0] = last closed (shift 1), [1] = the one before it, etc.
bool GetClosedCandles(int count, CandleInfo &out[])
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(_Symbol, InpEntryTimeframe, 1, count, r);
   if(got < count) return false;
   ArrayResize(out, got);
   for(int i = 0; i < got; i++)
   {
      out[i].o = r[i].open; out[i].h = r[i].high; out[i].l = r[i].low; out[i].c = r[i].close;
      out[i].range     = out[i].h - out[i].l;
      out[i].body      = MathAbs(out[i].c - out[i].o);
      out[i].upperWick  = out[i].h - MathMax(out[i].o, out[i].c);
      out[i].lowerWick  = MathMin(out[i].o, out[i].c) - out[i].l;
      out[i].t          = r[i].time;
   }
   return true;
}

//---- Candlestick pattern recognition (pure OHLC price action, closed candles only) ----
bool IsBullishEngulfing(const CandleInfo &c[]) { return (ArraySize(c) >= 2 && c[1].c < c[1].o && c[0].c > c[0].o && c[0].c >= c[1].o && c[0].o <= c[1].c); }
bool IsBearishEngulfing(const CandleInfo &c[]) { return (ArraySize(c) >= 2 && c[1].c > c[1].o && c[0].c < c[0].o && c[0].o >= c[1].c && c[0].c <= c[1].o); }
bool IsHammer(const CandleInfo &c[])
{
   if(ArraySize(c) < 1 || c[0].range <= 0.0 || c[0].body <= 0.0) return false;
   return (c[0].lowerWick >= 2.0 * c[0].body && c[0].upperWick <= 0.5 * c[0].body);
}
bool IsShootingStar(const CandleInfo &c[])
{
   if(ArraySize(c) < 1 || c[0].range <= 0.0 || c[0].body <= 0.0) return false;
   return (c[0].upperWick >= 2.0 * c[0].body && c[0].lowerWick <= 0.5 * c[0].body);
}
bool IsPinBarBullish(const CandleInfo &c[]) { return IsHammer(c); }
bool IsPinBarBearish(const CandleInfo &c[]) { return IsShootingStar(c); }
bool IsStrongBullMomentum(const CandleInfo &c[], double atr)
{
   if(ArraySize(c) < 1 || atr <= 0.0 || c[0].range <= 0.0) return false;
   return (c[0].c > c[0].o && c[0].body >= 0.7 * c[0].range && c[0].range >= 1.2 * atr);
}
bool IsStrongBearMomentum(const CandleInfo &c[], double atr)
{
   if(ArraySize(c) < 1 || atr <= 0.0 || c[0].range <= 0.0) return false;
   return (c[0].c < c[0].o && c[0].body >= 0.7 * c[0].range && c[0].range >= 1.2 * atr);
}
bool IsInsideBar(const CandleInfo &c[]) { return (ArraySize(c) >= 2 && c[0].h <= c[1].h && c[0].l >= c[1].l); }
bool IsBreakoutCandle(const CandleInfo &c[], double level, int direction, double atr)
{
   if(ArraySize(c) < 1 || atr <= 0.0 || level <= 0.0) return false;
   if(direction == 1)  return (c[0].c > level && c[0].range >= 1.1 * atr && c[0].c > c[0].o);
   if(direction == -1) return (c[0].c < level && c[0].range >= 1.1 * atr && c[0].c < c[0].o);
   return false;
}
bool HasRejectionEvidence(int dir, const CandleInfo &c[])
{
   if(dir == 1)  return (IsHammer(c) || IsPinBarBullish(c) || IsBullishEngulfing(c));
   if(dir == -1) return (IsShootingStar(c) || IsPinBarBearish(c) || IsBearishEngulfing(c));
   return false;
}
// 0..1 ratio feeding the "Candle confirmation" score component.
double CandleConfirmRatio(int dir, const CandleInfo &c[], double atr)
{
   if(ArraySize(c) < 1) return 0.0;
   if(dir == 1)
   {
      if(IsStrongBullMomentum(c, atr) || IsBullishEngulfing(c)) return 1.0;
      if(c[0].c > c[0].o) return 0.6;
      return 0.0;
   }
   if(dir == -1)
   {
      if(IsStrongBearMomentum(c, atr) || IsBearishEngulfing(c)) return 1.0;
      if(c[0].c < c[0].o) return 0.6;
      return 0.0;
   }
   return 0.0;
}

//---- Swing High/Low Detection + Support/Resistance Zones ----
// Fractal scan: a point beats SWING_FRACTAL_K closed bars on each side to count as a swing high/low.
void FindSwings(int lookback, double &swingHighs[], double &swingLows[])
{
   ArrayResize(swingHighs, 0);
   ArrayResize(swingLows, 0);
   int total = lookback + 2 * SWING_FRACTAL_K;
   double hi[], lo[];
   ArraySetAsSeries(hi, true); ArraySetAsSeries(lo, true);
   if(CopyHigh(_Symbol, InpEntryTimeframe, 1, total, hi) < total) return;
   if(CopyLow(_Symbol, InpEntryTimeframe, 1, total, lo)  < total) return;

   for(int i = SWING_FRACTAL_K; i < total - SWING_FRACTAL_K; i++)
   {
      bool isHigh = true, isLow = true;
      for(int k = 1; k <= SWING_FRACTAL_K; k++)
      {
         if(hi[i] <= hi[i - k] || hi[i] <= hi[i + k]) isHigh = false;
         if(lo[i] >= lo[i - k] || lo[i] >= lo[i + k]) isLow = false;
      }
      if(isHigh) { int n = ArraySize(swingHighs); ArrayResize(swingHighs, n + 1); swingHighs[n] = hi[i]; }
      if(isLow)  { int n = ArraySize(swingLows);  ArrayResize(swingLows,  n + 1); swingLows[n]  = lo[i]; }
   }
}

// Merges raw swing points within 'tol' of each other into one zone (the zone's price = their average).
void ClusterPoints(const double &pts[], double tol, double &zones[])
{
   ArrayResize(zones, 0);
   int n = ArraySize(pts);
   if(n == 0) return;
   double sorted[];
   ArrayResize(sorted, n);
   for(int i = 0; i < n; i++) sorted[i] = pts[i];
   ArraySort(sorted);

   double clusterSum = sorted[0], clusterStart = sorted[0];
   int clusterCount = 1;
   for(int i = 1; i < n; i++)
   {
      if(sorted[i] - clusterStart <= tol) { clusterSum += sorted[i]; clusterCount++; }
      else
      {
         int m = ArraySize(zones); ArrayResize(zones, m + 1); zones[m] = clusterSum / clusterCount;
         clusterSum = sorted[i]; clusterStart = sorted[i]; clusterCount = 1;
      }
   }
   int m = ArraySize(zones); ArrayResize(zones, m + 1); zones[m] = clusterSum / clusterCount;
}

// Refreshes g_nearestResistance / g_nearestSupport (0.0 = none found) from clustered swing zones.
void UpdateSwingZones(double atr)
{
   g_nearestResistance = 0.0;
   g_nearestSupport    = 0.0;
   if(atr <= 0.0) return;

   double rawHighs[], rawLows[];
   FindSwings(InpSwingLookback, rawHighs, rawLows);

   double resZones[], supZones[];
   ClusterPoints(rawHighs, InpZoneClusterATR * atr, resZones);
   ClusterPoints(rawLows,  InpZoneClusterATR * atr, supZones);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0) return;

   double bestResDist = 1e18, bestSupDist = 1e18;
   for(int i = 0; i < ArraySize(resZones); i++)
   {
      if(resZones[i] > price && (resZones[i] - price) < bestResDist) { bestResDist = resZones[i] - price; g_nearestResistance = resZones[i]; }
   }
   for(int i = 0; i < ArraySize(supZones); i++)
   {
      if(supZones[i] < price && (price - supZones[i]) < bestSupDist) { bestSupDist = price - supZones[i]; g_nearestSupport = supZones[i]; }
   }
}

//---- Market Regime Classifier (ADX Market Regime Detection + ATR Volatility Intelligence) ----
ENUM_MARKET_REGIME DetectRegime()
{
   if(!g_indicatorsReady) return REGIME_NONE;

   if(g_atrAvgLast > 0.0)
   {
      double ratio = g_atrLast / g_atrAvgLast;
      if(ratio < InpATRMinRatio || ratio > InpATRMaxRatio) return REGIME_NONE;   // abnormal volatility - no-trade
   }

   bool allUp   = (g_h1TrendDir == 1  && g_m15TrendDir == 1  && g_m5TrendDir == 1);
   bool allDown = (g_h1TrendDir == -1 && g_m15TrendDir == -1 && g_m5TrendDir == -1);

   if(g_adxLast >= InpADXTrendMin && (allUp || allDown)) return REGIME_TREND;
   if(g_adxLast <= InpADXRangeMax)                        return REGIME_RANGE;
   return REGIME_NONE;   // ambiguous: between the two ADX thresholds, or trend strength without TF agreement
}

//---- Weighted Signal Scoring (0-100, normalized by the actual sum of the weight inputs) ----
void ZeroScore(ScoreBreakdown &sb)
{
   sb.h1 = 0; sb.m15 = 0; sb.m5 = 0; sb.rsi = 0; sb.adx = 0; sb.atr = 0; sb.candle = 0; sb.pullback = 0;
   sb.total = 0; sb.mode = ""; sb.rejectReason = ""; sb.accepted = false;
}

bool ComputeSignalScore(int dir, ENUM_MARKET_REGIME regime, ScoreBreakdown &sb)
{
   ZeroScore(sb);
   if(dir != 1 && dir != -1) { sb.rejectReason = "invalid direction"; return false; }
   sb.mode = RegimeToString(regime);

   if(g_h1TrendDir == dir)       sb.h1 = InpWeightH1;
   else if(g_h1TrendDir == 0)    sb.h1 = InpWeightH1 * 0.5;

   if(g_m15TrendDir == dir)      sb.m15 = InpWeightM15;
   else if(g_m15TrendDir == 0)   sb.m15 = InpWeightM15 * 0.5;

   if(g_m5TrendDir == dir)       sb.m5 = InpWeightM5;
   else if(g_m5TrendDir == 0)    sb.m5 = InpWeightM5 * 0.5;

   double rsiRatio = (dir == 1) ? MathMax(0.0, MathMin(1.0, (g_rsiLast - 40.0) / 30.0))
                                 : MathMax(0.0, MathMin(1.0, (60.0 - g_rsiLast) / 30.0));
   sb.rsi = InpWeightRSI * rsiRatio;

   double adxRatio = 0.0;
   if(regime == REGIME_TREND)
      adxRatio = MathMax(0.0, MathMin(1.0, (g_adxLast - InpADXTrendMin) / MathMax(1.0, 35.0 - InpADXTrendMin)));
   else if(regime == REGIME_RANGE)
      adxRatio = MathMax(0.0, MathMin(1.0, (InpADXRangeMax - g_adxLast) / MathMax(1.0, InpADXRangeMax)));
   sb.adx = InpWeightADX * adxRatio;

   double atrRatio = 0.0;
   if(g_atrAvgLast > 0.0)
   {
      double r = g_atrLast / g_atrAvgLast;
      double mid = (InpATRMinRatio + InpATRMaxRatio) / 2.0;
      double half = (InpATRMaxRatio - InpATRMinRatio) / 2.0;
      if(half > 0.0) atrRatio = MathMax(0.0, 1.0 - MathAbs(r - mid) / half);
   }
   sb.atr = InpWeightATR * atrRatio;

   CandleInfo candles[];
   bool haveCandles = GetClosedCandles(3, candles);
   sb.candle = InpWeightCandle * (haveCandles ? CandleConfirmRatio(dir, candles, g_atrLast) : 0.0);

   double pullbackRatio = 0.0;
   if(regime == REGIME_TREND && haveCandles && g_atrLast > 0.0)
   {
      double stretch = (dir == 1) ? (candles[0].c - g_fastEmaM5Last) : (g_fastEmaM5Last - candles[0].c);
      pullbackRatio = MathMax(0.0, 1.0 - MathMax(0.0, stretch) / (InpMaxChaseATR * g_atrLast));
   }
   else if(regime == REGIME_RANGE && g_atrLast > 0.0)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(dir == 1 && g_nearestSupport > 0.0)
         pullbackRatio = MathMax(0.0, 1.0 - MathAbs(price - g_nearestSupport) / g_atrLast / InpRangeZoneATR);
      else if(dir == -1 && g_nearestResistance > 0.0)
         pullbackRatio = MathMax(0.0, 1.0 - MathAbs(g_nearestResistance - price) / g_atrLast / InpRangeZoneATR);
   }
   sb.pullback = InpWeightPullback * MathMax(0.0, MathMin(1.0, pullbackRatio));

   double sumWeights = InpWeightH1 + InpWeightM15 + InpWeightM5 + InpWeightRSI + InpWeightADX + InpWeightATR + InpWeightCandle + InpWeightPullback;
   double raw = sb.h1 + sb.m15 + sb.m5 + sb.rsi + sb.adx + sb.atr + sb.candle + sb.pullback;
   sb.total = (sumWeights > 0.0) ? (100.0 * raw / sumWeights) : 0.0;
   return true;
}

//---- London/New York Session Filter (server time) ----
bool SessionOk()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime t;
   TimeToStruct(Now(), t);
   if(InpSessionStartHour <= InpSessionEndHour)
      return (t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour);
   return (t.hour >= InpSessionStartHour || t.hour < InpSessionEndHour);   // wraps midnight
}

//---- Optional Economic Calendar Filter: native MQL5 only, no-ops (never blocks everything) if unavailable ----
bool CalendarOk()
{
   if(!InpUseCalendarFilter) return true;
   MqlCalendarValue values[];
   datetime from = Now() - InpCalendarBlockMinutesBefore * 60;
   datetime to   = Now() + InpCalendarBlockMinutesAfter  * 60;
   int got = CalendarValueHistory(values, from, to, NULL, NULL);
   if(got <= 0) return true;   // no data returned / API unavailable in this environment - fail OPEN, never block everything by accident
   for(int i = 0; i < got; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if((int)ev.importance >= InpCalendarMinImportance) return false;
   }
   return true;
}

//---- Multi-Timeframe Trend Intelligence: recomputed once per newly CLOSED entry-timeframe bar ----
void UpdateSignal()
{
   if(maFastHandleM5 == INVALID_HANDLE || maSlowHandleM5 == INVALID_HANDLE) return;

   datetime barTime[];
   ArraySetAsSeries(barTime, true);
   if(CopyTime(_Symbol, InpEntryTimeframe, 1, 1, barTime) != 1) return;
   if(barTime[0] == g_lastEvalBar) return;

   double fastM5[];
   ArraySetAsSeries(fastM5, true);
   if(CopyBuffer(maFastHandleM5, 0, 1, 1, fastM5) != 1 || !MathIsValidNumber(fastM5[0]) || fastM5[0] == EMPTY_VALUE)
   {
      if(ThrottleOk(0, 60)) LogWarning("EMA buffers not ready yet - will retry.");
      return;
   }
   g_fastEmaM5Last = fastM5[0];

   g_m5TrendDir  = GetTrendDir(maFastHandleM5,  maSlowHandleM5);
   g_m15TrendDir = GetTrendDir(maFastHandleM15, maSlowHandleM15);
   g_h1TrendDir  = GetTrendDir(maFastHandleH1,  maSlowHandleH1);

   double rsi[], adx[], atr[];
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(adx, true); ArraySetAsSeries(atr, true);
   bool rsiOk = (rsiHandle != INVALID_HANDLE && CopyBuffer(rsiHandle, 0, 1, 1, rsi) == 1 && MathIsValidNumber(rsi[0]) && rsi[0] != EMPTY_VALUE);
   bool adxOk = (adxHandle != INVALID_HANDLE && CopyBuffer(adxHandle, 0, 1, 1, adx) == 1 && MathIsValidNumber(adx[0]) && adx[0] != EMPTY_VALUE);
   bool atrOk = (atrHandle != INVALID_HANDLE && CopyBuffer(atrHandle, 0, 1, 1, atr) == 1 && MathIsValidNumber(atr[0]) && atr[0] != EMPTY_VALUE && atr[0] > 0.0);
   if(rsiOk) g_rsiLast = rsi[0];
   if(adxOk) g_adxLast = adx[0];
   if(atrOk) g_atrLast = atr[0];

   double atrSeries[];
   ArraySetAsSeries(atrSeries, true);
   if(atrHandle != INVALID_HANDLE && CopyBuffer(atrHandle, 0, 1, InpATRNormalLookback, atrSeries) == InpATRNormalLookback)
   {
      double sum = 0.0; int cnt = 0;
      for(int i = 0; i < InpATRNormalLookback; i++)
         if(MathIsValidNumber(atrSeries[i]) && atrSeries[i] != EMPTY_VALUE && atrSeries[i] > 0.0) { sum += atrSeries[i]; cnt++; }
      if(cnt > 0) g_atrAvgLast = sum / cnt;
   }

   g_indicatorsReady = (rsiOk && adxOk && atrOk && g_atrAvgLast > 0.0);
   if(g_indicatorsReady) UpdateSwingZones(g_atrLast);

   g_lastEvalBar = barTime[0];
   g_regimeLast = DetectRegime();
}

bool RSIConfirms(int dir)
{
   if(dir == 1)  return (g_rsiLast >= InpRSIBuyMin);
   if(dir == -1) return (g_rsiLast <= InpRSISellMax);
   return true;
}

//================================= INDEPENDENT RISK ENGINE (pre-entry gates only) ====================================
// Equity Drawdown Guard: blocks new entries once equity has fallen InpMaxAccountDrawdownPct below its recorded peak.
// Never force-closes an open basket - same philosophy as the existing daily realized-loss limit.
bool EquityDrawdownOk()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) { g_peakEquity = eq; SavePersistentState(); }
   if(g_peakEquity <= 0.0) return true;
   double ddPct = 100.0 * (g_peakEquity - eq) / g_peakEquity;
   return (ddPct < InpMaxAccountDrawdownPct);
}

// Maximum daily floating drawdown: blocks new entries if today's start-of-day equity minus current
// equity (i.e. including whatever is floating right now) exceeds the configured $ limit.
bool DailyFloatingDrawdownOk()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = g_dayStartEquity - eq;
   return (dd < InpMaxDailyFloatingDrawdownUSD);
}

bool MarginUsageOk()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return false;
   double marginUsed = AccountInfoDouble(ACCOUNT_MARGIN);
   double pct = 100.0 * marginUsed / equity;
   return (pct < InpMaxMarginUsagePct);
}

// Fixed Exposure Engine helper: the basket volume ExecuteOpen would actually try to open right now.
double EstimateBasketVolume()
{
   double lot = CurrentLot();
   if(lot <= 0.0) return 0.0;
   int n = MathMin(CurrentBasketSize(), (int)MathFloor(InpMaxBasketVolume / lot + 1e-9));
   if(n < 1) n = 1;
   return n * lot;
}

// Monetary/percent-equity basket risk check using the real protective-stop distance - "if a safe stop
// cannot be calculated, do not open a position" (same rule v4.8 already enforced via ComputeProtectiveStop).
bool BasketRiskOk(int dir, double volume, string &why)
{
   string slWhy;
   double sl = ComputeProtectiveStop(dir, slWhy);
   if(sl <= 0.0) { why = "cannot compute a valid protective stop (" + slWhy + ")"; return false; }
   double riskUSD = ComputeBasketRiskUSD(dir, volume, sl);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pctLimitUSD = equity * InpMaxBasketRiskPctEquity / 100.0;
   if(riskUSD > InpMaxBasketRiskUSD + 1e-9)
   { why = StringFormat("basket risk %.2f exceeds InpMaxBasketRiskUSD %.2f", riskUSD, InpMaxBasketRiskUSD); return false; }
   if(riskUSD > pctLimitUSD + 1e-9)
   { why = StringFormat("basket risk %.2f exceeds %.1f%% of equity (%.2f)", riskUSD, InpMaxBasketRiskPctEquity, pctLimitUSD); return false; }
   return true;
}

//================================= MODE A / MODE B / MODE C - THE SINGLE ENTRY/REVERSAL GATE ====================================
//+------------------------------------------------------------------+
//| The ONE function used by both a fresh entry (STATE_WAITING_       |
//| INITIAL_SIGNAL) and a reversal (STATE_REVERSAL_PENDING). This is  |
//| what makes a reversal a genuine re-evaluation of the market - the |
//| exact same regime classification, scoring, candle/pullback/range  |
//| gates, spread/session/calendar checks and risk-engine gates a      |
//| fresh entry must pass. Every call - accepted or rejected - is      |
//| written to the decision log. Never fabricates a component it      |
//| could not compute; missing data scores 0 for that component and   |
//| is named in the rejection reason.                                  |
//+------------------------------------------------------------------+
bool EvaluateEntry(int dir, ScoreBreakdown &sb, string &rejectReason)
{
   ZeroScore(sb);
   ENUM_MARKET_REGIME regime = REGIME_NONE;
   bool accepted = false;
   rejectReason = "";

   do
   {
      if(dir != 1 && dir != -1) { rejectReason = "invalid candidate direction"; break; }
      if(!g_indicatorsReady)    { rejectReason = "indicator data not ready/available yet"; break; }
      if(!SpreadOK())           { rejectReason = StringFormat("spread %.1f pts exceeds InpMaxSpreadPoints=%d", CurrentSpreadPoints(), InpMaxSpreadPoints); break; }
      if(!SessionOk())          { rejectReason = "outside the configured trading session (server time)"; break; }
      if(!CalendarOk())         { rejectReason = "blocked by a high-importance economic calendar event window"; break; }
      if(!DirectionAllowed(dir)){ rejectReason = StringFormat("symbol trade mode does not allow a %s order right now", DirToString(dir)); break; }
      if(BlockedByHalt())       { rejectReason = "daily loss / max-reversal halt is active"; break; }

      regime = DetectRegime();
      if(regime == REGIME_NONE) { rejectReason = "no-trade regime: ambiguous multi-timeframe trend or abnormal ATR"; break; }
      if(InpSignalModel == SIGNAL_MODEL_TREND_ONLY && regime != REGIME_TREND) { rejectReason = "TREND_ONLY model active and regime is not TREND"; break; }
      if(InpSignalModel == SIGNAL_MODEL_RANGE_ONLY && regime != REGIME_RANGE) { rejectReason = "RANGE_ONLY model active and regime is not RANGE"; break; }

      CandleInfo candles[];
      bool haveCandles = GetClosedCandles(3, candles);
      if(!haveCandles) { rejectReason = "could not read closed candle data"; break; }

      if(regime == REGIME_TREND)
      {
         sb.mode = "TREND";
         if(!RSIConfirms(dir)) { rejectReason = StringFormat("MODE A: RSI momentum gate failed (RSI=%.1f)", g_rsiLast); break; }
         if(InpRequireCandleConfirm)
         {
            bool candleWithTrend = (dir == 1) ? (candles[0].c > candles[0].o) : (candles[0].c < candles[0].o);
            bool patternAgrees = CandleConfirmRatio(dir, candles, g_atrLast) > 0.0;
            if(!candleWithTrend && !patternAgrees) { rejectReason = "MODE A: last closed candle does not confirm the trade direction"; break; }
         }
         if(InpUsePullbackFilter)
         {
            double stretch = (dir == 1) ? (candles[0].c - g_fastEmaM5Last) : (g_fastEmaM5Last - candles[0].c);
            bool withinZone = (g_atrLast <= 0.0) || (stretch <= InpMaxChaseATR * g_atrLast);
            if(!withinZone)
            {
               if(g_pullbackWaitDir != dir) { g_pullbackWaitDir = dir; g_pullbackWaitSince = Now(); }
               int waitedMin = (int)((Now() - g_pullbackWaitSince) / 60);
               if(InpMaxPullbackWaitMin > 0 && waitedMin >= InpMaxPullbackWaitMin)
               {
                  withinZone = true;   // bounded wait elapsed - do not sit out the trend forever
                  if(ThrottleOk(12, 60)) LogInfo(StringFormat("Pullback wait timed out after %d min - proceeding with %s.", waitedMin, DirToString(dir)));
               }
            }
            else { g_pullbackWaitDir = 0; g_pullbackWaitSince = 0; }
            if(!withinZone) { rejectReason = StringFormat("MODE A: price extended beyond %.1f ATR pullback zone (waiting)", InpMaxChaseATR); break; }
         }
      }
      else   // REGIME_RANGE
      {
         sb.mode = "RANGE";
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(price <= 0.0 || g_atrLast <= 0.0) { rejectReason = "MODE B: no valid price/ATR to evaluate range boundaries"; break; }

         double nearLevel = (dir == 1) ? g_nearestSupport : g_nearestResistance;
         double farLevel  = (dir == 1) ? g_nearestResistance : g_nearestSupport;
         if(nearLevel <= 0.0) { rejectReason = StringFormat("MODE B: no confirmed %s zone identified", (dir == 1) ? "support" : "resistance"); break; }

         double distNear = MathAbs(price - nearLevel);
         if(distNear > InpRangeZoneATR * g_atrLast) { rejectReason = "MODE B: price is not close enough to the range boundary"; break; }

         bool rsiExtreme = (dir == 1) ? (g_rsiLast <= InpRSIOversold) : (g_rsiLast >= InpRSIOverbought);
         bool rejectionCandle = HasRejectionEvidence(dir, candles);
         if(!rsiExtreme && !rejectionCandle) { rejectReason = "MODE B: no RSI extreme or rejection-candle evidence at the boundary"; break; }

         if(farLevel <= 0.0) { rejectReason = "MODE B: no opposite boundary found - cannot verify reward:risk space"; break; }
         double distFar = MathAbs(farLevel - price);
         if(distNear <= 0.0 || distFar < InpMinRewardRiskRatio * distNear)
         { rejectReason = StringFormat("MODE B: insufficient reward:risk space to the opposite boundary (%.1f < %.1fx)", distFar / MathMax(distNear, 1e-9), InpMinRewardRiskRatio); break; }
      }

      if(!ComputeSignalScore(dir, regime, sb)) { rejectReason = (sb.rejectReason != "") ? sb.rejectReason : "score could not be computed"; break; }
      if(sb.total < InpMinSignalScore) { rejectReason = StringFormat("signal score %.1f below InpMinSignalScore %.1f", sb.total, InpMinSignalScore); break; }

      if(!EquityDrawdownOk())       { rejectReason = StringFormat("equity drawdown guard active (>= %.1f%% below peak)", InpMaxAccountDrawdownPct); break; }
      if(!DailyFloatingDrawdownOk()){ rejectReason = StringFormat("daily floating drawdown guard active (>= %.2f)", InpMaxDailyFloatingDrawdownUSD); break; }
      if(!MarginUsageOk())          { rejectReason = StringFormat("margin usage guard active (>= %.1f%%)", InpMaxMarginUsagePct); break; }
      string riskWhy;
      if(!BasketRiskOk(dir, EstimateBasketVolume(), riskWhy)) { rejectReason = "risk engine: " + riskWhy; break; }

      accepted = true;
   }
   while(false);

   sb.accepted = accepted;
   if(!accepted) { sb.rejectReason = rejectReason; if(sb.mode == "") sb.mode = RegimeToString(regime); }
   g_lastRejectReason = accepted ? "" : rejectReason;
   if(dir == 1)  g_lastScoreBuy  = sb.total;
   if(dir == -1) g_lastScoreSell = sb.total;
   LogDecisionRow(dir, regime, sb);
   return accepted;
}

// Multi-timeframe majority direction for MODE A candidate selection (>=2 of H1/M15/M5 agreeing).
int MultiTFMajorityDirection()
{
   int up = (g_h1TrendDir == 1 ? 1 : 0) + (g_m15TrendDir == 1 ? 1 : 0) + (g_m5TrendDir == 1 ? 1 : 0);
   int dn = (g_h1TrendDir == -1 ? 1 : 0) + (g_m15TrendDir == -1 ? 1 : 0) + (g_m5TrendDir == -1 ? 1 : 0);
   if(up >= 2 && up > dn) return 1;
   if(dn >= 2 && dn > up) return -1;
   return 0;
}

// MODE B candidate: whichever boundary price is currently nearest, in the mean-reverting direction.
int RangeBoundaryCandidateDirection()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0 || g_atrLast <= 0.0) return 0;
   double distSup = (g_nearestSupport    > 0.0) ? MathAbs(price - g_nearestSupport)    : 1e18;
   double distRes = (g_nearestResistance > 0.0) ? MathAbs(g_nearestResistance - price) : 1e18;
   if(distSup <= InpRangeZoneATR * g_atrLast && distSup <= distRes) return 1;
   if(distRes <= InpRangeZoneATR * g_atrLast && distRes <  distSup) return -1;
   return 0;
}

// Picks a candidate direction for the CURRENT regime, for use by STATE_WAITING_INITIAL_SIGNAL.
// Returns 0 (no candidate) when nothing qualifies - MODE C: NO-TRADE, a deliberate, logged decision.
int SelectCandidateDirection(ENUM_MARKET_REGIME regime)
{
   if(regime == REGIME_TREND) return MultiTFMajorityDirection();
   if(regime == REGIME_RANGE) return RangeBoundaryCandidateDirection();
   return 0;
}

//================================= ORDER EXECUTION ====================================
bool IsUncertainRetcode(uint rc)
{
   return (rc == TRADE_RETCODE_TIMEOUT || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_ERROR || rc == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Opens one BASKET: InpBasketMax same-direction positions of the    |
//| FIXED InpFixedLotSize lot (no growth, no randomness), shrunk to    |
//| fit InpMaxBasketVolume and free margin. The boolean returned by   |
//| CTrade is NOT proof of a fill: ResultRetcode() is checked for      |
//| every order, uncertain outcomes are reconciled against the real    |
//| broker positions instead of being guessed. The accepted score/     |
//| regime from EvaluateEntry() is captured here as the basket's       |
//| context for the v5 CSV columns.                                    |
//+------------------------------------------------------------------+
ENUM_REQ_RESULT ExecuteOpen(int direction, ENUM_OPEN_INTENT intent, const ScoreBreakdown &sb, ENUM_MARKET_REGIME regime)
{
   if(EmergencyActive())            { LogWarning("Open refused: emergency stop is active."); return REQ_DEFERRED; }
   if(BlockedByHalt())              { if(ThrottleOk(1, 60)) LogWarning("Open refused: daily loss / max-reversal halt is active."); return REQ_DEFERRED; }
   if(g_state == STATE_ERROR)       return REQ_DEFERRED;
   if(!IsDemoAccount())             { LogError("Open refused: not a DEMO account."); return REQ_DEFERRED; }
   if(Now() < g_nextRequestAllowed) return REQ_DEFERRED;

   string why;
   if(!TradingPermitted(why))
   {
      if(ThrottleOk(2, 60)) LogWarning("Open deferred: " + why);
      return REQ_DEFERRED;
   }
   if(!DirectionAllowed(direction))
   {
      if(ThrottleOk(3, 60)) LogWarning(StringFormat("Open deferred: symbol trade mode does not allow a %s order right now.", DirToString(direction)));
      return REQ_DEFERRED;
   }

   PosSnap existing;
   if(ScanManaged(existing) > 0)
   {
      if(ThrottleOk(11, 30)) LogError("Open refused: a managed basket already exists - a second basket is never opened on top of it.");
      return REQ_DEFERRED;
   }
   if(NettingForeignConflict())
   {
      if(ThrottleOk(4, 60)) LogWarning("Open deferred: netting account has a foreign position on this symbol - would merge with it.");
      return REQ_DEFERRED;
   }
   if(!SpreadOK())
   {
      if(ThrottleOk(5, 60)) LogWarning(StringFormat("Open deferred: spread %.1f pts exceeds InpMaxSpreadPoints=%d.", CurrentSpreadPoints(), InpMaxSpreadPoints));
      return REQ_DEFERRED;
   }
   if(!EquityDrawdownOk())        { if(ThrottleOk(21, 60)) LogWarning("Open deferred: equity drawdown guard active."); return REQ_DEFERRED; }
   if(!DailyFloatingDrawdownOk()) { if(ThrottleOk(22, 60)) LogWarning("Open deferred: daily floating drawdown guard active."); return REQ_DEFERRED; }
   if(!MarginUsageOk())           { if(ThrottleOk(23, 60)) LogWarning("Open deferred: margin usage guard active."); return REQ_DEFERRED; }

   double lot = CurrentLot();
   if(lot <= 0.0)
   {
      EnterError("Open REJECTED: lot is not supported by this symbol's volume min/max/step configuration.");
      return REQ_DEFERRED;
   }

   int n = CurrentBasketSize();
   n = MathMin(n, (int)MathFloor(InpMaxBasketVolume / lot + 1e-9));
   if(n < 1) n = 1;

   string riskWhy;
   if(!BasketRiskOk(direction, n * lot, riskWhy))
   {
      if(ThrottleOk(24, 60)) LogWarning("Open deferred: risk engine - " + riskWhy);
      return REQ_DEFERRED;
   }

   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double margin1 = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lot, price, margin1) || margin1 <= 0.0)
   {
      if(ThrottleOk(7, 60)) LogWarning(StringFormat("Open deferred: OrderCalcMargin failed (error %d).", GetLastError()));
      return REQ_DEFERRED;
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   n = MathMin(n, (int)MathFloor(freeMargin * 0.8 / margin1));   // keep a 20% free-margin buffer
   if(n < 1)
   {
      if(ThrottleOk(8, 60)) LogWarning(StringFormat("Open deferred: free margin %.2f cannot afford even one %.2f-lot position (needs %.2f).", freeMargin, lot, margin1));
      return REQ_DEFERRED;
   }

   string slWhy;
   if(ComputeProtectiveStop(direction, slWhy) <= 0.0)
   {
      if(ThrottleOk(6, 60)) LogWarning("Open deferred: cannot place a valid protective stop (" + slWhy + ").");
      return REQ_DEFERRED;
   }

   // ---- capture the basket's v5 context now, at the moment it is actually attempted ----
   g_basketOpenTime      = Now();
   g_basketSignalScore   = sb.total;
   g_basketRegime        = regime;
   g_basketMode          = sb.mode;
   g_basketH1Trend       = g_h1TrendDir;
   g_basketM15Trend      = g_m15TrendDir;
   g_basketM5Trend       = g_m5TrendDir;
   g_basketRSI           = g_rsiLast;
   g_basketADX           = g_adxLast;
   g_basketATR           = g_atrLast;
   g_basketSpreadEntry   = CurrentSpreadPoints();
   double slForRisk = ComputeProtectiveStop(direction, slWhy);
   g_basketInitialRiskUSD = ComputeBasketRiskUSD(direction, n * lot, slForRisk);

   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;
   g_openRequestTime = Now();

   int opened = 0;
   for(int k = 0; k < n; k++)
   {
      if(k > 0 && !SpreadOK()) { LogWarning(StringFormat("Basket stopped at %d/%d positions: spread widened.", opened, n)); break; }

      double sl = ComputeProtectiveStop(direction, slWhy);
      if(sl <= 0.0)
      {
         if(opened == 0) { LogWarning("Open deferred: cannot place a valid protective stop (" + slWhy + ")."); return REQ_DEFERRED; }
         LogWarning(StringFormat("Basket stopped at %d/%d positions: no valid stop (%s).", opened, n, slWhy));
         break;
      }

      ulong t0 = GetTickCount64();
      bool sent = (direction == 1)
                ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, InpTradeComment)
                : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, InpTradeComment);
      uint rc = trade.ResultRetcode();
      g_lastOrderLatencyMs = (double)(GetTickCount64() - t0);
      g_lastRetcode = rc;
      g_lastOrderLabel = StringFormat("%s open #%d/%d", DirToString(direction), opened + 1, n);

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
      {
         if(rc == TRADE_RETCODE_DONE_PARTIAL) LogWarning("An open order was only PARTIALLY filled - the real broker volume is tracked, no top-up is sent.");
         opened++;
         continue;
      }

      if(IsUncertainRetcode(rc))
      {
         if(opened == 0)
         {
            LogWarning(StringFormat("Open %s outcome UNCERTAIN (retcode %u: %s) - reconciling against real positions before any retry.",
                                    DirToString(direction), rc, trade.ResultRetcodeDescription()));
            g_openIntent = intent; g_openDir = direction; g_basketLot = lot;
            return REQ_UNCERTAIN;
         }
         LogWarning(StringFormat("Basket stopped at %d/%d positions: next order outcome uncertain (retcode %u).", opened, n, rc));
         break;
      }

      if(opened == 0)
      {
         if(rc == TRADE_RETCODE_MARKET_CLOSED)
         {
            if(ThrottleOk(9, 120)) LogWarning("Open deferred: market is closed.");
            return REQ_DEFERRED;
         }
         g_retryCounter++;
         g_lastErrorDetail = trade.ResultRetcodeDescription();
         LogError(StringFormat("Open %s REJECTED (attempt %d/%d): %s", DirToString(direction), g_retryCounter, InpMaxExecutionRetries,
                               trade.ResultRetcodeDescription()), (int)rc);
         if(g_retryCounter >= InpMaxExecutionRetries)
            EnterError(StringFormat("Open %s failed %d consecutive times - halting for manual review.", DirToString(direction), g_retryCounter));
         return REQ_REJECTED;
      }
      LogWarning(StringFormat("Basket stopped at %d/%d positions: order rejected (retcode %u: %s).", opened, n, rc, trade.ResultRetcodeDescription()));
      break;
   }

   g_openIntent = intent;
   g_openDir = direction;
   g_basketLot = lot;
   if(opened < n) LogWarning(StringFormat("Basket opened with %d of %d planned positions.", opened, n));
   return REQ_ACCEPTED;
}

//+------------------------------------------------------------------+
//| Requests closure of EVERY basket position. DONE does not mean     |
//| flat: completion is only ever confirmed by Reconcile() seeing zero|
//| managed volume. The close reason is stored BEFORE the requests so  |
//| the confirmation path can never mistake it for a loss reversal.    |
//| Captures a pre-close snapshot (floating P/L, timestamp) for the    |
//| v5 CSV's execution-latency columns.                                 |
//+------------------------------------------------------------------+
ENUM_REQ_RESULT ExecuteClose(ENUM_CLOSE_REASON reason, string detail)
{
   if(Now() < g_nextRequestAllowed) return REQ_DEFERRED;

   string why;
   if(!TradingPermitted(why))
   {
      if(ThrottleOk(10, 60)) LogWarning("Close deferred: " + why);
      return REQ_DEFERRED;
   }

   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   if(cnt == 0) return REQ_DEFERRED;
   if(s.mixed) { EnterError("Close aborted: BUY and SELL positions are mixed in the basket."); return REQ_DEFERRED; }
   SyncTracking(s, id);

   ENUM_CLOSE_REASON prevReason = g_pendingCloseReason;
   string prevDetail = g_pendingCloseDetail;
   bool firstRequestForThisClose = (g_pendingCloseReason == CLOSE_REASON_NONE);
   g_pendingCloseReason = reason;
   g_pendingCloseDetail = detail;
   g_closeRequestTime = Now();
   if(firstRequestForThisClose) g_closeRequestTimeExact = Now();
   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;
   LogInfo("Closing basket: " + detail);

   int okCount = 0, uncertainCount = 0, failCount = 0;
   bool anyPartial = false;
   uint lastRc = 0;
   string lastDesc = "";
   for(int i = 0; i < cnt; i++)
   {
      ulong t0 = GetTickCount64();
      bool sent = trade.PositionClose(tk[i], (ulong)InpSlippagePoints);
      uint rc = trade.ResultRetcode();
      g_lastOrderLatencyMs = (double)(GetTickCount64() - t0);
      lastRc = rc;
      lastDesc = trade.ResultRetcodeDescription();
      if(sent && rc == TRADE_RETCODE_DONE)              okCount++;
      else if(sent && rc == TRADE_RETCODE_DONE_PARTIAL) { okCount++; anyPartial = true; }
      else if(IsUncertainRetcode(rc))                   uncertainCount++;
      else                                              failCount++;
   }
   g_closeRetcode = lastRc;
   g_lastRetcode = lastRc;

   if(okCount > 0 || uncertainCount > 0)
   {
      g_retryCounter = 0;
      g_closePartial = (okCount < cnt) || anyPartial;
      if(failCount > 0 || anyPartial)
         LogWarning(StringFormat("Basket close: %d of %d closed, %d failed, %d uncertain - remaining positions will be retried.", okCount, cnt, failCount, uncertainCount));
      return (okCount == 0) ? REQ_UNCERTAIN : REQ_ACCEPTED;
   }

   g_pendingCloseReason = prevReason;
   g_pendingCloseDetail = prevDetail;
   g_retryCounter++;
   g_lastErrorDetail = lastDesc;
   LogError(StringFormat("Basket close REJECTED (%d positions, attempt %d/%d): %s", cnt, g_retryCounter, InpMaxExecutionRetries, lastDesc), (int)lastRc);
   if(reason != CLOSE_REASON_EMERGENCY && g_retryCounter >= InpMaxExecutionRetries)
      EnterError(StringFormat("Basket close failed %d consecutive times - halting for manual review.", g_retryCounter));
   return REQ_REJECTED;
}

// If the broker stripped a stop, put it back (the SL is the only protection against a missed monitoring tick).
void EnsureProtectiveStop()
{
   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   for(int i = 0; i < cnt; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      string why;
      double sl = ComputeProtectiveStop(s.dir, why);
      if(sl <= 0.0) { LogWarning("Position has no protective stop and none could be computed: " + why); continue; }
      if(!trade.PositionModify(tk[i], sl, 0.0))
         LogWarning(StringFormat("Could not attach protective stop to #%I64u (retcode %u: %s).", tk[i], trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

//================================= RECONCILIATION & CLOSE ROUTING ====================================
void ConsumeEntryBar() { g_lastEntryBarConsumed = g_pendingConsumeBar; SavePersistentState(); }

// Decides the next state once the basket is CONFIRMED completely closed.
void RouteAfterClose(ENUM_CLOSE_REASON reason, int closedDir)
{
   if(reason == CLOSE_REASON_EMERGENCY || EmergencyActive())
   {
      TransitionTo(STATE_EMERGENCY_HALTED, "Emergency stop: basket closed, trading halted - no reversal, no new entries.");
      return;
   }

   switch(reason)
   {
      case CLOSE_REASON_LOSS_REVERSAL:
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Loss close confirmed but a halt is active - no reversal.");
         else if(g_consecutiveReversals >= InpMaxConsecutiveReversals)
         {
            g_maxRevHalt = true;
            SavePersistentState();
            TransitionTo(STATE_DAILY_HALTED, StringFormat("Reversal cap (%d) reached - no further reversal until the next trading day.", InpMaxConsecutiveReversals));
         }
         else
         {
            g_reversalDir = -closedDir;
            TransitionTo(STATE_REVERSAL_PENDING, StringFormat("Original %s basket confirmed fully closed - will RE-EVALUATE the market for a %s setup after the reversal cooldown.", DirToString(closedDir), DirToString(g_reversalDir)));
         }
         break;

      case CLOSE_REASON_DAILY_LIMIT:
         TransitionTo(STATE_DAILY_HALTED, "Loss close confirmed during daily halt - no reversal.");
         break;

      case CLOSE_REASON_MAX_REVERSALS:
         g_maxRevHalt = true;
         SavePersistentState();
         TransitionTo(STATE_DAILY_HALTED, StringFormat("Loss close at reversal cap (%d) - no reversal, halted until the next trading day.", InpMaxConsecutiveReversals));
         break;

      case CLOSE_REASON_PROFIT:
      case CLOSE_REASON_MAX_HOLDING:
         g_consecutiveReversals = 0;
         ConsumeEntryBar();
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Basket closed; a halt is active.");
         else
         {
            g_cooldownEnd = Now() + InpPostProfitWaitSeconds;
            TransitionTo(STATE_COOLDOWN, "Basket closed (no reversal) - short cooldown, then the next evaluation.");
         }
         break;

      default:   // EXTERNAL / unknown: SL, manual, broker - never reversed
         g_consecutiveReversals = 0;
         ConsumeEntryBar();
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Basket closed externally; a halt is active.");
         else
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Basket closed externally (SL/manual/broker) - no reversal, waiting for a fresh signal.");
         break;
   }
}

// The whole basket is now confirmed gone from the broker: book every position as ONE completed trade, then route.
// Final basket outcome (WIN/LOSS/BREAKEVEN) is always computed from the ACTUAL completed deal history net sum -
// never assumed from the close trigger's name (a basket closed on a "PROFIT" trigger that nets negative after
// commission/swap/slippage is logged as LOSS, not WIN).
void OnBasketClosed(const TradeSummary &sums[])
{
   ENUM_CLOSE_REASON reason = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL;
   uint execRetcode = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_closeRetcode : 0;
   int closedDir = (g_posDir != 0) ? g_posDir : (ArraySize(sums) > 0 ? sums[0].dir : 0);
   int nextDir = (reason == CLOSE_REASON_LOSS_REVERSAL) ? -closedDir : 0;

   double units = (g_posVolume > 0.0) ? (g_posVolume / REF_LOT) : 0.0;
   double maxFloatLossUSD   = (g_troughPerUnit <  1e17) ? MathMax(0.0, -g_troughPerUnit * units) : 0.0;
   double maxFloatProfitUSD = (g_peakPerUnit  > -1e17) ? MathMax(0.0,  g_peakPerUnit  * units) : 0.0;
   double peakProfitUSD     = maxFloatProfitUSD;
   datetime finalCloseTime  = Now();
   datetime closeReqTime    = (g_closeRequestTimeExact != 0) ? g_closeRequestTimeExact : finalCloseTime;
   double latencyMs         = (double)(finalCloseTime - closeReqTime) * 1000.0;

   g_basketNo++;
   double basketNet = 0.0;
   int n = ArraySize(sums);
   for(int i = 0; i < n; i++)
   {
      double net = sums[i].profit + sums[i].commission + sums[i].swap + sums[i].fee;
      basketNet += net;
      g_tradeNumberCounter++;
      g_totalTrades++;
      g_sessionTrades++;
      if(net >= 0.0) { g_totalWins++;   g_totalRealizedProfit += net; }
      else           { g_totalLosses++; g_totalRealizedLoss   += (-net); }
   }

   string outcome = (basketNet > 1e-9) ? "WIN" : (basketNet < -1e-9) ? "LOSS" : "BREAKEVEN";
   for(int i = 0; i < n; i++)
   {
      double net = sums[i].profit + sums[i].commission + sums[i].swap + sums[i].fee;
      LogTradeRow(sums[i], g_basketNo, reason, execRetcode, nextDir, net, maxFloatLossUSD, maxFloatProfitUSD, peakProfitUSD,
                  closeReqTime, finalCloseTime, latencyMs, outcome);
   }

   if(basketNet >= 0.0) { g_basketWins++;   g_basketRealizedProfit += basketNet; g_todayBasketWins++; }
   else                 { g_basketLosses++; g_basketRealizedLoss   += (-basketNet); g_todayBasketLosses++; }

   if(basketNet >= 0.0)
   {
      g_sessionBasketWins++;   g_sessionBasketRealizedProfit += basketNet;
      g_sessionCurConsecWins++; g_sessionCurConsecLosses = 0;
      if(g_sessionCurConsecWins > g_sessionMaxConsecWins) g_sessionMaxConsecWins = g_sessionCurConsecWins;
   }
   else
   {
      g_sessionBasketLosses++; g_sessionBasketRealizedLoss += (-basketNet);
      g_sessionCurConsecLosses++; g_sessionCurConsecWins = 0;
      if(g_sessionCurConsecLosses > g_sessionMaxConsecLosses) g_sessionMaxConsecLosses = g_sessionCurConsecLosses;
   }

   LogInfo(StringFormat("Basket #%d closed: %d positions, net %.2f (%s), reason %s, regime %s, score %.1f.",
                        g_basketNo, n, basketNet, outcome, CloseReasonToString(reason), RegimeToString(g_basketRegime), g_basketSignalScore));

   ClearTracking();
   g_pendingCloseReason = CLOSE_REASON_NONE;
   g_pendingCloseDetail = "";
   g_closeRequestTimeExact = 0;
   g_retryCounter = 0;
   g_lastError = "";
   g_finalizeWaitSince = 0;

   if(!RebuildDailyState())
   {
      g_dailyRealizedPL += basketNet;
      if(InpDailyLossLimitEnabled && g_dailyRealizedPL <= -InpDailyLossLimitUSD + 1e-9) g_dailyHaltFlag = true;
   }
   if(g_dailyHaltFlag)
      LogWarning(StringFormat("Daily loss limit reached (realized=%.2f, limit=%.2f). New entries/reversals are halted for the rest of the broker day.",
                              g_dailyRealizedPL, InpDailyLossLimitUSD));
   SavePersistentState();

   RouteAfterClose(reason, closedDir);
}

// Managed position(s) exist at the broker.
void OnPositionPresent(const PosSnap &s, const ulong &idents[])
{
   if(s.mixed)
   {
      EnterError("BUY and SELL managed positions are both open - this EA only ever holds one direction. Halting for manual review.");
      return;
   }
   if(s.count > MAX_BASKET_HARD)
   {
      EnterError(StringFormat("%d managed positions found - above the hard basket ceiling of %d. Halting for manual review.", s.count, MAX_BASKET_HARD));
      return;
   }

   if(g_posCount > 0 && (s.count < g_posCount || s.volume < g_posVolume - 1e-8))
   {
      LogWarning(StringFormat("Basket shrank: %d -> %d positions, %.2f -> %.2f lots still open.", g_posCount, s.count, g_posVolume, s.volume));
      if(g_pendingCloseReason != CLOSE_REASON_NONE) g_closePartial = true;
   }
   SyncTracking(s, idents);

   switch(g_state)
   {
      case STATE_OPENING_POSITION:
      {
         if(s.dir != g_openDir)
         {
            EnterError(StringFormat("Opened basket direction %s does not match the requested %s.", DirToString(s.dir), DirToString(g_openDir)));
            return;
         }
         if(g_openIntent == INTENT_REVERSAL)
         {
            g_consecutiveReversals++;
            LogInfo(StringFormat("Reversal #%d CONFIRMED: %s basket of %d positions is open.", g_consecutiveReversals, DirToString(s.dir), s.count));
         }
         else
            g_consecutiveReversals = 0;
         g_openIntent = INTENT_NONE;
         g_reversalDir = 0;
         g_retryCounter = 0;
         g_lastError = "";
         g_pendingCloseReason = CLOSE_REASON_NONE;
         g_peakPerUnit = -1e18;
         g_troughPerUnit = 1e18;
         ConsumeEntryBar();
         SavePersistentState();
         EnsureProtectiveStop();
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Confirmed: %s basket %d x %.2f lot (%.2f total) @ %s. Score %.1f, regime %s.",
                      DirToString(s.dir), s.count, (s.count > 0) ? s.volume / s.count : 0.0, s.volume, DoubleToString(s.avgPrice, _Digits),
                      g_basketSignalScore, RegimeToString(g_basketRegime)));
         break;
      }
      case STATE_START_DELAY:
      case STATE_WAITING_INITIAL_SIGNAL:
      case STATE_REVERSAL_PENDING:
      case STATE_COOLDOWN:
      case STATE_DAILY_HALTED:
         g_openIntent = INTENT_NONE;
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Adopted unexpected managed %s basket: %d positions, %.2f lots.", DirToString(s.dir), s.count, s.volume));
         break;
      default:
         break;
   }
}

// No managed position exists at the broker.
void OnPositionAbsent()
{
   int n = ArraySize(g_idents);
   if(n == 0) return;

   TradeSummary sums[];
   ArrayResize(sums, n);
   bool all = true;
   for(int i = 0; i < n; i++)
      if(!BuildTradeSummary(g_idents[i], sums[i], true)) all = false;

   if(!all)
   {
      if(g_finalizeWaitSince == 0) g_finalizeWaitSince = Now();
      if(Now() - g_finalizeWaitSince < FINALIZE_WAIT_SEC) return;

      int missing = 0;
      for(int i = 0; i < n; i++)
      {
         if(BuildTradeSummary(g_idents[i], sums[i], false)) continue;
         missing++;
         ZeroMemory(sums[i]);
         sums[i].ident = g_idents[i]; sums[i].dir = g_posDir; sums[i].volume = g_basketLot;
         sums[i].entryPrice = g_posAvgPrice; sums[i].entryTime = g_posEntryTime; sums[i].exitTime = Now();
      }
      LogWarning(StringFormat("Close history incomplete after %ds: %d of %d positions had no closing deal and are logged from tracked data only.",
                              FINALIZE_WAIT_SEC, missing, n));
   }
   OnBasketClosed(sums);
}

//+------------------------------------------------------------------+
//| The single source of truth for "what position do we really have". |
//+------------------------------------------------------------------+
void Reconcile()
{
   if(g_state == STATE_INITIALIZING || g_state == STATE_ERROR) return;

   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   if(cnt > 0) OnPositionPresent(s, id);
   else        OnPositionAbsent();
}

//================================= ADAPTIVE PROFIT MANAGER HELPERS ====================================
// Optional Partial Close Reconciliation: closes InpPartialCloseFraction of the basket's CURRENT volume once,
// via whole-ticket PositionClose() where that fits (hedging) and PositionClosePartial() for any remainder
// (netting, or the last ticket) - fires at most once per basket (g_partialDone).
bool DoPartialClose()
{
   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   if(cnt == 0 || s.volume <= 0.0) return false;

   double targetVol = s.volume * InpPartialCloseFraction;
   double closedVol = 0.0;
   for(int i = 0; i < cnt && closedVol < targetVol - 1e-9; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      double remaining = targetVol - closedVol;
      if(v <= remaining + 1e-9)
      {
         if(trade.PositionClose(tk[i], (ulong)InpSlippagePoints)) closedVol += v;
      }
      else
      {
         double partVol = ClampLot(remaining);
         if(partVol > 0.0 && partVol < v && trade.PositionClosePartial(tk[i], partVol, (ulong)InpSlippagePoints)) closedVol += partVol;
      }
   }
   if(closedVol > 1e-9)
   {
      LogInfo(StringFormat("Partial close fired: %.2f of %.2f lots closed (target fraction %.2f).", closedVol, s.volume, InpPartialCloseFraction));
      return true;
   }
   return false;
}

//================================= STATE MACHINE TICK LOGIC ====================================
//+------------------------------------------------------------------+
//| Global emergency hook, evaluated BEFORE any state logic. Returns  |
//| true when it fully handled the tick for the current state.        |
//+------------------------------------------------------------------+
bool HandleEmergency()
{
   if(!EmergencyActive()) return false;
   g_emergencyLatched = true;

   switch(g_state)
   {
      case STATE_POSITION_ACTIVE:
      case STATE_EMERGENCY_HALTED:
      {
         PosSnap s;
         if(ScanManaged(s) > 0)
         {
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_EMERGENCY, "EMERGENCY STOP: closing the whole basket, no reversal");
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_EMERGENCY, "Emergency stop - closing the basket. No reversal, no new entries.");
         }
         return true;
      }
      case STATE_START_DELAY:
      case STATE_WAITING_INITIAL_SIGNAL:
      case STATE_REVERSAL_PENDING:
      case STATE_COOLDOWN:
      case STATE_DAILY_HALTED:
      {
         PosSnap s;
         if(ScanManaged(s) == 0)
            TransitionTo(STATE_EMERGENCY_HALTED, "Emergency stop active - no position open, all entries blocked.");
         return true;
      }
      default:
         return false;
   }
}

void RunStateMachine()
{
   if(g_state == STATE_ERROR) return;

   Reconcile();
   if(g_state == STATE_ERROR) return;
   if(HandleEmergency()) return;

   switch(g_state)
   {
      case STATE_INITIALIZING:
         TransitionTo(STATE_START_DELAY, "Unexpected INITIALIZING state observed in a tick - recovering.");
         g_startDelayBegin = Now();
         break;

      case STATE_START_DELAY:
         if(Now() - g_startDelayBegin >= InpStartDelaySeconds)
         {
            if(BlockedByHalt()) TransitionTo(STATE_DAILY_HALTED, "Start delay elapsed but a halt is active.");
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Ready - waiting for a MODE A/B signal.");
         }
         break;

      case STATE_WAITING_INITIAL_SIGNAL:
      {
         if(BlockedByHalt()) { TransitionTo(STATE_DAILY_HALTED, "Halt active - not entering."); g_entryCandidateDir = 0; break; }
         if(!g_indicatorsReady) { g_entryCandidateDir = 0; g_lastAction = "Waiting for indicator data (ATR/RSI/ADX/MA) to become ready..."; break; }
         if(g_lastEvalBar != 0 && g_lastEvalBar == g_lastEntryBarConsumed) { g_entryCandidateDir = 0; break; }   // already acted on this closed bar

         int dir = SelectCandidateDirection(g_regimeLast);
         if(dir == 0)
         {
            g_entryCandidateDir = 0;
            // v5.6: also refresh g_lastRejectReason here (previously only EvaluateEntry() set it, so the
            // MARKET section's "Last rejection" line kept showing a stale MODE A/B reason from before the
            // regime went ambiguous/NONE, even though EXECUTION's "Last" line was already current).
            g_lastRejectReason = StringFormat("MODE C: no-trade right now (regime %s)", RegimeToString(g_regimeLast));
            g_lastAction = StringFormat("MODE C: no-trade right now (regime %s).", RegimeToString(g_regimeLast));
            break;
         }

         ScoreBreakdown sb;
         string reject;
         bool ok = EvaluateEntry(dir, sb, reject);
         if(!ok)
         {
            g_entryCandidateDir = 0;
            g_lastAction = StringFormat("Rejected %s: %s", DirToString(dir), reject);
            break;
         }

         // Entry confirmation hold: the setup must still score and hold for InpEntryConfirmSeconds before opening.
         if(g_entryCandidateDir != dir)
         {
            g_entryCandidateDir = dir;
            g_entryCandidateSince = Now();
            g_lastAction = StringFormat("Confirming %s signal (MODE %s, score %.1f, 0/%ds)...", DirToString(dir), sb.mode, sb.total, InpEntryConfirmSeconds);
            break;
         }
         int heldSec = (int)(Now() - g_entryCandidateSince);
         if(heldSec < InpEntryConfirmSeconds)
         {
            g_lastAction = StringFormat("Confirming %s signal (MODE %s, score %.1f, %d/%ds)...", DirToString(dir), sb.mode, sb.total, heldSec, InpEntryConfirmSeconds);
            break;
         }

         g_pendingConsumeBar = g_lastEvalBar;
         ENUM_REQ_RESULT r = ExecuteOpen(dir, INTENT_INITIAL, sb, g_regimeLast);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
         {
            g_entryCandidateDir = 0;
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Opening %s basket (MODE %s, score %.1f, confirmed %ds).", DirToString(dir), sb.mode, sb.total, InpEntryConfirmSeconds));
         }
         break;
      }

      case STATE_OPENING_POSITION:
         if(Now() - g_openRequestTime >= InpOperationTimeoutSeconds)
         {
            g_retryCounter++;
            LogWarning(StringFormat("Open not confirmed after %ds and no managed position exists (attempt %d/%d).",
                                    InpOperationTimeoutSeconds, g_retryCounter, InpMaxExecutionRetries));
            if(g_retryCounter >= InpMaxExecutionRetries)
            {
               EnterError("Open request was never confirmed by a real position - halting for manual review.");
               break;
            }
            if(g_openIntent == INTENT_REVERSAL)
               TransitionTo(STATE_REVERSAL_PENDING, "Reversal open unconfirmed - retrying.");
            else
            {
               g_openIntent = INTENT_NONE;
               TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Initial open unconfirmed - back to waiting for a signal.");
            }
         }
         break;

      case STATE_POSITION_ACTIVE:
      {
         double pl, units;
         if(!GetFloatingPL(pl, units) || units <= 0.0) break;

         double lossLimit = InpLossThresholdUSD * units;
         double maxProfit = InpProfitTargetUSD * units;

         // Maximum Holding-Time Manager
         if(InpMaxHoldingMinutes > 0 && g_basketOpenTime > 0 && (Now() - g_basketOpenTime) >= InpMaxHoldingMinutes * 60)
         {
            string mdetail = StringFormat("MAX_HOLDING: basket open %d min >= limit %d min (P/L=%.2f)",
                                          (int)((Now() - g_basketOpenTime) / 60), InpMaxHoldingMinutes, pl);
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_MAX_HOLDING, mdetail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_PROFIT, "Maximum holding duration reached - closing the basket (no reversal).");
            break;
         }

         if(pl <= -lossLimit)
         {
            ENUM_CLOSE_REASON reason;
            if(g_dailyHaltFlag || g_maxRevHalt)                          reason = (g_dailyHaltFlag ? CLOSE_REASON_DAILY_LIMIT : CLOSE_REASON_MAX_REVERSALS);
            else if(g_consecutiveReversals >= InpMaxConsecutiveReversals) reason = CLOSE_REASON_MAX_REVERSALS;
            else                                                          reason = CLOSE_REASON_LOSS_REVERSAL;

            string detail = StringFormat("%s: basket P/L=%.2f <= -%.2f", CloseReasonToString(reason), pl, lossLimit);
            ENUM_REQ_RESULT r = ExecuteClose(reason, detail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_LOSS, "Loss threshold hit - closing the basket before any reversal (" + CloseReasonToString(reason) + ").");
            break;
         }

         double perUnit = pl / units;
         if(perUnit > g_peakPerUnit)   g_peakPerUnit   = perUnit;
         if(perUnit < g_troughPerUnit) g_troughPerUnit = perUnit;

         if(InpPartialCloseEnabled && !g_partialDone && perUnit >= InpPartialCloseTriggerUSD)
            if(DoPartialClose()) g_partialDone = true;

         bool closeProfit = false;
         string pdetail = "";
         if(pl >= maxProfit)
         {
            closeProfit = true;
            pdetail = StringFormat("PROFIT max: basket P/L=%.2f >= %.2f", pl, maxProfit);
         }
         else if(g_peakPerUnit >= InpProfitMinUSD)
         {
            double trailDist = InpTrailGivebackUSD;
            if(InpUseATRTrailing && g_atrLast > 0.0)
            {
               double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
               double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
               if(tickSize > 0.0 && tickValue > 0.0)
                  trailDist = (InpATRTrailMultiple * g_atrLast / tickSize) * tickValue * REF_LOT;
            }
            double floorPU = MathMax(InpProfitMinUSD, g_peakPerUnit - trailDist);
            if(InpBreakEvenTriggerUSD > 0.0 && g_peakPerUnit >= InpBreakEvenTriggerUSD) floorPU = MathMax(floorPU, 0.0);
            if(perUnit <= floorPU)
            {
               closeProfit = true;
               pdetail = StringFormat("PROFIT trail: %.3f/0.01lot fell to floor %.3f (peak %.3f, min %.3f, ATR-trail=%s); basket P/L=%.2f",
                                      perUnit, floorPU, g_peakPerUnit, InpProfitMinUSD, InpUseATRTrailing ? "on" : "off", pl);
            }
         }
         if(closeProfit)
         {
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_PROFIT, pdetail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_PROFIT, "Profit target hit - closing the basket, cycle will reset.");
         }
         break;
      }

      case STATE_CLOSING_LOSS:
      case STATE_CLOSING_PROFIT:
      case STATE_CLOSING_EMERGENCY:
      {
         PosSnap s;
         if(ScanManaged(s) == 0) break;
         bool stale = (Now() - g_closeRequestTime >= InpOperationTimeoutSeconds);
         if(g_closePartial || stale)
            ExecuteClose(g_pendingCloseReason != CLOSE_REASON_NONE ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL, g_pendingCloseDetail);
         break;
      }

      case STATE_REVERSAL_PENDING:
      {
         if(BlockedByHalt()) { TransitionTo(STATE_DAILY_HALTED, "Halt active - reversal suppressed."); break; }
         if(g_consecutiveReversals >= InpMaxConsecutiveReversals)
         {
            g_maxRevHalt = true;
            SavePersistentState();
            TransitionTo(STATE_DAILY_HALTED, StringFormat("Reversal cap (%d) reached - reversal suppressed.", InpMaxConsecutiveReversals));
            break;
         }
         if(g_reversalDir == 0)
         {
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "No valid reversal direction - waiting for a fresh signal.");
            break;
         }
         if(Now() < g_reversalCooldownEnd)
         {
            g_lastAction = StringFormat("Reversal cooldown (%ds remaining) before re-evaluation starts...", (int)(g_reversalCooldownEnd - Now()));
            break;
         }
         if(!g_indicatorsReady) { g_lastAction = "Waiting for indicator data before re-evaluating the reversal..."; break; }

         // Specific cancellation: the market has already moved back toward the ORIGINAL direction - chasing a
         // reversal into a direction the market has already left again is exactly the whipsaw this guards against.
         if(g_m5TrendDir != 0 && g_m5TrendDir == -g_reversalDir)
         {
            g_revConfirmDir = 0;
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, StringFormat("Reversal to %s CANCELLED: M5 trend already points back %s - waiting for a fresh signal instead of chasing.", DirToString(g_reversalDir), DirToString(g_m5TrendDir)));
            break;
         }

         ScoreBreakdown sb;
         string reject;
         bool ok = EvaluateEntry(g_reversalDir, sb, reject);
         if(!ok)
         {
            g_revConfirmDir = 0;
            g_lastAction = StringFormat("Reversal %s not yet re-confirmed: %s (retrying each new bar)", DirToString(g_reversalDir), reject);
            break;   // stay in REVERSAL_PENDING - bounded by the reversal cap / halts, not abandoned on a transient miss
         }

         if(g_revConfirmDir != g_reversalDir)
         {
            g_revConfirmDir = g_reversalDir;
            g_revConfirmSince = Now();
            g_lastAction = StringFormat("Confirming reversal %s (score %.1f, 0/%ds)...", DirToString(g_reversalDir), sb.total, InpReversalConfirmSeconds);
            break;
         }
         int revHeldSec = (int)(Now() - g_revConfirmSince);
         if(revHeldSec < InpReversalConfirmSeconds)
         {
            g_lastAction = StringFormat("Confirming reversal %s (score %.1f, %d/%ds)...", DirToString(g_reversalDir), sb.total, revHeldSec, InpReversalConfirmSeconds);
            break;
         }

         g_pendingConsumeBar = g_lastEvalBar;
         ENUM_REQ_RESULT r = ExecuteOpen(g_reversalDir, INTENT_REVERSAL, sb, g_regimeLast);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
         {
            g_revConfirmDir = 0;
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Opening reversal %s basket (MODE %s, score %.1f; will count as reversal #%d on fill).",
                                                               DirToString(g_reversalDir), sb.mode, sb.total, g_consecutiveReversals + 1));
         }
         break;
      }

      case STATE_COOLDOWN:
         if(Now() >= g_cooldownEnd)
         {
            if(BlockedByHalt()) TransitionTo(STATE_DAILY_HALTED, "Cooldown elapsed but a halt is active.");
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Cooldown over - waiting for the next MODE A/B signal.");
         }
         break;

      case STATE_DAILY_HALTED:
         if(!BlockedByHalt())
         {
            g_lastEntryBarConsumed = g_lastEvalBar;   // a stale pre-halt bar must not fire the instant trading resumes
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Halt cleared - resuming, a fresh evaluation bar is required.");
         }
         break;

      case STATE_EMERGENCY_HALTED:
      case STATE_ERROR:
         break;
   }
}

//================================= INSTANCE LOCK ====================================
string LockKey()
{
   return StringFormat("%sLOCK_%I64d_%s_%d", GV_PREFIX, AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagicNumber);
}

// Prevents two live EA instances from managing the same account + symbol + magic.
bool AcquireInstanceLock()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) return true;

   string key = LockKey();
   if(GlobalVariableCheck(key))
   {
      double age = (double)TimeLocal() - GlobalVariableGet(key);
      if(age >= 0.0 && age < LOCK_STALE_SEC)
      {
         Print("INIT REJECTED: another SmartReversalEA instance is already running for this account/symbol/magic (heartbeat ",
               DoubleToString(age, 0), "s old). Use a different magic number or chart.");
         return false;
      }
   }
   GlobalVariableSet(key, (double)TimeLocal());
   g_lockOwned = true;
   return true;
}

void RefreshInstanceLock()
{
   if(g_lockOwned) GlobalVariableSet(LockKey(), (double)TimeLocal());
}

void ReleaseInstanceLock()
{
   if(g_lockOwned) { GlobalVariableDel(LockKey()); g_lockOwned = false; }
}

//================================= INIT / DEINIT ====================================
int OnInit()
{
   // --- DEMO-ONLY GUARD (mandatory, evaluated first, no side effects before it). Never weaken or bypass. ---
   if(!IsDemoAccount())
   {
      Print("INIT REJECTED: this account is not a DEMO account. SmartReversalEA v", EA_VERSION, " refuses to run on live/contest accounts.");
      return INIT_FAILED;
   }

   // MQL5 does NOT reset global variables on a "soft" reinit - OnDeinit/OnInit triggered by a chart
   // symbol/period change (REASON_CHARTCHANGE), an input change (REASON_PARAMETERS), or a MetaEditor
   // recompile hot-reloading an already-attached EA (REASON_RECOMPILE). g_state is a global, so without
   // this it would still hold whatever state the EA was in a moment ago (e.g. WAITING_INITIAL_SIGNAL),
   // and the unconditional TransitionTo() below would then see an illegal transition from THAT instead
   // of a clean start, failing safe into STATE_ERROR. Force a clean state machine on every OnInit, soft
   // or cold, so switching the chart's timeframe (or any input/recompile reload) never bricks the EA.
   g_state = STATE_INITIALIZING;

   if(!ValidateInputs())
   {
      Print("INIT REJECTED: invalid input parameters (see INPUT ERROR lines above).");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolSelect(_Symbol, true))
      Print("WARNING: SymbolSelect failed for ", _Symbol, " (error ", GetLastError(), ")");

   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("INIT REJECTED: symbol trading is disabled by the broker for ", _Symbol);
      return INIT_FAILED;
   }

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpFixedLotSize < minVol - 1e-9 || (maxVol > 0.0 && InpFixedLotSize > maxVol + 1e-9))
   {
      Print("INPUT ERROR: InpFixedLotSize ", DoubleToString(InpFixedLotSize, 4), " is outside the symbol volume limits [",
            DoubleToString(minVol, 4), ", ", DoubleToString(maxVol, 4), "]");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(step > 0.0 && MathAbs(InpFixedLotSize / step - MathRound(InpFixedLotSize / step)) > 1e-6)
   {
      Print("INPUT ERROR: InpFixedLotSize ", DoubleToString(InpFixedLotSize, 4), " is not a multiple of the symbol volume step ", DoubleToString(step, 4));
      return INIT_PARAMETERS_INCORRECT;
   }
   if(CalcBaseLot() <= 0.0)
   {
      Print("INIT REJECTED: the symbol's minimum volume exceeds the lot cap of ", DoubleToString(MathMin(InpMaxLotSize, HARD_MAX_LOT), 2));
      return INIT_FAILED;
   }

   if(!AcquireInstanceLock()) return INIT_FAILED;

   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_isNetting = (mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_marginModeStr = (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) ? "HEDGING" : (mm == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) ? "NETTING" : "EXCHANGE";

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.SetAsyncMode(false);

   maFastHandleM5  = iMA(_Symbol, InpEntryTimeframe,   InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandleM5  = iMA(_Symbol, InpEntryTimeframe,   InpSlowMA, 0, InpMAMethod, InpMAPrice);
   maFastHandleM15 = iMA(_Symbol, InpConfirmTimeframe, InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandleM15 = iMA(_Symbol, InpConfirmTimeframe, InpSlowMA, 0, InpMAMethod, InpMAPrice);
   maFastHandleH1  = iMA(_Symbol, InpTrendTimeframe,   InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandleH1  = iMA(_Symbol, InpTrendTimeframe,   InpSlowMA, 0, InpMAMethod, InpMAPrice);
   atrHandle       = iATR(_Symbol, InpEntryTimeframe, InpATRPeriod);
   rsiHandle       = iRSI(_Symbol, InpEntryTimeframe, InpRSIPeriod, PRICE_CLOSE);
   adxHandle       = iADX(_Symbol, InpEntryTimeframe, InpADXPeriod);
   if(maFastHandleM5 == INVALID_HANDLE || maSlowHandleM5 == INVALID_HANDLE ||
      maFastHandleM15 == INVALID_HANDLE || maSlowHandleM15 == INVALID_HANDLE ||
      maFastHandleH1 == INVALID_HANDLE || maSlowHandleH1 == INVALID_HANDLE ||
      atrHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
   {
      LogError("Failed to create one or more MA/ATR/RSI/ADX indicator handles", GetLastError());
      ReleaseInstanceLock();
      return INIT_FAILED;
   }

   OpenLogFile();
   LogInfo(StringFormat("EA session starting. Smart Reversal EA v%s Symbol=%s Entry=%s Confirm=%s Trend=%s Magic=%d Account=%I64d (%s, DEMO)",
                        EA_VERSION, _Symbol, EnumToString(InpEntryTimeframe), EnumToString(InpConfirmTimeframe), EnumToString(InpTrendTimeframe),
                        InpMagicNumber, AccountInfoInteger(ACCOUNT_LOGIN), g_marginModeStr));
   LogInfo("Single-symbol EA: it only manages " + _Symbol + ". Attach one instance (own magic number) per symbol/chart for several symbols.");
   LogInfo(StringFormat("Basket engine (FIXED - no growth, no randomness): %d positions per basket, fixed lot %.2f, basket volume cap %.2f lots.",
                        InpBasketMax, InpFixedLotSize, InpMaxBasketVolume));
   LogInfo(StringFormat("Signal model: %s. Minimum signal score: %.1f/100. Regime thresholds: ADX>=%.1f=TREND, ADX<=%.1f=RANGE.",
                        EnumToString(InpSignalModel), InpMinSignalScore, InpADXTrendMin, InpADXRangeMax));
   LogInfo(StringFormat("Exits are per %.2f lot and scale with basket volume: reverse at -%.2f, profit trail arms at +%.2f, closes at +%.2f (giveback %.2f, ATR-trail=%s). Max holding: %d min (0=none).",
                        REF_LOT, InpLossThresholdUSD, InpProfitMinUSD, InpProfitTargetUSD, InpTrailGivebackUSD, InpUseATRTrailing ? "on" : "off", InpMaxHoldingMinutes));
   LogInfo(StringFormat("Risk engine: max basket risk %.2f (or %.1f%% equity), max daily floating DD %.2f, max account DD %.1f%%, max margin usage %.1f%%. All amounts in account currency (%s).",
                        InpMaxBasketRiskUSD, InpMaxBasketRiskPctEquity, InpMaxDailyFloatingDrawdownUSD, InpMaxAccountDrawdownPct, InpMaxMarginUsagePct, AccountInfoString(ACCOUNT_CURRENCY)));
   LogInfo(StringFormat("Daily realized-loss limit: %s (limit %.2f). Max consecutive reversals: %d. Reversal cooldown: %ds.",
                        InpDailyLossLimitEnabled ? "ON" : "OFF", InpDailyLossLimitUSD, InpMaxConsecutiveReversals, InpReversalCooldownSeconds));
   LogInfo(StringFormat("Protective stop: %d-point backstop per position - it does NOT guarantee a fixed money loss (gaps, slippage, tick value, spread, execution uncertainty).", InpProtectiveStopPoints));
   if(InpUseSessionFilter)
      LogInfo(StringFormat("Session filter ON: server-time hours %d..%d. Verify this matches your broker's server time (see CLAUDE.md for this PC's known offset).", InpSessionStartHour, InpSessionEndHour));

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double sp = CurrentSpreadPoints();
   if(tv > 0.0 && ts > 0.0 && sp > 0.0)
   {
      double spreadCost = sp * _Point / ts * tv * REF_LOT;
      if(spreadCost >= InpLossThresholdUSD)
         LogWarning(StringFormat("Current spread costs about %.2f per %.2f lot, which is >= InpLossThresholdUSD (%.2f): baskets may reverse immediately after opening.",
                                 spreadCost, REF_LOT, InpLossThresholdUSD));
   }

   g_dailyHaltFlag = false;
   LoadPersistentState();
   LogInfo(StringFormat("Entry confirmation: a signal must hold for %ds before a basket is opened. Reversal re-confirmation: %ds (after a %ds cooldown).",
                        InpEntryConfirmSeconds, InpReversalConfirmSeconds, InpReversalCooldownSeconds));

   PosSnap snap;
   ulong tk[], id[];
   double fl;
   int existing = ScanManagedFull(snap, tk, id, fl);
   g_startDelayBegin = Now();
   g_eaStartTime = Now();
   if(snap.mixed || existing > MAX_BASKET_HARD)
      TransitionTo(STATE_ERROR, StringFormat("Found %d managed positions (mixed directions: %s) on init. Manual intervention required.", existing, snap.mixed ? "yes" : "no"));
   else if(existing >= 1)
   {
      SyncTracking(snap, id);
      g_basketOpenTime = snap.firstTime;   // best available estimate on restart-recovery
      TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Adopted pre-existing %s basket: %d positions, %.2f lots, on restart.", DirToString(snap.dir), snap.count, snap.volume));
   }
   else if(EmergencyActive())
      TransitionTo(STATE_EMERGENCY_HALTED, "Emergency stop input is ON and no position is open - all trading blocked.");
   else
      TransitionTo(STATE_START_DELAY, StringFormat("No existing position - starting %d-second init delay.", InpStartDelaySeconds));

   EventSetTimer(1);
   if(InpShowDashboard) CreateDashboard();
   LogInfo("EA initialized successfully.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistentState();
   LogInfo(StringFormat("Session ending. Reason=%d | THIS SESSION baskets: %d wins / %d losses, net %.2f (%d positions) | LIFETIME baskets: %d wins / %d losses, profit %.2f, loss %.2f, net %.2f | LIFETIME positions: %d trades, %d wins / %d losses, profit %.2f, loss %.2f",
                         reason, g_sessionBasketWins, g_sessionBasketLosses, g_sessionBasketRealizedProfit - g_sessionBasketRealizedLoss, g_sessionTrades,
                         g_basketWins, g_basketLosses, g_basketRealizedProfit, g_basketRealizedLoss, g_basketRealizedProfit - g_basketRealizedLoss,
                         g_totalTrades, g_totalWins, g_totalLosses, g_totalRealizedProfit, g_totalRealizedLoss));
   if(maFastHandleM5  != INVALID_HANDLE) { IndicatorRelease(maFastHandleM5);  maFastHandleM5  = INVALID_HANDLE; }
   if(maSlowHandleM5  != INVALID_HANDLE) { IndicatorRelease(maSlowHandleM5);  maSlowHandleM5  = INVALID_HANDLE; }
   if(maFastHandleM15 != INVALID_HANDLE) { IndicatorRelease(maFastHandleM15); maFastHandleM15 = INVALID_HANDLE; }
   if(maSlowHandleM15 != INVALID_HANDLE) { IndicatorRelease(maSlowHandleM15); maSlowHandleM15 = INVALID_HANDLE; }
   if(maFastHandleH1  != INVALID_HANDLE) { IndicatorRelease(maFastHandleH1);  maFastHandleH1  = INVALID_HANDLE; }
   if(maSlowHandleH1  != INVALID_HANDLE) { IndicatorRelease(maSlowHandleH1);  maSlowHandleH1  = INVALID_HANDLE; }
   if(atrHandle       != INVALID_HANDLE) { IndicatorRelease(atrHandle);       atrHandle       = INVALID_HANDLE; }
   if(rsiHandle       != INVALID_HANDLE) { IndicatorRelease(rsiHandle);       rsiHandle       = INVALID_HANDLE; }
   if(adxHandle       != INVALID_HANDLE) { IndicatorRelease(adxHandle);       adxHandle       = INVALID_HANDLE; }
   RemoveDashboard();
   CloseLogFile();
   ReleaseInstanceLock();
}

//================================= EVENTS ====================================
void EAUpdate()
{
   if(g_inUpdate) return;
   g_inUpdate = true;
   CheckNewDay();
   UpdateSignal();
   RunStateMachine();
   if(InpShowDashboard) UpdateDashboard();
   g_inUpdate = false;
}

void OnTick()  { EAUpdate(); }

void OnTimer()
{
   RefreshInstanceLock();
   EAUpdate();
}

//+------------------------------------------------------------------+
//| Every deal is a trigger to RECONCILE against the real positions - |
//| the deal itself is never trusted as the truth.                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   long   magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   ulong  pid   = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(magic != (long)InpMagicNumber && IdentIndex(pid) < 0) return;

   Reconcile();
   if(InpShowDashboard) UpdateDashboard();
}

//================================= DASHBOARD v5.1 (display-only) ====================================
// Text size is FIXED at a comfortable, readable size on every machine - it never shrinks to "fit".
// Only the panel's width/height adapt to the chart (and only to grow a little on a wider chart,
// never to shrink text below readable). If the chart window is short, the panel simply runs taller
// than the visible chart area (scroll/resize the chart) rather than making the text unreadable.
#define DASH_PREFIX "SRE_DASH_"
#define PANEL_X 10
#define DASH_ROWS 31
#define DASH_ROW_H 16          // fixed row height - readable on any screen
#define DASH_FONT_BASE 9       // fixed body font size
#define DASH_FONT_HEADER 11    // fixed title font size
#define DASH_MAX_CHARS 56      // chars per row before wrapping/truncating (matches panel width below)

int g_dashPanelW = 400;

// Recomputed every time the panel is (re)created: widens a little on a wider chart (never narrower
// than a comfortable default), so the panel still looks right on a bigger monitor - without ever
// touching font size, which stays fixed and readable everywhere.
void ComputeDashboardSizing()
{
   long chartW = (long)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   if(chartW <= 0) chartW = 800;    // chart not sized yet (e.g. very first OnInit tick) - sane fallback
   g_dashPanelW = (int)MathMin(480.0, MathMax(400.0, chartW * 0.5));
}

// Properties are reapplied EVERY call, not only on first creation - a same-named object left over from an
// earlier EA session/version would otherwise silently keep its OLD background/border/visibility (the v4.1 bug).
void CreateRect(string name, int x, int y, int w, int h, color bg, color border)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
}

void CreateLabel(string name, int x, int y, color clr = clrWhite, int size = DASH_FONT_BASE)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   ComputeDashboardSizing();
   ObjectsDeleteAll(0, DASH_PREFIX);
   CreateRect(DASH_PREFIX + "Panel", PANEL_X - 6, 4, g_dashPanelW, DASH_ROWS * DASH_ROW_H + 10, C'8,8,10', clrSilver);
   for(int i = 0; i < DASH_ROWS; i++)
      CreateLabel(DASH_PREFIX + "R" + IntegerToString(i), PANEL_X, 7 + i * DASH_ROW_H, clrWhite, (i == 0) ? DASH_FONT_HEADER : DASH_FONT_BASE);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, DASH_PREFIX);
}

void SetRow(int i, string text, color clr)
{
   string name = DASH_PREFIX + "R" + IntegerToString(i);
   if(StringLen(text) > DASH_MAX_CHARS) text = StringSubstr(text, 0, DASH_MAX_CHARS - 3) + "...";
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

// Used for the two fields whose message text can genuinely run long (last rejection reason, last
// action/error) - wraps onto a second row, breaking at the last space in budget, instead of truncating
// mid-word. Always consumes exactly 2 dashboard rows (the 2nd is left blank when the text is short),
// so every other row keeps a fixed index.
void SetRowWrap2(int &row, string text, color clr)
{
   string line1 = text, line2 = "";
   int budget = DASH_MAX_CHARS;
   if(StringLen(text) > budget)
   {
      int brk = budget, lastSp = -1;
      for(int p = 0; p < budget && p < StringLen(text); p++)
         if(StringGetCharacter(text, p) == ' ') lastSp = p;
      if(lastSp > budget / 2) brk = lastSp;
      line1 = StringSubstr(text, 0, brk);
      line2 = "  " + StringSubstr(text, (lastSp == brk) ? brk + 1 : brk);
      if(StringLen(line2) > budget) line2 = StringSubstr(line2, 0, MathMax(0, budget - 3)) + "...";
   }
   SetRow(row++, line1, clr);
   SetRow(row++, line2, clr);
}

string FormatRunTime(long secs)
{
   if(secs < 0) secs = 0;
   int d = (int)(secs / 86400), h = (int)((secs % 86400) / 3600), m = (int)((secs % 3600) / 60), s = (int)(secs % 60);
   if(d > 0) return StringFormat("%dd %02dh %02dm %02ds", d, h, m, s);
   return StringFormat("%02dh %02dm %02ds", h, m, s);
}

string TfShort(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf == PERIOD_CURRENT ? _Period : tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

void UpdateDashboard()
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   double fl = 0.0, units = 0.0;
   bool haveBasket = GetFloatingPL(fl, units);
   double sp = CurrentSpreadPoints();

   string daily;
   color  dailyClr = clrLime;
   if(!InpDailyLossLimitEnabled) { daily = "OFF"; dailyClr = clrGray; }
   else if(g_dailyHaltFlag)      { daily = "HALTED(loss)"; dailyClr = clrTomato; }
   else if(g_maxRevHalt)         { daily = "HALTED(revcap)"; dailyClr = clrTomato; }
   else                          { daily = "ok"; }
   string emerg = EmergencyActive() ? ((g_state == STATE_EMERGENCY_HALTED) ? "HALTED" : "closing") : "off";

   string posTxt = haveBasket
                 ? StringFormat("%s %d x %.2f = %.2f lot", DirToString(g_posDir), g_posCount, (g_posCount > 0) ? g_posVolume / g_posCount : 0.0, g_posVolume)
                 : "none";
   double u = haveBasket ? units : EstimateBasketVolume() / REF_LOT;

   int sessionBaskets = g_sessionBasketWins + g_sessionBasketLosses;
   double sessionWinRate = (sessionBaskets > 0) ? (100.0 * g_sessionBasketWins / sessionBaskets) : 0.0;
   double sessionNet = g_sessionBasketRealizedProfit - g_sessionBasketRealizedLoss;
   double profitFactor = (g_sessionBasketRealizedLoss > 1e-9) ? (g_sessionBasketRealizedProfit / g_sessionBasketRealizedLoss) : 0.0;
   double avgWin = (g_sessionBasketWins > 0) ? (g_sessionBasketRealizedProfit / g_sessionBasketWins) : 0.0;
   double avgLoss = (g_sessionBasketLosses > 0) ? (g_sessionBasketRealizedLoss / g_sessionBasketLosses) : 0.0;
   double expectancy = (sessionBaskets > 0) ? (sessionNet / sessionBaskets) : 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double accountDDPct = (g_peakEquity > 0.0) ? (100.0 * (g_peakEquity - equity) / g_peakEquity) : 0.0;
   double lifetimeNet = g_basketRealizedProfit - g_basketRealizedLoss;
   string slTxt = "-";
   if(haveBasket)
   {
      double slPrice = 0.0;
      PosSnap sTmp; ulong tk[], id[]; double flTmp;
      if(ScanManagedFull(sTmp, tk, id, flTmp) > 0 && PositionSelectByTicket(tk[0]))
         slPrice = PositionGetDouble(POSITION_SL);
      slTxt = (slPrice > 0.0) ? DoubleToString(slPrice, _Digits) : "none";
   }
   string trailTxt = haveBasket ? ((g_peakPerUnit >= InpProfitMinUSD) ? StringFormat("ARMED peak %.3f/0.01l", g_peakPerUnit) : "not armed yet") : "-";

   int row = 0;
   SetRow(row++, StringFormat("Smart Reversal EA v%s  [DEMO]", EA_VERSION), clrGold);

   SetRow(row++, "-- SYSTEM --------------------------------------", clrSilver);
   SetRow(row++, StringFormat("%s | %s | Entry=%s Confirm=%s Trend=%s", _Symbol, g_marginModeStr, TfShort(InpEntryTimeframe), TfShort(InpConfirmTimeframe), TfShort(InpTrendTimeframe)), clrLime);
   SetRow(row++, "State: " + StateToString(g_state) + "   Model: " + EnumToString(InpSignalModel), (g_state == STATE_ERROR) ? clrTomato : clrSkyBlue);
   SetRow(row++, "Running: " + FormatRunTime((long)(Now() - g_eaStartTime)), clrAqua);

   SetRow(row++, "-- MARKET --------------------------------------", clrSilver);
   SetRow(row++, StringFormat("Regime: %s | H1:%s M15:%s M5:%s", RegimeToString(g_regimeLast), DirToString(g_h1TrendDir), DirToString(g_m15TrendDir), DirToString(g_m5TrendDir)), clrOrange);
   SetRow(row++, StringFormat("RSI %.1f | ADX %.1f | ATR %.5f | Spread %.1fpt", g_rsiLast, g_adxLast, g_atrLast, sp), clrLightGray);
   SetRow(row++, StringFormat("BUY score %.1f | SELL score %.1f | Min %.1f", g_lastScoreBuy, g_lastScoreSell, InpMinSignalScore), clrLightGray);
   SetRowWrap2(row, "Last rejection: " + (g_lastRejectReason == "" ? "-" : g_lastRejectReason), clrGray);

   SetRow(row++, "-- TRADING -------------------------------------", clrSilver);
   SetRow(row++, "Basket: " + posTxt, clrOrange);
   SetRow(row++, haveBasket ? StringFormat("AvgEntry: %s   Risk: %.2f %s", DoubleToString(g_posAvgPrice, _Digits), g_basketInitialRiskUSD, ccy) : "AvgEntry: -", clrLightGray);
   SetRow(row++, StringFormat("Float: %.2f %s | Peak: %s %s | SL: %s", fl, ccy, (haveBasket && g_peakPerUnit > -1e17) ? DoubleToString(g_peakPerUnit * units, 2) : "-", ccy, slTxt),
             (fl < 0.0) ? clrSalmon : clrAqua);
   SetRow(row++, StringFormat("Exit: -%.2f | arm %.2f .. cap %.2f | Trail: %s", InpLossThresholdUSD * u, InpProfitMinUSD * u, InpProfitTargetUSD * u, trailTxt), clrLightGray);
   SetRow(row++, haveBasket ? StringFormat("Score %.1f (MODE %s) | Regime %s", g_basketSignalScore, g_basketMode, RegimeToString(g_basketRegime)) : "Score: -", clrLightGray);

   SetRow(row++, "-- PERFORMANCE -----------------------------------", clrSilver);
   SetRow(row++, StringFormat("SESSION baskets: %d (W%d/L%d) WinRate %.1f%%", sessionBaskets, g_sessionBasketWins, g_sessionBasketLosses, sessionWinRate), clrWhite);
   SetRow(row++, StringFormat("Net %.2f %s | Gross +%.2f -%.2f | PF %.2f", sessionNet, ccy, g_sessionBasketRealizedProfit, g_sessionBasketRealizedLoss, profitFactor),
             (sessionNet >= 0.0) ? clrLime : clrSalmon);
   SetRow(row++, StringFormat("AvgWin %.2f | AvgLoss %.2f | EV/basket %.3f", avgWin, avgLoss, expectancy), clrLightGray);
   SetRow(row++, StringFormat("Max consec: %d wins / %d losses (session)", g_sessionMaxConsecWins, g_sessionMaxConsecLosses), clrLightGray);
   SetRow(row++, StringFormat("TODAY baskets: W%d/L%d   Daily P/L: %.2f %s", g_todayBasketWins, g_todayBasketLosses, g_dailyRealizedPL, ccy),
             (g_dailyRealizedPL >= 0.0) ? clrWhite : clrOrange);
   SetRow(row++, StringFormat("LIFETIME baskets: %d (W%d/L%d) Net %.2f %s", g_basketWins + g_basketLosses, g_basketWins, g_basketLosses, lifetimeNet, ccy), clrLightGray);
   SetRow(row++, StringFormat("Account DD: %.1f%% (limit %.1f%%) | Daily: %s | Emergency: %s", accountDDPct, InpMaxAccountDrawdownPct, daily, emerg),
             (accountDDPct >= InpMaxAccountDrawdownPct || g_dailyHaltFlag || g_maxRevHalt || EmergencyActive()) ? clrTomato : clrWhite);

   SetRow(row++, "-- EXECUTION -------------------------------------", clrSilver);
   SetRow(row++, "Last order: " + (g_lastOrderLabel == "" ? "-" : g_lastOrderLabel), clrLightGray);
   SetRow(row++, StringFormat("Last retcode: %u | Latency: %.0fms", g_lastRetcode, g_lastOrderLatencyMs), clrLightGray);
   SetRow(row++, "Partial close: " + (g_partialDone ? "done this basket" : (InpPartialCloseEnabled ? "armed" : "off")), clrLightGray);
   SetRowWrap2(row, g_lastError == "" ? "Last: " + g_lastAction : "ERR: " + g_lastError, g_lastError == "" ? clrLightGray : clrTomato);

   // Any remaining pre-allocated rows (if DASH_ROWS was sized generously) are left blank.
   for(int i = row; i < DASH_ROWS; i++) SetRow(i, "", clrGray);
}
