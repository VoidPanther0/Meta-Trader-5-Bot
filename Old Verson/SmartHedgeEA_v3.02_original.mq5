//+------------------------------------------------------------------+
//|                                          SmartHedgeEA_v3.02.mq5 |
//|                   Smart Reversal EA - state-driven, one position  |
//|                   at a time, loss-triggered direction reversal.   |
//+------------------------------------------------------------------+
#property copyright "Sachin Dev Bots"
#property version   "3.02"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//================================= INPUTS ====================================
input group "=== Signal (EMA Crossover, confirmed closed-candle only) ==="
input int    InpFastMA            = 10;
input int    InpSlowMA            = 30;
input ENUM_MA_METHOD InpMAMethod  = MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;

input group "=== Reversal Engine ==="
input double InpLossThresholdUSD    = 0.10;  // close+reverse when floating net loss reaches -this amount
input double InpProfitTargetUSD     = 1.00;  // close (no auto-reverse) when floating net profit reaches +this amount
input int    InpMaxConsecutiveReversals = 20; // safety cap - halts after this many consecutive loss-reversals

input group "=== Position Sizing ==="
input double InpFixedLotSize      = 0.01;
input double InpMaxLotSize        = 0.01;   // hard cap - never exceeded, no martingale/growth

input group "=== Broker-Side Protective Stop (hard backstop, NOT the $ trigger) ==="
input int    InpProtectiveStopPoints = 500; // wide point-distance SL floor in case the monitoring loop misses a tick

input group "=== Risk Protections ==="
input bool   InpDailyLossLimitEnabled = true;
input double InpDailyLossLimitUSD     = 5.00; // halts NEW entries/reversals only - never force-closes the open position
input int    InpMaxSpreadPoints       = 30;
input int    InpSlippagePoints        = 10;
input int    InpMaxExecutionRetries   = 3;
input int    InpMinSecondsBetweenRequests = 2;
input bool   InpEmergencyStop          = false; // true = close current position (if any) and halt everything

input group "=== Timing ==="
input int    InpStartDelaySeconds   = 10;
input int    InpPostProfitWaitSeconds = 10;

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

//================================= STATE MACHINE ====================================
enum ENUM_EA_STATE
{
   STATE_INITIALIZING,
   STATE_START_DELAY,
   STATE_WAITING_INITIAL_SIGNAL,
   STATE_OPENING_POSITION,
   STATE_POSITION_ACTIVE,
   STATE_CLOSING_LOSS,
   STATE_REVERSAL_PENDING,
   STATE_CLOSING_PROFIT,
   STATE_COOLDOWN,
   STATE_DAILY_HALTED,
   STATE_ERROR
};

string StateToString(ENUM_EA_STATE s)
{
   switch(s)
   {
      case STATE_INITIALIZING:         return "INITIALIZING";
      case STATE_START_DELAY:          return "START_DELAY";
      case STATE_WAITING_INITIAL_SIGNAL: return "WAITING_INITIAL_SIGNAL";
      case STATE_OPENING_POSITION:     return "OPENING_POSITION";
      case STATE_POSITION_ACTIVE:      return "POSITION_ACTIVE";
      case STATE_CLOSING_LOSS:         return "CLOSING_LOSS";
      case STATE_REVERSAL_PENDING:     return "REVERSAL_PENDING";
      case STATE_CLOSING_PROFIT:       return "CLOSING_PROFIT";
      case STATE_COOLDOWN:             return "COOLDOWN";
      case STATE_DAILY_HALTED:         return "DAILY_HALTED";
      case STATE_ERROR:                return "ERROR";
      default:                         return "UNKNOWN";
   }
}

//================================= GLOBALS ====================================
CTrade        trade;
CPositionInfo posInfo;
CSymbolInfo   symInfo;

int maFastHandle = INVALID_HANDLE;
int maSlowHandle = INVALID_HANDLE;

ENUM_EA_STATE g_state = STATE_INITIALIZING;
string        g_lastAction = "EA starting";

// Direction bookkeeping. 1 = BUY, -1 = SELL, 0 = none.
int      g_currentDirection  = 0;
int      g_previousDirection = 0;
ulong    g_currentTicket     = 0;
string   g_lastClosingReason = "";
double   g_lastRealizedResult = 0.0;
int      g_consecutiveReversals = 0;

// Confirmed-once-per-closed-candle EMA crossover signal.
datetime g_lastSignalBarTime = 0;
int      g_lastSignal        = 0; // 1 = bullish cross, -1 = bearish cross, 0 = none yet
datetime g_signalBarUsedForEntry = 0; // bar-time of the signal that was actually consumed for the last initial entry

// Timing state.
datetime g_startDelayBeginTime = 0;
datetime g_cooldownEndTime     = 0;
datetime g_lastRequestTime     = 0;

// Daily loss tracking (persisted).
datetime g_currentDay    = 0;
double   g_dailyRealizedPL = 0.0;
bool     g_dailyHaltFlag = false;

