//+------------------------------------------------------------------+
//|                                           SmartHedgeEA_v5.7.mq5  |
//|                   Smart Reversal EA v5.7 - SLIM REBUILD           |
//|                                                                  |
//|  DEMO ACCOUNTS ONLY. One chart symbol per EA instance.            |
//|                                                                  |
//|  v5.7 is a deliberate de-scoping of v5.6. The execution core is   |
//|  kept (state machine + transition table, symbol+magic position    |
//|  scan reconciled against real broker positions, retcode-aware     |
//|  orders, GlobalVariable persistence, instance lock, demo guard    |
//|  first in OnInit). Everything that was measured to be dead weight |
//|  or actively harmful is gone:                                     |
//|                                                                  |
//|  REMOVED                                                          |
//|  - The 8-component weighted 0-100 score. Two stacked gates per    |
//|    regime replace it. (v5.0-v5.6 evaluated 21,332 times and       |
//|    accepted 2; 42% of all rejections were the score gate alone.)  |
//|  - The entire reversal engine: REVERSAL_PENDING state, reversal   |
//|    cooldown, reversal confirm hold, InpMaxConsecutiveReversals,   |
//|    LOSS_REVERSAL close reason. Loss-close now always returns to   |
//|    WAITING_SIGNAL for a fresh signal. (LOSS_REVERSAL was the      |
//|    single most frequent loss reason across v3.x/v4.x.)            |
//|  - The pullback wait timer. It was dead code: g_pullbackWaitSince |
//|    was never persisted (every reattach wiped the 75-min clock)    |
//|    and line-2028's reset zeroed it on any single tick back inside |
//|    the zone. Zero "wait timed out" releases in the whole log      |
//|    history. Replaced by a plain hard gate: not near the EMA = no  |
//|    trade, no timer, no forced entry.                              |
//|  - The adaptive profit manager's USD-denominated trail: giveback, |
//|    ATR trail multiple, profit min/target, peak/trough per unit,   |
//|    partial close.                                                 |
//|  - The economic-calendar filter, the score decision-CSV columns.  |
//|                                                                  |
//|  FIXED                                                            |
//|  - Exit shape is now a real 0.5 R. SL = InpStopATRMult x ATR,     |
//|    TP = InpTargetATRMult x ATR, both placed with the order so     |
//|    they survive an EA/terminal outage. Breakeven WR for 0.5 R is  |
//|    66.7%; the old shape (-0.50 loss vs +0.25 trail arm) needed     |
//|    66.7% too but never got there - the history ran 56.8%.         |
//|  - Lifetime BASKET stats are rebuilt on first run (they never     |
//|    were, so the dashboard's basket line and position line could   |
//|    never agree).                                                  |
//|  - Close reason for broker-side SL/TP exits comes from the real   |
//|    DEAL_REASON of the closing deal, not from guessing at prices.  |
//|                                                                  |
//|  No code change can force a specific win rate or guarantee        |
//|  profit. The ATR multiples below are starting values, not          |
//|  statistically proven optima. Backtest before believing them.     |
//+------------------------------------------------------------------+
#property copyright "Sachin Dev Bots"
#property version   "5.7"
#property strict
#property description "DEMO-ONLY Smart Reversal EA v5.7 - slim dual-regime basket engine with 0.5R exits. One chart symbol per EA instance."

#include <Trade\Trade.mqh>

#define EA_VERSION            "5.7"
#define HARD_MAX_LOT          0.50        // absolute per-position lot ceiling, enforced in code
#define REF_LOT               0.01        // stats unit
#define MAX_BASKET_HARD       50          // absolute ceiling on positions in one basket
#define GV_PREFIX             "SRE57_"    // bumped so stale flags from older versions never carry over
#define LOCK_STALE_SEC        15          // duplicate-instance heartbeat older than this is dead
#define FINALIZE_WAIT_SEC     10          // wait for close deals to appear in history
#define HISTORY_LOOKBACK_SEC  (60*86400)  // look-back associating manual/SL deals with our positions
#define SWING_FRACTAL_K       2           // bars each side a swing must beat
#define BASKET_BUCKET_SEC     5           // entry-time bucket used to group history into baskets

//================================= ENUMS ====================================
enum ENUM_SIGNAL_MODEL
{
   SIGNAL_MODEL_TREND_ONLY = 0,   // only MODE A (trend continuation) may trade
   SIGNAL_MODEL_RANGE_ONLY = 1,   // only MODE B (range mean reversion) may trade
   SIGNAL_MODEL_HYBRID     = 2    // MODE A in a trend, MODE B in a range (default)
};

enum ENUM_MARKET_REGIME { REGIME_NONE = 0, REGIME_TREND = 1, REGIME_RANGE = 2 };

enum ENUM_EA_STATE
{
   STATE_INITIALIZING = 0,
   STATE_START_DELAY,
   STATE_WAITING_SIGNAL,
   STATE_OPENING,
   STATE_POSITION_ACTIVE,
   STATE_CLOSING,
   STATE_DAILY_HALTED,
   STATE_EMERGENCY_HALTED,
   STATE_ERROR
};

enum ENUM_CLOSE_REASON
{
   CLOSE_REASON_NONE = 0,     // the EA did not request this close
   CLOSE_REASON_TARGET,       // broker filled our take-profit
   CLOSE_REASON_STOP,         // broker filled our stop-loss (incl. a break-even stop)
   CLOSE_REASON_MAX_HOLDING,  // time stop
   CLOSE_REASON_EMERGENCY,    // emergency stop - never followed by anything
   CLOSE_REASON_EXTERNAL      // manual / stop-out / unknown
};

enum ENUM_REQ_RESULT
{
   REQ_DEFERRED = 0,   // pre-check failed, nothing was sent
   REQ_REJECTED,       // broker definitively rejected
   REQ_ACCEPTED,       // at least one order executed
   REQ_UNCERTAIN       // timeout/connection - outcome unknown, must reconcile
};

//================================= INPUTS ====================================
input group "=== Strategy Model ==="
input ENUM_SIGNAL_MODEL InpSignalModel = SIGNAL_MODEL_HYBRID;

input group "=== Multi-Timeframe Trend (closed candles only) ==="
input ENUM_TIMEFRAMES InpEntryTimeframe   = PERIOD_M5;   // MODE A/B evaluation timeframe
input ENUM_TIMEFRAMES InpConfirmTimeframe = PERIOD_M15;  // confirmation timeframe
input ENUM_TIMEFRAMES InpTrendTimeframe   = PERIOD_H1;   // higher timeframe trend
input int    InpFastMA  = 10;
input int    InpSlowMA  = 30;
input ENUM_MA_METHOD InpMAMethod  = MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== Regime Classifier ==="
input int    InpADXPeriod   = 14;
input double InpADXTrendMin = 22.0;   // ADX >= this AND 3-TF agreement -> MODE A
input double InpADXRangeMax = 18.0;   // ADX <= this -> MODE B. Between the two = no-trade.

