//+------------------------------------------------------------------+
//|                                          SmartHedgeEA_v3.03.mq5 |
//|                   Smart Reversal EA - state-driven, one position  |
//|                   at a time, loss-triggered direction reversal.   |
//|                                                                  |
//|  DEMO ACCOUNTS ONLY.  One chart symbol per EA instance - this EA  |
//|  is NOT multi-symbol. To trade several symbols attach one EA      |
//|  instance (with its own magic number) to one chart per symbol.   |
//+------------------------------------------------------------------+
#property copyright "Sachin Dev Bots"
#property version   "3.03"
#property strict
#property description "DEMO-ONLY smart reversal EA. One chart symbol per EA instance."

#include <Trade\Trade.mqh>

#define EA_VERSION            "3.03"
#define HARD_MAX_LOT          0.01       // absolute lot ceiling - no martingale / no growth, ever
#define GV_PREFIX             "SRE3_"
#define LOCK_STALE_SEC        15         // a duplicate-instance heartbeat older than this is considered dead
#define FINALIZE_WAIT_SEC     10         // how long to wait for close deals to show up in history
#define HISTORY_LOOKBACK_SEC  (60*86400) // look-back used to associate manual/SL close deals with our positions

//================================= INPUTS ====================================
input group "=== Signal (EMA Crossover, confirmed closed-candle only) ==="
input int    InpFastMA            = 10;
input int    InpSlowMA            = 30;
input ENUM_MA_METHOD InpMAMethod  = MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== Reversal Engine ==="
input double InpLossThresholdUSD    = 0.10;  // close+reverse when floating net loss reaches -this amount
input double InpProfitTargetUSD     = 1.00;  // close (no auto-reverse) when floating net profit reaches +this amount
input int    InpMaxConsecutiveReversals = 20; // safety cap - no further reversal once this many CONFIRMED reversals happened in a row

input group "=== Position Sizing ==="
input double InpFixedLotSize      = 0.01;
input double InpMaxLotSize        = 0.01;   // hard cap - never exceeded, no martingale/growth (also capped at 0.01 in code)

input group "=== Broker-Side Protective Stop (hard backstop, NOT the $ trigger) ==="
input int    InpProtectiveStopPoints = 500; // wide point-distance SL floor in case the monitoring loop misses a tick (NOT a fixed-money loss guarantee)

input group "=== Risk Protections ==="
input bool   InpDailyLossLimitEnabled = true;
input double InpDailyLossLimitUSD     = 5.00; // REALIZED (closed-deal) loss only, floating P/L excluded. Blocks NEW entries/reversals - never force-closes the open position
input int    InpMaxSpreadPoints       = 30;
input int    InpSlippagePoints        = 10;
input int    InpMaxExecutionRetries   = 3;
input int    InpMinSecondsBetweenRequests = 2;
input bool   InpEmergencyStop          = false; // true = close the managed position (if any), NEVER reverse, and block every entry

