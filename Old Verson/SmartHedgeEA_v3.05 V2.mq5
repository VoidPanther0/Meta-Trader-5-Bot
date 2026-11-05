//+------------------------------------------------------------------+
//|                                       SmartHedgeEA_v3.05 V2.mq5 |
//|                   Smart Reversal EA - state-driven BASKET engine: |
//|                   N same-direction positions are opened, trailed, |
//|                   closed and reversed together as ONE unit.       |
//|                                                                  |
//|  DEMO ACCOUNTS ONLY.  One chart symbol per EA instance - this EA  |
//|  is NOT multi-symbol. To trade several symbols attach one EA      |
//|  instance (with its own magic number) to one chart per symbol.   |
//+------------------------------------------------------------------+
#property copyright "Sachin Dev Bots"
#property version   "3.05"
#property strict
#property description "DEMO-ONLY smart reversal basket EA. One chart symbol per EA instance."

#include <Trade\Trade.mqh>

#define EA_VERSION            "3.05 V2"
#define HARD_MAX_LOT          0.50       // absolute per-position lot ceiling, enforced in code regardless of inputs
#define REF_LOT               0.01       // all $ thresholds are defined PER this volume and scale with the basket volume
#define MAX_BASKET_HARD       50         // absolute ceiling on positions in one basket
#define GV_PREFIX             "SRE3_"
#define LOCK_STALE_SEC        15         // a duplicate-instance heartbeat older than this is considered dead
#define FINALIZE_WAIT_SEC     10         // how long to wait for close deals to show up in history
#define HISTORY_LOOKBACK_SEC  (60*86400) // look-back used to associate manual/SL close deals with our positions

//================================= INPUTS ====================================
enum ENUM_ENTRY_MODE
{
   ENTRY_ON_CROSS_ONLY = 0,     // wait for a fresh EMA cross every time (slow on M1)
   ENTRY_ON_CROSS_OR_TREND = 1  // fresh cross if one is pending, otherwise enter with the current EMA trend (fast start)
};

input group "=== Signal (EMA Crossover, confirmed closed-candle only) ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_ON_CROSS_OR_TREND;
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_M5; // EMAs are computed on this timeframe whatever the chart shows (M1 is too noisy for these exits)
input int    InpFastMA            = 10;
input int    InpSlowMA            = 30;
input ENUM_MA_METHOD InpMAMethod  = MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== Entry Filter (anti-chase, applies to trend-mode entries only) ==="
input bool   InpUsePullbackFilter    = true;  // trend entries wait until price has pulled back near the fast EMA (stops buying tops / selling bottoms)
input int    InpATRPeriod            = 14;
input double InpMaxChaseATR          = 1.0;   // max distance, in ATRs, that the last close may be beyond the fast EMA in the trade direction
input bool   InpRequireCandleConfirm = true;  // the last closed candle must close in the trade direction
input int    InpMaxPullbackWaitMin   = 15;    // enter anyway after waiting this many minutes for a pullback (0 = wait forever)

input group "=== Basket Exits (every $ value is PER 0.01 LOT, scaled by the basket's total volume) ==="
input double InpLossThresholdUSD    = 0.40;  // reverse the WHOLE basket when its floating net loss reaches -(this x volume/0.01)
input double InpProfitMinUSD        = 0.40;  // profit trailing arms once basket profit reaches +(this x volume/0.01)
input double InpProfitTargetUSD     = 0.80;  // basket closes at once at +(this x volume/0.01)  (the maximum)
input double InpTrailGivebackUSD    = 0.20;  // once armed, close if profit falls this far below its peak (never below the minimum)
input int    InpMaxConsecutiveReversals = 20; // no further reversal once this many CONFIRMED reversals happened in a row

input group "=== Basket Size & Lot Growth (growth ONLY after winning baskets, reset on any loss) ==="
input int    InpBasketMin       = 3;     // positions in the first basket / after any loss
input int    InpBasketMax       = 5;     // size grows by 1 per winning basket up to this
input double InpFixedLotSize    = 0.01;  // base lot per position
input double InpMaxLotSize      = 0.50;  // per-position lot ceiling (also capped at 0.50 in code)
input double InpMaxTotalLots    = 5.00;  // ceiling on basket volume (positions x lot); the basket is shrunk to fit
input bool   InpGrowthEnabled   = true;  // false = always InpBasketMin positions of InpFixedLotSize
input int    InpWinsPerStep     = 3;     // lot is raised one step after this many winning baskets in a row
input double InpLotStep         = 0.01;  // lot increase per step

input group "=== Broker-Side Protective Stop (hard backstop, NOT the $ trigger) ==="
input int    InpProtectiveStopPoints = 500; // wide point-distance SL floor in case the monitoring loop misses a tick (NOT a fixed-money loss guarantee)

input group "=== Risk Protections ==="
input bool   InpDailyLossLimitEnabled = true;
input double InpDailyLossLimitUSD     = 5.00; // REALIZED (closed-deal) loss only, floating P/L excluded. Blocks NEW entries/reversals - never force-closes the open basket
input int    InpMaxSpreadPoints       = 30;
input int    InpSlippagePoints        = 10;
input int    InpMaxExecutionRetries   = 3;
input int    InpMinSecondsBetweenRequests = 2;
input bool   InpEmergencyStop          = false; // true = close the whole basket (if any), NEVER reverse, and block every entry

input group "=== Timing ==="
input int    InpStartDelaySeconds   = 3;
input int    InpPostProfitWaitSeconds = 3;
input int    InpOperationTimeoutSeconds = 30; // max wait for broker confirmation of an open/close before reconciling against real positions

input group "=== Misc ==="
input int    InpMagicNumber       = 20261103;
input string InpTradeComment      = "SmartReversalEA";

input group "=== Trade Logging ==="
input bool   InpLogToCSV            = true;
input bool   InpLogCommonFolder     = false;
input bool   InpLogAlsoToExpertsTab = true;
input string InpLogSubFolder        = "SachinDevBotsLog";

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
      case CLOSE_REASON_EXTERNAL:      return "EXTERNAL";
   }
   return "UNKNOWN";
}

string DirToString(int d) { return (d == 1) ? "BUY" : (d == -1) ? "SELL" : "NONE"; }

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

//================================= GLOBALS ====================================
CTrade trade;

