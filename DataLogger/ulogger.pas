{ ============================================================================
  ulogger - logger thread + CSV writer
    Monitor : read all tags every IntervalMs and show them
    Record  : the same, and write one CSV row per cycle
  File name from the PC clock of each row:
    <LogFolder>\mm-yyyy\dd-mm-yyyy.csv
  -> new day = new file, new month / new year = new folder and new file.
  The thread keeps running when the window is hidden (tray).
  Speed: all tags in as few requests as possible (udrivers.ReadAll), schedule and time stamps
  from the precise PC clock (QueryPerformanceCounter / GetSystemTimePreciseAsFileTime),
  the CSV file stays open while recording (one write per row).
  ============================================================================ }
unit ulogger;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, syncobjs, Math, uaddress, udrivers, uproject, uformat;

type
  TLogMode = (lmIdle, lmMonitor, lmRecord);

  TTagValue = udrivers.TTagValue;
  TTagValues = udrivers.TTagValues;

  TLogSnapshot = record
    Mode: TLogMode;
    Connected: Boolean;
    Status: string;          // connection state / last error
    Values: TTagValues;
    Cycles: Int64;
    RecFile: string;         // file written at the moment
    Rows: Int64;             // rows written since Record was started
    Pending: Integer;        // rows waiting because the file is locked (e.g. opened in Excel)
    CycleMs: Double;         // time of the last read cycle (read + CSV)
    Requests: Integer;       // requests to the PLC in the last cycle
    RatePerS: Double;        // cycles per second (average of the last seconds)
    Overrun: Boolean;        // reading takes longer than the interval
  end;

  { TCsvWriter - append rows, change file / folder with the date }

  TCsvWriter = class
  private
    FFolder: string;
    FHeader: string;
    FPath: string;           // file of the last row
    FPending: TStringList;   // rows that could not be written yet
    FStream: TFileStream;    // the open CSV file (kept open while recording)
    FOpenPath: string;
    FRows: Int64;
    FLastError: string;
    procedure AppendLines(const APath: string; Lines: TStrings; WriteHeader: Boolean);
    procedure CloseFile;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Setup(const AFolder: string; const ColumnNames: array of string);
    procedure WriteRow(T: TDateTime; const Status: string; const Vals: TTagValues;
      const Types: array of TDataType; const Fmts: array of string);
    procedure Reset;
    property Path: string read FPath;
    property Rows: Int64 read FRows;
    property LastError: string read FLastError;
    function PendingCount: Integer;
  end;

  { TLoggerThread }

  TLoggerThread = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FParams: TDriverParams;
    FTags: array of TTagDef;
    FInterval: Integer;
    FFolder: string;
    FMode: TLogMode;
    FVersion: Integer;       // incremented by Configure
    FSnap: TLogSnapshot;
    procedure Publish(const S: TLogSnapshot);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const P: TDriverParams; const Tags: array of TTagDef;
      AIntervalMs: Integer; const AFolder: string);
    procedure SetMode(M: TLogMode);
    function Snapshot: TLogSnapshot;
  end;

{ True when two settings use the same connection (no reconnect needed) }
const
  MIN_INTERVAL_MS = 5;

function SameConnection(const A, B: TDriverParams): Boolean;
{ <Folder>\mm-yyyy\dd-mm-yyyy.csv }
function LogFilePath(const Folder: string; T: TDateTime): string;
function LogFolderOf(const Folder: string; T: TDateTime): string;
function CsvField(const S: string): string;
{ milliseconds of a high resolution clock (QueryPerformanceCounter) }
function MsClock: Double;
{ local date + time with sub-millisecond resolution (Now only changes every ~16 ms) }
function PreciseNow: TDateTime;

implementation

var
  QpcFreq: Int64 = 0;
  GetPreciseTime: procedure(out FT: TFileTime); stdcall = nil;

function timeBeginPeriod(uPeriod: LongWord): LongWord; stdcall; external 'winmm.dll';
function timeEndPeriod(uPeriod: LongWord): LongWord; stdcall; external 'winmm.dll';

function MsClock: Double;
var
  C: Int64;
begin
  if QpcFreq = 0 then QueryPerformanceFrequency(QpcFreq);
  QueryPerformanceCounter(C);
  Result := Double(C) / Double(QpcFreq) * 1000;   // Double: FPC types 1000.0 as Single
end;