input group "=== ATR Volatility Band ==="
input int    InpATRPeriod         = 14;
input int    InpATRNormalLookback = 50;
input double InpATRMinRatio       = 0.4;   // ATR below this x rolling avg = abnormally quiet = no-trade
input double InpATRMaxRatio       = 3.0;   // ATR above this x rolling avg = abnormally volatile = no-trade

input group "=== RSI ==="
input int    InpRSIPeriod     = 14;
input double InpRSIBuyMin     = 50.0;   // MODE A: BUY requires RSI >= this
input double InpRSISellMax    = 50.0;   // MODE A: SELL requires RSI <= this
input double InpRSIOversold   = 30.0;   // MODE B: BUY at support requires RSI <= this
input double InpRSIOverbought = 70.0;   // MODE B: SELL at resistance requires RSI >= this

input group "=== MODE A: pullback gate (hard, no timer) ==="
input double InpMaxChaseATR = 0.75;     // last close may be at most this many ATRs beyond the fast EMA

input group "=== MODE B: range boundaries ==="
input int    InpSwingLookback  = 50;
input double InpZoneClusterATR = 0.5;   // swings this close together are one zone
input double InpRangeZoneATR   = 0.6;   // price must be within this many ATRs of the near zone

input group "=== Exits: fixed 0.5 R (SL and TP are placed WITH the order) ==="
input double InpStopATRMult       = 1.50;   // SL distance = this x ATR
input double InpTargetATRMult     = 0.75;   // TP distance = this x ATR  (0.5 R when stop is 1.5)
input double InpBreakEvenR        = 0.30;   // move SL to entry once profit reaches this fraction of risk (0 = off)
input int    InpMaxHoldingMinutes = 240;    // time stop, closes the whole basket (0 = no limit)

input group "=== Basket Size & Lot (FIXED - no growth, no martingale) ==="
input int    InpBasketMax       = 5;
input double InpFixedLotSize    = 0.01;
input double InpMaxLotSize      = 0.50;
input double InpMaxBasketVolume = 0.05;

input group "=== Independent Risk Engine (pre-entry gates only) ==="
input double InpMaxBasketRiskUSD           = 30.00;
input double InpMaxBasketRiskPctEquity     = 2.0;
input double InpMaxDailyFloatingDrawdownUSD = 20.00;
input double InpMaxAccountDrawdownPct      = 20.0;
input double InpMaxMarginUsagePct          = 50.0;

input group "=== Daily Risk Protections ==="
input bool   InpDailyLossLimitEnabled = true;
input double InpDailyLossLimitUSD     = 5.00;   // realized loss only; blocks NEW entries, never force-closes
input int    InpMaxSpreadPoints       = 30;
input int    InpSlippagePoints        = 10;
input int    InpMaxExecutionRetries   = 3;
input int    InpMinSecondsBetweenRequests = 2;
input bool   InpEmergencyStop         = false;

input group "=== Session Filter (server time) ==="
input bool   InpUseSessionFilter = false;
input int    InpSessionStartHour = 7;
input int    InpSessionEndHour   = 21;

input group "=== Timing ==="
input int    InpStartDelaySeconds    = 3;
input int    InpEntryConfirmSeconds  = 4;    // a signal must still hold this long before opening
input int    InpOperationTimeoutSeconds = 30;

input group "=== Misc ==="
input int    InpMagicNumber  = 20261103;
input string InpTradeComment = "SmartReversalEA";

input group "=== Trade Logging ==="
input bool   InpLogToCSV            = true;
input bool   InpLogCommonFolder     = false;
input bool   InpLogAlsoToExpertsTab = true;
input string InpLogSubFolder        = "SachinDevBotsLog";
input bool   InpLogDecisions        = false;  // second CSV with every accepted/rejected evaluation

input group "=== On-Chart Dashboard (display-only) ==="
input bool   InpShowDashboard = true;

//================================= STRUCTS ====================================
struct PosSnap
{
   bool     valid;
   int      count;
   int      dir;
   bool     mixed;
   double   volume;
   double   avgPrice;
   datetime firstTime;
};

struct DealRec
{
   ulong    ticket;
   ulong    posId;
   long     entry;
   int      dtype;        // DEAL_TYPE of this deal
   datetime time;
   bool     magicOK;
   double   net;          // profit + swap + commission + fee, this deal only
};

struct TradeSummary
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

struct HistBasket        // one reconstructed basket, used only by the first-run lifetime rebuild
{
   long     bucket;
   int      dir;
   double   net;
};

//================================= GLOBALS ====================================
CTrade trade;

int hFastEntry = INVALID_HANDLE, hSlowEntry = INVALID_HANDLE;
int hFastConf  = INVALID_HANDLE, hSlowConf  = INVALID_HANDLE;
int hFastTrend = INVALID_HANDLE, hSlowTrend = INVALID_HANDLE;
int hAtr = INVALID_HANDLE, hRsi = INVALID_HANDLE, hAdx = INVALID_HANDLE;

ENUM_EA_STATE g_state      = STATE_INITIALIZING;
datetime      g_stateSince = 0;
string        g_lastAction = "EA starting";
string        g_lastError  = "";

bool     g_isNetting     = false;
string   g_marginModeStr = "UNKNOWN";
bool     g_lockOwned     = false;
bool     g_inUpdate      = false;

// ---- tracked basket (every tick re-verified against the broker) ----
ulong    g_idents[];
double   g_identCost[];
bool     g_identCostOk[];
int      g_posDir = 0;
double   g_posVolume = 0.0;
int      g_posCount = 0;
double   g_posAvgPrice = 0.0;
datetime g_posEntryTime = 0;
double   g_basketLot = 0.0;

// ---- basket context captured at open ----
datetime g_basketOpenTime = 0;
ENUM_MARKET_REGIME g_basketRegime = REGIME_NONE;
string   g_basketMode = "";
int      g_basketH1Dir = 0, g_basketM15Dir = 0, g_basketM5Dir = 0;
double   g_basketRSI = 0.0, g_basketADX = 0.0, g_basketATR = 0.0;
double   g_basketSpreadEntry = 0.0;
double   g_basketInitialRiskUSD = 0.0;
double   g_basketSL = 0.0, g_basketTP = 0.0;
double   g_basketEntryRef = 0.0;      // price the break-even stop was moved to
bool     g_beDone = false;