int maFastHandle = INVALID_HANDLE;
int maSlowHandle = INVALID_HANDLE;
int atrHandle    = INVALID_HANDLE;

ENUM_EA_STATE g_state      = STATE_INITIALIZING;
datetime      g_stateSince = 0;
string        g_lastAction = "EA starting";
string        g_lastError  = "";
uint          g_lastRetcode = 0;
string        g_lastRetcodeText = "";

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
double   g_basketPeak    = -1e18;    // highest basket P/L seen (drives the profit trail)
int      g_basketTarget  = 0;        // positions we tried to open
double   g_basketLot     = 0.0;

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

// ---- EMA signal (only ever fed by FULLY CLOSED candles) ----
datetime g_lastEvalBar         = 0;   // last closed bar that was evaluated
int      g_lastSignal          = 0;   // 1 = bullish cross, -1 = bearish cross, 0 = none yet
datetime g_lastSignalCrossBar  = 0;   // open time of the closed bar on which that cross was confirmed
datetime g_signalBarUsedForEntry = 0; // cross bar that was already consumed by an entry (never reused)
int      g_trendDir            = 0;   // 1 = fast above slow, -1 = below, on the last CLOSED bar (used for the fast-start entry)
bool     g_trendEntryOk        = true; // anti-chase filter verdict for a trend entry in g_trendDir, refreshed once per closed bar
datetime g_pullbackWaitSince   = 0;    // when the pullback filter first blocked the current trend direction
int      g_pullbackWaitDir     = 0;
datetime g_eaStartTime         = 0;   // for the dashboard run-time display

// ---- timing ----
datetime g_startDelayBegin = 0;
datetime g_cooldownEnd     = 0;

// ---- daily protection / reversal chain / growth (persisted) ----
datetime g_currentDay        = 0;
double   g_dailyRealizedPL   = 0.0;
bool     g_dailyHaltFlag     = false;
bool     g_maxRevHalt        = false;
int      g_consecutiveReversals = 0;
int      g_winStreak         = 0;     // consecutive winning baskets - drives basket size and lot growth
int      g_basketNo          = 0;

// ---- lifetime totals (persisted) ----
int      g_totalTrades = 0;
int      g_totalWins   = 0;
int      g_totalLosses = 0;
double   g_totalRealizedProfit = 0.0;
double   g_totalRealizedLoss   = 0.0;
int      g_tradeNumberCounter  = 0;

// ---- CSV logger ----
int    gLogHandle   = INVALID_HANDLE;
string gLogFileName = "";

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
   static datetime last[16];
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