// Lifetime totals (persisted, reconstructed from history on first-ever run).
int      g_totalTrades       = 0;
int      g_totalWins         = 0;
int      g_totalLosses       = 0;
double   g_totalRealizedProfit = 0.0; // sum of winning closes only
double   g_totalRealizedLoss    = 0.0; // sum of losing closes only (stored as a positive magnitude)

// Pending-operation guards - prevent opening a new position while a close is still unconfirmed,
// and prevent reacting twice to the same OnTradeTransaction deal stream.
bool     g_closePendingForReversal = false; // true while waiting for the loss-close to confirm before reversing
bool     g_closePendingForProfit   = false; // true while waiting for the profit-close to confirm
string   g_pendingCloseReason      = "";
int      g_tradeNumberCounter      = 0; // increments on every confirmed close, used as the CSV "trade number"
int      g_retryCounter            = 0; // counts consecutive failed attempts of the operation currently in flight

// Trade event logger state.
int    gLogHandle   = INVALID_HANDLE;
string gLogFileName = "";

#define GV_PREFIX "SRE_"

//================================= PERSISTENCE ====================================
// Global Variables survive EA re-attach and terminal restart, so critical safety state
// (daily halt, reversal count, totals, direction/ticket) is never silently reset.
string GVKey(string suffix)
{
   return StringFormat("%s%s_%d_%s", GV_PREFIX, _Symbol, InpMagicNumber, suffix);
}

datetime DateOfDay(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return StructToTime(s);
}

//+------------------------------------------------------------------+
//| Reconstructs lifetime realized stats (trades/wins/losses/profit/ |
//| loss) for this symbol+magic from the full account deal history. |
//| Used only on the very first run (no persisted GV found) so a    |
//| fresh GV set doesn't understate history that already happened. |
//+------------------------------------------------------------------+
void ReconstructLifetimeStatsFromHistory()
{
   if(!HistorySelect(0, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue; // only closing deals realize P/L

      double net = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                  + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                  + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      g_totalTrades++;
      if(net >= 0.0) { g_totalWins++;   g_totalRealizedProfit += net; }
      else           { g_totalLosses++; g_totalRealizedLoss   += (-net); }
   }
}

//+------------------------------------------------------------------+
//| Rebuilds today's realized P/L (this symbol+magic only) from deal |
//| history - never trusted blindly from a possibly-stale GV value. |
//+------------------------------------------------------------------+
double ReconstructDailyRealizedPL(datetime dayStart)
{
   datetime dayEnd = dayStart + 86400;
   if(!HistorySelect(dayStart, dayEnd)) return 0.0;

   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      sum += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
           + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
           + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }
   return sum;
}

void LoadPersistentState()
{
   bool firstEverRun = !GlobalVariableCheck(GVKey("CurrentDay"));

   if(!firstEverRun)
   {
      g_currentDay           = (datetime)GlobalVariableGet(GVKey("CurrentDay"));
      g_dailyHaltFlag         = GlobalVariableGet(GVKey("DailyHalt")) > 0.5;
      g_currentDirection      = (int)GlobalVariableGet(GVKey("CurDir"));
      g_previousDirection     = (int)GlobalVariableGet(GVKey("PrevDir"));
      g_currentTicket         = (ulong)GlobalVariableGet(GVKey("CurTicket"));
      g_consecutiveReversals  = (int)GlobalVariableGet(GVKey("ConsecRev"));
      g_totalTrades           = (int)GlobalVariableGet(GVKey("TotTrades"));
      g_totalWins             = (int)GlobalVariableGet(GVKey("TotWins"));
      g_totalLosses           = (int)GlobalVariableGet(GVKey("TotLosses"));
      g_totalRealizedProfit   = GlobalVariableGet(GVKey("TotProfit"));
      g_totalRealizedLoss     = GlobalVariableGet(GVKey("TotLoss"));
      g_signalBarUsedForEntry = (datetime)GlobalVariableGet(GVKey("SigBarUsed"));
   }
   else
   {
      g_currentDay = DateOfDay(TimeCurrent());
      g_dailyHaltFlag = false;
      g_currentDirection = 0;
      g_previousDirection = 0;
      g_currentTicket = 0;
      g_consecutiveReversals = 0;
      g_totalTrades = 0; g_totalWins = 0; g_totalLosses = 0;
      g_totalRealizedProfit = 0.0; g_totalRealizedLoss = 0.0;
      g_signalBarUsedForEntry = 0;
      ReconstructLifetimeStatsFromHistory();
      LogInfo("First-ever run detected for this symbol+magic - lifetime stats reconstructed from account history.");
   }

   // Daily realized P/L is always rebuilt fresh from history regardless of GV age/trust.
   g_dailyRealizedPL = ReconstructDailyRealizedPL(g_currentDay);
   SavePersistentState();
}