input group "=== Timing ==="
input int    InpStartDelaySeconds   = 10;
input int    InpPostProfitWaitSeconds = 10;
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
   CLOSE_REASON_PROFIT,          // profit target hit, no reversal
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
   REQ_ACCEPTED,       // DONE / DONE_PARTIAL
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
struct PosSnap            // one live broker position that belongs to this EA (symbol + magic)
{
   bool     valid;
   ulong    ticket;       // POSITION_TICKET     - used to select / close the position
   ulong    ident;        // POSITION_IDENTIFIER - equals DEAL_POSITION_ID, used to query deal history
   int      dir;
   double   volume;
   double   price;
   datetime time;
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

struct TradeSummary       // a completed (fully flat) position, rebuilt from deal history
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

// ---- tracked managed position (always re-verified against the broker by Reconcile()) ----
ulong    g_posTicket     = 0;
ulong    g_posIdent      = 0;
int      g_posDir        = 0;
double   g_posVolume     = 0.0;
double   g_posEntryPrice = 0.0;
datetime g_posEntryTime  = 0;
double   g_posCost       = 0.0;    // entry commission + fee of the tracked position
bool     g_posCostLoaded = false;

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

// ---- timing ----
datetime g_startDelayBegin = 0;
datetime g_cooldownEnd     = 0;

// ---- daily protection / reversal chain (persisted) ----
datetime g_currentDay        = 0;
double   g_dailyRealizedPL   = 0.0;
bool     g_dailyHaltFlag     = false;
bool     g_maxRevHalt        = false;
int      g_consecutiveReversals = 0;

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
                                     ok = InputError(StringFormat("InpMaxLotSize (%.4f) exceeds the hard demo-safety ceiling of %.2f lots", InpMaxLotSize, HARD_MAX_LOT));
   if(InpFixedLotSize > InpMaxLotSize + 1e-9)
                                     ok = InputError(StringFormat("InpFixedLotSize (%.4f) must not exceed InpMaxLotSize (%.4f)", InpFixedLotSize, InpMaxLotSize));
   if(InpLossThresholdUSD <= 0.0)    ok = InputError(StringFormat("InpLossThresholdUSD must be > 0 (got %.4f)", InpLossThresholdUSD));
   if(InpProfitTargetUSD <= 0.0)     ok = InputError(StringFormat("InpProfitTargetUSD must be > 0 (got %.4f)", InpProfitTargetUSD));
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
//| Clamps the fixed lot to the broker's [min,max,step] and to the   |
//| hard cap. Returns 0.0 (reject) instead of silently exceeding the |
//| cap when the broker minimum alone is above it.                   |
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

double CalcLotSize() { return ClampLot(InpFixedLotSize); }

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

   FileWrite(gLogHandle, "LoggedAt", "TradeNo", "PositionID", "Symbol", "Magic", "Direction", "Volume",
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
//| One row per COMPLETED position (all partial closes aggregated).   |
//| CloseDealTicket is the last closing deal; ExecRetcode is the      |
//| retcode of OUR close request (0 = closed by SL/manual/unknown).   |
//+------------------------------------------------------------------+
void LogTradeRow(const TradeSummary &s, ENUM_CLOSE_REASON reason, uint execRetcode, int nextDir, double net)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);

   if(InpLogAlsoToExpertsTab)
   {
      PrintFormat("[TRADE #%d] pos=%I64u %s vol=%.2f entry=%s exit=%s gross=%.2f comm=%.2f swap=%.2f fee=%.2f net=%.2f %s reason=%s closeDeal=%I64u retcode=%u next=%s revCount=%d",
                  g_tradeNumberCounter, s.ident, DirToString(s.dir), s.volume,
                  DoubleToString(s.entryPrice, _Digits), DoubleToString(s.exitPrice, _Digits),
                  s.profit, s.commission, s.swap, s.fee, net, ccy,
                  CloseReasonToString(reason), s.closeDeal, execRetcode, DirToString(nextDir), g_consecutiveReversals);
   }

   if(gLogHandle == INVALID_HANDLE) return;