void RecordRetcode(uint rc, string desc)
{
   g_lastRetcode = rc;
   g_lastRetcodeText = desc;
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
   if(InpMaxTotalLots < InpFixedLotSize - 1e-9)
                                     ok = InputError(StringFormat("InpMaxTotalLots (%.2f) must be at least one position of InpFixedLotSize (%.4f)", InpMaxTotalLots, InpFixedLotSize));
   if(InpBasketMin < 1)              ok = InputError(StringFormat("InpBasketMin must be >= 1 (got %d)", InpBasketMin));
   if(InpBasketMax < InpBasketMin)   ok = InputError(StringFormat("InpBasketMax (%d) must be >= InpBasketMin (%d)", InpBasketMax, InpBasketMin));
   if(InpBasketMax > MAX_BASKET_HARD)ok = InputError(StringFormat("InpBasketMax (%d) exceeds the hard ceiling of %d positions", InpBasketMax, MAX_BASKET_HARD));
   if(InpWinsPerStep < 1)            ok = InputError(StringFormat("InpWinsPerStep must be >= 1 (got %d)", InpWinsPerStep));
   if(InpGrowthEnabled && InpLotStep <= 0.0)
                                     ok = InputError(StringFormat("InpLotStep must be > 0 when growth is enabled (got %.4f)", InpLotStep));
   if(InpATRPeriod < 1)              ok = InputError(StringFormat("InpATRPeriod must be >= 1 (got %d)", InpATRPeriod));
   if(InpMaxChaseATR <= 0.0)         ok = InputError(StringFormat("InpMaxChaseATR must be > 0 (got %.4f)", InpMaxChaseATR));
   if(InpMaxPullbackWaitMin < 0)     ok = InputError(StringFormat("InpMaxPullbackWaitMin must be >= 0 (got %d)", InpMaxPullbackWaitMin));
   if(InpLossThresholdUSD <= 0.0)    ok = InputError(StringFormat("InpLossThresholdUSD must be > 0 (got %.4f)", InpLossThresholdUSD));
   if(InpProfitMinUSD <= 0.0)        ok = InputError(StringFormat("InpProfitMinUSD must be > 0 (got %.4f)", InpProfitMinUSD));
   if(InpProfitTargetUSD < InpProfitMinUSD)
                                     ok = InputError(StringFormat("InpProfitTargetUSD (%.4f) must be >= InpProfitMinUSD (%.4f)", InpProfitTargetUSD, InpProfitMinUSD));
   if(InpTrailGivebackUSD < 0.0)     ok = InputError(StringFormat("InpTrailGivebackUSD must be >= 0 (got %.4f)", InpTrailGivebackUSD));
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
   if(InpStartDelaySeconds < 0)      ok = InputError(StringFormat("InpStartDelaySeconds must be >= 0 (got %d)", InpStartDelaySeconds));
   if(InpPostProfitWaitSeconds < 0)  ok = InputError(StringFormat("InpPostProfitWaitSeconds must be >= 0 (got %d)", InpPostProfitWaitSeconds));
   if(InpOperationTimeoutSeconds < 5)ok = InputError(StringFormat("InpOperationTimeoutSeconds must be >= 5 (got %d)", InpOperationTimeoutSeconds));
   if(InpMagicNumber <= 0)           ok = InputError(StringFormat("InpMagicNumber must be > 0 - magic 0 is the manual-trade magic and would hijack manual positions (got %d)", InpMagicNumber));
   if(StringLen(InpTradeComment) > 31)
                                     ok = InputError("InpTradeComment must be at most 31 characters");
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

// Lot grows ONLY after winning baskets and falls back to the base lot after any loss (anti-martingale, never up after a loss).
double CurrentLot()
{
   double lot = InpFixedLotSize;
   if(InpGrowthEnabled) lot += (double)(g_winStreak / InpWinsPerStep) * InpLotStep;
   return ClampLot(lot);
}

int CurrentBasketSize()
{
   int n = InpBasketMin;
   if(InpGrowthEnabled) n += g_winStreak;
   return MathMin(n, InpBasketMax);
}

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

//================================= PERSISTENCE ====================================
void SavePersistentState()
{
   GlobalVariableSet(GVKey("Day"),       (double)g_currentDay);
   GlobalVariableSet(GVKey("DailyHalt"), g_dailyHaltFlag ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("DailyLimit"),InpDailyLossLimitUSD);
   GlobalVariableSet(GVKey("MaxRevHalt"),g_maxRevHalt ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("ConsecRev"), (double)g_consecutiveReversals);
   GlobalVariableSet(GVKey("WinStreak"), (double)g_winStreak);
   GlobalVariableSet(GVKey("BasketNo"),  (double)g_basketNo);
   GlobalVariableSet(GVKey("SigBarUsed"),(double)g_signalBarUsedForEntry);
   GlobalVariableSet(GVKey("TradeNo"),   (double)g_tradeNumberCounter);
   GlobalVariableSet(GVKey("TotTrades"), (double)g_totalTrades);
   GlobalVariableSet(GVKey("TotWins"),   (double)g_totalWins);
   GlobalVariableSet(GVKey("TotLosses"), (double)g_totalLosses);
   GlobalVariableSet(GVKey("TotProfit"), g_totalRealizedProfit);
   GlobalVariableSet(GVKey("TotLoss"),   g_totalRealizedLoss);
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
//| commission and fee exactly once, so entry-side commission is not  |
//| missed and exit-side commission is not double counted.            |
//| Floating P/L is deliberately NOT included.                        |
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
      g_winStreak             = (int)GlobalVariableGet(GVKey("WinStreak"));
      g_basketNo              = (int)GlobalVariableGet(GVKey("BasketNo"));
      g_signalBarUsedForEntry = (datetime)(long)GlobalVariableGet(GVKey("SigBarUsed"));
      g_tradeNumberCounter    = (int)GlobalVariableGet(GVKey("TradeNo"));
      g_totalTrades           = (int)GlobalVariableGet(GVKey("TotTrades"));
      g_totalWins             = (int)GlobalVariableGet(GVKey("TotWins"));
      g_totalLosses           = (int)GlobalVariableGet(GVKey("TotLosses"));
      g_totalRealizedProfit   = GlobalVariableGet(GVKey("TotProfit"));
      g_totalRealizedLoss     = GlobalVariableGet(GVKey("TotLoss"));

      if(savedDay != g_currentDay)
      {
         // The trading day rolled while the EA was off: yesterday's max-reversal halt and chain no longer apply.
         g_maxRevHalt = false;
         g_consecutiveReversals = 0;
         LogInfo("Trading day changed while the EA was offline - max-reversal halt and reversal chain reset.");
      }
   }
   else
   {
      ReconstructLifetimeFromHistory();
      LogInfo(StringFormat("First run for this account/symbol/magic - lifetime stats rebuilt from history (%d closed trades).", g_totalTrades));
   }

   // Restore a same-day halt from the persisted flag - but only if the limit has not been changed since, so that a
   // deliberate limit change on restart is honoured. History may still be syncing right after a terminal start, so the
   // persisted flag is the safe floor; the deal-history rebuild below can only ADD to it, never clear it.
   g_dailyHaltFlag = false;
   if(InpDailyLossLimitEnabled && GlobalVariableCheck(GVKey("Day")) &&
      (datetime)(long)GlobalVariableGet(GVKey("Day")) == g_currentDay &&
      GlobalVariableGet(GVKey("DailyHalt")) > 0.5 &&
      MathAbs(GlobalVariableGet(GVKey("DailyLimit")) - InpDailyLossLimitUSD) < 1e-9)
      g_dailyHaltFlag = true;

   // Today's realized P/L is ALWAYS rebuilt from deal history, so a restart can never erase today's loss.
   RebuildDailyState();
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
   RebuildDailyState();
   SavePersistentState();
   LogInfo("New broker-server trading day - daily realized P/L rebuilt, daily and max-reversal halts cleared.");
}

//================================= TRADE EVENT LOGGER ====================================
void OpenLogFile()
{
   if(!InpLogToCSV) return;

   if(InpLogSubFolder != "")
      FolderCreate(InpLogSubFolder, InpLogCommonFolder ? FILE_COMMON : 0);

   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   string baseName = StringFormat("SmartReversalEA_%s_%d_%04d%02d%02d_%02d%02d%02d.csv",
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

   FileWrite(gLogHandle, "LoggedAt", "TradeNo", "BasketNo", "PositionID", "Symbol", "Magic", "Direction", "Volume",
             "EntryTime", "EntryPrice", "ExitTime", "ExitPrice",
             "GrossProfit", "Commission", "Swap", "Fee", "NetPL",
             "ClosingReason", "CloseDealTicket", "ExecRetcode", "ReversalCount", "NextDirection", "Currency");
   FileFlush(gLogHandle);
}

void CloseLogFile()
{
   if(gLogHandle != INVALID_HANDLE)
   {
      FileClose(gLogHandle);
      gLogHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| One row per COMPLETED position (all partial closes aggregated),   |
//| tagged with its BasketNo. CloseDealTicket is the last closing deal;|
//| ExecRetcode is the retcode of OUR close request (0 = closed by    |
//| SL/manual/unknown).                                               |
//+------------------------------------------------------------------+
void LogTradeRow(const TradeSummary &s, int basketNo, ENUM_CLOSE_REASON reason, uint execRetcode, int nextDir, double net)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);

   if(InpLogAlsoToExpertsTab)
   {
      PrintFormat("[TRADE #%d basket %d] pos=%I64u %s vol=%.2f entry=%s exit=%s gross=%.2f comm=%.2f swap=%.2f fee=%.2f net=%.2f %s reason=%s closeDeal=%I64u retcode=%u next=%s revCount=%d",
                  g_tradeNumberCounter, basketNo, s.ident, DirToString(s.dir), s.volume,
                  DoubleToString(s.entryPrice, _Digits), DoubleToString(s.exitPrice, _Digits),
                  s.profit, s.commission, s.swap, s.fee, net, ccy,
                  CloseReasonToString(reason), s.closeDeal, execRetcode, DirToString(nextDir), g_consecutiveReversals);
   }

   if(gLogHandle == INVALID_HANDLE) return;

   FileWrite(gLogHandle,
             TimeToString(Now(), TIME_DATE | TIME_SECONDS), g_tradeNumberCounter, basketNo, (string)s.ident, _Symbol, InpMagicNumber,
             DirToString(s.dir), DoubleToString(s.volume, 2),
             TimeToString(s.entryTime, TIME_DATE | TIME_SECONDS), DoubleToString(s.entryPrice, _Digits),
             TimeToString(s.exitTime, TIME_DATE | TIME_SECONDS),  DoubleToString(s.exitPrice, _Digits),
             DoubleToString(s.profit, 2), DoubleToString(s.commission, 2), DoubleToString(s.swap, 2), DoubleToString(s.fee, 2),
             DoubleToString(net, 2), CloseReasonToString(reason), (string)s.closeDeal, (string)execRetcode,
             g_consecutiveReversals, DirToString(nextDir), ccy);
   FileFlush(gLogHandle);
}

//================================= STATE MACHINE CORE ====================================
#define SM(x) (1 << (x))

// Explicit transition table. Anything not listed here is an illegal transition.
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
//| entered (redirected to EMERGENCY_HALTED, or refused if a managed  |
//| position is still open) - the halt cannot be bypassed.            |
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
//|  POSITION_TICKET     -> used to select / close a position         |
//|  POSITION_IDENTIFIER -> equals DEAL_POSITION_ID, used for history |
//| They are separate fields and are never assumed interchangeable.   |
//| 'floating' = sum of POSITION_PROFIT + POSITION_SWAP (no entry     |
//| commission - that is added from deal history by GetFloatingPL).   |
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
   g_basketPeak = -1e18;
   g_basketTarget = 0;
   g_basketLot = 0.0;
   g_closePartial = false;
}

