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

//================================= SIGNAL UPDATE ====================================
// Runs once per newly CLOSED entry-timeframe bar. H1/M15 values are read from shift 1 of their
// own handles, so they are correct even though this is driven by the entry timeframe's ticks.
void UpdateSignal()
{
   if(hFastEntry == INVALID_HANDLE || hSlowEntry == INVALID_HANDLE) return;

   datetime barTime[];
   ArraySetAsSeries(barTime, true);
   if(CopyTime(_Symbol, InpEntryTimeframe, 1, 1, barTime) != 1) return;
   if(barTime[0] == g_lastEvalBar) return;

   double fast[];
   ArraySetAsSeries(fast, true);
   if(CopyBuffer(hFastEntry, 0, 1, 1, fast) != 1 || !MathIsValidNumber(fast[0]) || fast[0] == EMPTY_VALUE)
   {
      if(ThrottleOk(0, 60)) LogWarning("EMA buffers not ready yet - will retry.");
      return;
   }
   g_fastEmaEntry = fast[0];

   g_entryDir = GetTrendDir(hFastEntry, hSlowEntry);
   g_confDir  = GetTrendDir(hFastConf,  hSlowConf);
   g_trendDir = GetTrendDir(hFastTrend, hSlowTrend);

   double rsi[], adx[], atr[];
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(adx, true); ArraySetAsSeries(atr, true);
   bool rsiOk = (hRsi != INVALID_HANDLE && CopyBuffer(hRsi, 0, 1, 1, rsi) == 1 && MathIsValidNumber(rsi[0]) && rsi[0] != EMPTY_VALUE);
   bool adxOk = (hAdx != INVALID_HANDLE && CopyBuffer(hAdx, 0, 1, 1, adx) == 1 && MathIsValidNumber(adx[0]) && adx[0] != EMPTY_VALUE);
   bool atrOk = (hAtr != INVALID_HANDLE && CopyBuffer(hAtr, 0, 1, 1, atr) == 1 && MathIsValidNumber(atr[0]) && atr[0] != EMPTY_VALUE && atr[0] > 0.0);
   if(rsiOk) g_rsiLast = rsi[0];
   if(adxOk) g_adxLast = adx[0];
   if(atrOk) g_atrLast = atr[0];

   double atrSeries[];
   ArraySetAsSeries(atrSeries, true);
   if(hAtr != INVALID_HANDLE && CopyBuffer(hAtr, 0, 1, InpATRNormalLookback, atrSeries) == InpATRNormalLookback)
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
   return false;
}