void SavePersistentState()
{
   GlobalVariableSet(GVKey("CurrentDay"), (double)g_currentDay);
   GlobalVariableSet(GVKey("DailyHalt"), g_dailyHaltFlag ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("CurDir"), (double)g_currentDirection);
   GlobalVariableSet(GVKey("PrevDir"), (double)g_previousDirection);
   GlobalVariableSet(GVKey("CurTicket"), (double)g_currentTicket);
   GlobalVariableSet(GVKey("ConsecRev"), (double)g_consecutiveReversals);
   GlobalVariableSet(GVKey("TotTrades"), (double)g_totalTrades);
   GlobalVariableSet(GVKey("TotWins"), (double)g_totalWins);
   GlobalVariableSet(GVKey("TotLosses"), (double)g_totalLosses);
   GlobalVariableSet(GVKey("TotProfit"), g_totalRealizedProfit);
   GlobalVariableSet(GVKey("TotLoss"), g_totalRealizedLoss);
   GlobalVariableSet(GVKey("SigBarUsed"), (double)g_signalBarUsedForEntry);
}

void CheckNewDay()
{
   datetime today = DateOfDay(TimeCurrent());
   if(today != g_currentDay)
   {
      g_currentDay = today;
      g_dailyRealizedPL = 0.0;
      g_dailyHaltFlag = false;
      SavePersistentState();
      LogInfo("New trading day - daily realized P/L counter and daily halt flag reset.");
   }
}

//================================= TRADE EVENT LOGGER ====================================
void OpenLogFile()
{
   if(!InpLogToCSV) return;

   if(InpLogSubFolder != "")
      FolderCreate(InpLogSubFolder, InpLogCommonFolder ? FILE_COMMON : 0);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
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

   FileWrite(gLogHandle, "Timestamp", "TradeNumber", "PositionTicket", "Direction", "Volume",
             "EntryPrice", "ExitPrice", "RealizedPL", "ClosingReason", "PreviousDirection",
             "NextDirection", "ReversalNumber", "ExecutionRetcode", "AccountCurrency");
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

string DirToString(int d) { return (d == 1) ? "BUY" : (d == -1) ? "SELL" : "NONE"; }

//+------------------------------------------------------------------+
//| Writes one CSV row for a confirmed closed trade. Called only     |
//| from OnTradeTransaction on a genuine closing deal - never on a   |
//| per-tick basis, so the file stays free of noise.                 |
//+------------------------------------------------------------------+
void LogTradeRow(ulong ticket, int direction, double volume, double entryPrice, double exitPrice,
                  double realizedPL, string closingReason, int prevDir, int nextDir, int reversalNum, int retcode)
{
   g_tradeNumberCounter++;
   string acctCcy = AccountInfoString(ACCOUNT_CURRENCY);

   if(InpLogAlsoToExpertsTab)
   {
      PrintFormat("[TRADE #%d] ticket=%I64u dir=%s vol=%.2f entry=%s exit=%s PL=%.2f (%s) reason=%s prevDir=%s nextDir=%s revNum=%d retcode=%d",
                  g_tradeNumberCounter, ticket, DirToString(direction), volume,
                  DoubleToString(entryPrice, _Digits), DoubleToString(exitPrice, _Digits),
                  realizedPL, acctCcy, closingReason, DirToString(prevDir), DirToString(nextDir), reversalNum, retcode);
   }

   if(gLogHandle == INVALID_HANDLE) return;

   string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   FileWrite(gLogHandle, ts, g_tradeNumberCounter, (long)ticket, DirToString(direction),
             DoubleToString(volume, 2), DoubleToString(entryPrice, _Digits), DoubleToString(exitPrice, _Digits),
             DoubleToString(realizedPL, 2), closingReason, DirToString(prevDir), DirToString(nextDir),
             reversalNum, retcode, acctCcy);
   FileFlush(gLogHandle);
}

void LogInfo(string details)
{
   if(InpLogAlsoToExpertsTab) PrintFormat("[INFO] %s", details);
}
void LogWarning(string details)
{
   if(InpLogAlsoToExpertsTab) PrintFormat("[WARNING] %s", details);
}
void LogError(string details, int retcode = 0)
{
   if(InpLogAlsoToExpertsTab) PrintFormat("[ERROR] retcode=%d | %s", retcode, details);
}

//================================= STATE TRANSITION HELPER ====================================
//| Every state change goes through here so transitions are explicit |
//| and auditable - nothing flips g_state directly anywhere else.    |
//+------------------------------------------------------------------+
void TransitionTo(ENUM_EA_STATE newState, string why)
{
   if(newState == g_state)
   {
      g_lastAction = why;
      return;
   }
   LogInfo(StringFormat("STATE: %s -> %s (%s)", StateToString(g_state), StateToString(newState), why));
   g_state = newState;
   g_lastAction = why;
}

//================================= HELPERS ====================================
bool SpreadOK()
{
   symInfo.RefreshRates();
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= InpMaxSpreadPoints);
}

bool SymbolTradeable()
{
   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (tradeMode != SYMBOL_TRADE_MODE_DISABLED);
}

bool RequestThrottleOk()
{
   return (TimeCurrent() - g_lastRequestTime >= InpMinSecondsBetweenRequests);
}

