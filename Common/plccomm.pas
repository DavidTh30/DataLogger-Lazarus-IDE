{ ============================================================================
  plccomm - background communication thread
    - cyclic read of all status / value tags (grouped per DB)
    - queued writes (setpoints, enable bit, curves)
    - curve upload/download with read-back verification
  The GUI reads a thread-safe snapshot and pops events from a timer.
  ============================================================================ }
unit plccomm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs, Math, nlcore, s7comm;

type
  TPlcCmdKind = (pcWriteReal, pcWriteBool, pcWriteCurve, pcReadCurves);

  TPlcCmd = record
    Kind: TPlcCmdKind;
    Tag: TTagId;
    Value: Double;
    CurveKind: TCurveKind;
    Curve: TNLCurve;
    Kinds: TCurveKinds;
  end;

  TPlcEventKind = (evCurvesRead, evCurveWritten, evInfo, evError);

  TPlcEvent = record
    Kind: TPlcEventKind;
    Text: string;
    Curves: TCurveSet;
    Kinds: TCurveKinds;
  end;

  { is the PLC program running? (the PLC heartbeat changes every scan) }
  TRunState = (rsUnknown, rsRunning, rsStopped);

  TPlcSnapshot = record
    Connected: Boolean;
    Status: string;
    Values: TTagValues;
    Updates: Cardinal;
    PDU: Integer;
    RunState: TRunState;         // rsStopped = connected, but heartbeat frozen (CPU STOP?)
    PlcCurves: TCurveSet;        // curves as they are in the PLC right now
    PlcCurvesOk: Boolean;        // PlcCurves have been read
  end;

  { TPlcComm }

  TPlcComm = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FClient: TS7Client;
    FNet: TNetConfig;
    FTags: TTagTable;
    FCfgChanged: Boolean;
    FWantConnect: Boolean;
    FCmds: array of TPlcCmd;
    FEvents: array of TPlcEvent;
    FSnap: TPlcSnapshot;
    FHBLast: Double;             // heartbeat watch
    FHBChangeTick: QWord;
    FConnectTick: QWord;
    procedure PushCmd(const C: TPlcCmd);
    function PopCmd(out C: TPlcCmd): Boolean;
    procedure ClearCmds;
    procedure AddEvent(const E: TPlcEvent);
    procedure AddText(K: TPlcEventKind; const S: string);
    procedure SetState(AConnected: Boolean; const S: string);
    procedure ReadValues(const Tags: TTagTable);
    procedure DoCmd(const C: TPlcCmd; const Tags: TTagTable);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const ANet: TNetConfig; const ATags: TTagTable);
    procedure SetConnect(AValue: Boolean);
    function WantConnect: Boolean;
    procedure WriteReal(Tag: TTagId; V: Double);
    procedure WriteBool(Tag: TTagId; V: Boolean);
    procedure WriteCurve(Kind: TCurveKind; const C: TNLCurve);
    procedure ReadCurves(Kinds: TCurveKinds);
    function Snapshot: TPlcSnapshot;
    function PopEvent(out E: TPlcEvent): Boolean;
  end;

{ ---- status sentences for the operator: always say HMI or PLC and what to do ----
  Level: 0 = OK (green), 1 = attention (orange), 2 = error (red) }
function RunStateText(const S: TPlcSnapshot; out Level: Integer): string;
function CurvePlcText(const S: TPlcSnapshot; Kind: TCurveKind; const HmiCurve: TNLCurve;
  out Level: Integer): string;

implementation

function RunStateText(const S: TPlcSnapshot; out Level: Integer): string;
begin
  if not S.Connected then
  begin
    Level := 2;
    Result := 'PLC offline';
  end
  else
    case S.RunState of
      rsRunning:
        begin
          Level := 0;
          Result := 'PLC program RUNNING';
        end;
      rsStopped:
        begin
          Level := 2;
          Result := 'PLC program NOT RUNNING (CPU in STOP?) - outputs stay 0 V, set the CPU to RUN';
        end;
    else
      Level := 1;
      Result := 'PLC program: checking ...';
    end;
end;

function CurvePlcText(const S: TPlcSnapshot; Kind: TCurveKind; const HmiCurve: TNLCurve;
  out Level: Integer): string;