//+------------------------------------------------------------------+
//| Net floating P/L of the whole live basket (profit + swap + entry  |
//| commission/fee) and its size in REF_LOT units. Never silently     |
//| reports 0 for positions that exist.                               |
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
      if(!g_identCostOk[idx]) g_identCostOk[idx] = LoadIdentCost(id[i], g_identCost[idx]);   // history may lag right after the fill
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

   if(volOut <= 0.0) return false;                                  // no closing deal visible yet
   if(requireComplete && volOut + 1e-8 < volIn) return false;       // history still missing part of the close

   s.volume     = (volIn > 0.0) ? volIn : volOut;
   s.entryPrice = (volIn  > 0.0) ? pxIn  / volIn  : g_posAvgPrice;
   s.exitPrice  = pxOut / volOut;
   if(s.dir == 0)       s.dir = g_posDir;
   if(s.entryTime == 0) s.entryTime = g_posEntryTime;
   return true;
}

//================================= SIGNAL (CLOSED CANDLES ONLY) ====================================
//+------------------------------------------------------------------+
//| Detects a fresh EMA cross on the last FULLY CLOSED bars.          |
//| CopyBuffer() always places the OLDEST copied element at the start |
//| of the physical array. With the default (non-series) flag index 0 |
//| is therefore the oldest bar and the LAST index is the newest -    |
//| which in v3.02 meant fast[2] was the still-forming candle. Here   |
//| every array is explicitly set as series (index 0 = newest copied) |
//| and copied from shift 1, so shift 0 (the forming bar) is NEVER    |
//| read:   [0] = shift 1 (last closed)   [1] = shift 2 (before it)   |
//+------------------------------------------------------------------+
void UpdateSignal()
{
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE) return;

   datetime barTime[];
   ArraySetAsSeries(barTime, true);
   if(CopyTime(_Symbol, InpSignalTimeframe, 1, 1, barTime) != 1) return;   // shift 1 = last closed bar of the SIGNAL timeframe
   if(barTime[0] == g_lastEvalBar) return;                              // this closed bar was already evaluated

   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(maFastHandle, 0, 1, 2, fast) != 2 || CopyBuffer(maSlowHandle, 0, 1, 2, slow) != 2)
   {
      if(ThrottleOk(0, 60)) LogWarning("EMA buffers not ready yet (CopyBuffer returned fewer bars than requested) - will retry.");
      return;                                                           // g_lastEvalBar untouched -> retried on next call
   }
   if(!MathIsValidNumber(fast[0]) || !MathIsValidNumber(fast[1]) || !MathIsValidNumber(slow[0]) || !MathIsValidNumber(slow[1])
      || fast[0] == EMPTY_VALUE || slow[0] == EMPTY_VALUE || fast[1] == EMPTY_VALUE || slow[1] == EMPTY_VALUE)
      return;

   g_lastEvalBar = barTime[0];
   g_trendDir = (fast[0] > slow[0]) ? 1 : (fast[0] < slow[0]) ? -1 : 0;   // closed-bar trend, never the forming bar

   // Anti-chase filter for trend entries. Uses only the last CLOSED bar (shift 1): the close must not be stretched
   // more than InpMaxChaseATR ATRs beyond the fast EMA in the trade direction (= wait for a pullback), and the candle
   // must close in the trade direction (= the pullback has turned). If any input is unavailable the filter fails SAFE (blocks).
   g_trendEntryOk = true;
   if(InpUsePullbackFilter && g_trendDir != 0)
   {
      double atr[], cl[], op[];
      ArraySetAsSeries(atr, true); ArraySetAsSeries(cl, true); ArraySetAsSeries(op, true);
      bool have = (atrHandle != INVALID_HANDLE &&
                   CopyBuffer(atrHandle, 0, 1, 1, atr) == 1 &&
                   CopyClose(_Symbol, InpSignalTimeframe, 1, 1, cl) == 1 &&
                   CopyOpen(_Symbol, InpSignalTimeframe, 1, 1, op) == 1 &&
                   MathIsValidNumber(atr[0]) && atr[0] > 0.0);
      if(!have) g_trendEntryOk = false;
      else
      {
         double stretch = (g_trendDir == 1) ? (cl[0] - fast[0]) : (fast[0] - cl[0]);   // >0 = beyond the fast EMA in trade direction
         if(stretch > InpMaxChaseATR * atr[0]) g_trendEntryOk = false;                  // too extended - would be chasing
         if(InpRequireCandleConfirm)
         {
            bool candleWithTrend = (g_trendDir == 1) ? (cl[0] > op[0]) : (cl[0] < op[0]);
            if(!candleWithTrend) g_trendEntryOk = false;
         }
      }
   }

   if(fast[1] <= slow[1] && fast[0] > slow[0])
   {
      g_lastSignal = 1;
      g_lastSignalCrossBar = barTime[0];
      LogInfo("EMA crossover signal: BULLISH cross confirmed on the last closed bar.");
   }
   else if(fast[1] >= slow[1] && fast[0] < slow[0])
   {
      g_lastSignal = -1;
      g_lastSignalCrossBar = barTime[0];
      LogInfo("EMA crossover signal: BEARISH cross confirmed on the last closed bar.");
   }
   // No cross on this bar: the previous cross (if still unused) intentionally stays valid until it is consumed.
}