//+------------------------------------------------------------------+
//| Normalizes/clamps the fixed lot to the broker's volume step and  |
//| [min,max], further capped by InpMaxLotSize. Rejects (returns 0.0)|
//| rather than silently exceeding the cap if the broker minimum     |
//| alone is already above it.                                       |
//+------------------------------------------------------------------+
double ClampLot(double lots)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   if(minVol <= 0.0) minVol = step;

   double hardCap = MathMin(InpMaxLotSize, maxVol > 0.0 ? maxVol : InpMaxLotSize);
   if(minVol > hardCap) return 0.0;

   double norm = MathRound(lots / step) * step;
   norm = MathMax(minVol, MathMin(hardCap, norm));

   int stepDigits = 0;
   double s = step;
   while(s < 0.999999 && stepDigits < 8) { s *= 10.0; stepDigits++; }
   norm = NormalizeDouble(norm, stepDigits);

   if(norm < minVol || norm > hardCap) return 0.0;
   return norm;
}

double CalcLotSize()
{
   return ClampLot(InpFixedLotSize);
}

//+------------------------------------------------------------------+
//| Computes the wide protective-stop price for a new order. This is |
//| a point-distance backstop only - NOT the same trigger as the $   |
//| loss threshold (which is monitored every tick in software). If   |
//| the terminal disconnects or a tick is missed, this SL is the only|
//| thing standing between the position and an unbounded loss, so it |
//| is deliberately much wider than the $ threshold would imply.     |
//+------------------------------------------------------------------+
double ComputeProtectiveStop(ENUM_ORDER_TYPE type, double refPrice)
{
   int stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int minSafePoints = MathMax(stopsLevel, freezeLevel) + 1;
   int slPoints = MathMax(InpProtectiveStopPoints, minSafePoints);
   double slDist = slPoints * _Point;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) tickSize = _Point;

   double sl = (type == ORDER_TYPE_BUY) ? (refPrice - slDist) : (refPrice + slDist);
   return NormalizeDouble(MathRound(sl / tickSize) * tickSize, _Digits);
}