//================================= ENTRY GATES ====================================
//+------------------------------------------------------------------+
//| Two gates, one per regime - no weighted score. v5.0..v5.6        |
//| evaluated 21,332 times and accepted 2; the score gate alone was  |
//| 42% of all rejections. Every call, accepted or rejected, goes to |
//| the decision log when InpLogDecisions is on.                     |
//+------------------------------------------------------------------+
bool EvaluateEntry(int dir, string &mode, string &rejectReason)
{
   mode = "";
   rejectReason = "";
   ENUM_MARKET_REGIME regime = REGIME_NONE;
   bool accepted = false;

   do
   {
      if(dir != 1 && dir != -1) { rejectReason = "invalid candidate direction"; break; }
      if(!g_indicatorsReady)    { rejectReason = "indicator data not ready/available yet"; break; }
      if(!SpreadOK())           { rejectReason = StringFormat("spread %.1f pts exceeds InpMaxSpreadPoints=%d", CurrentSpreadPoints(), InpMaxSpreadPoints); break; }
      if(!SessionOk())          { rejectReason = "outside the configured trading session (server time)"; break; }
      if(!DirectionAllowed(dir)){ rejectReason = StringFormat("symbol trade mode does not allow a %s order right now", DirToString(dir)); break; }
      if(BlockedByHalt())       { rejectReason = "daily loss halt is active"; break; }

      regime = DetectRegime();
      if(regime == REGIME_NONE) { rejectReason = "no-trade regime: ambiguous multi-timeframe trend or abnormal ATR"; break; }
      if(InpSignalModel == SIGNAL_MODEL_TREND_ONLY && regime != REGIME_TREND) { rejectReason = "TREND_ONLY model active and regime is not TREND"; break; }
      if(InpSignalModel == SIGNAL_MODEL_RANGE_ONLY && regime != REGIME_RANGE) { rejectReason = "RANGE_ONLY model active and regime is not RANGE"; break; }

      CandleInfo candles[];
      if(!GetClosedCandles(3, candles)) { rejectReason = "could not read closed candle data"; break; }

      if(regime == REGIME_TREND)
      {
         mode = "TREND";
         if(!RSIConfirms(dir)) { rejectReason = StringFormat("MODE A: RSI momentum gate failed (RSI=%.1f)", g_rsiLast); break; }

         // Hard chase gate - replaces the old pullback timer. No clock, no forced entry.
         double stretch = (dir == 1) ? (candles[0].c - g_fastEmaEntry) : (g_fastEmaEntry - candles[0].c);
         if(stretch > InpMaxChaseATR * g_atrLast)
         { rejectReason = StringFormat("MODE A: price %.2f ATR beyond the fast EMA (max %.2f)", stretch / g_atrLast, InpMaxChaseATR); break; }

         bool withTrend = (dir == 1) ? (candles[0].c > candles[0].o) : (candles[0].c < candles[0].o);
         if(!withTrend && !HasRejectionEvidence(dir, candles))
         { rejectReason = "MODE A: last closed candle does not confirm the trade direction"; break; }
      }
      else
      {
         mode = "RANGE";
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(price <= 0.0 || g_atrLast <= 0.0) { rejectReason = "MODE B: no valid price/ATR to evaluate range boundaries"; break; }

         double nearLevel = (dir == 1) ? g_nearestSupport : g_nearestResistance;
         double farLevel  = (dir == 1) ? g_nearestResistance : g_nearestSupport;
         if(nearLevel <= 0.0) { rejectReason = StringFormat("MODE B: no confirmed %s zone identified", (dir == 1) ? "support" : "resistance"); break; }
         if(MathAbs(price - nearLevel) > InpRangeZoneATR * g_atrLast)
         { rejectReason = "MODE B: price is not close enough to the range boundary"; break; }

         bool rsiExtreme = (dir == 1) ? (g_rsiLast <= InpRSIOversold) : (g_rsiLast >= InpRSIOverbought);
         if(!rsiExtreme && !HasRejectionEvidence(dir, candles))
         { rejectReason = "MODE B: no RSI extreme or rejection-candle evidence at the boundary"; break; }

         if(farLevel <= 0.0) { rejectReason = "MODE B: no opposite boundary found"; break; }
      }

      if(!EquityDrawdownOk())        { rejectReason = StringFormat("equity drawdown guard active (>= %.1f%% below peak)", InpMaxAccountDrawdownPct); break; }
      if(!DailyFloatingDrawdownOk()) { rejectReason = StringFormat("daily floating drawdown guard active (>= %.2f)", InpMaxDailyFloatingDrawdownUSD); break; }
      if(!MarginUsageOk())           { rejectReason = StringFormat("margin usage guard active (>= %.1f%%)", InpMaxMarginUsagePct); break; }
      string riskWhy;
      if(!BasketRiskOk(dir, EstimateBasketVolume(), riskWhy)) { rejectReason = "risk engine: " + riskWhy; break; }

      accepted = true;
   }
   while(false);

   g_lastRejectReason = accepted ? "" : rejectReason;
   LogDecisionRow(dir, mode, accepted, rejectReason);
   return accepted;
}

// >=2 of H1/M15/M5 agreeing.
int MultiTFMajorityDirection()
{
   int up = (g_trendDir == 1 ? 1 : 0) + (g_confDir == 1 ? 1 : 0) + (g_entryDir == 1 ? 1 : 0);
   int dn = (g_trendDir == -1 ? 1 : 0) + (g_confDir == -1 ? 1 : 0) + (g_entryDir == -1 ? 1 : 0);
   if(up >= 2 && up > dn) return 1;
   if(dn >= 2 && dn > up) return -1;
   return 0;
}