bool HasFreshUnusedSignal()
{
   return (g_lastSignal != 0 && g_lastSignalCrossBar != 0 && g_lastSignalCrossBar != g_signalBarUsedForEntry);
}

// Marks the current cross as used so it can never trigger an entry again (also across restarts).
void ConsumeCurrentSignal()
{
   g_signalBarUsedForEntry = g_lastSignalCrossBar;
   SavePersistentState();
}

//================================= ORDER EXECUTION ====================================
bool IsUncertainRetcode(uint rc)
{
   return (rc == TRADE_RETCODE_TIMEOUT || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_ERROR || rc == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Opens one BASKET: N same-direction positions of the current lot.  |
//| N and the lot come from the win streak (CurrentBasketSize/Lot)    |
//| and are shrunk to fit InpMaxTotalLots and the free margin. The    |
//| boolean returned by CTrade is NOT proof of a fill: ResultRetcode()|
//| is checked for every order, and uncertain outcomes (timeout /     |
//| connection) are reconciled against the real broker positions      |
//| instead of being guessed. If a later order of the basket fails,   |
//| the basket simply stays at the size that was actually filled.     |
//+------------------------------------------------------------------+
ENUM_REQ_RESULT ExecuteOpen(int direction, ENUM_OPEN_INTENT intent)
{
   // ---- hard guards: these make every halt un-bypassable regardless of the caller ----
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

   double lot = CurrentLot();
   if(lot <= 0.0)
   {
      EnterError("Open REJECTED: lot is not supported by this symbol's volume min/max/step configuration.");
      return REQ_DEFERRED;
   }

   // ---- basket size: streak-based, then capped by total volume and by free margin ----
   int n = CurrentBasketSize();
   n = MathMin(n, (int)MathFloor(InpMaxTotalLots / lot + 1e-9));

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

   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;
   g_openRequestTime = Now();

   int opened = 0;
   for(int k = 0; k < n; k++)
   {
      if(k > 0 && !SpreadOK()) { LogWarning(StringFormat("Basket stopped at %d/%d positions: spread widened.", opened, n)); break; }

      double sl = ComputeProtectiveStop(direction, slWhy);   // fresh stop for every order
      if(sl <= 0.0)
      {
         if(opened == 0) { LogWarning("Open deferred: cannot place a valid protective stop (" + slWhy + ")."); return REQ_DEFERRED; }
         LogWarning(StringFormat("Basket stopped at %d/%d positions: no valid stop (%s).", opened, n, slWhy));
         break;
      }

      bool sent = (direction == 1)
                ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, InpTradeComment)
                : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, InpTradeComment);
      uint rc = trade.ResultRetcode();
      RecordRetcode(rc, trade.ResultRetcodeDescription());

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
            g_openIntent = intent; g_openDir = direction; g_basketTarget = n; g_basketLot = lot;
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
   g_basketTarget = n;
   g_basketLot = lot;
   if(opened < n) LogWarning(StringFormat("Basket opened with %d of %d planned positions.", opened, n));
   return REQ_ACCEPTED;
}

//+------------------------------------------------------------------+
//| Requests closure of EVERY basket position. DONE does not mean     |
//| flat: completion is only ever confirmed by Reconcile() seeing zero|
//| managed volume. Positions that fail to close are retried by the   |
//| CLOSING watchdog. The close reason is stored BEFORE the requests  |
//| so the confirmation path can never mistake it for a loss reversal.|
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
   if(cnt == 0) return REQ_DEFERRED;                       // already flat - Reconcile() will finalize it
   if(s.mixed) { EnterError("Close aborted: BUY and SELL positions are mixed in the basket."); return REQ_DEFERRED; }
   SyncTracking(s, id);

   ENUM_CLOSE_REASON prevReason = g_pendingCloseReason;
   string prevDetail = g_pendingCloseDetail;
   g_pendingCloseReason = reason;
   g_pendingCloseDetail = detail;
   g_closeRequestTime = Now();
   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;

   int okCount = 0, uncertainCount = 0, failCount = 0;
   bool anyPartial = false;
   uint lastRc = 0;
   string lastDesc = "";
   for(int i = 0; i < cnt; i++)
   {
      bool sent = trade.PositionClose(tk[i], (ulong)InpSlippagePoints);
      uint rc = trade.ResultRetcode();
      lastRc = rc;
      lastDesc = trade.ResultRetcodeDescription();
      if(sent && rc == TRADE_RETCODE_DONE)              okCount++;
      else if(sent && rc == TRADE_RETCODE_DONE_PARTIAL) { okCount++; anyPartial = true; }
      else if(IsUncertainRetcode(rc))                   uncertainCount++;
      else                                              failCount++;
   }
   g_closeRetcode = lastRc;
   RecordRetcode(lastRc, lastDesc);

   if(okCount > 0 || uncertainCount > 0)
   {
      g_retryCounter = 0;
      g_closePartial = (okCount < cnt) || anyPartial;
      if(failCount > 0 || anyPartial)
         LogWarning(StringFormat("Basket close: %d of %d closed, %d failed, %d uncertain - remaining positions will be retried.", okCount, cnt, failCount, uncertainCount));
      return (okCount == 0) ? REQ_UNCERTAIN : REQ_ACCEPTED;
   }

   // nothing closed: definite rejection - the pending close did not happen
   g_pendingCloseReason = prevReason;
   g_pendingCloseDetail = prevDetail;
   g_retryCounter++;
   LogError(StringFormat("Basket close REJECTED (%d positions, attempt %d/%d): %s", cnt, g_retryCounter, InpMaxExecutionRetries, lastDesc), (int)lastRc);
   // An emergency close is retried indefinitely (with throttle) - it must never give up and leave positions unmanaged.
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
            TransitionTo(STATE_REVERSAL_PENDING, StringFormat("Original %s basket confirmed fully closed - reversing to %s.", DirToString(closedDir), DirToString(g_reversalDir)));
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
         g_consecutiveReversals = 0;
         ConsumeCurrentSignal();
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Profit close confirmed; a halt is active.");
         else
         {
            g_cooldownEnd = Now() + InpPostProfitWaitSeconds;
            TransitionTo(STATE_COOLDOWN, "Profit close confirmed - short cooldown, then the next basket.");
         }
         break;

      default:   // EXTERNAL / unknown: SL, manual, broker - never reversed
         g_consecutiveReversals = 0;
         ConsumeCurrentSignal();
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Basket closed externally; a halt is active.");
         else
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Basket closed externally (SL/manual/broker) - no reversal, waiting for a fresh signal.");
         break;
   }
}