//+------------------------------------------------------------------+
//| 1 = fast EMA above slow (bullish), -1 = bearish, 0 = n/a          |
//+------------------------------------------------------------------+
int GetTrendBias()
{
   double fast[1], slow[1];
   if(CopyBuffer(maFastHandle, 0, 0, 1, fast) < 1) return 0;
   if(CopyBuffer(maSlowHandle, 0, 0, 1, slow) < 1) return 0;
   if(fast[0] > slow[0]) return 1;
   if(fast[0] < slow[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Detects a fresh EMA cross on the last fully closed bar (indices  |
//| 1 and 2 - never the still-forming bar 0, so it cannot repaint).  |
//| Updates g_lastSignal/g_lastSignalBarTime exactly once per closed  |
//| candle. This is the ONLY source of entry-direction decisions.    |
//+------------------------------------------------------------------+
void UpdateSignal()
{
   datetime barTime[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 1, 1, barTime) < 1) return;
   if(barTime[0] == g_lastSignalBarTime) return;

   double fast[3], slow[3];
   if(CopyBuffer(maFastHandle, 0, 0, 3, fast) < 3) return;
   if(CopyBuffer(maSlowHandle, 0, 0, 3, slow) < 3) return;

   bool wasBelow = fast[2] < slow[2];
   bool isAbove  = fast[1] > slow[1];
   bool wasAbove = fast[2] > slow[2];
   bool isBelow  = fast[1] < slow[1];

   g_lastSignalBarTime = barTime[0];

   if(wasBelow && isAbove)
   {
      g_lastSignal = 1;
      LogInfo("EMA crossover signal: BULLISH cross confirmed on last closed bar.");
   }
   else if(wasAbove && isBelow)
   {
      g_lastSignal = -1;
      LogInfo("EMA crossover signal: BEARISH cross confirmed on last closed bar.");
   }
   // else: no new cross this candle - g_lastSignal intentionally retains its previous value.
}

//+------------------------------------------------------------------+
//| True only if there is a confirmed signal AND it has not already  |
//| been consumed for an initial entry (prevents re-firing on the    |
//| same bar/cross after a profit close resets to WAITING_SIGNAL).   |
//+------------------------------------------------------------------+
bool HasFreshUnusedSignal()
{
   return (g_lastSignal != 0 && g_lastSignalBarTime != g_signalBarUsedForEntry);
}

double FloatingPL()
{
   if(g_currentTicket == 0) return 0.0;
   if(!posInfo.SelectByTicket(g_currentTicket)) return 0.0;
   return posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
}

//+------------------------------------------------------------------+
//| Counts live positions for this symbol+magic. Used at startup to  |
//| detect and adopt a pre-existing position after an EA/terminal    |
//| restart, and to detect an unexpected extra position (STATE_ERROR)|
//+------------------------------------------------------------------+
int CountManagedPositions(ulong &foundTicket, int &foundDirection)
{
   int cnt = 0;
   foundTicket = 0;
   foundDirection = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      cnt++;
      foundTicket = posInfo.Ticket();
      foundDirection = (posInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return cnt;
}

//================================= INIT / DEINIT ====================================
int OnInit()
{
   OpenLogFile();
   LogInfo(StringFormat("EA session starting. Symbol=%s Magic=%d Version=3.02", _Symbol, InpMagicNumber));

   // --- Demo-account guard: this EA is restricted to DEMO accounts only, per project requirement. ---
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      LogError("Initialization REJECTED: this account is not a DEMO account. SmartReversalEA v3.02 refuses to run on live/contest accounts.");
      return INIT_FAILED;
   }

   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(!SymbolTradeable())
   {
      LogError("Initialization REJECTED: symbol trading is disabled by the broker.");
      return INIT_FAILED;
   }

   maFastHandle = iMA(_Symbol, PERIOD_CURRENT, InpFastMA, 0, InpMAMethod, InpMAPrice);
   maSlowHandle = iMA(_Symbol, PERIOD_CURRENT, InpSlowMA, 0, InpMAMethod, InpMAPrice);
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      LogError("Failed to create EMA indicator handles", GetLastError());
      return INIT_FAILED;
   }

   LoadPersistentState();

   LogInfo(StringFormat(
      "Protective stop note: the broker-side SL is set at a fixed %d-point distance as a hard execution "
      "backstop only. The actual reversal/close decisions are driven every tick by the $%.2f loss threshold "
      "and $%.2f profit target in software - the point-distance SL will normally never be hit; it exists "
      "solely to bound risk if the terminal disconnects or a tick is missed.",
      InpProtectiveStopPoints, InpLossThresholdUSD, InpProfitTargetUSD));

   // --- Restart recovery: adopt an existing position instead of blindly opening a new one. ---
   ulong foundTicket; int foundDirection;
   int existingCount = CountManagedPositions(foundTicket, foundDirection);
   if(existingCount == 1)
   {
      g_currentTicket = foundTicket;
      g_currentDirection = foundDirection;
      SavePersistentState();
      TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Adopted pre-existing %s position #%I64u on restart.", DirToString(foundDirection), foundTicket));
   }
   else if(existingCount > 1)
   {
      TransitionTo(STATE_ERROR, StringFormat("Found %d positions for this symbol+magic on init - this EA only ever intends to hold one. Manual intervention required.", existingCount));
   }
   else
   {
      g_startDelayBeginTime = TimeCurrent();
      TransitionTo(STATE_START_DELAY, StringFormat("No existing position found - starting %d-second init delay.", InpStartDelaySeconds));
   }

   if(InpShowDashboard) CreateDashboard();
   LogInfo("EA initialized successfully.");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SavePersistentState();
   LogInfo(StringFormat("Session ending. Reason=%d TotalTrades=%d Wins=%d Losses=%d TotalProfit=%.2f TotalLoss=%.2f",
                         reason, g_totalTrades, g_totalWins, g_totalLosses, g_totalRealizedProfit, g_totalRealizedLoss));
   if(maFastHandle != INVALID_HANDLE) IndicatorRelease(maFastHandle);
   if(maSlowHandle != INVALID_HANDLE) IndicatorRelease(maSlowHandle);
   RemoveDashboard();
   CloseLogFile();
}

//================================= ORDER EXECUTION ====================================
//+------------------------------------------------------------------+
//| Opens exactly one position in the given direction. Validates lot |
//| size, spread, and symbol tradeability first; retries up to       |
//| InpMaxExecutionRetries times on a non-fatal reject. Verifies the  |
//| actual ResultRetcode() - a "true" return from trade.Buy/Sell is  |
//| NOT itself proof of a fill.                                      |
//+------------------------------------------------------------------+
bool ExecuteOpen(int direction)
{
   if(!RequestThrottleOk()) return false;
   if(!SymbolTradeable())
   {
      LogError("Open skipped: symbol trading disabled by broker right now.");
      return false;
   }
   if(!SpreadOK())
   {
      LogWarning("Open deferred: spread currently exceeds InpMaxSpreadPoints.");
      return false;
   }

   double lots = CalcLotSize();
   if(lots <= 0.0)
   {
      LogError("Open REJECTED: lot size 0.01 is not supported by this symbol's volume min/max/step configuration.");
      TransitionTo(STATE_ERROR, "Lot size validation failed - cannot open any position on this symbol.");
      return false;
   }

   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string orderTypeStr = (direction == 1) ? "BUY" : "SELL";
   double refPrice = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = ComputeProtectiveStop(orderType, refPrice);

   g_lastRequestTime = TimeCurrent();

   bool sent = (direction == 1)
             ? trade.Buy(lots, _Symbol, 0.0, sl, 0.0, InpTradeComment)
             : trade.Sell(lots, _Symbol, 0.0, sl, 0.0, InpTradeComment);

   uint retcode = trade.ResultRetcode();
   bool executed = sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL);

   if(!executed)
   {
      g_retryCounter++;
      LogError(StringFormat("Open %s REJECTED (attempt %d/%d): %s", orderTypeStr, g_retryCounter, InpMaxExecutionRetries,
                             trade.ResultRetcodeDescription()), (int)retcode);
      if(g_retryCounter >= InpMaxExecutionRetries)
      {
         TransitionTo(STATE_ERROR, StringFormat("Open %s failed %d consecutive times - halting for manual review.", orderTypeStr, g_retryCounter));
      }
      return false;
   }

   g_retryCounter = 0;
   // g_currentTicket/g_currentDirection are set definitively from OnTradeTransaction's DEAL_ENTRY_IN
   // handling, not here - a "true" send is not yet a confirmed position.
   return true;
}

//+------------------------------------------------------------------+
//| Requests closure of the current position. Confirmation that it   |
//| is actually flat happens in OnTradeTransaction/PositionsTotal,    |
//| never assumed from PositionClose()'s boolean return alone.       |
//+------------------------------------------------------------------+
bool ExecuteClose(string reason)
{
   if(g_currentTicket == 0) return false;
   if(!posInfo.SelectByTicket(g_currentTicket))
   {
      // Already gone (e.g. closed by broker/manually) - treat as confirmed closed.
      return true;
   }

   g_lastRequestTime = TimeCurrent();
   g_pendingCloseReason = reason;
   bool closed = trade.PositionClose(g_currentTicket, InpSlippagePoints);

   if(!closed)
   {
      g_retryCounter++;
      LogError(StringFormat("Close REJECTED for ticket %I64u (attempt %d/%d): %s",
                             g_currentTicket, g_retryCounter, InpMaxExecutionRetries, trade.ResultRetcodeDescription()),
               (int)trade.ResultRetcode());
      g_pendingCloseReason = "";
      if(g_retryCounter >= InpMaxExecutionRetries)
      {
         TransitionTo(STATE_ERROR, StringFormat("Close failed %d consecutive times for ticket %I64u - halting for manual review.", g_retryCounter, g_currentTicket));
      }
      return false;
   }

   g_retryCounter = 0;
   return true;
}

//================================= STATE MACHINE TICK LOGIC ====================================
void RunStateMachine()
{
   switch(g_state)
   {
      case STATE_INITIALIZING:
         // Should never be observed on a tick - OnInit always moves past this. Defensive only.
         TransitionTo(STATE_START_DELAY, "Unexpected INITIALIZING state observed in OnTick - recovering.");
         g_startDelayBeginTime = TimeCurrent();
         break;

      case STATE_START_DELAY:
         if(TimeCurrent() - g_startDelayBeginTime >= InpStartDelaySeconds)
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Start delay elapsed - waiting for a confirmed EMA crossover.");
         break;

      case STATE_WAITING_INITIAL_SIGNAL:
         if(g_dailyHaltFlag) { TransitionTo(STATE_DAILY_HALTED, "Daily loss limit active - not entering."); break; }
         if(HasFreshUnusedSignal())
         {
            int dir = g_lastSignal;
            if(ExecuteOpen(dir))
            {
               g_signalBarUsedForEntry = g_lastSignalBarTime;
               SavePersistentState();
               TransitionTo(STATE_OPENING_POSITION, StringFormat("Fresh %s crossover confirmed - opening initial position.", DirToString(dir)));
            }
         }
         break;

      case STATE_OPENING_POSITION:
         // Waits here until OnTradeTransaction confirms the DEAL_ENTRY_IN fill and moves to POSITION_ACTIVE.
         break;

      case STATE_POSITION_ACTIVE:
      {
         if(InpEmergencyStop)
         {
            g_pendingCloseReason = "EMERGENCY_STOP input activated";
            if(ExecuteClose(g_pendingCloseReason))
               TransitionTo(STATE_CLOSING_LOSS, "Emergency stop requested - closing current position, no reversal.");
            break;
         }

         double pl = FloatingPL();

         if(pl <= -InpLossThresholdUSD)
         {
            if(g_dailyHaltFlag)
            {
               // Daily halt still allows closing the current losing position for safety, it just blocks the reversal re-entry.
               if(ExecuteClose(StringFormat("LOSS_THRESHOLD reached ($%.2f) while daily-halted - closing without reversal.", pl)))
                  TransitionTo(STATE_CLOSING_LOSS, "Loss threshold hit during daily halt - closing, no reversal will follow.");
            }
            else if(g_consecutiveReversals >= InpMaxConsecutiveReversals)
            {
               if(ExecuteClose(StringFormat("LOSS_THRESHOLD reached ($%.2f) at max consecutive reversals (%d) - closing without further reversal.", pl, g_consecutiveReversals)))
                  TransitionTo(STATE_CLOSING_LOSS, "Max consecutive reversals reached - closing, entering daily halt.");
            }
            else
            {
               if(ExecuteClose(StringFormat("LOSS_THRESHOLD reached: floating P/L=%.2f <= -%.2f", pl, InpLossThresholdUSD)))
                  TransitionTo(STATE_CLOSING_LOSS, "Loss threshold hit - closing before reversing direction.");
            }
         }
         else if(pl >= InpProfitTargetUSD)
         {
            if(ExecuteClose(StringFormat("PROFIT_TARGET reached: floating P/L=%.2f >= %.2f", pl, InpProfitTargetUSD)))
               TransitionTo(STATE_CLOSING_PROFIT, "Profit target hit - closing, cycle will reset.");
         }
         break;
      }

      case STATE_CLOSING_LOSS:
         // Waits here until OnTradeTransaction confirms the close, then decides REVERSAL_PENDING vs DAILY_HALTED/COOLDOWN.
         break;

      case STATE_REVERSAL_PENDING:
      {
         if(g_dailyHaltFlag) { TransitionTo(STATE_DAILY_HALTED, "Daily loss limit reached - reversal suppressed."); break; }
         int reverseDir = -g_previousDirection;
         if(reverseDir == 0) { TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "No valid previous direction to reverse from - waiting for fresh signal."); break; }
         if(ExecuteOpen(reverseDir))
            TransitionTo(STATE_OPENING_POSITION, StringFormat("Reversing into %s (reversal #%d).", DirToString(reverseDir), g_consecutiveReversals));
         break;
      }

      case STATE_CLOSING_PROFIT:
         // Waits here until OnTradeTransaction confirms the close, then moves to COOLDOWN.
         break;

      case STATE_COOLDOWN:
         if(TimeCurrent() - g_cooldownEndTime >= 0)
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Cooldown elapsed - waiting for a fresh confirmed EMA crossover.");
         break;

      case STATE_DAILY_HALTED:
         if(!g_dailyHaltFlag)
            TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Daily halt cleared (new trading day) - resuming.");
         break;

      case STATE_ERROR:
         // Terminal state - no automatic recovery. Requires EA restart after the underlying issue is fixed.
         break;
   }
}