var
  Same: Boolean;
  {$IFDEF LINEAR2}
  Code: Integer;
  {$ENDIF}
begin
  if not S.Connected then
  begin
    Level := 1;
    Exit('PLC offline - cannot compare with the PLC');
  end;
  if not S.PlcCurvesOk then
  begin
    Level := 1;
    Exit('reading the PLC ...');
  end;
  Same := CurvesEqual(HmiCurve, S.PlcCurves[Kind]);
  if Same then
  begin
    Level := 0;
    Result := 'PLC = HMI (this curve is in use)';
  end
  else
  begin
    Level := 1;
    Result := 'PLC is DIFFERENT from HMI - press "Download to PLC" to use the HMI curve, ' +
      'or "Upload to HMI" to see the PLC curve';
  end;
  {$IFDEF LINEAR2}
  Code := Round(S.Values[CurveErrTag[Kind]]);
  if Code <> 0 then
  begin
    Level := 2;
    Result := Format('PLC REJECTED a calibration (code %d: %s) and keeps its previous one. %s',
      [Code, CalErrorText[EnsureRange(Code, 0, High(CalErrorText))], Result]);
  end;
  {$ENDIF}
  if S.RunState = rsStopped then
  begin
    Level := 2;
    Result := Result + '  [PLC NOT RUNNING]';
  end;
end;

{ TPlcComm }

constructor TPlcComm.Create;
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FClient := TS7Client.Create;
  FNet := DefaultNet;
  FTags := DefaultTags;
  FSnap.Status := 'Disconnected';
  inherited Create(False);
end;

destructor TPlcComm.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  FClient.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPlcComm.Configure(const ANet: TNetConfig; const ATags: TTagTable);
begin
  FLock.Enter;
  try
    FNet := ANet;
    FTags := ATags;
    FCfgChanged := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TPlcComm.SetConnect(AValue: Boolean);
begin
  FLock.Enter;
  try
    FWantConnect := AValue;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TPlcComm.WantConnect: Boolean;
begin
  FLock.Enter;
  try
    Result := FWantConnect;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.PushCmd(const C: TPlcCmd);
begin
  FLock.Enter;
  try
    SetLength(FCmds, Length(FCmds) + 1);
    FCmds[High(FCmds)] := C;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TPlcComm.PopCmd(out C: TPlcCmd): Boolean;
begin
  FLock.Enter;
  try
    Result := Length(FCmds) > 0;
    if Result then
    begin
      C := FCmds[0];
      Delete(FCmds, 0, 1);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.ClearCmds;
begin
  FLock.Enter;
  try
    FCmds := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.AddEvent(const E: TPlcEvent);
begin
  FLock.Enter;
  try
    SetLength(FEvents, Length(FEvents) + 1);
    FEvents[High(FEvents)] := E;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.AddText(K: TPlcEventKind; const S: string);
var
  E: TPlcEvent;
begin
  E := Default(TPlcEvent);
  E.Kind := K;
  E.Text := S;
  AddEvent(E);
end;

function TPlcComm.PopEvent(out E: TPlcEvent): Boolean;
begin
  FLock.Enter;
  try
    Result := Length(FEvents) > 0;
    if Result then
    begin
      E := FEvents[0];
      Delete(FEvents, 0, 1);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.SetState(AConnected: Boolean; const S: string);
begin
  FLock.Enter;
  try
    FSnap.Connected := AConnected;
    if not AConnected then
    begin
      FSnap.RunState := rsUnknown;
      FSnap.PlcCurvesOk := False;
    end;
    FSnap.Status := S;
    FSnap.PDU := FClient.PDULength;
  finally
    FLock.Leave;
  end;
end;

function TPlcComm.Snapshot: TPlcSnapshot;
begin
  FLock.Enter;
  try
    Result := FSnap;
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.WriteReal(Tag: TTagId; V: Double);
var
  C: TPlcCmd;
begin
  C := Default(TPlcCmd);
  C.Kind := pcWriteReal;
  C.Tag := Tag;
  C.Value := V;
  PushCmd(C);
end;

procedure TPlcComm.WriteBool(Tag: TTagId; V: Boolean);
var
  C: TPlcCmd;