   FileWrite(gLogHandle,
             TimeToString(Now(), TIME_DATE | TIME_SECONDS), g_tradeNumberCounter, (string)s.ident, _Symbol, InpMagicNumber,
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

//================================= POSITION TRACKING ====================================
//+------------------------------------------------------------------+
//| Finds this EA's live position(s) by SYMBOL + MAGIC only. Returns |
//| the count; 'out' describes the first one.                        |
//|  POSITION_TICKET     -> used to select / close the position      |
//|  POSITION_IDENTIFIER -> equals DEAL_POSITION_ID, used for history |
//| They are separate fields and are never assumed interchangeable.  |
//+------------------------------------------------------------------+
int ScanManaged(PosSnap &out)
{
   out.valid = false; out.ticket = 0; out.ident = 0; out.dir = 0; out.volume = 0.0; out.price = 0.0; out.time = 0;
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      cnt++;
      if(!out.valid)
      {
         out.valid  = true;
         out.ticket = t;
         out.ident  = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         out.dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         out.volume = PositionGetDouble(POSITION_VOLUME);
         out.price  = PositionGetDouble(POSITION_PRICE_OPEN);
         out.time   = (datetime)PositionGetInteger(POSITION_TIME);
      }
   }
   return cnt;
}

// Entry-side commission/fee of the tracked position, read once from deal history (POSITION_COMMISSION is deprecated).
void LoadPositionCosts(ulong ident)
{
   g_posCost = 0.0;
   g_posCostLoaded = false;
   if(ident == 0 || !HistorySelectByPosition(ident)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      g_posCost += HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      g_posCostLoaded = true;
   }
}

void TrackFromSnap(const PosSnap &s)
{
   if(s.ident != g_posIdent || !g_posCostLoaded) LoadPositionCosts(s.ident);
   g_posTicket     = s.ticket;
   g_posIdent      = s.ident;
   g_posDir        = s.dir;
   g_posVolume     = s.volume;
   g_posEntryPrice = s.price;
   g_posEntryTime  = s.time;
}

void ClearTracking()
{
   g_posTicket = 0; g_posIdent = 0; g_posDir = 0; g_posVolume = 0.0; g_posEntryPrice = 0.0; g_posEntryTime = 0;
   g_posCost = 0.0; g_posCostLoaded = false;
   g_closePartial = false;
}

// Net floating P/L of the tracked position. Never silently reports 0 for a position that still exists:
// if the tracked ticket no longer selects, the broker is re-scanned and the tracking healed.
bool GetFloatingPL(double &pl)
{
   pl = 0.0;
   if(g_posTicket == 0) return false;
   if(!PositionSelectByTicket(g_posTicket))
   {
      PosSnap s;
      if(ScanManaged(s) != 1) return false;
      TrackFromSnap(s);
      if(!PositionSelectByTicket(g_posTicket)) return false;
   }
   if(!g_posCostLoaded) LoadPositionCosts(g_posIdent);
   pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + g_posCost;
   return true;
}

//+------------------------------------------------------------------+
//| Rebuilds a completed trade from the position's own deal history.  |
//| Partial closes, partial fills, SL closes and manual closes are all|
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
   s.entryPrice = (volIn  > 0.0) ? pxIn  / volIn  : g_posEntryPrice;
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
   if(CopyTime(_Symbol, PERIOD_CURRENT, 1, 1, barTime) != 1) return;   // shift 1 = last closed bar
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
//| Opens exactly one position. The boolean returned by CTrade is NOT |
//| proof of a fill: ResultRetcode() is always checked, and uncertain |
//| outcomes (timeout/connection) are reconciled against the real     |
//| broker positions instead of being guessed.                        |
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
      if(ThrottleOk(11, 30)) LogError("Open refused: a managed position already exists - duplicate positions are never opened.");
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

   double lots = CalcLotSize();
   if(lots <= 0.0)
   {
      EnterError("Open REJECTED: fixed lot is not supported by this symbol's volume min/max/step configuration.");
      return REQ_DEFERRED;
   }

   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string slWhy;
   double sl = ComputeProtectiveStop(direction, slWhy);
   if(sl <= 0.0)
   {
      if(ThrottleOk(6, 60)) LogWarning("Open deferred: cannot place a valid protective stop (" + slWhy + ").");
      return REQ_DEFERRED;
   }