// MODE B candidate: whichever boundary is nearest, traded in the mean-reverting direction.
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
//| Opens one basket: InpBasketMax same-direction positions of the    |
//| FIXED InpFixedLotSize lot, shrunk to fit InpMaxBasketVolume and   |
//| free margin. SL and TP are computed once and sent WITH every      |
//| order, so the 0.5 R shape survives an EA or terminal outage.      |
//+------------------------------------------------------------------+
ENUM_REQ_RESULT ExecuteOpen(int direction, ENUM_MARKET_REGIME regime)
{
   if(EmergencyActive())            { LogWarning("Open refused: emergency stop is active."); return REQ_DEFERRED; }
   if(BlockedByHalt())              { if(ThrottleOk(1, 60)) LogWarning("Open refused: daily loss halt is active."); return REQ_DEFERRED; }
   if(g_state == STATE_ERROR)       return REQ_DEFERRED;
   if(!IsDemoAccount())             { LogError("Open refused: not a DEMO account."); return REQ_DEFERRED; }
   if(Now() < g_nextRequestAllowed) return REQ_DEFERRED;

   string why;
   if(!TradingPermitted(why))       { if(ThrottleOk(2, 60)) LogWarning("Open deferred: " + why); return REQ_DEFERRED; }
   if(!DirectionAllowed(direction)) { if(ThrottleOk(3, 60)) LogWarning(StringFormat("Open deferred: symbol trade mode does not allow a %s order right now.", DirToString(direction))); return REQ_DEFERRED; }

   PosSnap existing;
   if(ScanManaged(existing) > 0)
   {
      if(ThrottleOk(11, 30)) LogError("Open refused: a managed basket already exists - a second basket is never opened on top of it.");
      return REQ_DEFERRED;
   }
   if(NettingForeignConflict())     { if(ThrottleOk(4, 60)) LogWarning("Open deferred: netting account has a foreign position on this symbol."); return REQ_DEFERRED; }
   if(!SpreadOK())                  { if(ThrottleOk(5, 60)) LogWarning(StringFormat("Open deferred: spread %.1f pts exceeds InpMaxSpreadPoints=%d.", CurrentSpreadPoints(), InpMaxSpreadPoints)); return REQ_DEFERRED; }
   if(!EquityDrawdownOk())          { if(ThrottleOk(21, 60)) LogWarning("Open deferred: equity drawdown guard active."); return REQ_DEFERRED; }
   if(!DailyFloatingDrawdownOk())   { if(ThrottleOk(22, 60)) LogWarning("Open deferred: daily floating drawdown guard active."); return REQ_DEFERRED; }
   if(!MarginUsageOk())             { if(ThrottleOk(23, 60)) LogWarning("Open deferred: margin usage guard active."); return REQ_DEFERRED; }

   double lot = CurrentLot();
   if(lot <= 0.0)
   {
      EnterError("Open REJECTED: lot is not supported by this symbol's volume min/max/step configuration.");
      return REQ_DEFERRED;
   }

   int n = CurrentBasketSize();
   n = MathMin(n, (int)MathFloor(InpMaxBasketVolume / lot + 1e-9));
   if(n < 1) n = 1;

   string stWhy;
   double sl0, tp0, riskDist;
   if(!ComputeStopTarget(direction, sl0, tp0, riskDist, stWhy))
   {
      if(ThrottleOk(6, 60)) LogWarning("Open deferred: cannot place a valid stop/target (" + stWhy + ").");
      return REQ_DEFERRED;
   }

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

   // ---- basket context, captured at the moment the open is actually attempted ----
   g_basketOpenTime       = Now();
   g_basketRegime         = regime;
   g_basketMode           = (regime == REGIME_TREND) ? "TREND" : "RANGE";
   g_basketH1Dir          = g_trendDir;
   g_basketM15Dir         = g_confDir;
   g_basketM5Dir          = g_entryDir;
   g_basketRSI            = g_rsiLast;
   g_basketADX            = g_adxLast;
   g_basketATR            = g_atrLast;
   g_basketSpreadEntry    = CurrentSpreadPoints();
   g_basketInitialRiskUSD = RiskUSD(riskDist, n * lot);
   g_basketSL             = sl0;
   g_basketTP             = tp0;
   g_basketEntryRef       = 0.0;
   g_beDone               = false;

   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;
   g_openRequestTime    = Now();

   int opened = 0;
   for(int k = 0; k < n; k++)
   {
      if(k > 0 && !SpreadOK()) { LogWarning(StringFormat("Basket stopped at %d/%d positions: spread widened.", opened, n)); break; }

      // recompute per order: price may have moved enough to violate the broker's stop level
      double sl, tp, rd;
      if(!ComputeStopTarget(direction, sl, tp, rd, stWhy))
      {
         if(opened == 0) { LogWarning("Open deferred: cannot place a valid stop/target (" + stWhy + ")."); return REQ_DEFERRED; }
         LogWarning(StringFormat("Basket stopped at %d/%d positions: no valid stop (%s).", opened, n, stWhy));
         break;
      }

      ulong t0 = GetTickCount64();
      bool sent = (direction == 1)
                ? trade.Buy(lot, _Symbol, 0.0, sl, tp, InpTradeComment)
                : trade.Sell(lot, _Symbol, 0.0, sl, tp, InpTradeComment);
      uint rc = trade.ResultRetcode();
      g_lastOrderLatencyMs = (double)(GetTickCount64() - t0);
      g_lastRetcode = rc;
      g_lastOrderLabel = StringFormat("%s open #%d/%d", DirToString(direction), opened + 1, n);

      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
      {
         if(rc == TRADE_RETCODE_DONE_PARTIAL) LogWarning("An open order was only PARTIALLY filled - the real broker volume is tracked, no top-up is sent.");
         if(opened == 0) { g_basketSL = sl; g_basketTP = tp; }
         opened++;
         continue;
      }

      if(IsUncertainRetcode(rc))
      {
         if(opened == 0)
         {
            LogWarning(StringFormat("Open %s outcome UNCERTAIN (retcode %u: %s) - reconciling against real positions before any retry.",
                                    DirToString(direction), rc, trade.ResultRetcodeDescription()));
            g_openDir = direction; g_basketLot = lot;
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

   g_openDir = direction;
   g_basketLot = lot;
   if(opened == 0) return REQ_REJECTED;
   if(opened < n) LogWarning(StringFormat("Basket opened with %d of %d planned positions.", opened, n));
   return REQ_ACCEPTED;
}

//+------------------------------------------------------------------+
//| Requests closure of EVERY basket position. DONE does not mean     |
//| flat: completion is only ever confirmed by Reconcile() seeing zero|
//| managed volume.                                                   |
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
      g_closeIncomplete = (okCount < cnt) || anyPartial;
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

// If the broker stripped a stop, put it back - the SL is the only protection against a missed tick.
void EnsureProtectiveStop()
{
   if(g_basketSL <= 0.0) return;
   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   for(int i = 0; i < cnt; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;
      if(!trade.PositionModify(tk[i], g_basketSL, g_basketTP))
         LogWarning(StringFormat("Could not attach protective stop to #%I64u (retcode %u: %s).",
                                 tk[i], trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
//| Break-even arm: once price has moved InpBreakEvenR x the stop    |
//| distance in our favour, the SL is moved to the basket's average  |
//| entry. Fires once per basket (g_beDone).                          |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   if(InpBreakEvenR <= 0.0 || g_beDone) return;
   if(g_basketSL <= 0.0 || g_posAvgPrice <= 0.0) return;

   double riskDist = MathAbs(g_posAvgPrice - g_basketSL);
   if(riskDist <= 0.0) return;
   double trigger = InpBreakEvenR * riskDist;

   PosSnap s;
   ulong tk[], id[];
   double fl;
   int cnt = ScanManagedFull(s, tk, id, fl);
   if(cnt == 0 || s.mixed) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return;

   double newSL = 0.0;
   if(s.dir == 1) { if(bid < g_posAvgPrice + trigger) return; newSL = g_posAvgPrice; }
   else           { if(ask > g_posAvgPrice - trigger) return; newSL = g_posAvgPrice; }
   newSL = NormalizeDouble(newSL, _Digits);

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (stopsLevel + 2) * _Point;
   if(s.dir == 1 && bid - newSL < minDist) return;   // not far enough from price yet - retry next tick
   if(s.dir == -1 && newSL - ask < minDist) return;

   if(!ThrottleOk(30, 5)) return;   // one modify attempt per 5s at most

   int moved = 0;
   for(int i = 0; i < cnt; i++)
   {
      if(!PositionSelectByTicket(tk[i])) continue;
      double cur = PositionGetDouble(POSITION_SL);
      if(cur > 0.0 && MathAbs(cur - newSL) < _Point) { moved++; continue; }
      if(trade.PositionModify(tk[i], newSL, g_basketTP)) moved++;
      else LogWarning(StringFormat("Break-even modify failed on #%I64u (retcode %u: %s).",
                                   tk[i], trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
   if(moved > 0)
   {
      g_beDone = true;
      g_basketEntryRef = newSL;
      LogInfo(StringFormat("Break-even armed: SL moved to entry %s (%s, trigger %.2f x risk distance %.5f).",
                           DoubleToString(newSL, _Digits), DirToString(s.dir), InpBreakEvenR, riskDist));
   }
}

//================================= CLOSE ROUTING ====================================
void ConsumeEntryBar() { g_lastEntryBarConsumed = g_pendingConsumeBar; SavePersistentState(); }

// The real reason a basket closed when the EA did not ask for it: read DEAL_REASON off the
// closing deal instead of guessing from prices (a break-even stop would be mislabelled).
ENUM_CLOSE_REASON DetectBrokerReason(const TradeSummary &sums[])
{
   for(int i = 0; i < ArraySize(sums); i++)
   {
      if(sums[i].closeDeal == 0 || sums[i].ident == 0) continue;
      if(!HistorySelectByPosition(sums[i].ident)) continue;
      long r = HistoryDealGetInteger(sums[i].closeDeal, DEAL_REASON);
      if(r == DEAL_REASON_TP) return CLOSE_REASON_TARGET;
      if(r == DEAL_REASON_SL) return CLOSE_REASON_STOP;
   }
   return CLOSE_REASON_EXTERNAL;
}

// Decides the next state once the basket is CONFIRMED completely closed. v5.7 never reverses:
// every close returns to WAITING_SIGNAL and waits for a genuinely fresh signal.
void RouteAfterClose(ENUM_CLOSE_REASON reason)
{
   if(reason == CLOSE_REASON_EMERGENCY || EmergencyActive())
   {
      TransitionTo(STATE_EMERGENCY_HALTED, "Emergency stop: basket closed, trading halted - no new entries.");
      return;
   }
   ConsumeEntryBar();
   if(BlockedByHalt())
   {
      TransitionTo(STATE_DAILY_HALTED, "Basket closed (" + CloseReasonToString(reason) + "); a daily halt is active.");
      return;
   }
   TransitionTo(STATE_WAITING_SIGNAL, "Basket closed (" + CloseReasonToString(reason) + ") - waiting for a fresh signal.");
}

// The whole basket is confirmed gone from the broker: book every position as ONE completed trade.
// The basket outcome is always computed from the ACTUAL net sum, never from the trigger's name.
void OnBasketClosed(const TradeSummary &sums[])
{
   ENUM_CLOSE_REASON reason = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_pendingCloseReason : DetectBrokerReason(sums);
   uint execRetcode = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_closeRetcode : 0;
   int closedDir = (g_posDir != 0) ? g_posDir : (ArraySize(sums) > 0 ? sums[0].dir : 0);

   datetime finalCloseTime = Now();
   datetime closeReqTime   = (g_closeRequestTimeExact != 0) ? g_closeRequestTimeExact : finalCloseTime;
   double latencyMs        = (double)(finalCloseTime - closeReqTime) * 1000.0;

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
      LogTradeRow(sums[i], g_basketNo, reason, execRetcode, net, outcome, closeReqTime, finalCloseTime, latencyMs);
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

   LogInfo(StringFormat("Basket #%d closed: %d positions, net %.2f (%s), reason %s, regime %s, mode %s.",
                        g_basketNo, n, basketNet, outcome, CloseReasonToString(reason),
                        RegimeToString(g_basketRegime), g_basketMode));

   ClearTracking();
   g_pendingCloseReason = CLOSE_REASON_NONE;
   g_pendingCloseDetail = "";
   g_closeRequestTimeExact = 0;
   g_retryCounter = 0;
   g_lastError = "";
   g_finalizeWaitSince = 0;
   g_basketOpenTime = 0;

   if(!RebuildDailyState())
   {
      g_dailyRealizedPL += basketNet;
      if(InpDailyLossLimitEnabled && g_dailyRealizedPL <= -InpDailyLossLimitUSD + 1e-9) g_dailyHaltFlag = true;
   }
   if(g_dailyHaltFlag)
      LogWarning(StringFormat("Daily loss limit reached (realized=%.2f, limit=%.2f). New entries are halted for the rest of the broker day.",
                              g_dailyRealizedPL, InpDailyLossLimitUSD));
   SavePersistentState();

   RouteAfterClose(reason);
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
      if(g_pendingCloseReason != CLOSE_REASON_NONE) g_closeIncomplete = true;
   }
   SyncTracking(s, idents);

   switch(g_state)
   {
      case STATE_OPENING:
      {
         if(s.dir != g_openDir)
         {
            EnterError(StringFormat("Opened basket direction %s does not match the requested %s.", DirToString(s.dir), DirToString(g_openDir)));
            return;
         }
         g_retryCounter = 0;
         g_lastError = "";
         g_pendingCloseReason = CLOSE_REASON_NONE;
         g_beDone = false;
         ConsumeEntryBar();
         SavePersistentState();
         EnsureProtectiveStop();
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Confirmed: %s basket %d x %.2f lot (%.2f total) @ %s. SL %s / TP %s, regime %s.",
                      DirToString(s.dir), s.count, (s.count > 0) ? s.volume / s.count : 0.0, s.volume, DoubleToString(s.avgPrice, _Digits),
                      DoubleToString(g_basketSL, _Digits), DoubleToString(g_basketTP, _Digits), RegimeToString(g_basketRegime)));
         break;
      }
      case STATE_START_DELAY:
      case STATE_WAITING_SIGNAL:
      case STATE_DAILY_HALTED:
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

// The single source of truth for "what position do we really have".
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

//================================= STATE MACHINE TICK LOGIC ====================================
// Global emergency hook, evaluated BEFORE any state logic.
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
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_EMERGENCY, "EMERGENCY STOP: closing the whole basket");
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING, "Emergency stop - closing the basket. No new entries.");
         }
         return true;
      }
      case STATE_START_DELAY:
      case STATE_WAITING_SIGNAL:
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
            else                TransitionTo(STATE_WAITING_SIGNAL, "Ready - waiting for a MODE A/B signal.");
         }
         break;

      case STATE_WAITING_SIGNAL:
      {
         if(BlockedByHalt()) { TransitionTo(STATE_DAILY_HALTED, "Halt active - not entering."); g_entryCandidateDir = 0; break; }
         if(!g_indicatorsReady) { g_entryCandidateDir = 0; g_lastAction = "Waiting for indicator data (ATR/RSI/ADX/MA)..."; break; }
         if(g_lastEvalBar != 0 && g_lastEvalBar == g_lastEntryBarConsumed) { g_entryCandidateDir = 0; break; }   // this closed bar already acted on

         int dir = SelectCandidateDirection(g_regimeLast);
         if(dir == 0)
         {
            g_entryCandidateDir = 0;
            g_lastRejectReason = StringFormat("MODE C: no-trade right now (regime %s)", RegimeToString(g_regimeLast));
            g_lastAction = StringFormat("MODE C: no-trade right now (regime %s).", RegimeToString(g_regimeLast));
            break;
         }

         string mode, reject;
         if(!EvaluateEntry(dir, mode, reject))
         {
            g_entryCandidateDir = 0;
            g_lastAction = StringFormat("Rejected %s: %s", DirToString(dir), reject);
            break;
         }

         // Entry confirmation hold: the setup must still pass for InpEntryConfirmSeconds before opening.
         if(g_entryCandidateDir != dir)
         {
            g_entryCandidateDir = dir;
            g_entryCandidateSince = Now();
            g_lastAction = StringFormat("Confirming %s signal (MODE %s, 0/%ds)...", DirToString(dir), mode, InpEntryConfirmSeconds);
            break;
         }
         int heldSec = (int)(Now() - g_entryCandidateSince);
         if(heldSec < InpEntryConfirmSeconds)
         {
            g_lastAction = StringFormat("Confirming %s signal (MODE %s, %d/%ds)...", DirToString(dir), mode, heldSec, InpEntryConfirmSeconds);
            break;
         }

         g_pendingConsumeBar = g_lastEvalBar;
         ENUM_REQ_RESULT r = ExecuteOpen(dir, g_regimeLast);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
         {
            g_entryCandidateDir = 0;
            TransitionTo(STATE_OPENING, StringFormat("Opening %s basket (MODE %s, confirmed %ds).", DirToString(dir), mode, InpEntryConfirmSeconds));
         }
         break;
      }

      case STATE_OPENING:
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
            TransitionTo(STATE_WAITING_SIGNAL, "Open unconfirmed - back to waiting for a signal.");
         }
         break;

      case STATE_POSITION_ACTIVE:
      {
         if(InpMaxHoldingMinutes > 0 && g_basketOpenTime > 0 && (Now() - g_basketOpenTime) >= InpMaxHoldingMinutes * 60)
         {
            string mdetail = StringFormat("MAX_HOLDING: basket open %d min >= limit %d min",
                                          (int)((Now() - g_basketOpenTime) / 60), InpMaxHoldingMinutes);
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_MAX_HOLDING, mdetail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING, "Maximum holding duration reached - closing the basket.");
            break;
         }

         ManageBreakEven();
         if(ThrottleOk(31, 10)) EnsureProtectiveStop();
         g_lastAction = StringFormat("Basket live: %s %d x %.2f lot, SL %s TP %s%s",
                                     DirToString(g_posDir), g_posCount, g_posVolume,
                                     DoubleToString(g_basketSL, _Digits), DoubleToString(g_basketTP, _Digits),
                                     (InpBreakEvenR > 0.0 && g_beDone) ? ", BE armed" : "");
         break;
      }

      case STATE_CLOSING:
      {
         PosSnap s;
         if(ScanManaged(s) == 0) break;
         bool stale = (Now() - g_closeRequestTime >= InpOperationTimeoutSeconds);
         if(g_closeIncomplete || stale)
            ExecuteClose(g_pendingCloseReason != CLOSE_REASON_NONE ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL, g_pendingCloseDetail);
         break;
      }

      case STATE_DAILY_HALTED:
         if(!BlockedByHalt())
         {
            g_lastEntryBarConsumed = g_lastEvalBar;   // a stale pre-halt bar must not fire the instant trading resumes
            TransitionTo(STATE_WAITING_SIGNAL, "Halt cleared - resuming, a fresh evaluation bar is required.");
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

   // MQL5 does NOT reset globals on a soft reinit (chart change, input change, recompile hot-reload).
   // Force a clean state machine on every OnInit so a timeframe switch never bricks the EA.
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
   if(CurrentLot() <= 0.0)
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

   hFastEntry = iMA(_Symbol, InpEntryTimeframe,   InpFastMA, 0, InpMAMethod, InpMAPrice);
   hSlowEntry = iMA(_Symbol, InpEntryTimeframe,   InpSlowMA, 0, InpMAMethod, InpMAPrice);
   hFastConf  = iMA(_Symbol, InpConfirmTimeframe, InpFastMA, 0, InpMAMethod, InpMAPrice);
   hSlowConf  = iMA(_Symbol, InpConfirmTimeframe, InpSlowMA, 0, InpMAMethod, InpMAPrice);
   hFastTrend = iMA(_Symbol, InpTrendTimeframe,   InpFastMA, 0, InpMAMethod, InpMAPrice);
   hSlowTrend = iMA(_Symbol, InpTrendTimeframe,   InpSlowMA, 0, InpMAMethod, InpMAPrice);
   hAtr = iATR(_Symbol, InpEntryTimeframe, InpATRPeriod);
   hRsi = iRSI(_Symbol, InpEntryTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hAdx = iADX(_Symbol, InpEntryTimeframe, InpADXPeriod);
   if(hFastEntry == INVALID_HANDLE || hSlowEntry == INVALID_HANDLE ||
      hFastConf  == INVALID_HANDLE || hSlowConf  == INVALID_HANDLE ||
      hFastTrend == INVALID_HANDLE || hSlowTrend == INVALID_HANDLE ||
      hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAdx == INVALID_HANDLE)
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
   LogInfo(StringFormat("Signal model: %s. Two gates per regime (no score). Regime thresholds: ADX>=%.1f=TREND, ADX<=%.1f=RANGE.",
                        EnumToString(InpSignalModel), InpADXTrendMin, InpADXRangeMax));
   LogInfo(StringFormat("Exits: SL = %.2f x ATR and TP = %.2f x ATR, both placed WITH the order (0.5 R shape), break-even at %.2f R, time stop %d min (0=none).",
                        InpStopATRMult, InpTargetATRMult, InpBreakEvenR, InpMaxHoldingMinutes));
   LogInfo(StringFormat("MODE A chase gate: max %.2f ATR beyond the fast EMA. MODE B zone gate: max %.2f ATR from the nearest swing boundary.",
                        InpMaxChaseATR, InpRangeZoneATR));
   LogInfo(StringFormat("Risk engine: max basket risk %.2f (or %.1f%% equity), max daily floating DD %.2f, max account DD %.1f%%, max margin usage %.1f%%. All amounts in account currency (%s).",
                        InpMaxBasketRiskUSD, InpMaxBasketRiskPctEquity, InpMaxDailyFloatingDrawdownUSD, InpMaxAccountDrawdownPct, InpMaxMarginUsagePct, AccountInfoString(ACCOUNT_CURRENCY)));
   LogInfo(StringFormat("Daily realized-loss limit: %s (limit %.2f). Losses never reverse - every close returns to a fresh signal.",
                        InpDailyLossLimitEnabled ? "ON" : "OFF", InpDailyLossLimitUSD));
   if(InpUseSessionFilter)
      LogInfo(StringFormat("Session filter ON: server-time hours %d..%d. Verify this matches your broker's server time.", InpSessionStartHour, InpSessionEndHour));

   LoadPersistentState();
   LogInfo(StringFormat("Entry confirmation: a signal must hold for %ds before a basket is opened.", InpEntryConfirmSeconds));

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
   if(hFastEntry != INVALID_HANDLE) { IndicatorRelease(hFastEntry); hFastEntry = INVALID_HANDLE; }
   if(hSlowEntry != INVALID_HANDLE) { IndicatorRelease(hSlowEntry); hSlowEntry = INVALID_HANDLE; }
   if(hFastConf  != INVALID_HANDLE) { IndicatorRelease(hFastConf);  hFastConf  = INVALID_HANDLE; }
   if(hSlowConf  != INVALID_HANDLE) { IndicatorRelease(hSlowConf);  hSlowConf  = INVALID_HANDLE; }
   if(hFastTrend != INVALID_HANDLE) { IndicatorRelease(hFastTrend); hFastTrend = INVALID_HANDLE; }
   if(hSlowTrend != INVALID_HANDLE) { IndicatorRelease(hSlowTrend); hSlowTrend = INVALID_HANDLE; }
   if(hAtr != INVALID_HANDLE) { IndicatorRelease(hAtr); hAtr = INVALID_HANDLE; }
   if(hRsi != INVALID_HANDLE) { IndicatorRelease(hRsi); hRsi = INVALID_HANDLE; }
   if(hAdx != INVALID_HANDLE) { IndicatorRelease(hAdx); hAdx = INVALID_HANDLE; }
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

// Every deal is a trigger to RECONCILE against the real positions - the deal itself is never the truth.
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

//================================= DASHBOARD (display-only) ====================================
// Text size is FIXED at 9pt body / 11pt header on every machine - it never shrinks to "fit".
#define DASH_PREFIX "SRE57_DASH_"
#define PANEL_X 10
#define DASH_ROWS 29
#define DASH_ROW_H 16
#define DASH_FONT_BASE 9
#define DASH_FONT_HEADER 11
#define DASH_MAX_CHARS 56

int g_dashPanelW = 400;

void ComputeDashboardSizing()
{
   long chartW = (long)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   if(chartW <= 0) chartW = 800;
   g_dashPanelW = (int)MathMin(480.0, MathMax(400.0, chartW * 0.5));
}

// Properties are reapplied EVERY call, not only on first creation - a same-named object left over from
// an earlier EA session/version would otherwise keep its OLD background/border/visibility.
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
   if(i < 0 || i >= DASH_ROWS) return;
   string name = DASH_PREFIX + "R" + IntegerToString(i);
   if(StringLen(text) > DASH_MAX_CHARS) text = StringSubstr(text, 0, DASH_MAX_CHARS - 3) + "...";
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

// Wraps onto a second row at the last space instead of truncating mid-word. Always consumes exactly
// 2 rows (the 2nd stays blank when the text is short), so every other row keeps a fixed index.
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
   else                          { daily = "ok"; }
   string emerg = EmergencyActive() ? ((g_state == STATE_EMERGENCY_HALTED) ? "HALTED" : "closing") : "off";

   string posTxt = haveBasket
                 ? StringFormat("%s %d x %.2f = %.2f lot", DirToString(g_posDir), g_posCount, (g_posCount > 0) ? g_posVolume / g_posCount : 0.0, g_posVolume)
                 : "none";

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

   string slTxt = (g_basketSL > 0.0) ? DoubleToString(g_basketSL, _Digits) : "-";
   string tpTxt = (g_basketTP > 0.0) ? DoubleToString(g_basketTP, _Digits) : "-";

   int row = 0;
   SetRow(row++, StringFormat("Smart Reversal EA v%s  [DEMO]", EA_VERSION), clrGold);

   SetRow(row++, "-- SYSTEM --------------------------------------", clrSilver);
   SetRow(row++, StringFormat("%s | %s | Entry=%s Confirm=%s Trend=%s", _Symbol, g_marginModeStr, TfShort(InpEntryTimeframe), TfShort(InpConfirmTimeframe), TfShort(InpTrendTimeframe)), clrLime);
   SetRow(row++, "State: " + StateToString(g_state) + "   Model: " + EnumToString(InpSignalModel), (g_state == STATE_ERROR) ? clrTomato : clrSkyBlue);
   SetRow(row++, "Running: " + FormatRunTime((long)(Now() - g_eaStartTime)), clrAqua);

   SetRow(row++, "-- MARKET --------------------------------------", clrSilver);
   SetRow(row++, StringFormat("Regime: %s | H1:%s M15:%s M5:%s", RegimeToString(g_regimeLast), DirToString(g_trendDir), DirToString(g_confDir), DirToString(g_entryDir)), clrOrange);
   SetRow(row++, StringFormat("RSI %.1f | ADX %.1f | ATR %.5f | Spread %.1fpt", g_rsiLast, g_adxLast, g_atrLast, sp), clrLightGray);
   SetRowWrap2(row, "Last rejection: " + (g_lastRejectReason == "" ? "-" : g_lastRejectReason), clrGray);

   SetRow(row++, "-- TRADING -------------------------------------", clrSilver);
   SetRow(row++, "Basket: " + posTxt, clrOrange);
   SetRow(row++, haveBasket ? StringFormat("AvgEntry: %s   Risk: %.2f %s", DoubleToString(g_posAvgPrice, _Digits), g_basketInitialRiskUSD, ccy) : "AvgEntry: -", clrLightGray);
   SetRow(row++, StringFormat("Float: %.2f %s | SL: %s | TP: %s", fl, ccy, slTxt, tpTxt), (fl < 0.0) ? clrSalmon : clrAqua);
   SetRow(row++, StringFormat("Exit 0.5R: stop %.2f ATR / target %.2f ATR | BE %s", InpStopATRMult, InpTargetATRMult,
                              (InpBreakEvenR <= 0.0) ? "off" : (g_beDone ? StringFormat("armed (%.2fR)", InpBreakEvenR) : StringFormat("wait %.2fR", InpBreakEvenR))), clrLightGray);
   SetRow(row++, haveBasket ? StringFormat("Ctx: MODE %s | %s | RSI %.1f ADX %.1f", g_basketMode, RegimeToString(g_basketRegime), g_basketRSI, g_basketADX) : "Ctx: -", clrLightGray);

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
              (accountDDPct >= InpMaxAccountDrawdownPct || g_dailyHaltFlag || EmergencyActive()) ? clrTomato : dailyClr);

   SetRow(row++, "-- EXECUTION -------------------------------------", clrSilver);
   SetRow(row++, "Last order: " + (g_lastOrderLabel == "" ? "-" : g_lastOrderLabel), clrLightGray);
   SetRow(row++, StringFormat("Last retcode: %u | Latency: %.0fms", g_lastRetcode, g_lastOrderLatencyMs), clrLightGray);
   SetRowWrap2(row, g_lastError == "" ? "Last: " + g_lastAction : "ERR: " + g_lastError, g_lastError == "" ? clrLightGray : clrTomato);

   for(int i = row; i < DASH_ROWS; i++) SetRow(i, "", clrGray);
}