// ---- pending close request ----
ENUM_CLOSE_REASON g_pendingCloseReason = CLOSE_REASON_NONE;
string   g_pendingCloseDetail = "";
uint     g_closeRetcode = 0;
datetime g_closeRequestTime = 0;
datetime g_closeRequestTimeExact = 0;
bool     g_closeIncomplete = false;

int      g_openDir = 0;
datetime g_openRequestTime = 0;
int      g_retryCounter = 0;
datetime g_nextRequestAllowed = 0;
datetime g_finalizeWaitSince = 0;
bool     g_emergencyLatched = false;

// ---- signal state (closed candles only) ----
datetime g_lastEvalBar = 0;
datetime g_lastEntryBarConsumed = 0;
datetime g_pendingConsumeBar = 0;
int      g_entryDir = 0, g_confDir = 0, g_trendDir = 0;
double   g_fastEmaEntry = 0.0;
double   g_rsiLast = 50.0, g_adxLast = 0.0, g_atrLast = 0.0, g_atrAvgLast = 0.0;
bool     g_indicatorsReady = false;
ENUM_MARKET_REGIME g_regimeLast = REGIME_NONE;
datetime g_eaStartTime = 0;

// ---- latest verdict, for the dashboard ----
string g_lastRejectReason = "";
string g_lastDecisionKey  = "";

// ---- swing zones ----
double g_nearestResistance = 0.0;
double g_nearestSupport    = 0.0;

// ---- timing ----
datetime g_startDelayBegin = 0;
int      g_entryCandidateDir = 0;
datetime g_entryCandidateSince = 0;

// ---- daily protection (persisted) ----
datetime g_currentDay      = 0;
double   g_dailyRealizedPL = 0.0;
bool     g_dailyHaltFlag   = false;
int      g_basketNo        = 0;

double   g_dayStartEquity = 0.0;
double   g_peakEquity     = 0.0;

// ---- lifetime, POSITION level (persisted) ----
int    g_totalTrades = 0, g_totalWins = 0, g_totalLosses = 0, g_tradeNumberCounter = 0;
double g_totalRealizedProfit = 0.0, g_totalRealizedLoss = 0.0;

// ---- lifetime, BASKET level (persisted, rebuilt on first run) ----
int    g_basketWins = 0, g_basketLosses = 0;
double g_basketRealizedProfit = 0.0, g_basketRealizedLoss = 0.0;

// ---- THIS SESSION, basket + position level (NOT persisted) ----
int    g_sessionBasketWins = 0, g_sessionBasketLosses = 0;
double g_sessionBasketRealizedProfit = 0.0, g_sessionBasketRealizedLoss = 0.0;
int    g_sessionTrades = 0;
int    g_sessionCurConsecWins = 0, g_sessionCurConsecLosses = 0;
int    g_sessionMaxConsecWins = 0, g_sessionMaxConsecLosses = 0;

// ---- TODAY, basket level ----
int g_todayBasketWins = 0, g_todayBasketLosses = 0;

// ---- execution instrumentation ----
double g_lastOrderLatencyMs = 0.0;
uint   g_lastRetcode = 0;
string g_lastErrorDetail = "";
string g_lastOrderLabel = "";

// ---- CSV ----
int    gLogHandle = INVALID_HANDLE;
string gLogFileName = "";
int    gDecisionLogHandle = INVALID_HANDLE;
string gDecisionLogFileName = "";

//================================= SMALL HELPERS ====================================
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
bool BlockedByHalt()   { return g_dailyHaltFlag; }

bool ThrottleOk(const int slot, const int seconds)
{
   static datetime last[32];
   datetime t = Now();
   if(t - last[slot] < seconds) return false;
   last[slot] = t;
   return true;
}

void LogInfo(string d)    { if(InpLogAlsoToExpertsTab) PrintFormat("[INFO] %s", d); }
void LogWarning(string d) { if(InpLogAlsoToExpertsTab) PrintFormat("[WARNING] %s", d); }
void LogError(string d, int rc = 0)
{
   PrintFormat("[ERROR] retcode=%d | %s", rc, d);   // errors are never silenced
   g_lastError = d;
}

string GVKey(string suffix)
{
   return StringFormat("%s%I64d_%s_%d_%s", GV_PREFIX, AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagicNumber, suffix);
}

string StateToString(ENUM_EA_STATE s)
{
   switch(s)
   {
      case STATE_INITIALIZING:      return "INITIALIZING";
      case STATE_START_DELAY:       return "START_DELAY";
      case STATE_WAITING_SIGNAL:    return "WAITING_SIGNAL";
      case STATE_OPENING:           return "OPENING";
      case STATE_POSITION_ACTIVE:   return "POSITION_ACTIVE";
      case STATE_CLOSING:           return "CLOSING";
      case STATE_DAILY_HALTED:      return "DAILY_HALTED";
      case STATE_EMERGENCY_HALTED:  return "EMERGENCY_HALTED";
      case STATE_ERROR:             return "ERROR";
   }
   return "UNKNOWN";
}

string CloseReasonToString(ENUM_CLOSE_REASON r)
{
   switch(r)
   {
      case CLOSE_REASON_NONE:         return "NONE";
      case CLOSE_REASON_TARGET:       return "TARGET";
      case CLOSE_REASON_STOP:         return "STOP";
      case CLOSE_REASON_MAX_HOLDING:  return "MAX_HOLDING";
      case CLOSE_REASON_EMERGENCY:    return "EMERGENCY";
      case CLOSE_REASON_EXTERNAL:     return "EXTERNAL";
   }
   return "UNKNOWN";
}

string DirToString(int d) { return (d == 1) ? "BUY" : (d == -1) ? "SELL" : "NONE"; }
string RegimeToString(ENUM_MARKET_REGIME r) { return (r == REGIME_TREND) ? "TREND" : (r == REGIME_RANGE) ? "RANGE" : "NONE"; }

//================================= INPUT VALIDATION ====================================
bool InputError(string msg) { Print("INPUT ERROR: ", msg); return false; }