   double margin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lots, price, margin))
   {
      if(ThrottleOk(7, 60)) LogWarning(StringFormat("Open deferred: OrderCalcMargin failed (error %d).", GetLastError()));
      return REQ_DEFERRED;
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
   {
      if(ThrottleOk(8, 60)) LogWarning(StringFormat("Open deferred: required margin %.2f exceeds free margin %.2f.", margin, freeMargin));
      return REQ_DEFERRED;
   }

   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;
   g_openRequestTime = Now();

   bool sent = (direction == 1)
             ? trade.Buy(lots, _Symbol, 0.0, sl, 0.0, InpTradeComment)
             : trade.Sell(lots, _Symbol, 0.0, sl, 0.0, InpTradeComment);

   uint rc = trade.ResultRetcode();
   RecordRetcode(rc, trade.ResultRetcodeDescription());

   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
   {
      if(rc == TRADE_RETCODE_DONE_PARTIAL)
         LogWarning("Open order only PARTIALLY filled - the actual broker position volume will be tracked, no top-up is sent.");
      g_openIntent = intent;
      g_openDir = direction;
      return REQ_ACCEPTED;
   }

   if(IsUncertainRetcode(rc))
   {
      LogWarning(StringFormat("Open %s outcome UNCERTAIN (retcode %u: %s) - reconciling against real positions before any retry.",
                              DirToString(direction), rc, trade.ResultRetcodeDescription()));
      g_openIntent = intent;
      g_openDir = direction;
      return REQ_UNCERTAIN;
   }

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

//+------------------------------------------------------------------+
//| Requests closure of the managed position. DONE does not mean flat:|
//| completion is only ever confirmed by Reconcile() seeing zero      |
//| managed volume. The close reason is stored BEFORE the request so  |
//| the confirmation path can never mistake it for a loss reversal.   |
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
   int cnt = ScanManaged(s);
   if(cnt == 0) return REQ_DEFERRED;                       // already flat - Reconcile() will finalize it
   if(cnt > 1) { EnterError(StringFormat("Close aborted: %d managed positions found.", cnt)); return REQ_DEFERRED; }
   TrackFromSnap(s);

   ENUM_CLOSE_REASON prevReason = g_pendingCloseReason;
   string prevDetail = g_pendingCloseDetail;
   g_pendingCloseReason = reason;
   g_pendingCloseDetail = detail;
   g_closeRequestTime = Now();
   g_nextRequestAllowed = Now() + InpMinSecondsBetweenRequests;

   bool sent = trade.PositionClose(s.ticket, (ulong)InpSlippagePoints);
   uint rc = trade.ResultRetcode();
   g_closeRetcode = rc;
   RecordRetcode(rc, trade.ResultRetcodeDescription());

   if(sent && rc == TRADE_RETCODE_DONE)
   {
      g_retryCounter = 0;
      return REQ_ACCEPTED;
   }
   if(sent && rc == TRADE_RETCODE_DONE_PARTIAL)
   {
      g_retryCounter = 0;
      g_closePartial = true;
      LogWarning("Close only PARTIALLY executed - the remaining volume will be closed by a controlled retry.");
      return REQ_ACCEPTED;
   }
   if(IsUncertainRetcode(rc))
   {
      LogWarning(StringFormat("Close outcome UNCERTAIN (retcode %u: %s) - reconciling against real positions.", rc, trade.ResultRetcodeDescription()));
      return REQ_UNCERTAIN;
   }

   // definite rejection: the pending close did not happen
   g_pendingCloseReason = prevReason;
   g_pendingCloseDetail = prevDetail;
   g_retryCounter++;
   LogError(StringFormat("Close REJECTED for ticket %I64u (attempt %d/%d): %s", s.ticket, g_retryCounter, InpMaxExecutionRetries,
                         trade.ResultRetcodeDescription()), (int)rc);
   // An emergency close is retried indefinitely (with throttle) - it must never give up and leave the position unmanaged.
   if(reason != CLOSE_REASON_EMERGENCY && g_retryCounter >= InpMaxExecutionRetries)
      EnterError(StringFormat("Close failed %d consecutive times for ticket %I64u - halting for manual review.", g_retryCounter, s.ticket));
   return REQ_REJECTED;
}