function PreciseNow: TDateTime;
var
  FT, LFT: TFileTime;
  ST: TSystemTime;
begin
  if not Assigned(GetPreciseTime) then Exit(Now);
  GetPreciseTime(FT);                       // UTC, 100 ns units
  FileTimeToLocalFileTime(FT, LFT);
  FileTimeToSystemTime(LFT, ST);
  Result := EncodeDate(ST.wYear, ST.wMonth, ST.wDay) +
    Double(((Int64(LFT.dwHighDateTime) shl 32) or LFT.dwLowDateTime) mod 864000000000) /
    Double(864000000000);     // Double: a Single constant would give 5 ms steps
end;
function SameConnection(const A, B: TDriverParams): Boolean;
begin
  Result := (A.Protocol = B.Protocol) and (A.Host = B.Host) and (A.Port = B.Port) and
    (A.Rack = B.Rack) and (A.Slot = B.Slot) and (A.UnitId = B.UnitId) and (A.ComPort = B.ComPort) and
    (A.Baud = B.Baud) and (A.DataBits = B.DataBits) and (A.Parity = B.Parity) and
    (A.StopBits = B.StopBits) and (A.TimeoutMs = B.TimeoutMs);
end;

function LogFolderOf(const Folder: string; T: TDateTime): string;
begin
  Result := IncludeTrailingPathDelimiter(Folder) + FormatDateTime('mm"-"yyyy', T);
end;

function LogFilePath(const Folder: string; T: TDateTime): string;
begin
  Result := LogFolderOf(Folder, T) + PathDelim + FormatDateTime('dd"-"mm"-"yyyy', T) + '.csv';
end;