bool ValidateInputs()
{
   bool ok = true;
   if(InpFastMA < 1)                          ok = InputError(StringFormat("InpFastMA must be >= 1 (got %d)", InpFastMA));
   if(InpSlowMA <= InpFastMA)                 ok = InputError(StringFormat("InpSlowMA (%d) must be > InpFastMA (%d)", InpSlowMA, InpFastMA));
   if(InpADXRangeMax >= InpADXTrendMin)       ok = InputError(StringFormat("InpADXRangeMax (%.1f) must be < InpADXTrendMin (%.1f)", InpADXRangeMax, InpADXTrendMin));
   if(InpATRPeriod < 1)                       ok = InputError(StringFormat("InpATRPeriod must be >= 1 (got %d)", InpATRPeriod));
   if(InpADXPeriod < 1)                       ok = InputError(StringFormat("InpADXPeriod must be >= 1 (got %d)", InpADXPeriod));
   if(InpATRNormalLookback < 5)               ok = InputError(StringFormat("InpATRNormalLookback must be >= 5 (got %d)", InpATRNormalLookback));
   if(InpATRMinRatio <= 0.0 || InpATRMinRatio >= 1.0) ok = InputError(StringFormat("InpATRMinRatio must be within (0,1) (got %.2f)", InpATRMinRatio));
   if(InpATRMaxRatio <= 1.0)                  ok = InputError(StringFormat("InpATRMaxRatio must be > 1 (got %.2f)", InpATRMaxRatio));
   if(InpRSIPeriod < 1)                       ok = InputError(StringFormat("InpRSIPeriod must be >= 1 (got %d)", InpRSIPeriod));
   if(InpRSIBuyMin < 0.0 || InpRSIBuyMin > 100.0 || InpRSISellMax < 0.0 || InpRSISellMax > 100.0)
                                              ok = InputError("InpRSIBuyMin/InpRSISellMax must be within 0..100");
   if(InpRSIOversold < 0.0 || InpRSIOversold > 100.0 || InpRSIOverbought < 0.0 || InpRSIOverbought > 100.0 || InpRSIOversold >= InpRSIOverbought)
                                              ok = InputError("InpRSIOversold/InpRSIOverbought must be within 0..100 with oversold < overbought");
   if(InpMaxChaseATR <= 0.0)                  ok = InputError(StringFormat("InpMaxChaseATR must be > 0 (got %.2f)", InpMaxChaseATR));
   if(InpSwingLookback < 10)                  ok = InputError(StringFormat("InpSwingLookback must be >= 10 (got %d)", InpSwingLookback));
   if(InpZoneClusterATR <= 0.0)               ok = InputError(StringFormat("InpZoneClusterATR must be > 0 (got %.2f)", InpZoneClusterATR));
   if(InpRangeZoneATR <= 0.0)                 ok = InputError(StringFormat("InpRangeZoneATR must be > 0 (got %.2f)", InpRangeZoneATR));
   if(InpStopATRMult <= 0.0)                  ok = InputError(StringFormat("InpStopATRMult must be > 0 (got %.2f)", InpStopATRMult));
   if(InpTargetATRMult <= 0.0)                ok = InputError(StringFormat("InpTargetATRMult must be > 0 (got %.2f)", InpTargetATRMult));
   if(InpBreakEvenR < 0.0)                    ok = InputError(StringFormat("InpBreakEvenR must be >= 0 (got %.2f)", InpBreakEvenR));
   if(InpMaxHoldingMinutes < 0)               ok = InputError(StringFormat("InpMaxHoldingMinutes must be >= 0 (got %d)", InpMaxHoldingMinutes));
   if(InpFixedLotSize <= 0.0)                 ok = InputError(StringFormat("InpFixedLotSize must be > 0 (got %.4f)", InpFixedLotSize));
   if(InpMaxLotSize <= 0.0 || InpMaxLotSize > HARD_MAX_LOT + 1e-9)
                                              ok = InputError(StringFormat("InpMaxLotSize must be within (0, %.2f]", HARD_MAX_LOT));
   if(InpFixedLotSize > InpMaxLotSize + 1e-9) ok = InputError("InpFixedLotSize must not exceed InpMaxLotSize");
   if(InpMaxBasketVolume < InpFixedLotSize - 1e-9)
                                              ok = InputError("InpMaxBasketVolume must be at least one InpFixedLotSize position");
   if(InpBasketMax < 1 || InpBasketMax > MAX_BASKET_HARD)
                                              ok = InputError(StringFormat("InpBasketMax must be within 1..%d (got %d)", MAX_BASKET_HARD, InpBasketMax));
   if(InpMaxBasketRiskUSD <= 0.0)             ok = InputError("InpMaxBasketRiskUSD must be > 0");
   if(InpMaxBasketRiskPctEquity <= 0.0 || InpMaxBasketRiskPctEquity > 100.0) ok = InputError("InpMaxBasketRiskPctEquity must be within (0,100]");
   if(InpMaxDailyFloatingDrawdownUSD <= 0.0)  ok = InputError("InpMaxDailyFloatingDrawdownUSD must be > 0");
   if(InpMaxAccountDrawdownPct <= 0.0 || InpMaxAccountDrawdownPct > 100.0) ok = InputError("InpMaxAccountDrawdownPct must be within (0,100]");
   if(InpMaxMarginUsagePct <= 0.0 || InpMaxMarginUsagePct > 100.0)        ok = InputError("InpMaxMarginUsagePct must be within (0,100]");
   if(InpDailyLossLimitEnabled && InpDailyLossLimitUSD <= 0.0)            ok = InputError("InpDailyLossLimitUSD must be > 0 when the limit is enabled");
   if(InpMaxSpreadPoints <= 0)                ok = InputError("InpMaxSpreadPoints must be > 0");
   if(InpSlippagePoints < 0)                  ok = InputError("InpSlippagePoints must be >= 0");
   if(InpMaxExecutionRetries < 1 || InpMaxExecutionRetries > 10) ok = InputError("InpMaxExecutionRetries must be within 1..10");
   if(InpMinSecondsBetweenRequests < 0 || InpMinSecondsBetweenRequests > 3600) ok = InputError("InpMinSecondsBetweenRequests must be within 0..3600");
   if(InpUseSessionFilter && (InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 1 || InpSessionEndHour > 24 || InpSessionEndHour <= InpSessionStartHour))
                                              ok = InputError("Session range must be a valid 0..24 server-time range with End > Start");
   if(InpStartDelaySeconds < 0)               ok = InputError("InpStartDelaySeconds must be >= 0");
   if(InpEntryConfirmSeconds < 0 || InpEntryConfirmSeconds > 60) ok = InputError("InpEntryConfirmSeconds must be within 0..60");
   if(InpOperationTimeoutSeconds < 5)         ok = InputError("InpOperationTimeoutSeconds must be >= 5");
   if(InpMagicNumber <= 0)                    ok = InputError("InpMagicNumber must be > 0 (0 is the manual-trade magic)");
   if(StringLen(InpTradeComment) > 31)        ok = InputError("InpTradeComment must be at most 31 characters");
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
   return (sp >= 0.0 && sp <= (double)InpMaxSpreadPoints);
}