// If the broker stripped the stop, put it back (the SL is the only protection against a missed monitoring tick).
void EnsureProtectiveStop()
{
   if(g_posTicket == 0 || !PositionSelectByTicket(g_posTicket)) return;
   if(PositionGetDouble(POSITION_SL) > 0.0) return;

   string why;
   double sl = ComputeProtectiveStop(g_posDir, why);
   if(sl <= 0.0) { LogWarning("Position has no protective stop and none could be computed: " + why); return; }
   if(trade.PositionModify(g_posTicket, sl, 0.0))
      LogInfo(StringFormat("Protective stop attached after fill @ %s.", DoubleToString(sl, _Digits)));
   else
      LogWarning(StringFormat("Could not attach protective stop (retcode %u: %s).", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
}

//================================= RECONCILIATION & CLOSE ROUTING ====================================
// Decides the next state once a position is CONFIRMED completely closed.
void RouteAfterClose(ENUM_CLOSE_REASON reason, int closedDir)
{
   if(reason == CLOSE_REASON_EMERGENCY || EmergencyActive())
   {
      TransitionTo(STATE_EMERGENCY_HALTED, "Emergency stop: position closed, trading halted - no reversal, no new entries.");
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
            TransitionTo(STATE_REVERSAL_PENDING, StringFormat("Original %s position confirmed fully closed - reversing to %s.", DirToString(closedDir), DirToString(g_reversalDir)));
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
            TransitionTo(STATE_COOLDOWN, "Profit close confirmed - cooldown, then a fresh signal is required.");
         }
         break;

      default:   // EXTERNAL / unknown: SL, manual, broker - never reversed
         g_consecutiveReversals = 0;
         ConsumeCurrentSignal();
         if(BlockedByHalt())
            TransitionTo(STATE_DAILY_HALTED, "Position closed externally; a halt is active.");
         else
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Position closed externally (SL/manual/broker) - no reversal, waiting for a fresh signal.");
         break;
   }
}

// A tracked position is now confirmed gone from the broker: book it as ONE completed trade, then route.
void OnPositionClosed(const TradeSummary &s)
{
   ENUM_CLOSE_REASON reason = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL;
   uint execRetcode = (g_pendingCloseReason != CLOSE_REASON_NONE) ? g_closeRetcode : 0;
   double net = s.profit + s.commission + s.swap + s.fee;

   g_tradeNumberCounter++;
   g_totalTrades++;
   if(net >= 0.0) { g_totalWins++;   g_totalRealizedProfit += net; }
   else           { g_totalLosses++; g_totalRealizedLoss   += (-net); }

   int nextDir = (reason == CLOSE_REASON_LOSS_REVERSAL) ? -s.dir : 0;
   LogTradeRow(s, reason, execRetcode, nextDir, net);

   ClearTracking();
   g_pendingCloseReason = CLOSE_REASON_NONE;
   g_pendingCloseDetail = "";
   g_retryCounter = 0;
   g_finalizeWaitSince = 0;

   if(!RebuildDailyState())
   {
      g_dailyRealizedPL += net;
      if(InpDailyLossLimitEnabled && g_dailyRealizedPL <= -InpDailyLossLimitUSD + 1e-9) g_dailyHaltFlag = true;
   }
   if(g_dailyHaltFlag)
      LogWarning(StringFormat("Daily loss limit reached (realized=%.2f, limit=%.2f). New entries/reversals are halted for the rest of the broker day.",
                              g_dailyRealizedPL, InpDailyLossLimitUSD));
   SavePersistentState();

   RouteAfterClose(reason, s.dir);
}

// A managed position exists at the broker.
void OnPositionPresent(const PosSnap &s)
{
   if(g_posIdent != 0 && g_posIdent != s.ident)
      LogWarning(StringFormat("Tracked position %I64u was replaced by %I64u between scans - re-baselining.", g_posIdent, s.ident));

   if(g_posIdent == s.ident && s.volume < g_posVolume - 1e-8)
   {
      LogWarning(StringFormat("Partial close detected on position %I64u: %.2f -> %.2f lots remain open.", s.ident, g_posVolume, s.volume));
      if(g_pendingCloseReason != CLOSE_REASON_NONE) g_closePartial = true;
   }
   TrackFromSnap(s);

   switch(g_state)
   {
      case STATE_OPENING_POSITION:
      {
         if(s.dir != g_openDir)
         {
            EnterError(StringFormat("Opened position direction %s does not match the requested %s.", DirToString(s.dir), DirToString(g_openDir)));
            return;
         }
         if(g_openIntent == INTENT_REVERSAL)
         {
            g_consecutiveReversals++;   // counted ONLY now: the original is confirmed closed AND the opposite position is confirmed open
            LogInfo(StringFormat("Reversal #%d CONFIRMED: %s position %I64u is open.", g_consecutiveReversals, DirToString(s.dir), s.ident));
         }
         else
            g_consecutiveReversals = 0;     // an initial entry starts a new reversal chain
         g_openIntent = INTENT_NONE;
         g_reversalDir = 0;
         g_retryCounter = 0;
         g_pendingCloseReason = CLOSE_REASON_NONE;
         SavePersistentState();
         EnsureProtectiveStop();
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Confirmed fill: %s %.2f lots, position #%I64u @ %s.",
                      DirToString(s.dir), s.volume, s.ticket, DoubleToString(s.price, _Digits)));
         break;
      }
      case STATE_START_DELAY:
      case STATE_WAITING_INITIAL_SIGNAL:
      case STATE_REVERSAL_PENDING:
      case STATE_COOLDOWN:
      case STATE_DAILY_HALTED:
         g_openIntent = INTENT_NONE;
         TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Adopted unexpected managed %s position #%I64u.", DirToString(s.dir), s.ticket));
         break;
      default:
         break;   // ACTIVE / CLOSING_* / EMERGENCY_HALTED (the emergency hook closes strays) / ERROR
   }
}