begin
  C := Default(TPlcCmd);
  C.Kind := pcWriteBool;
  C.Tag := Tag;
  C.Value := Ord(V);
  PushCmd(C);
end;

procedure TPlcComm.WriteCurve(Kind: TCurveKind; const C: TNLCurve);
var
  Cmd: TPlcCmd;
begin
  Cmd := Default(TPlcCmd);
  Cmd.Kind := pcWriteCurve;
  Cmd.CurveKind := Kind;
  Cmd.Curve := C;
  PushCmd(Cmd);
end;

procedure TPlcComm.ReadCurves(Kinds: TCurveKinds);
var
  C: TPlcCmd;
begin
  C := Default(TPlcCmd);
  C.Kind := pcReadCurves;
  C.Kinds := Kinds;
  PushCmd(C);
end;

procedure TPlcComm.ReadValues(const Tags: TTagTable);
var
  DBs: array of Integer;
  T: TTagId;
  I, DB, Lo, Hi, P: Integer;
  Found: Boolean;
  Buf, RB: TBytes;
  V: TTagValues;
  K: TCurveKind;
  PC: TCurveSet;
  Now64: QWord;
  RS: TRunState;
begin
  V := FSnap.Values;
  { distinct DB numbers of the scalar tags }
  DBs := nil;
  for T := Low(TTagId) to High(TTagId) do
  begin
    if TagType[T] = ttCurve then Continue;
    Found := False;
    for I := 0 to High(DBs) do
      if DBs[I] = Tags[T].DB then Found := True;
    if not Found then
    begin
      SetLength(DBs, Length(DBs) + 1);
      DBs[High(DBs)] := Tags[T].DB;
    end;
  end;
  { one block read per DB covering all its tags }
  for I := 0 to High(DBs) do
  begin
    DB := DBs[I];
    Lo := MaxInt;
    Hi := 0;
    for T := Low(TTagId) to High(TTagId) do
      if (TagType[T] <> ttCurve) and (Tags[T].DB = DB) then
      begin
        if Tags[T].Offset < Lo then Lo := Tags[T].Offset;
        if Tags[T].Offset + TagTypeSize[TagType[T]] > Hi then
          Hi := Tags[T].Offset + TagTypeSize[TagType[T]];
      end;
    FClient.DBRead(DB, Lo, Hi - Lo, Buf);
    for T := Low(TTagId) to High(TTagId) do
      if (TagType[T] <> ttCurve) and (Tags[T].DB = DB) then
      begin
        P := Tags[T].Offset - Lo;
        case TagType[T] of
          ttReal: V[T] := S7GetReal(Buf, P);
          ttInt: V[T] := S7GetInt(Buf, P);
          ttBool: V[T] := Ord(S7GetBit(Buf, P, Tags[T].Bit));
        end;
      end;
  end;
  { the curves as they are in the PLC, to compare with the HMI }
  for K := Low(TCurveKind) to High(TCurveKind) do
  begin
    T := CurveTag[K];
    FClient.DBRead(Tags[T].DB, Tags[T].Offset, CURVE_BYTES, RB);
    BytesToCurve(RB, 0, PC[K]);
  end;
  { heartbeat watch: no change for 1.5 s = program not running }
  Now64 := GetTickCount64;
  if V[tgHeartbeat] <> FHBLast then
  begin
    if FHBLast <> -1 then FHBChangeTick := Now64;   // first sample is no change
    FHBLast := V[tgHeartbeat];
  end;
  if (FHBChangeTick > 0) and (Now64 - FHBChangeTick < 1500) then RS := rsRunning
  else if Now64 - FConnectTick < 1500 then RS := rsUnknown
  else RS := rsStopped;
  FLock.Enter;
  try
    FSnap.Values := V;
    FSnap.PlcCurves := PC;
    FSnap.PlcCurvesOk := True;
    FSnap.RunState := RS;
    Inc(FSnap.Updates);
  finally
    FLock.Leave;
  end;
end;

procedure TPlcComm.DoCmd(const C: TPlcCmd; const Tags: TTagTable);
var
  B, RB: TBytes;
  K: TCurveKind;
  T: TTagId;
  E: TPlcEvent;
  Back: TNLCurve;