//================================= DAILY LOSS PROTECTION ====================================
void RegisterDailyLoss()
{
   if(!InpDailyLossLimitEnabled) return;
   if(g_dailyHaltFlag) return;
   if(g_dailyRealizedPL <= -InpDailyLossLimitUSD)
   {
      g_dailyHaltFlag = true;
      SavePersistentState();
      LogWarning(StringFormat("Daily loss limit reached (realized=%.2f, limit=%.2f). New entries/reversals halted for the rest of the day.",
                               g_dailyRealizedPL, InpDailyLossLimitUSD));
   }
}

//================================= ON TRADE TRANSACTION (source of truth for fills) ====================================
//+------------------------------------------------------------------+
//| Fires for every executed deal. This - not the boolean return of  |
//| trade.Buy/Sell/PositionClose - is what confirms an open or close.|
//| Drives the state-machine transitions that depend on confirmed    |
//| execution (OPENING_POSITION -> POSITION_ACTIVE; CLOSING_LOSS /    |
//| CLOSING_PROFIT -> their respective next states).                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_TYPE  dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   int dealDirection = (dtype == DEAL_TYPE_BUY) ? 1 : (dtype == DEAL_TYPE_SELL) ? -1 : 0;

   ulong  positionId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double volume     = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price      = HistoryDealGetDouble(trans.deal, DEAL_PRICE);

   if(entry == DEAL_ENTRY_IN)
   {
      g_currentTicket    = positionId;
      g_currentDirection  = dealDirection;
      SavePersistentState();
      TransitionTo(STATE_POSITION_ACTIVE, StringFormat("Confirmed fill: %s position #%I64u opened @ %s.",
                   DirToString(dealDirection), positionId, DoubleToString(price, _Digits)));
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      double realized = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                         HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                         HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

      g_dailyRealizedPL += realized;
      g_lastRealizedResult = realized;
      g_totalTrades++;
      if(realized >= 0.0) { g_totalWins++;   g_totalRealizedProfit += realized; }
      else                 { g_totalLosses++; g_totalRealizedLoss   += (-realized); }

      string reason = (g_pendingCloseReason != "") ? g_pendingCloseReason : "Closed (broker/manual/SL)";
      bool wasLossClose = (g_state == STATE_CLOSING_LOSS);
      bool wasProfitClose = (g_state == STATE_CLOSING_PROFIT);

      int prevDirForLog = dealDirection; // the direction that was just closed
      int nextDirForLog = wasLossClose ? -prevDirForLog : 0;
      if(wasLossClose) g_consecutiveReversals++;
      if(wasProfitClose) g_consecutiveReversals = 0;

      LogTradeRow(positionId, prevDirForLog, volume, 0.0, price, realized, reason,
                  g_previousDirection, nextDirForLog, g_consecutiveReversals, (int)trans.deal);

      g_previousDirection = g_currentDirection;
      g_currentDirection = 0;
      g_currentTicket = 0;
      g_lastClosingReason = reason;
      g_pendingCloseReason = "";
      RegisterDailyLoss();
      SavePersistentState();

      // Only decide the post-close transition once the position is actually confirmed flat.
      ulong dummyTicket; int dummyDir;
      bool stillOpen = (CountManagedPositions(dummyTicket, dummyDir) > 0);
      if(stillOpen) return; // partial fill / another leg still open - wait for the next deal

      if(wasLossClose)
      {
         if(g_dailyHaltFlag)
            TransitionTo(STATE_DAILY_HALTED, "Loss close confirmed while daily-halted - no reversal.");
         else if(g_consecutiveReversals >= InpMaxConsecutiveReversals)
         {
            g_dailyHaltFlag = true; // treat max-reversal breach as a halt condition until manually/day reset
            SavePersistentState();
            TransitionTo(STATE_DAILY_HALTED, StringFormat("Max consecutive reversals (%d) reached - halting until next trading day.", g_consecutiveReversals));
         }
         else
            TransitionTo(STATE_REVERSAL_PENDING, "Loss close confirmed - proceeding to reverse direction.");
      }
      else if(wasProfitClose)
      {
         g_consecutiveReversals = 0;
         g_signalBarUsedForEntry = g_lastSignalBarTime; // the signal that led here is "used up" even on profit exit
         SavePersistentState();
         g_cooldownEndTime = TimeCurrent() + InpPostProfitWaitSeconds;
         TransitionTo(STATE_COOLDOWN, "Profit close confirmed - starting post-profit cooldown before requiring a fresh signal.");
      }
      else
      {
         // Position closed outside our own CLOSING_LOSS/CLOSING_PROFIT flow (manual/SL/broker-side).
         TransitionTo(STATE_WAITING_INITIAL_SIGNAL, "Position closed externally (manual/SL/broker) - resuming signal wait.");
      }
   }
}