// No managed position exists at the broker.
void OnPositionAbsent()
{
   if(g_posIdent == 0) return;   // nothing was being tracked

   TradeSummary ts;
   bool ok = BuildTradeSummary(g_posIdent, ts, true);
   if(!ok)
   {
      if(g_finalizeWaitSince == 0) g_finalizeWaitSince = Now();
      if(Now() - g_finalizeWaitSince < FINALIZE_WAIT_SEC) return;   // give the history time to catch up, retried every tick/timer

      ok = BuildTradeSummary(g_posIdent, ts, false);
      if(!ok)
      {
         ZeroMemory(ts);
         ts.ident = g_posIdent; ts.dir = g_posDir; ts.volume = g_posVolume;
         ts.entryPrice = g_posEntryPrice; ts.entryTime = g_posEntryTime; ts.exitTime = Now();
         LogWarning("Closing deals were not found in history - logging the trade from tracked data only.");
      }
      else
         LogWarning("Close history looks incomplete - logging what history contains.");
   }
   OnPositionClosed(ts);
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
   int cnt = ScanManaged(s);
   if(cnt > 1)
   {
      EnterError(StringFormat("Duplicate managed positions detected (%d) for this symbol+magic - halting for manual review.", cnt));
      return;
   }
   if(cnt == 1) OnPositionPresent(s);
   else         OnPositionAbsent();
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
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_EMERGENCY, "EMERGENCY STOP: closing the managed position, no reversal");
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_EMERGENCY, "Emergency stop - closing the managed position. No reversal, no new entries.");
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
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Start delay elapsed - waiting for a confirmed EMA crossover.");
         }
         break;

      case STATE_WAITING_INITIAL_SIGNAL:
      {
         if(BlockedByHalt()) { TransitionTo(STATE_DAILY_HALTED, "Halt active - not entering."); break; }
         if(!HasFreshUnusedSignal()) break;

         int dir = g_lastSignal;
         datetime backup = g_signalBarUsedForEntry;
         ENUM_REQ_RESULT r = ExecuteOpen(dir, INTENT_INITIAL);
         if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
         {
            g_signalUsedBackup = backup;
            ConsumeCurrentSignal();   // one cross -> at most one entry, even across restarts
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Fresh %s crossover confirmed - opening initial position.", DirToString(dir)));
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
         double pl;
         if(!GetFloatingPL(pl)) break;

         if(pl <= -InpLossThresholdUSD)
         {
            ENUM_CLOSE_REASON reason;
            if(g_dailyHaltFlag || g_maxRevHalt)                          reason = (g_dailyHaltFlag ? CLOSE_REASON_DAILY_LIMIT : CLOSE_REASON_MAX_REVERSALS);
            else if(g_consecutiveReversals >= InpMaxConsecutiveReversals) reason = CLOSE_REASON_MAX_REVERSALS;
            else                                                          reason = CLOSE_REASON_LOSS_REVERSAL;

            string detail = StringFormat("%s: floating P/L=%.2f <= -%.2f", CloseReasonToString(reason), pl, InpLossThresholdUSD);
            ENUM_REQ_RESULT r = ExecuteClose(reason, detail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_LOSS, "Loss threshold hit - closing before any reversal (" + CloseReasonToString(reason) + ").");
         }
         else if(pl >= InpProfitTargetUSD)
         {
            ENUM_REQ_RESULT r = ExecuteClose(CLOSE_REASON_PROFIT, StringFormat("PROFIT_TARGET: floating P/L=%.2f >= %.2f", pl, InpProfitTargetUSD));
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN)
               TransitionTo(STATE_CLOSING_PROFIT, "Profit target hit - closing, cycle will reset.");
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
         {
            ENUM_REQ_RESULT r = ExecuteClose(g_pendingCloseReason != CLOSE_REASON_NONE ? g_pendingCloseReason : CLOSE_REASON_EXTERNAL,
                                             g_pendingCloseDetail);
            if(r == REQ_ACCEPTED || r == REQ_UNCERTAIN) g_closePartial = (r == REQ_ACCEPTED && trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL);
         }
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
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Opening reversal %s (confirmed reversal #%d will be counted on fill).", DirToString(g_reversalDir), g_consecutiveReversals + 1));
         break;
      }

      case STATE_COOLDOWN:
         if(Now() >= g_cooldownEnd)
         {
            if(BlockedByHalt()) TransitionTo(STATE_DAILY_HALTED, "Cooldown elapsed but a halt is active.");
            else                TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Cooldown elapsed - waiting for a fresh confirmed EMA crossover.");
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

   // Lot must sit inside the symbol's limits and step grid.
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
   if(CalcLotSize() <= 0.0)
   {
      Print("INIT REJECTED: the symbol's minimum volume exceeds the hard lot cap of ", DoubleToString(MathMin(InpMaxLotSize, HARD_MAX_LOT), 2));
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

   maFastHandle = iMA(_Symbol, PERIOD_CURRENT, InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandle = iMA(_Symbol, PERIOD_CURRENT, InpSlowMA, 0, InpMAMethod, InpMAPrice);
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      LogError("Failed to create EMA indicator handles", GetLastError());
      ReleaseInstanceLock();
      return INIT_FAILED;
   }

   OpenLogFile();
   LogInfo(StringFormat("EA session starting. v%s Symbol=%s TF=%s Magic=%d Account=%I64d (%s, DEMO)",
                        EA_VERSION, _Symbol, EnumToString(_Period), InpMagicNumber, AccountInfoInteger(ACCOUNT_LOGIN), g_marginModeStr));
   LogInfo("Single-symbol EA: it only manages " + _Symbol + ". Attach one instance (own magic number) per symbol/chart for several symbols.");
   LogInfo(StringFormat("Daily loss limit counts REALIZED (closed-deal) P/L only; floating P/L is excluded. Protective stop: %d-point backstop - "
                        "it does NOT guarantee a fixed money loss (gaps, slippage, tick value, spread). Reversals are driven by the $%.2f loss threshold / $%.2f profit target.",
                        InpProtectiveStopPoints, InpLossThresholdUSD, InpProfitTargetUSD));

   // A loss threshold below the immediate spread cost makes every new position reverse at once.
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double sp = CurrentSpreadPoints();
   if(tv > 0.0 && ts > 0.0 && sp > 0.0)
   {
      double spreadCost = sp * _Point / ts * tv * CalcLotSize();
      if(spreadCost >= InpLossThresholdUSD)
         LogWarning(StringFormat("Current spread costs about %.2f per position, which is >= InpLossThresholdUSD (%.2f): positions may reverse immediately after opening.",
                                 spreadCost, InpLossThresholdUSD));
   }

   LoadPersistentState();

   // --- restart recovery: adopt the real broker position instead of trusting stored state ---
   PosSnap snap;
   int existing = ScanManaged(snap);
   g_startDelayBegin = Now();
   if(existing > 1)
      TransitionTo(STATE_ERROR, StringFormat("Found %d managed positions for this symbol+magic on init - this EA only ever holds one. Manual intervention required.", existing));
   else if(existing == 1)
   {
      TrackFromSnap(snap);
      TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Adopted pre-existing %s position #%I64u (%.2f lots) on restart.", DirToString(snap.dir), snap.ticket, snap.volume));
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
//| by our magic OR by the tracked position id (a manual close deal   |
//| carries magic 0 but still belongs to our position).               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   long   magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   ulong  pid   = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(magic != (long)InpMagicNumber && !(g_posIdent != 0 && pid == g_posIdent)) return;

   Reconcile();
   if(InpShowDashboard) UpdateDashboard();
}

//================================= DASHBOARD (display-only) ====================================
#define DASH_PREFIX "SRE_DASH_"
#define PANEL_X 10
#define PANEL_W 430
#define DASH_ROWS 16
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
   if(StringLen(text) > 62) text = StringSubstr(text, 0, 59) + "...";
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void UpdateDashboard()
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   double fl = 0.0;
   GetFloatingPL(fl);

   string haltTxt;
   color  haltClr = clrLime;
   if(!InpDailyLossLimitEnabled)      { haltTxt = "OFF (disabled)"; haltClr = clrGray; }
   else if(g_dailyHaltFlag)           { haltTxt = "HALTED - daily loss limit reached"; haltClr = clrTomato; }
   else if(g_maxRevHalt)              { haltTxt = "HALTED - reversal cap reached"; haltClr = clrTomato; }
   else                               { haltTxt = "ACTIVE"; }

   string emTxt = EmergencyActive() ? ((g_state == STATE_EMERGENCY_HALTED) ? "ON - HALTED" : "ON - closing") : "OFF";

   string posTxt = (g_posDir != 0) ? StringFormat("%s  %.2f lot", DirToString(g_posDir), g_posVolume) : "none";
   double sp = CurrentSpreadPoints();

   SetRow(0,  StringFormat("Smart Reversal EA v%s   [DEMO]", EA_VERSION), clrGold);
   SetRow(1,  StringFormat("Account: DEMO | %s | %s %s", g_marginModeStr, _Symbol, EnumToString(_Period)), clrLime);
   SetRow(2,  "State: " + StateToString(g_state), (g_state == STATE_ERROR) ? clrTomato : clrSkyBlue);
   SetRow(3,  "Position: " + posTxt, clrOrange);
   SetRow(4,  StringFormat("Floating P/L: %.2f %s", fl, ccy), (fl < 0.0) ? clrSalmon : clrAqua);
   SetRow(5,  StringFormat("Today realized: %.2f / limit %s %s (closed only)", g_dailyRealizedPL,
                           InpDailyLossLimitEnabled ? StringFormat("-%.2f", InpDailyLossLimitUSD) : "n/a", ccy), clrWhite);
   SetRow(6,  "Daily protection: " + haltTxt, haltClr);
   SetRow(7,  "Emergency stop: " + emTxt, EmergencyActive() ? clrRed : clrLime);
   SetRow(8,  StringFormat("Reversals (confirmed): %d / max %d", g_consecutiveReversals, InpMaxConsecutiveReversals), clrWhite);
   SetRow(9,  StringFormat("Spread: %s / max %d pts", (sp >= 0.0) ? DoubleToString(sp, 1) : "n/a", InpMaxSpreadPoints),
              (sp >= 0.0 && sp <= InpMaxSpreadPoints) ? clrWhite : clrOrange);
   SetRow(10, StringFormat("Total trades: %d (W:%d / L:%d)", g_totalTrades, g_totalWins, g_totalLosses), clrWhite);
   SetRow(11, StringFormat("Realized profit: %.2f %s", g_totalRealizedProfit, ccy), clrAqua);
   SetRow(12, StringFormat("Realized loss: -%.2f %s", g_totalRealizedLoss, ccy), clrSalmon);
   SetRow(13, "Last action: " + g_lastAction, clrLightGray);
   SetRow(14, StringFormat("Last retcode: %u %s", g_lastRetcode, g_lastRetcodeText), clrLightGray);
   SetRow(15, "Last error: " + (g_lastError == "" ? "none" : g_lastError), (g_lastError == "") ? clrLightGray : clrTomato);
}
//+------------------------------------------------------------------+