bool DirectionAllowed(int direction)
{
   switch((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
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

bool NettingForeignConflict()
{
   if(!g_isNetting) return false;
   if(PositionSelect(_Symbol)) return (PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber);
   return false;
}

bool SessionOk()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime t;
   TimeToStruct(Now(), t);
   if(InpSessionStartHour <= InpSessionEndHour) return (t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour);
   return (t.hour >= InpSessionStartHour || t.hour < InpSessionEndHour);
}

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

   int digits = 0;
   double s = step;
   while(s < 0.999999 && digits < 8) { s *= 10.0; digits++; }
   norm = NormalizeDouble(norm, digits);
   if(norm < minVol - 1e-12 || norm > hardCap + 1e-12) return 0.0;
   return norm;
}

double CurrentLot() { return ClampLot(InpFixedLotSize); }
int    CurrentBasketSize() { return InpBasketMax; }

double EstimateBasketVolume()
{
   double lot = CurrentLot();
   if(lot <= 0.0) return 0.0;
   int n = MathMin(CurrentBasketSize(), (int)MathFloor(InpMaxBasketVolume / lot + 1e-9));
   if(n < 1) n = 1;
   return n * lot;
}

//================================= STOP / TARGET (the 0.5 R shape) ====================================
// SL and TP are both ATR-derived and both are sent WITH the order, so they survive an EA or
// terminal outage. riskDist is the price distance the broker-side stop actually represents -
// it is what the risk engine prices, not a point count.
bool ComputeStopTarget(int dir, double &sl, double &tp, double &riskDist, string &why)
{
   sl = 0.0; tp = 0.0; riskDist = 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || ask < bid) { why = "no valid quote"; return false; }
   if(g_atrLast <= 0.0)                      { why = "no ATR value yet"; return false; }
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = _Point;

   int stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double spreadPts  = (ask - bid) / _Point;
   double minDistPts = (double)MathMax(stopsLevel, freezeLevel) + spreadPts + 2.0;

   double slDist = MathMax(InpStopATRMult * g_atrLast, minDistPts * _Point);
   double tpDist = MathMax(InpTargetATRMult * g_atrLast, minDistPts * _Point);

   if(dir == 1)
   {
      sl = MathFloor((ask - slDist) / tick + 1e-9) * tick;   // round away from price
      tp = MathCeil ((ask + tpDist) / tick - 1e-9) * tick;
      riskDist = bid - sl;
      if(bid - sl < stopsLevel * _Point) { why = "stop inside broker stop level"; return false; }
   }
   else
   {
      sl = MathCeil ((bid + slDist) / tick - 1e-9) * tick;
      tp = MathFloor((bid - tpDist) / tick + 1e-9) * tick;
      riskDist = sl - ask;
      if(sl - ask < stopsLevel * _Point) { why = "stop inside broker stop level"; return false; }
   }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   if(sl <= 0.0 || tp <= 0.0 || riskDist <= 0.0) { why = "computed stop/target is not positive"; return false; }
   return true;
}

double RiskUSD(double dist, double volume)
{
   if(dist <= 0.0 || volume <= 0.0) return 0.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   return (dist / tickSize) * tickValue * volume;
}

//================================= PERSISTENCE ====================================
void SavePersistentState()
{
   GlobalVariableSet(GVKey("Day"),        (double)g_currentDay);
   GlobalVariableSet(GVKey("DailyHalt"),  g_dailyHaltFlag ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("DailyLimit"), InpDailyLossLimitUSD);
   GlobalVariableSet(GVKey("BasketNo"),   (double)g_basketNo);
   GlobalVariableSet(GVKey("EntryBarUsed"), (double)g_lastEntryBarConsumed);
   GlobalVariableSet(GVKey("TradeNo"),    (double)g_tradeNumberCounter);
   GlobalVariableSet(GVKey("TotTrades"),  (double)g_totalTrades);
   GlobalVariableSet(GVKey("TotWins"),    (double)g_totalWins);
   GlobalVariableSet(GVKey("TotLosses"),  (double)g_totalLosses);
   GlobalVariableSet(GVKey("TotProfit"),  g_totalRealizedProfit);
   GlobalVariableSet(GVKey("TotLoss"),    g_totalRealizedLoss);
   GlobalVariableSet(GVKey("BWins"),      (double)g_basketWins);
   GlobalVariableSet(GVKey("BLosses"),    (double)g_basketLosses);
   GlobalVariableSet(GVKey("BProfit"),    g_basketRealizedProfit);
   GlobalVariableSet(GVKey("BLoss"),      g_basketRealizedLoss);
   GlobalVariableSet(GVKey("DayStartEq"), g_dayStartEquity);
   GlobalVariableSet(GVKey("PeakEq"),     g_peakEquity);
}

//================================= DEAL HISTORY ====================================
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
      r.dtype   = (int)type;
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

// A position is ours if ANY of its deals carries our magic; manual closes carry magic 0, so
// matching on the position id (never the close deal's magic) is what keeps them attributed.
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

// Authoritative rebuild of today's realized P/L. The halt is STICKY for the rest of the broker
// day: it can be set here but is only ever cleared by a new day.
bool RebuildDailyState()
{
   double pl;
   if(ComputeDailyRealizedPL(g_currentDay, pl))
   {
      g_dailyRealizedPL = pl;
      if(InpDailyLossLimitEnabled && pl <= -InpDailyLossLimitUSD + 1e-9) g_dailyHaltFlag = true;
      return true;
   }
   LogWarning("Daily P/L history rebuild failed (HistorySelect) - keeping last known values.");
   return false;
}