// The whole basket is now confirmed gone from the broker: book every position as ONE completed trade, update the
// win streak (drives basket size / lot growth), then route.
void OnBasketClosed(const TradeSummary &sums[])
{
   ENUM_CLOSE_REASON reason = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL;
   uint execRetcode = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_closeRetcode : 0;
   int closedDir = (g_posDir != 0) ? g_posDir : (ArraySize(sums) > 0 ? sums[0].dir : 0);
   int nextDir = (reason == CLOSE_REASON_LOSS_REVERSAL) ? -closedDir : 0;

   g_basketNo++;
   double basketNet = 0.0;
   int n = ArraySize(sums);
   for(int i = 0; i < n; i++)
   {
      double net = sums[i].profit + sums[i].commission + sums[i].swap + sums[i].fee;
      basketNet += net;
      g_tradeNumberCounter++;
      g_totalTrades++;
      if(net >= 0.0) { g_totalWins++;   g_totalRealizedProfit += net; }
      else           { g_totalLosses++; g_totalRealizedLoss   += (-net); }
      LogTradeRow(sums[i], g_basketNo, reason, execRetcode, nextDir, net);
   }

   // Growth is earned only by profit: a winning basket extends the streak, any losing basket resets size and lot to the minimum.
   if(basketNet > 1e-9)       g_winStreak++;
   else if(basketNet < -1e-9) g_winStreak = 0;
   LogInfo(StringFormat("Basket #%d closed: %d positions, net %.2f, reason %s. Win streak now %d -> next basket %d x %.2f lot.",
                        g_basketNo, n, basketNet, CloseReasonToString(reason), g_winStreak, CurrentBasketSize(), CurrentLot()));

   ClearTracking();
   g_pendingCloseReason = CLOSE_REASON_NONE;
   g_pendingCloseDetail = "";
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
            g_consecutiveReversals++;   // counted ONLY now: the original is confirmed closed AND the opposite basket is confirmed open
            LogInfo(StringFormat("Reversal #%d CONFIRMED: %s basket of %d positions is open.", g_consecutiveReversals, DirToString(s.dir), s.count));
         }
         else
            g_consecutiveReversals = 0;     // an initial entry starts a new reversal chain
         g_openIntent = INTENT_NONE;
         g_reversalDir = 0;
         g_retryCounter = 0;
         g_lastError = "";
         g_pendingCloseReason = CLOSE_REASON_NONE;
         g_basketPeak = -1e18;
         SavePersistentState();
         EnsureProtectiveStop();
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Confirmed: %s basket %d x %.2f lot (%.2f total) @ %s.",
                      DirToString(s.dir), s.count, (s.count > 0) ? s.volume / s.count : 0.0, s.volume, DoubleToString(s.avgPrice, _Digits)));
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
         break;   // ACTIVE / CLOSING_* / EMERGENCY_HALTED (the emergency hook closes strays) / ERROR
   }
}