function CsvField(const S: string): string;
begin
  if (Pos(',', S) > 0) or (Pos('"', S) > 0) or (Pos(#10, S) > 0) then
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

{ ============================== TCsvWriter ============================= }

constructor TCsvWriter.Create;
begin
  FPending := TStringList.Create;
end;

destructor TCsvWriter.Destroy;
begin
  CloseFile;
  FPending.Free;
  inherited Destroy;
end;

procedure TCsvWriter.Setup(const AFolder: string; const ColumnNames: array of string);
var
  I: Integer;
begin
  FFolder := AFolder;
  FHeader := 'Date,Time,Status';
  for I := 0 to High(ColumnNames) do
    FHeader := FHeader + ',' + CsvField(ColumnNames[I]);
  CloseFile;                   // open again: header check
  FPath := '';                 // check the header of the next file again
end;

procedure TCsvWriter.CloseFile;
begin
  FreeAndNil(FStream);
  FOpenPath := '';
end;

procedure TCsvWriter.Reset;
begin
  CloseFile;
  FPath := '';
  FRows := 0;
end;

function TCsvWriter.PendingCount: Integer;
begin
  Result := FPending.Count;
end;

{ the file stays open while recording (one write per row, no open / close each time).
  Other programs can still read it (Excel opens it read-only). A crash of the program
  loses nothing: every row is handed to Windows at once. }
procedure TCsvWriter.AppendLines(const APath: string; Lines: TStrings; WriteHeader: Boolean);
var
  S, First: string;
  New: Boolean;
  Buf: array[0..4095] of Char;
  N, P: Integer;
begin
  S := '';
  if (FStream = nil) or (FOpenPath <> APath) then
  begin
    CloseFile;
    ForceDirectories(ExtractFileDir(APath));
    New := not FileExists(APath);
    if New then
      FStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite)
    else
      FStream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite);
    FOpenPath := APath;
    if New then
      S := FHeader + #13#10
    else if WriteHeader then
    begin
      { another tag list than the existing file: write the new header again }
      N := FStream.Read(Buf, SizeOf(Buf));
      SetString(First, PChar(@Buf[0]), N);
      P := Pos(#13, First);
      if P = 0 then P := Pos(#10, First);
      if P > 0 then First := Copy(First, 1, P - 1);
      if First <> FHeader then S := #13#10 + FHeader + #13#10;
    end;
    FStream.Seek(0, soEnd);
  end;
  S := S + Lines.Text;
  try
    if S <> '' then FStream.WriteBuffer(S[1], Length(S));
  except
    CloseFile;                 // e.g. disk full: try to open it again next row
    raise;
  end;
end;

procedure TCsvWriter.WriteRow(T: TDateTime; const Status: string; const Vals: TTagValues;
  const Types: array of TDataType; const Fmts: array of string);
var
  Line, NewPath: string;
  I: Integer;
  HeaderCheck: Boolean;
begin
  Line := FormatDateTime('yyyy"-"mm"-"dd', T) + ',' + FormatDateTime('hh":"nn":"ss"."zzz', T) + ',' +
    CsvField(Status);
  for I := 0 to High(Vals) do
    if Vals[I].Ok then Line := Line + ',' + CsvField(FormatValue(Types[I], Fmts[I], Vals[I].Value))
    else Line := Line + ',';
  NewPath := LogFilePath(FFolder, T);
  { the date changed (or the first row): finish the old file, start the new one }
  if (NewPath <> FPath) and (FPending.Count > 0) and (FPath <> '') then
  try
    AppendLines(FPath, FPending, False);
    FPending.Clear;
  except
    { still locked - those rows are kept in memory }
  end;
  HeaderCheck := NewPath <> FPath;
  if HeaderCheck then CloseFile;
  FPath := NewPath;
  FPending.Add(Line);
  try
    AppendLines(FPath, FPending, HeaderCheck);
    Inc(FRows, FPending.Count);
    FPending.Clear;
    FLastError := '';
  except
    on E: Exception do
    begin
      FLastError := E.Message;     // e.g. the file is open in Excel
      if HeaderCheck then FPath := '';
      while FPending.Count > 100000 do FPending.Delete(0);
    end;
  end;
end;

{ ============================== TLoggerThread ========================== }

constructor TLoggerThread.Create;
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FInterval := DEFAULT_INTERVAL_MS;
  inherited Create(False);
end;

destructor TLoggerThread.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLoggerThread.Configure(const P: TDriverParams; const Tags: array of TTagDef;
  AIntervalMs: Integer; const AFolder: string);
var
  I: Integer;
begin
  FLock.Enter;
  try
    FParams := P;
    SetLength(FTags, Length(Tags));
    for I := 0 to High(Tags) do FTags[I] := Tags[I];
    FInterval := Max(MIN_INTERVAL_MS, AIntervalMs);
    FFolder := AFolder;
    Inc(FVersion);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TLoggerThread.SetMode(M: TLogMode);
begin
  FLock.Enter;
  try
    FMode := M;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TLoggerThread.Publish(const S: TLogSnapshot);
begin
  FLock.Enter;
  try
    FSnap := S;
    FSnap.Values := Copy(S.Values);
  finally
    FLock.Leave;
  end;
end;

function TLoggerThread.Snapshot: TLogSnapshot;
begin
  FLock.Enter;
  try
    Result := FSnap;
    Result.Values := Copy(FSnap.Values);
  finally
    FLock.Leave;
  end;
end;

procedure TLoggerThread.Execute;
var
  Driver: TPlcDriver;
  Writer: TCsvWriter;
  Version, Interval, I, N: Integer;
  Params: TDriverParams;
  Tags: array of TTagDef;
  Addrs: array of TTagAddr;
  Valid: array of Boolean;
  ParseErr: array of string;
  Types: array of TDataType;
  Fmts, Names: array of string;
  Folder, Err, RowStatus: string;
  Mode, LastMode: TLogMode;
  S: TLogSnapshot;
  Stamp: TDateTime;
  T0, Next, NowT, RateT0: Double;
  RateN: Integer;
  CommErr: Boolean;
begin
  Driver := nil;
  Writer := TCsvWriter.Create;
  Version := -1;
  LastMode := lmIdle;
  S := Default(TLogSnapshot);
  timeBeginPeriod(1);              // waits with 1 ms resolution instead of ~16 ms
  Next := MsClock;
  RateT0 := Next;
  RateN := 0;
  try
    while not Terminated do
    begin
      { ---- take over new settings ---- }
      FLock.Enter;
      try
        Mode := FMode;
        if Version <> FVersion then
        begin
          Version := FVersion;
          { new driver only when the connection settings changed (no needless reconnect) }
          if (Driver = nil) or not SameConnection(Params, FParams) then
          begin
            FreeAndNil(Driver);
            Driver := CreateDriver(FParams);
          end;
          Params := FParams;
          Tags := Copy(FTags);
          Interval := FInterval;
          Folder := FFolder;
          N := Length(Tags);
          SetLength(Addrs, N);
          SetLength(Valid, N);
          SetLength(ParseErr, N);
          SetLength(Types, N);
          SetLength(Fmts, N);
          SetLength(Names, N);
          for I := 0 to N - 1 do
          begin
            Valid[I] := ParseAddress(Params.Protocol, Tags[I].Address, Addrs[I], ParseErr[I]);
            if Valid[I] then Types[I] := Addrs[I].DT else Types[I] := dtReal;
            Fmts[I] := Tags[I].Format;
            Names[I] := Tags[I].Name + ' (' + Trim(Tags[I].Address) + ')';
          end;
          Writer.Setup(Folder, Names);
          Driver.SetTags(Addrs, Valid);        // plan the block reads
          SetLength(S.Values, N);
        end;
      finally
        FLock.Leave;
      end;

      if Mode <> lmRecord then Writer.Reset;
      if (Mode = lmRecord) and (LastMode <> lmRecord) then Writer.Reset;
      LastMode := Mode;
      S.Mode := Mode;

      { ---- stopped ---- }
      if Mode = lmIdle then
      begin
        if Driver.Connected then Driver.Disconnect;
        S.Connected := False;
        S.Status := 'Stopped';
        for I := 0 to High(S.Values) do S.Values[I].Ok := False;
        Publish(S);
        FWake.WaitFor(300);
        Next := MsClock;
        Continue;
      end;

      { ---- not yet time for the next cycle (woken by a setting / mode change) ---- }
      NowT := MsClock;
      if Next > NowT + 0.5 then
      begin
        S.RecFile := Writer.Path;
        S.Rows := Writer.Rows;
        Publish(S);
        FWake.WaitFor(Max(1, Trunc(Next - NowT)));
        Continue;
      end;

      { ---- one cycle ---- }
      T0 := MsClock;
      Stamp := PreciseNow;
      CommErr := False;
      Err := '';
      if not Driver.Connected then
      try
        Driver.Connect;
      except
        on E: Exception do
        begin
          CommErr := True;
          Err := E.Message;
        end;
      end;
      for I := 0 to High(S.Values) do
      begin
        S.Values[I].Ok := False;
        S.Values[I].Err := '';
        if not Valid[I] then S.Values[I].Err := ParseErr[I];
      end;
      S.Requests := 0;
      if not CommErr then
      try
        Driver.ReadAll(S.Values);         // all tags, as few requests as possible
        S.Requests := Driver.Requests;
      except
        on E: Exception do                // connection lost (tag errors are in S.Values)
        begin
          CommErr := True;
          Err := E.Message;
          Driver.Disconnect;
          for I := 0 to High(S.Values) do S.Values[I].Ok := False;
        end;
      end;

      S.Connected := not CommErr;
      if CommErr then
      begin
        S.Status := 'No connection: ' + Err;
        RowStatus := 'NO CONNECTION';
      end
      else
      begin
        S.Status := 'Connected  ' + Driver.Description;
        RowStatus := 'OK';
        for I := 0 to High(S.Values) do
          if not S.Values[I].Ok then RowStatus := 'TAG ERROR';
      end;

      if Mode = lmRecord then
        Writer.WriteRow(Stamp, RowStatus, S.Values, Types, Fmts);
      S.RecFile := Writer.Path;
      S.Rows := Writer.Rows;
      S.Pending := Writer.PendingCount;
      if Writer.LastError <> '' then S.Status := S.Status + '   [file: ' + Writer.LastError + ']';
      Inc(S.Cycles);
      S.CycleMs := MsClock - T0;
      Inc(RateN);
      if T0 - RateT0 >= 1000 then
      begin
        S.RatePerS := RateN * 1000 / (T0 - RateT0);
        RateT0 := T0;
        RateN := 0;
      end;

      { ---- wait for the next cycle (fixed schedule, no drift) ---- }
      if CommErr then
        Next := MsClock + Max(Interval, 2000)     // retry every 2 s
      else
        Next := Next + Interval;
      NowT := MsClock;
      S.Overrun := Next < NowT;
      if Next < NowT then Next := NowT;
      Publish(S);
      if Next - NowT >= 1 then FWake.WaitFor(Trunc(Next - NowT));
    end;
  finally
    timeEndPeriod(1);
    FreeAndNil(Driver);
    Writer.Free;
  end;
end;

initialization
  Pointer(GetPreciseTime) := GetProcAddress(GetModuleHandle('kernel32.dll'),
    'GetSystemTimePreciseAsFileTime');      // Windows 8 and newer
end.