//+------------------------------------------------------------------+
//| First run only: rebuild BOTH lifetime scopes from account history.|
//| v5.6 rebuilt positions but never baskets, so the dashboard's two |
//| lifetime lines could never agree. Baskets are grouped by a 5-    |
//| second entry-time bucket (one basket opens in a single tight     |
//| loop), which is an estimate - but a consistent, always-same-one  |
//| estimate rather than a number that silently reset to zero.        |
//+------------------------------------------------------------------+
void ReconstructLifetimeFromHistory()
{
   g_totalTrades = 0; g_totalWins = 0; g_totalLosses = 0;
   g_totalRealizedProfit = 0.0; g_totalRealizedLoss = 0.0; g_tradeNumberCounter = 0;
   g_basketWins = 0; g_basketLosses = 0;
   g_basketRealizedProfit = 0.0; g_basketRealizedLoss = 0.0;

   DealRec recs[];
   if(!LoadDeals(0, recs)) { LogWarning("Lifetime history reconstruction failed (HistorySelect)."); return; }
   ulong ours[];
   BuildOurPositionIds(recs, ours);

   int m = ArraySize(ours);
   double nets[]; datetime inT[]; int dirs[]; bool closed[];
   ArrayResize(nets, m); ArrayResize(inT, m); ArrayResize(dirs, m); ArrayResize(closed, m);
   ArrayInitialize(nets, 0.0); ArrayInitialize(inT, 0); ArrayInitialize(dirs, 0); ArrayInitialize(closed, false);

   int n = ArraySize(recs);
   for(int i = 0; i < n; i++)
   {
      int idx = IndexOfId(ours, recs[i].posId);
      if(idx < 0) continue;
      nets[idx] += recs[i].net;
      if(recs[i].entry != DEAL_ENTRY_IN) closed[idx] = true;
      else
      {
         if(inT[idx] == 0 || recs[i].time < inT[idx]) inT[idx] = recs[i].time;
         dirs[idx] = (recs[i].dtype == (int)DEAL_TYPE_BUY) ? 1 : -1;
      }
   }

   HistBasket baskets[];
   ArrayResize(baskets, 0);
   for(int k = 0; k < m; k++)
   {
      if(!closed[k]) continue;
      g_totalTrades++; g_tradeNumberCounter++;
      if(nets[k] >= 0.0) { g_totalWins++;   g_totalRealizedProfit += nets[k]; }
      else               { g_totalLosses++; g_totalRealizedLoss   += (-nets[k]); }

      long bucket = (long)(inT[k] / BASKET_BUCKET_SEC);
      int b = -1;
      for(int j = 0; j < ArraySize(baskets); j++)
         if(baskets[j].bucket == bucket && baskets[j].dir == dirs[k]) { b = j; break; }
      if(b < 0)
      {
         int cnt = ArraySize(baskets);
         ArrayResize(baskets, cnt + 1);
         baskets[cnt].bucket = bucket;
         baskets[cnt].dir    = dirs[k];
         baskets[cnt].net    = 0.0;
         b = cnt;
      }
      baskets[b].net += nets[k];
   }

   for(int q = 0; q < ArraySize(baskets); q++)
   {
      if(baskets[q].net >= 0.0) { g_basketWins++;   g_basketRealizedProfit += baskets[q].net; }
      else                      { g_basketLosses++; g_basketRealizedLoss   += (-baskets[q].net); }
   }
}

void LoadPersistentState()
{
   g_currentDay = DayStart(Now());

   if(GlobalVariableCheck(GVKey("Day")))
   {
      datetime savedDay = (datetime)(long)GlobalVariableGet(GVKey("Day"));
      g_basketNo           = (int)GlobalVariableGet(GVKey("BasketNo"));
      g_lastEntryBarConsumed = (datetime)(long)GlobalVariableGet(GVKey("EntryBarUsed"));
      g_tradeNumberCounter = (int)GlobalVariableGet(GVKey("TradeNo"));
      g_totalTrades        = (int)GlobalVariableGet(GVKey("TotTrades"));
      g_totalWins          = (int)GlobalVariableGet(GVKey("TotWins"));
      g_totalLosses        = (int)GlobalVariableGet(GVKey("TotLosses"));
      g_totalRealizedProfit = GlobalVariableGet(GVKey("TotProfit"));
      g_totalRealizedLoss   = GlobalVariableGet(GVKey("TotLoss"));
      g_basketWins          = (int)GlobalVariableGet(GVKey("BWins"));
      g_basketLosses        = (int)GlobalVariableGet(GVKey("BLosses"));
      g_basketRealizedProfit = GlobalVariableGet(GVKey("BProfit"));
      g_basketRealizedLoss   = GlobalVariableGet(GVKey("BLoss"));
      g_dayStartEquity = GlobalVariableCheck(GVKey("DayStartEq")) ? GlobalVariableGet(GVKey("DayStartEq")) : AccountInfoDouble(ACCOUNT_EQUITY);
      g_peakEquity     = GlobalVariableCheck(GVKey("PeakEq"))     ? GlobalVariableGet(GVKey("PeakEq"))     : AccountInfoDouble(ACCOUNT_EQUITY);

      if(savedDay != g_currentDay)
      {
         g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         LogInfo("Trading day changed while the EA was offline - day-start equity re-anchored.");
      }
      RebuildDailyState();
   }
   else
   {
      ReconstructLifetimeFromHistory();
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
      LogInfo(StringFormat("First run for this account/symbol/magic - lifetime rebuilt from history (%d positions, %d baskets).",
                           g_totalTrades, g_basketWins + g_basketLosses));
   }

   g_dailyHaltFlag = false;   // a fresh attach must never inherit a stale halt
   RebuildDailyState();
   SavePersistentState();
}

void CheckNewDay()
{
   datetime today = DayStart(Now());
   if(today == g_currentDay) return;
   g_currentDay = today;
   g_dailyHaltFlag = false;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_todayBasketWins = 0;
   g_todayBasketLosses = 0;
   RebuildDailyState();
   SavePersistentState();
   LogInfo("New broker-server trading day - daily P/L rebuilt, halt cleared, day-start equity re-anchored.");
}