// No managed position exists at the broker.
void OnPositionAbsent()
{
   int n = ArraySize(g_idents);
   if(n == 0) return;   // nothing was being tracked

   TradeSummary sums[];
   ArrayResize(sums, n);
   bool all = true;
   for(int i = 0; i < n; i++)
      if(!BuildTradeSummary(g_idents[i], sums[i], true)) all = false;

   if(!all)
   {
      if(g_finalizeWaitSince == 0) g_finalizeWaitSince = Now();
      if(Now() - g_finalizeWaitSince < FINALIZE_WAIT_SEC) return;   // give the history time to catch up, retried every tick/timer

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
//| Called after every relevant trade transaction and on every tick / |
//| timer in the states where a position can appear or vanish.        |
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
         return false;   // OPENING / CLOSING_* handle themselves (CLOSING_* routes to EMERGENCY_HALTED on confirmation)
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
            RebuildDailyState();   // history may have finished syncing since OnInit - can only tighten the halt, never loosen it
            if(BlockedByHalt()) TransitionTo(STATE_DAILY_HALTED, "Start delay elapsed but a halt is active.");
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Ready - waiting for entry signal.");
         }
         break;

      case STATE_WAITING_INITIAL_SIGNAL:
      {
         if(BlockedByHalt()) { TransitionTo(STATE_DAILY_HALTED, "Halt active - not entering."); break; }

         // A fresh unused cross always wins. Otherwise, in fast-start mode, enter with the current closed-bar EMA trend
         // instead of waiting (possibly for a long time on M1) for the next cross.
         int dir = 0;
         bool viaCross = false;
         if(HasFreshUnusedSignal())                                              { dir = g_lastSignal; viaCross = true; }
         else if(InpEntryMode == ENTRY_ON_CROSS_OR_TREND && g_trendDir != 0)
         {
            if(g_pullbackWaitDir != g_trendDir) { g_pullbackWaitDir = g_trendDir; g_pullbackWaitSince = 0; }   // trend flipped: restart the wait
            if(g_trendEntryOk) dir = g_trendDir;
            else
            {
               if(g_pullbackWaitSince == 0) g_pullbackWaitSince = Now();
               int waitedMin = (int)((Now() - g_pullbackWaitSince) / 60);
               if(InpMaxPullbackWaitMin > 0 && waitedMin >= InpMaxPullbackWaitMin)
               {
                  dir = g_trendDir;   // bounded wait: do not sit out the trend forever
                  if(ThrottleOk(12, 60)) LogInfo(StringFormat("Pullback wait timed out after %d min - entering %s with the trend.", waitedMin, DirToString(dir)));
               }
               else g_lastAction = StringFormat("Wait pullback %s (%d/%d min)", DirToString(g_trendDir), waitedMin, InpMaxPullbackWaitMin);
            }
         }
         if(dir == 0) break;

         datetime backup = g_signalBarUsedForEntry;
         ENUM_REQ_RESULT r = ExecuteOpen(dir, INTENT_INITIAL);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
         {
            g_signalUsedBackup = backup;
            g_pullbackWaitSince = 0;
            if(viaCross) ConsumeCurrentSignal();   // one cross -> at most one entry, even across restarts
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Opening %s basket (%s).", DirToString(dir), viaCross ? "EMA cross" : "EMA trend"));
         }
         break;
      }

      case STATE_OPENING_POSITION:
         // Confirmation arrives via Reconcile() (transaction event or poll). Watchdog: never wait forever.
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
               g_signalBarUsedForEntry = g_signalUsedBackup;   // un-consume: the entry never happened
               g_openIntent = INTENT_NONE;
               TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Initial open unconfirmed - back to waiting for the signal.");
            }
         }
         break;

      case STATE_POSITION_ACTIVE:
      {
         double pl, units;
         if(!GetFloatingPL(pl, units) || units <= 0.0) break;

         // All thresholds are per REF_LOT and scale with the basket's total volume, so the price distance that triggers an
         // exit is the same for a 1-position basket and a 20-position basket, and spread alone cannot trigger a reversal.
         double lossLimit = InpLossThresholdUSD * units;
         double minProfit = InpProfitMinUSD * units;
         double maxProfit = InpProfitTargetUSD * units;
         double giveback  = InpTrailGivebackUSD * units;

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

         if(pl > g_basketPeak) g_basketPeak = pl;

         // Profit: close at once at the maximum; once the minimum has been reached, trail the peak but never let the
         // stop-out level fall below the minimum.
         bool closeProfit = false;
         string pdetail = "";
         if(pl >= maxProfit)
         {
            closeProfit = true;
            pdetail = StringFormat("PROFIT max: basket P/L=%.2f >= %.2f", pl, maxProfit);
         }
         else if(g_basketPeak >= minProfit)
         {
            double floorLvl = MathMax(minProfit, g_basketPeak - giveback);
            if(pl <= floorLvl)
            {
               closeProfit = true;
               pdetail = StringFormat("PROFIT trail: basket P/L=%.2f fell to floor %.2f (peak %.2f, min %.2f)", pl, floorLvl, g_basketPeak, minProfit);
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
         // Completion is confirmed by Reconcile() (zero managed volume). Here only the controlled retry / watchdog lives.
         PosSnap s;
         if(ScanManaged(s) == 0) break;
         bool stale = (Now() - g_closeRequestTime >= InpOperationTimeoutSeconds);
         if(g_closePartial || stale)
            ExecuteClose(g_pendingCloseReason != CLOSE_REASON_NONE ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL, g_pendingCloseDetail);
         break;
      }

      case STATE_REVERSAL_PENDING:
      {
         // Checks, in order: halts -> reversal cap -> (ExecuteOpen: flat verification, permissions, spread, margin, stop).
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
            ConsumeCurrentSignal();
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "No valid reversal direction - waiting for a fresh signal.");
            break;
         }
         ENUM_REQ_RESULT r = ExecuteOpen(g_reversalDir, INTENT_REVERSAL);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Opening reversal %s basket (confirmed reversal #%d will be counted on fill).", DirToString(g_reversalDir), g_consecutiveReversals + 1));
         break;
      }

      case STATE_COOLDOWN:
         if(Now() >= g_cooldownEnd)
         {
            if(BlockedByHalt()) TransitionTo(STATE_DAILY_HALTED, "Cooldown elapsed but a halt is active.");
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Cooldown over - waiting for entry signal.");
         }
         break;

      case STATE_DAILY_HALTED:
         if(!BlockedByHalt())
         {
            ConsumeCurrentSignal();   // a stale pre-halt cross must not fire the moment trading resumes
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Halt cleared (new trading day) - resuming, a fresh signal is required.");
         }
         break;

      case STATE_EMERGENCY_HALTED:
      case STATE_ERROR:
         break;   // terminal for trading
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

   // The base lot must sit inside the symbol's limits and step grid.
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

   // --- account mode ---
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_isNetting = (mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_marginModeStr = (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) ? "HEDGING" : (mm == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) ? "NETTING" : "EXCHANGE";

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.SetAsyncMode(false);

   maFastHandle = iMA(_Symbol, InpSignalTimeframe, InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandle = iMA(_Symbol, InpSignalTimeframe, InpSlowMA, 0, InpMAMethod, InpMAPrice);
   atrHandle    = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      LogError("Failed to create EMA/ATR indicator handles", GetLastError());
      ReleaseInstanceLock();
      return INIT_FAILED;
   }

   OpenLogFile();
   LogInfo(StringFormat("EA session starting. v%s Symbol=%s TF=%s Magic=%d Account=%I64d (%s, DEMO)",
                        EA_VERSION, _Symbol, EnumToString(_Period), InpMagicNumber, AccountInfoInteger(ACCOUNT_LOGIN), g_marginModeStr));
   LogInfo("Single-symbol EA: it only manages " + _Symbol + ". Attach one instance (own magic number) per symbol/chart for several symbols.");
   LogInfo(StringFormat("Basket engine: %d-%d positions per basket, base lot %.2f, growth %s (+%.2f lot per %d winning baskets, per-position cap %.2f, basket cap %.2f lots). "
                        "Lot and basket size grow only after wins and reset after any loss.",
                        InpBasketMin, InpBasketMax, InpFixedLotSize, InpGrowthEnabled ? "ON" : "OFF", InpLotStep, InpWinsPerStep,
                        MathMin(InpMaxLotSize, HARD_MAX_LOT), InpMaxTotalLots));
   LogInfo(StringFormat("Exits are per %.2f lot and scale with basket volume: reverse at -%.2f, profit trail arms at +%.2f, closes at +%.2f (giveback %.2f).",
                        REF_LOT, InpLossThresholdUSD, InpProfitMinUSD, InpProfitTargetUSD, InpTrailGivebackUSD));
   LogInfo(StringFormat("Daily loss limit counts REALIZED (closed-deal) P/L only; floating P/L is excluded. Protective stop: %d-point backstop per position - "
                        "it does NOT guarantee a fixed money loss (gaps, slippage, tick value, spread).", InpProtectiveStopPoints));

   // A loss threshold below the immediate spread cost makes every new basket reverse at once.
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

   LoadPersistentState();

   // --- restart recovery: adopt the real broker positions instead of trusting stored state ---
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
   LogInfo(StringFormat("Session ending. Reason=%d TotalTrades=%d Wins=%d Losses=%d TotalProfit=%.2f TotalLoss=%.2f",
                         reason, g_totalTrades, g_totalWins, g_totalLosses, g_totalRealizedProfit, g_totalRealizedLoss));
   if(maFastHandle != INVALID_HANDLE) { IndicatorRelease(maFastHandle); maFastHandle = INVALID_HANDLE; }
   if(maSlowHandle != INVALID_HANDLE) { IndicatorRelease(maSlowHandle); maSlowHandle = INVALID_HANDLE; }
   if(atrHandle    != INVALID_HANDLE) { IndicatorRelease(atrHandle);    atrHandle    = INVALID_HANDLE; }
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
//| the deal itself is never trusted as the truth. Deals are matched  |
//| by our magic OR by a tracked position id (a manual close deal     |
//| carries magic 0 but still belongs to our position).               |
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

//================================= DASHBOARD (display-only) ====================================
#define DASH_PREFIX "SRE_DASH_"
#define PANEL_X 10
#define PANEL_W 380
#define DASH_ROWS 12
#define DASH_ROW_H 17

void CreateRect(string name, int x, int y, int w, int h, color bg, color border)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, border);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}