//================================= MAIN LOOP ====================================
void OnTick()
{
   CheckNewDay();
   UpdateSignal();
   RunStateMachine();
   if(InpShowDashboard) UpdateDashboard();
}

//================================= DASHBOARD (minimal, display-only) ====================================
#define DASH_PREFIX "SRE_DASH_"
#define PANEL_X 10
#define PANEL_W 300

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
   CreateRect(DASH_PREFIX+"Panel", PANEL_X-6, 4, PANEL_W, 172, C'20,20,24', clrDimGray);

   CreateLabel(DASH_PREFIX+"Title",   PANEL_X, 10, clrGold, 11);
   CreateLabel(DASH_PREFIX+"Account", PANEL_X, 32, clrLime);
   CreateLabel(DASH_PREFIX+"Engine",  PANEL_X, 50, clrSkyBlue);
   CreateLabel(DASH_PREFIX+"Trades",  PANEL_X, 68, clrWhite);
   CreateLabel(DASH_PREFIX+"Pos",     PANEL_X, 86, clrOrange);
   CreateLabel(DASH_PREFIX+"Profit",  PANEL_X, 104, clrAqua);
   CreateLabel(DASH_PREFIX+"Loss",    PANEL_X, 122, clrSalmon);
   CreateLabel(DASH_PREFIX+"Float",   PANEL_X, 140, clrWhite);
   CreateLabel(DASH_PREFIX+"Action",  PANEL_X, 158, clrLightGray, 8);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, DASH_PREFIX);
}