//================================= CSV LOGGING ====================================
void OpenLogFile()
{
   if(!InpLogToCSV) return;
   if(InpLogSubFolder != "") FolderCreate(InpLogSubFolder, InpLogCommonFolder ? FILE_COMMON : 0);

   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   string base = StringFormat("SmartReversalEA_v57_%s_%d_%04d%02d%02d_%02d%02d%02d.csv",
                              _Symbol, InpMagicNumber, dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   gLogFileName = (InpLogSubFolder != "") ? (InpLogSubFolder + "\\" + base) : base;

   int flags = FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ;
   if(InpLogCommonFolder) flags |= FILE_COMMON;

   gLogHandle = FileOpen(gLogFileName, flags, ',');
   if(gLogHandle == INVALID_HANDLE)
   {
      Print("LOGGER: failed to open '", gLogFileName, "', error=", GetLastError());
      return;
   }
   FileWrite(gLogHandle,
             "LoggedAt", "TradeNo", "BasketNo", "PositionID", "Symbol", "Magic", "Direction", "Volume",
             "EntryTF", "Regime", "Mode", "H1Trend", "M15Trend", "M5Trend", "RSI", "ADX", "ATR",
             "SpreadAtEntry", "SpreadAtExit",
             "EntryTime", "EntryPrice", "ExitTime", "ExitPrice",
             "InitialRiskUSD", "GrossProfit", "Commission", "Swap", "Fee", "NetPL",
             "CloseTrigger", "CloseRequestTime", "FinalCloseTime", "ExecutionLatencyMs",
             "CloseDealTicket", "ExecRetcode", "FinalBasketOutcome", "Currency");
   FileFlush(gLogHandle);

   if(!InpLogDecisions) return;
   string dec = StringFormat("SmartReversalEA_v57_%s_%d_%04d%02d%02d_%02d%02d%02d_Decisions.csv",
                             _Symbol, InpMagicNumber, dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   gDecisionLogFileName = (InpLogSubFolder != "") ? (InpLogSubFolder + "\\" + dec) : dec;
   gDecisionLogHandle = FileOpen(gDecisionLogFileName, flags, ',');
   if(gDecisionLogHandle == INVALID_HANDLE)
   {
      Print("LOGGER: failed to open decision log '", gDecisionLogFileName, "', error=", GetLastError());
      return;
   }
   FileWrite(gDecisionLogHandle, "LoggedAt", "Symbol", "Direction", "Regime", "Mode",
                                 "H1Trend", "M15Trend", "M5Trend", "RSI", "ADX", "ATR", "Spread",
                                 "Accepted", "Reason");
   FileFlush(gDecisionLogHandle);
}

void CloseLogFile()
{
   if(gLogHandle != INVALID_HANDLE)        { FileClose(gLogHandle);        gLogHandle = INVALID_HANDLE; }
   if(gDecisionLogHandle != INVALID_HANDLE){ FileClose(gDecisionLogHandle);gDecisionLogHandle = INVALID_HANDLE; }
}

void LogTradeRow(const TradeSummary &s, int basketNo, ENUM_CLOSE_REASON reason, uint rc, double net, string outcome,
                 datetime closeReqTime, datetime finalCloseTime, double latencyMs)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   if(InpLogAlsoToExpertsTab)
      PrintFormat("[TRADE #%d basket %d] pos=%I64u %s vol=%.2f entry=%s exit=%s net=%.2f %s reason=%s outcome=%s closeDeal=%I64u retcode=%u",
                  g_tradeNumberCounter, basketNo, s.ident, DirToString(s.dir), s.volume,
                  DoubleToString(s.entryPrice, _Digits), DoubleToString(s.exitPrice, _Digits),
                  net, ccy, CloseReasonToString(reason), outcome, s.closeDeal, rc);

   if(gLogHandle == INVALID_HANDLE) return;
   FileWrite(gLogHandle,
             TimeToString(Now(), TIME_DATE | TIME_SECONDS), g_tradeNumberCounter, basketNo, (string)s.ident, _Symbol, InpMagicNumber,
             DirToString(s.dir), DoubleToString(s.volume, 2),
             EnumToString(InpEntryTimeframe), RegimeToString(g_basketRegime), g_basketMode,
             DirToString(g_basketH1Dir), DirToString(g_basketM15Dir), DirToString(g_basketM5Dir),
             DoubleToString(g_basketRSI, 1), DoubleToString(g_basketADX, 1), DoubleToString(g_basketATR, 5),
             DoubleToString(g_basketSpreadEntry, 1), DoubleToString(CurrentSpreadPoints(), 1),
             TimeToString(s.entryTime, TIME_DATE | TIME_SECONDS), DoubleToString(s.entryPrice, _Digits),
             TimeToString(s.exitTime, TIME_DATE | TIME_SECONDS),  DoubleToString(s.exitPrice, _Digits),
             DoubleToString(g_basketInitialRiskUSD, 2),
             DoubleToString(s.profit, 2), DoubleToString(s.commission, 2), DoubleToString(s.swap, 2), DoubleToString(s.fee, 2),
             DoubleToString(net, 2), CloseReasonToString(reason),
             TimeToString(closeReqTime, TIME_DATE | TIME_SECONDS), TimeToString(finalCloseTime, TIME_DATE | TIME_SECONDS),
             DoubleToString(latencyMs, 0), (string)s.closeDeal, (string)rc, outcome, ccy);
   FileFlush(gLogHandle);
}

// EvaluateEntry() runs every tick, so printing unconditionally floods the Experts log with
// identical lines (v5.5 measured 937 in under 6 minutes). Print only on a changed verdict,
// plus a 30s heartbeat; the CSV decision log stays unthrottled.
void LogDecisionRow(int dir, string mode, bool accepted, string reason)
{
   if(InpLogAlsoToExpertsTab)
   {
      string key = StringFormat("%s|%s|%s|%s", DirToString(dir), RegimeToString(g_regimeLast), mode, accepted ? "YES" : "NO") + reason;
      if(key != g_lastDecisionKey || ThrottleOk(25, 30))
      {
         PrintFormat("[DECISION] dir=%s regime=%s mode=%s accepted=%s reason=%s",
                     DirToString(dir), RegimeToString(g_regimeLast), mode, accepted ? "YES" : "NO", reason);
         g_lastDecisionKey = key;
      }
   }
   if(gDecisionLogHandle == INVALID_HANDLE) return;
   FileWrite(gDecisionLogHandle, TimeToString(Now(), TIME_DATE | TIME_SECONDS), _Symbol, DirToString(dir),
             RegimeToString(g_regimeLast), mode,
             DirToString(g_entryDir), DirToString(g_confDir), DirToString(g_trendDir),
             DoubleToString(g_rsiLast, 1), DoubleToString(g_adxLast, 1), DoubleToString(g_atrLast, 5),
             DoubleToString(CurrentSpreadPoints(), 1), accepted ? "YES" : "NO", reason);
   FileFlush(gDecisionLogHandle);
}

//================================= STATE MACHINE CORE ====================================
#define SM(x) (1 << (x))

// Explicit transition table: anything not listed is illegal and fails safe into STATE_ERROR.
int AllowedTargets(ENUM_EA_STATE from)
{
   switch(from)
   {
      case STATE_INITIALIZING:     return SM(STATE_START_DELAY) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_START_DELAY:      return SM(STATE_WAITING_SIGNAL) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_WAITING_SIGNAL:   return SM(STATE_OPENING) | SM(STATE_POSITION_ACTIVE) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_OPENING:          return SM(STATE_POSITION_ACTIVE) | SM(STATE_WAITING_SIGNAL) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_POSITION_ACTIVE:  return SM(STATE_CLOSING) | SM(STATE_WAITING_SIGNAL) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_CLOSING:          return SM(STATE_POSITION_ACTIVE) | SM(STATE_WAITING_SIGNAL) | SM(STATE_DAILY_HALTED) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_DAILY_HALTED:     return SM(STATE_WAITING_SIGNAL) | SM(STATE_POSITION_ACTIVE) | SM(STATE_EMERGENCY_HALTED) | SM(STATE_ERROR);
      case STATE_EMERGENCY_HALTED: return SM(STATE_CLOSING) | SM(STATE_ERROR);   // terminal for trading
      case STATE_ERROR:            return 0;                                     // terminal
   }
   return 0;
}

bool IsEntryCapableState(ENUM_EA_STATE s)
{
   return (s == STATE_START_DELAY || s == STATE_WAITING_SIGNAL || s == STATE_OPENING);
}

int ScanManaged(PosSnap &out);

// Every state change goes through here. While the emergency stop is active no state from which
// an order could be sent can be entered, so the halt cannot be bypassed.
bool TransitionTo(ENUM_EA_STATE newState, string why)
{
   if(newState == g_state) { g_lastAction = why; return true; }

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
   if(newState == STATE_WAITING_SIGNAL) { g_entryCandidateDir = 0; g_entryCandidateSince = 0; }
   return true;
}

void EnterError(string msg)
{
   LogError(msg);
   TransitionTo(STATE_ERROR, msg);
}

//================================= POSITION / BASKET TRACKING ====================================
int ScanManagedFull(PosSnap &out, ulong &tickets[], ulong &idents[], double &floating)
{
   out.valid = false; out.count = 0; out.dir = 0; out.mixed = false;
   out.volume = 0.0; out.avgPrice = 0.0; out.firstTime = 0;
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

// Entry-side commission/fee of one position, read from deal history (POSITION_COMMISSION is deprecated).
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
   g_basketLot = 0.0;
   g_closeIncomplete = false;
   g_beDone = false;
   g_basketSL = 0.0; g_basketTP = 0.0; g_basketEntryRef = 0.0;
}

// Net floating P/L of the live basket (profit + swap + entry commission/fee) and its REF_LOT size.
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

// One completed position rebuilt from its own deal history: partial fills, SL closes and manual
// closes are all aggregated, so ONE position is ONE completed trade.
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
   s.entryPrice = (volIn > 0.0) ? pxIn / volIn : g_posAvgPrice;
   s.exitPrice  = pxOut / volOut;
   if(s.dir == 0)       s.dir = g_posDir;
   if(s.entryTime == 0) s.entryTime = g_posEntryTime;
   return true;
}