begin
  case C.Kind of
    pcWriteReal:
      begin
        B := nil;
        SetLength(B, 4);
        S7SetReal(B, 0, C.Value);
        FClient.DBWrite(Tags[C.Tag].DB, Tags[C.Tag].Offset, B);
      end;
    pcWriteBool:
      FClient.DBWriteBit(Tags[C.Tag].DB, Tags[C.Tag].Offset, Tags[C.Tag].Bit, C.Value <> 0);
    pcWriteCurve:
      begin
        T := CurveTag[C.CurveKind];
        {$IFDEF LINEAR2}
        { acknowledge an old reject code first: the PLC sets it again if this curve is bad too }
        B := nil;
        SetLength(B, 2);
        S7SetInt(B, 0, 0);
        FClient.DBWrite(Tags[CurveErrTag[C.CurveKind]].DB, Tags[CurveErrTag[C.CurveKind]].Offset, B);
        {$ENDIF}
        B := nil;
        SetLength(B, CURVE_BYTES);
        CurveToBytes(C.Curve, B, 0);
        FClient.DBWrite(Tags[T].DB, Tags[T].Offset, B);
        Sleep(150);    // let the PLC scan once: it may reject the curve and restore the old one
        FClient.DBRead(Tags[T].DB, Tags[T].Offset, CURVE_BYTES, RB);
        BytesToCurve(RB, 0, Back);
        if CurvesEqual(Back, C.Curve) then
          AddText(evCurveWritten, CurveName[C.CurveKind] + ' written to PLC and verified')
        else
          {$IFDEF LINEAR2}
          AddText(evError, CurveName[C.CurveKind] + ' REJECTED by the PLC - previous calibration kept (see Err code)');
          {$ELSE}
          AddText(evError, CurveName[C.CurveKind] + ' read-back mismatch after write');
          {$ENDIF}
      end;
    pcReadCurves:
      begin
        E := Default(TPlcEvent);
        E.Kind := evCurvesRead;
        E.Kinds := C.Kinds;
        for K := Low(TCurveKind) to High(TCurveKind) do
          if K in C.Kinds then
          begin
            T := CurveTag[K];
            FClient.DBRead(Tags[T].DB, Tags[T].Offset, CURVE_BYTES, RB);
            BytesToCurve(RB, 0, E.Curves[K]);
          end;
        E.Text := 'Curves read from PLC';
        AddEvent(E);
      end;
  end;
end;

procedure TPlcComm.Execute;
var
  Net: TNetConfig;
  Tags: TTagTable;
  Changed, Want: Boolean;
  C: TPlcCmd;
begin
  while not Terminated do
  begin
    FLock.Enter;
    try
      Net := FNet;
      Tags := FTags;
      Changed := FCfgChanged;
      FCfgChanged := False;
      Want := FWantConnect;
    finally
      FLock.Leave;
    end;

    if FClient.Connected and (Changed or not Want) then
    begin
      FClient.Disconnect;
      SetState(False, 'Disconnected');
    end;

    if not Want then
    begin
      ClearCmds;
      FWake.WaitFor(200);
      Continue;
    end;

    try
      if not FClient.Connected then
      begin
        SetState(False, 'Connecting to ' + Net.Host + ' ...');
        FClient.Connect(Net.Host, Net.Rack, Net.Slot, Net.TimeoutMs);
        FHBLast := -1;
        FHBChangeTick := 0;
        FConnectTick := GetTickCount64;
        SetState(True, Format('Connected %s  rack %d slot %d  PDU %d',
          [Net.Host, Net.Rack, Net.Slot, FClient.PDULength]));
        AddText(evInfo, 'Connected to ' + Net.Host);
      end;
      while (not Terminated) and PopCmd(C) do
        DoCmd(C, Tags);
      ReadValues(Tags);
      FWake.WaitFor(Net.PollMs);
    except
      on E: Exception do
      begin
        FClient.Disconnect;
        ClearCmds;
        SetState(False, 'Error: ' + E.Message);
        AddText(evError, E.Message);
        FWake.WaitFor(2000);
      end;
    end;
  end;
  FClient.Disconnect;
end;

end.