void UpdateDashboard()
{
   string acctCcy = AccountInfoString(ACCOUNT_CURRENCY);

   ObjectSetString(0, DASH_PREFIX+"Title",   OBJPROP_TEXT, "Smart Reversal EA v3.02");
   ObjectSetString(0, DASH_PREFIX+"Account", OBJPROP_TEXT, "Account: DEMO");
   ObjectSetString(0, DASH_PREFIX+"Engine",  OBJPROP_TEXT, StringFormat("Engine: %s", StateToString(g_state)));
   ObjectSetString(0, DASH_PREFIX+"Trades",  OBJPROP_TEXT, StringFormat("Total trades: %d (W:%d / L:%d)", g_totalTrades, g_totalWins, g_totalLosses));
   ObjectSetString(0, DASH_PREFIX+"Pos",     OBJPROP_TEXT, StringFormat("Position: %s", DirToString(g_currentDirection)));
   ObjectSetString(0, DASH_PREFIX+"Profit",  OBJPROP_TEXT, StringFormat("Realized profit: %.2f %s", g_totalRealizedProfit, acctCcy));
   ObjectSetString(0, DASH_PREFIX+"Loss",    OBJPROP_TEXT, StringFormat("Realized loss: -%.2f %s", g_totalRealizedLoss, acctCcy));
   ObjectSetString(0, DASH_PREFIX+"Float",   OBJPROP_TEXT, StringFormat("Floating P/L: %.2f %s", FloatingPL(), acctCcy));
   ObjectSetString(0, DASH_PREFIX+"Action",  OBJPROP_TEXT, "Last: " + g_lastAction);
}
//+------------------------------------------------------------------+