// The real reason the broker closed a position - read from the closing deal itself instead of
// guessing by comparing prices (a break-even stop would otherwise be mislabelled).
ENUM_CLOSE_REASON ReasonFromDeal(const TradeSummary &s)
{
   if(s.closeDeal == 0) return CLOSE_REASON_EXTERNAL;
   if(!HistorySelectByPosition(s.ident)) return CLOSE_REASON_EXTERNAL;
   long r = HistoryDealGetInteger(s.closeDeal, DEAL_REASON);
   if(r == DEAL_REASON_TP) return CLOSE_REASON_TARGET;
   if(r == DEAL_REASON_SL) return CLOSE_REASON_STOP;
   return CLOSE_REASON_EXTERNAL;
}

//================================= RISK ENGINE (pre-entry gates only) ====================================
bool EquityDrawdownOk()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) { g_peakEquity = eq; SavePersistentState(); }
   if(g_peakEquity <= 0.0) return true;
   return (100.0 * (g_peakEquity - eq) / g_peakEquity < InpMaxAccountDrawdownPct);
}

bool DailyFloatingDrawdownOk()
{
   return ((g_dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) < InpMaxDailyFloatingDrawdownUSD);
}

bool MarginUsageOk()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return false;
   return (100.0 * AccountInfoDouble(ACCOUNT_MARGIN) / equity < InpMaxMarginUsagePct);
}

bool BasketRiskOk(int dir, double volume, string &why)
{
   string stWhy;
   double sl, tp, riskDist;
   if(!ComputeStopTarget(dir, sl, tp, riskDist, stWhy)) { why = "cannot compute a valid stop (" + stWhy + ")"; return false; }
   double risk = RiskUSD(riskDist, volume);
   double pctLimit = AccountInfoDouble(ACCOUNT_EQUITY) * InpMaxBasketRiskPctEquity / 100.0;
   if(risk > InpMaxBasketRiskUSD + 1e-9)
   { why = StringFormat("basket risk %.2f exceeds InpMaxBasketRiskUSD %.2f", risk, InpMaxBasketRiskUSD); return false; }
   if(risk > pctLimit + 1e-9)
   { why = StringFormat("basket risk %.2f exceeds %.1f%% of equity (%.2f)", risk, InpMaxBasketRiskPctEquity, pctLimit); return false; }
   return true;
}

//================================= SIGNAL ====================================
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

// Last N CLOSED entry-timeframe candles, [0] = last closed bar.
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
      out[i].upperWick = out[i].h - MathMax(out[i].o, out[i].c);
      out[i].lowerWick = MathMin(out[i].o, out[i].c) - out[i].l;
      out[i].t         = r[i].time;
   }
   return true;
}

// The only candle evidence MODE B needs: did price visibly reject this boundary?
bool HasRejectionEvidence(int dir, const CandleInfo &c[])
{
   if(ArraySize(c) < 1 || c[0].range <= 0.0 || c[0].body <= 0.0) return false;
   if(dir == 1)
   {
      bool hammer = (c[0].lowerWick >= 2.0 * c[0].body && c[0].upperWick <= 0.5 * c[0].body);
      bool bullEngulf = (ArraySize(c) >= 2 && c[1].c < c[1].o && c[0].c > c[0].o && c[0].c >= c[1].o && c[0].o <= c[1].c);
      return (hammer || bullEngulf);
   }
   bool star = (c[0].upperWick >= 2.0 * c[0].body && c[0].lowerWick <= 0.5 * c[0].body);
   bool bearEngulf = (ArraySize(c) >= 2 && c[1].c > c[1].o && c[0].c < c[0].o && c[0].o >= c[1].c && c[0].c <= c[1].o);
   return (star || bearEngulf);
}

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

   double bestRes = 1e18, bestSup = 1e18;
   for(int i = 0; i < ArraySize(resZones); i++)
      if(resZones[i] > price && (resZones[i] - price) < bestRes) { bestRes = resZones[i] - price; g_nearestResistance = resZones[i]; }
   for(int i = 0; i < ArraySize(supZones); i++)
      if(supZones[i] < price && (price - supZones[i]) < bestSup) { bestSup = price - supZones[i]; g_nearestSupport = supZones[i]; }
}

ENUM_MARKET_REGIME DetectRegime()
{
   if(!g_indicatorsReady) return REGIME_NONE;
   if(g_atrAvgLast > 0.0)
   {
      double ratio = g_atrLast / g_atrAvgLast;
      if(ratio < InpATRMinRatio || ratio > InpATRMaxRatio) return REGIME_NONE;
   }
   bool allUp   = (g_trendDir == 1  && g_confDir == 1  && g_entryDir == 1);
   bool allDown = (g_trendDir == -1 && g_confDir == -1 && g_entryDir == -1);
   if(g_adxLast >= InpADXTrendMin && (allUp || allDown)) return REGIME_TREND;
   if(g_adxLast <= InpADXRangeMax) return REGIME_RANGE;
   return REGIME_NONE;
}