void CreateLabel(string name, int x, int y, color clr = clrWhite, int size = 9)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void CreateDashboard()
{
   CreateRect(DASH_PREFIX + "Panel", PANEL_X - 6, 4, PANEL_W, DASH_ROWS * DASH_ROW_H + 14, C'20,20,24', clrDimGray);
   for(int i = 0; i < DASH_ROWS; i++)
      CreateLabel(DASH_PREFIX + "R" + IntegerToString(i), PANEL_X, 10 + i * DASH_ROW_H, clrWhite, (i == 0) ? 11 : 9);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, DASH_PREFIX);
}

void SetRow(int i, string text, color clr)
{
   string name = DASH_PREFIX + "R" + IntegerToString(i);
   if(StringLen(text) > 50) text = StringSubstr(text, 0, 47) + "...";
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

string FormatRunTime(long secs)
{
   if(secs < 0) secs = 0;
   int d = (int)(secs / 86400), h = (int)((secs % 86400) / 3600), m = (int)((secs % 3600) / 60), s = (int)(secs % 60);
   if(d > 0) return StringFormat("%dd %02dh %02dm %02ds", d, h, m, s);
   return StringFormat("%02dh %02dm %02ds", h, m, s);
}

string TimeframeShort()
{
   string tf = EnumToString(InpSignalTimeframe == PERIOD_CURRENT ? _Period : InpSignalTimeframe);   // PERIOD_M5 -> M5
   StringReplace(tf, "PERIOD_", "");
   return tf;
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
   else if(g_dailyHaltFlag)      { daily = "HALTED (loss limit)"; dailyClr = clrTomato; }
   else if(g_maxRevHalt)         { daily = "HALTED (reversal cap)"; dailyClr = clrTomato; }
   else                          { daily = "ok"; }
   string emerg = EmergencyActive() ? ((g_state == STATE_EMERGENCY_HALTED) ? "HALTED" : "closing") : "off";

   string posTxt = haveBasket
                 ? StringFormat("%s %d x %.2f = %.2f lot", DirToString(g_posDir), g_posCount, (g_posCount > 0) ? g_posVolume / g_posCount : 0.0, g_posVolume)
                 : "none";

   // The thresholds shown are for the live basket, or for the NEXT basket when flat.
   double u = haveBasket ? units : (double)CurrentBasketSize() * CurrentLot() / REF_LOT;

   SetRow(0, StringFormat("Smart Reversal EA v%s  [DEMO]", EA_VERSION), clrGold);
   SetRow(1, StringFormat("%s signal %s | %s", _Symbol, TimeframeShort(), g_marginModeStr), clrLime);
   SetRow(2, "Running: " + FormatRunTime((long)(Now() - g_eaStartTime)), clrAqua);
   SetRow(3, "State: " + StateToString(g_state), (g_state == STATE_ERROR) ? clrTomato : clrSkyBlue);
   SetRow(4, "Basket: " + posTxt, clrOrange);
   SetRow(5, StringFormat("Float: %.2f %s | Peak: %s", fl, ccy, (haveBasket && g_basketPeak > -1e17) ? StringFormat("%.2f", g_basketPeak) : "-"),
             (fl < 0.0) ? clrSalmon : clrAqua);
   SetRow(6, StringFormat("Exit: -%.2f | +%.2f..%.2f", InpLossThresholdUSD * u, InpProfitMinUSD * u, InpProfitTargetUSD * u), clrLightGray);
   SetRow(7, StringFormat("Today: %.2f / limit %s %s", g_dailyRealizedPL,
                          InpDailyLossLimitEnabled ? StringFormat("-%.2f", InpDailyLossLimitUSD) : "n/a", ccy), clrWhite);
   SetRow(8, StringFormat("Daily: %s | Emergency: %s", daily, emerg), (g_dailyHaltFlag || g_maxRevHalt || EmergencyActive()) ? clrTomato : dailyClr);
   SetRow(9, StringFormat("Streak: %d | Next: %d x %.2f | Rev: %d/%d", g_winStreak, CurrentBasketSize(), CurrentLot(),
                          g_consecutiveReversals, InpMaxConsecutiveReversals), clrWhite);
   SetRow(10, StringFormat("Trades: %d (W:%d L:%d) Net: %.2f | Spr %s", g_totalTrades, g_totalWins, g_totalLosses,
                           g_totalRealizedProfit - g_totalRealizedLoss, (sp >= 0.0) ? DoubleToString(sp, 1) : "n/a"),
              (sp >= 0.0 && sp <= InpMaxSpreadPoints) ? clrWhite : clrOrange);
   SetRow(11, g_lastError == "" ? "Last: " + g_lastAction : "ERR: " + g_lastError, g_lastError == "" ? clrLightGray : clrTomato);
}
//+------------------------------------------------------------------+
