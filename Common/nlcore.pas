{ ============================================================================
  nlcore - shared model for both HMIs
    - 10-point nonlinear curves (same math as PLC FC_NL_Interp)
    - network + PLC tag configuration
    - project file (INI format)  *.nlp
  ============================================================================ }
unit nlcore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Math;

const
{ Set 1 = 10-point nonlinear (default build), Set 2 = 2-point linear (compile with -dLINEAR2) }
{$IFDEF LINEAR2}
  NL_POINTS = 2;
  APP_KIND = 'Linear';
  APP_KIND_LONG = '2-point linear calibration';
  PLC_FC_NAME = 'FC_Lin_Scale';
{$ELSE}
  NL_POINTS = 10;
  APP_KIND = 'Nonlinear';
  APP_KIND_LONG = '10-point nonlinear curves';
  PLC_FC_NAME = 'FC_NL_Interp';
{$ENDIF}
  KV_FULL = 15.0;
  MA_FULL = 20.0;
  V_FULL = 10.0;
  CURVE_BYTES = NL_POINTS * 4 * 2;   // 80 bytes in PLC
  RANGE_TOL = 1E-6;                  // float noise allowed at the range ends

type
  TCurveKind = (ckVoltSP, ckVoltAct, ckCurSP, ckCurAct);
  TCurveKinds = set of TCurveKind;

  TNLCurve = record
    Eng: array[0..NL_POINTS - 1] of Double;
    Volt: array[0..NL_POINTS - 1] of Double;
  end;
  TCurveSet = array[TCurveKind] of TNLCurve;

  TTagType = (ttReal, ttInt, ttBool, ttCurve);

  TTagId = (
    tgVoltSP, tgCurSP, tgVoltAct, tgCurAct,
    tgAO0V, tgAO1V, tgAI0V, tgAI1V,
    tgAO0Raw, tgAO1Raw, tgAI0Raw, tgAI1Raw,
    tgEnable, tgValidVSP, tgValidVAct, tgValidCSP, tgValidCAct,
    tgAI0Fault, tgAI1Fault, tgHeartbeat,
    tgCurveVSP, tgCurveVAct, tgCurveCSP, tgCurveCAct
    {$IFDEF LINEAR2}
    , tgErrVSP, tgErrVAct, tgErrCSP, tgErrCAct, tgLimVSP, tgLimCSP
    {$ENDIF});

  TTagDef = record
    DB: Integer;
    Offset: Integer;
    Bit: Integer;
  end;
  TTagTable = array[TTagId] of TTagDef;
  TTagValues = array[TTagId] of Double;

  TNetConfig = record
    Host: string;
    Rack: Integer;
    Slot: Integer;
    PollMs: Integer;
    TimeoutMs: Integer;
    AutoConnect: Boolean;
  end;

const
  CurveTag: array[TCurveKind] of TTagId = (tgCurveVSP, tgCurveVAct, tgCurveCSP, tgCurveCAct);
  {$IFDEF LINEAR2}
  CurveErrTag: array[TCurveKind] of TTagId = (tgErrVSP, tgErrVAct, tgErrCSP, tgErrCAct);
  {$ENDIF}
  CurveName: array[TCurveKind] of string = ('Curve_VSP', 'Curve_VAct', 'Curve_CSP', 'Curve_CAct');
  CurveTitle: array[TCurveKind] of string = (
    'Voltage Setpoint (kV -> V)', 'Voltage Actual (V -> kV)',
    'Current Limit Setpoint (mA -> V)', 'Current Actual (V -> mA)');
  CurveUnit: array[TCurveKind] of string = ('kV', 'kV', 'mA', 'mA');
  CurveEngFull: array[TCurveKind] of Double = (KV_FULL, KV_FULL, MA_FULL, MA_FULL);
  CurveIsActual: array[TCurveKind] of Boolean = (False, True, False, True);

  TagName: array[TTagId] of string = (
    'VoltSP_kV', 'CurSP_mA', 'VoltAct_kV', 'CurAct_mA',
    'AO0_V', 'AO1_V', 'AI0_V', 'AI1_V',
    'AO0_Raw', 'AO1_Raw', 'AI0_Raw', 'AI1_Raw',
    'Enable', 'Valid_VSP', 'Valid_VAct', 'Valid_CSP', 'Valid_CAct',
    'AI0_Fault', 'AI1_Fault', 'Heartbeat',
    'Curve_VSP', 'Curve_VAct', 'Curve_CSP', 'Curve_CAct'
    {$IFDEF LINEAR2}
    , 'Err_VSP', 'Err_VAct', 'Err_CSP', 'Err_CAct', 'VSP_Limited', 'CSP_Limited'
    {$ENDIF});
  TagType: array[TTagId] of TTagType = (
    ttReal, ttReal, ttReal, ttReal,
    ttReal, ttReal, ttReal, ttReal,
    ttInt, ttInt, ttInt, ttInt,
    ttBool, ttBool, ttBool, ttBool, ttBool,
    ttBool, ttBool, ttInt,
    ttCurve, ttCurve, ttCurve, ttCurve
    {$IFDEF LINEAR2}
    , ttInt, ttInt, ttInt, ttInt, ttBool, ttBool
    {$ENDIF});
  TagDesc: array[TTagId] of string = (
    'HMI->PLC  Voltage setpoint 0..15 kV', 'HMI->PLC  Current limit setpoint 0..20 mA',
    'PLC->HMI  Actual voltage 0..15 kV', 'PLC->HMI  Actual current 0..20 mA',
    'PLC->HMI  AO ch0 voltage (V)', 'PLC->HMI  AO ch1 voltage (V)',
    'PLC->HMI  AI ch0 voltage (V)', 'PLC->HMI  AI ch1 voltage (V)',
    'PLC->HMI  AO ch0 raw', 'PLC->HMI  AO ch1 raw', 'PLC->HMI  AI ch0 raw', 'PLC->HMI  AI ch1 raw',
    'HMI->PLC  Output enable', 'PLC->HMI  Curve VSP valid', 'PLC->HMI  Curve VAct valid',
    'PLC->HMI  Curve CSP valid', 'PLC->HMI  Curve CAct valid',
    'PLC->HMI  AI ch0 fault', 'PLC->HMI  AI ch1 fault', 'PLC->HMI  Heartbeat',
    {$IFDEF LINEAR2}
    'HMI<->PLC  Voltage setpoint calibration (16 B)', 'HMI<->PLC  Voltage actual calibration (16 B)',
    'HMI<->PLC  Current setpoint calibration (16 B)', 'HMI<->PLC  Current actual calibration (16 B)',
    'PLC->HMI  Reject code Curve_VSP (0 = OK)', 'PLC->HMI  Reject code Curve_VAct (0 = OK)',
    'PLC->HMI  Reject code Curve_CSP (0 = OK)', 'PLC->HMI  Reject code Curve_CAct (0 = OK)',
    'PLC->HMI  Voltage setpoint clamped to X0..X1', 'PLC->HMI  Current setpoint clamped to X0..X1');
    {$ELSE}
    'HMI<->PLC  Voltage setpoint curve (80 B)', 'HMI<->PLC  Voltage actual curve (80 B)',
    'HMI<->PLC  Current setpoint curve (80 B)', 'HMI<->PLC  Current actual curve (80 B)');
    {$ENDIF}

  TagTypeName: array[TTagType] of string = ('Real', 'Int', 'Bool', 'typeNLCurve');
  TagTypeSize: array[TTagType] of Integer = (4, 2, 1, CURVE_BYTES);

  { minimum distance between neighbouring points (Set 2 = same rules as PLC FC_Lin_Check) }
  {$IFDEF LINEAR2}
  MIN_ENG_SPAN_FRAC = 0.1;     // fraction of full scale
  MIN_VOLT_SPAN = 1.0;         // V
  {$ELSE}
  MIN_ENG_SPAN_FRAC = 0;       // Set 1: strictly increasing is enough
  MIN_VOLT_SPAN = 0;
  {$ENDIF}

  { PLC reject codes (Set 2, FC_Lin_Check) }
  CalErrorText: array[0..6] of string = (
    'OK', 'engineering value out of range', 'voltage out of 0..10 V',
    'point 2 engineering value not greater than point 1', 'point 2 voltage not greater than point 1',
    'engineering span smaller than 10 % of full scale', 'voltage span smaller than 1.0 V');

{ curve math }
function LinearCurve(Kind: TCurveKind): TNLCurve;
function InterpTable(const Xs, Ys: array of Double; X, YMin, YMax: Double): Double;
function CurveSetpointToVolt(const C: TNLCurve; Eng, EngFull: Double): Double;
function CurveVoltToActual(const C: TNLCurve; Volt, EngFull: Double): Double;
function ValidateCurve(const C: TNLCurve; Kind: TCurveKind; out Msg: string): Boolean;
function PointOk(const C: TNLCurve; Kind: TCurveKind; I: Integer): Boolean;
{ setpoint range of a setpoint curve = its first .. last point (the PLC clamps to it) }
procedure SetpointRange(const C: TNLCurve; Kind: TCurveKind; out Lo, Hi: Double);
{ status text of a curve in the PLC: 'OK' / 'INVALID' (Set 1) / 'REJECTED: reason' (Set 2) }
function PlcCurveStatus(const V: TTagValues; Kind: TCurveKind): string;
{ Set 2: PLC reject codes / setpoint limits that changed since Prev, one text line each }
procedure PlcNotices(const Prev, Cur: TTagValues; Lines: TStrings);
procedure ClampPoint(const C: TNLCurve; Kind: TCurveKind; I: Integer; var E, V: Double);
function CurvesEqual(const A, B: TNLCurve): Boolean;
procedure CurveToBytes(const C: TNLCurve; var B: TBytes; Ofs: Integer);
procedure BytesToCurve(const B: TBytes; Ofs: Integer; out C: TNLCurve);

{ configuration }
function DefaultTags: TTagTable;
function DefaultNet: TNetConfig;
function TagAddress(Id: TTagId; const T: TTagTable): string;

type

  { TNLProject }

  TNLProject = class
  public
    Curves: TCurveSet;
    Net: TNetConfig;
    Tags: TTagTable;
    VoltSP: Double;
    CurSP: Double;
    VoltStep: Double;   // Step-up / Step-down size (kV)
    CurStep: Double;    // Step-up / Step-down size (mA)
    FileName: string;
    Modified: Boolean;
    constructor Create;
    procedure Reset;
    procedure LoadFromFile(const AFile: string);
    procedure SaveToFile(const AFile: string);
  end;

var
  NLFmt: TFormatSettings;   // '.' decimal separator for files and PLC values

const
  { Step-up / Step-down sizes offered on the monitor page (kV or mA) }
  STEP_SIZES: array[0..5] of Double = (0.01, 0.05, 0.1, 0.5, 1.0, 2.0);

{ one step from Base in direction Dir (+1 / -1), clamped to AMin..AMax }
function StepSetpoint(Base, Step: Double; Dir: Integer; AMin, AMax: Double): Double;

function FloatStr(V: Double; Digits: Integer = 3): string;
function StrFloat(const S: string; out V: Double): Boolean;

implementation

uses
  s7comm;

function StepSetpoint(Base, Step: Double; Dir: Integer; AMin, AMax: Double): Double;
begin
  Result := EnsureRange(RoundTo(Base + Dir * Step, -3), AMin, AMax);
end;

function FloatStr(V: Double; Digits: Integer): string;
begin
  Result := FloatToStrF(V, ffFixed, 15, Digits, NLFmt);
end;

function StrFloat(const S: string; out V: Double): Boolean;
begin
  Result := TryStrToFloat(StringReplace(Trim(S), ',', '.', [rfReplaceAll]), V, NLFmt);
end;

function LinearCurve(Kind: TCurveKind): TNLCurve;
var
  I: Integer;
begin
  for I := 0 to NL_POINTS - 1 do
  begin
    Result.Eng[I] := CurveEngFull[Kind] * I / (NL_POINTS - 1);
    Result.Volt[I] := V_FULL * I / (NL_POINTS - 1);
  end;
end;

function InterpTable(const Xs, Ys: array of Double; X, YMin, YMax: Double): Double;
var
  I, K: Integer;
begin
  K := 0;
  {$IFNDEF LINEAR2}
  { nonlinear table: no extrapolation outside the first / last point }
  if X < Xs[0] then X := Xs[0];
  if X > Xs[NL_POINTS - 1] then X := Xs[NL_POINTS - 1];
  {$ENDIF}
  for I := 1 to NL_POINTS - 2 do
    if X >= Xs[I] then K := I;
  if Xs[K + 1] - Xs[K] <= 0 then
    Result := Ys[K]
  else
    Result := Ys[K] + (Ys[K + 1] - Ys[K]) * (X - Xs[K]) / (Xs[K + 1] - Xs[K]);
  Result := EnsureRange(Result, YMin, YMax);
end;

function Increasing(const A: array of Double): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to High(A) do
    if A[I] <= A[I - 1] then Exit(False);
end;

function CurveSetpointToVolt(const C: TNLCurve; Eng, EngFull: Double): Double;
begin
  if Increasing(C.Eng) then
    Result := InterpTable(C.Eng, C.Volt, Eng, 0, V_FULL)
  else
    Result := EnsureRange(Eng * V_FULL / EngFull, 0, V_FULL);
end;

function CurveVoltToActual(const C: TNLCurve; Volt, EngFull: Double): Double;
begin
  if Increasing(C.Volt) then
    Result := InterpTable(C.Volt, C.Eng, Volt, 0, EngFull)
  else
    Result := EnsureRange(Volt * EngFull / V_FULL, 0, EngFull);
end;

procedure PlcNotices(const Prev, Cur: TTagValues; Lines: TStrings);
{$IFDEF LINEAR2}
const
  ErrTag: array[TCurveKind] of TTagId = (tgErrVSP, tgErrVAct, tgErrCSP, tgErrCAct);
var
  K: TCurveKind;
begin
  for K := Low(TCurveKind) to High(TCurveKind) do
    if (Round(Cur[ErrTag[K]]) <> Round(Prev[ErrTag[K]])) and (Cur[ErrTag[K]] <> 0) then
      Lines.Add('PLC rejected ' + CurveName[K] + ' (code ' + IntToStr(Round(Cur[ErrTag[K]])) + '): ' +
        CalErrorText[EnsureRange(Round(Cur[ErrTag[K]]), 0, High(CalErrorText))] + ' - previous calibration kept');
  if (Cur[tgLimVSP] <> 0) and (Prev[tgLimVSP] = 0) then
    Lines.Add('PLC limited the voltage setpoint to ' + FloatStr(Cur[tgVoltSP], 2) + ' kV (calibrated range X0..X1)');
  if (Cur[tgLimCSP] <> 0) and (Prev[tgLimCSP] = 0) then
    Lines.Add('PLC limited the current setpoint to ' + FloatStr(Cur[tgCurSP], 2) + ' mA (calibrated range X0..X1)');
end;
{$ELSE}
begin
  { Set 1 PLC has no reject codes }
end;
{$ENDIF}

function SpanOk(D, MinSpan: Double): Boolean;
begin
  Result := (D > 0) and (D >= MinSpan - RANGE_TOL);
end;

function PointOk(const C: TNLCurve; Kind: TCurveKind; I: Integer): Boolean;
var
  Full: Double;
begin
  Full := CurveEngFull[Kind];
  Result := (C.Eng[I] >= -RANGE_TOL) and (C.Eng[I] <= Full + RANGE_TOL) and
            (C.Volt[I] >= -RANGE_TOL) and (C.Volt[I] <= V_FULL + RANGE_TOL);
  if Result and (I > 0) then
    Result := SpanOk(C.Eng[I] - C.Eng[I - 1], Full * MIN_ENG_SPAN_FRAC) and
              SpanOk(C.Volt[I] - C.Volt[I - 1], MIN_VOLT_SPAN);
  if Result and (I < NL_POINTS - 1) then
    Result := SpanOk(C.Eng[I + 1] - C.Eng[I], Full * MIN_ENG_SPAN_FRAC) and
              SpanOk(C.Volt[I + 1] - C.Volt[I], MIN_VOLT_SPAN);
end;

procedure SetpointRange(const C: TNLCurve; Kind: TCurveKind; out Lo, Hi: Double);
begin
  Lo := EnsureRange(C.Eng[0], 0, CurveEngFull[Kind]);
  Hi := EnsureRange(C.Eng[NL_POINTS - 1], Lo, CurveEngFull[Kind]);
end;

function PlcCurveStatus(const V: TTagValues; Kind: TCurveKind): string;
{$IFDEF LINEAR2}
const
  ErrTag: array[TCurveKind] of TTagId = (tgErrVSP, tgErrVAct, tgErrCSP, tgErrCAct);
var
  Code: Integer;
begin
  Code := Round(V[ErrTag[Kind]]);
  if Code = 0 then Result := 'OK'
  else if (Code > 0) and (Code <= High(CalErrorText)) then Result := 'REJECTED: ' + CalErrorText[Code]
  else Result := 'REJECTED: code ' + IntToStr(Code);
end;
{$ELSE}
const
  ValidTag: array[TCurveKind] of TTagId = (tgValidVSP, tgValidVAct, tgValidCSP, tgValidCAct);
begin
  if V[ValidTag[Kind]] <> 0 then Result := 'OK' else Result := 'INVALID';
end;
{$ENDIF}

procedure ClampPoint(const C: TNLCurve; Kind: TCurveKind; I: Integer; var E, V: Double);
const
  GAP_V = 0.01;
var
  GapE, Lo, Hi: Double;
begin
  { keep point I inside its neighbours so the curve stays strictly increasing }
  GapE := CurveEngFull[Kind] * Max(0.001, MIN_ENG_SPAN_FRAC);
  Lo := 0;
  Hi := CurveEngFull[Kind];
  if I > 0 then Lo := C.Eng[I - 1] + GapE;
  if I < NL_POINTS - 1 then Hi := C.Eng[I + 1] - GapE;
  if Hi < Lo then Hi := Lo;
  E := RoundTo(EnsureRange(E, Lo, Hi), -3);
  Lo := 0;
  Hi := V_FULL;
  if I > 0 then Lo := C.Volt[I - 1] + Max(GAP_V, MIN_VOLT_SPAN);
  if I < NL_POINTS - 1 then Hi := C.Volt[I + 1] - Max(GAP_V, MIN_VOLT_SPAN);
  if Hi < Lo then Hi := Lo;
  V := RoundTo(EnsureRange(V, Lo, Hi), -3);
end;

function ValidateCurve(const C: TNLCurve; Kind: TCurveKind; out Msg: string): Boolean;
var
  I: Integer;
begin
  Msg := '';
  for I := 0 to NL_POINTS - 1 do
  begin
    if (C.Eng[I] < -RANGE_TOL) or (C.Eng[I] > CurveEngFull[Kind] + RANGE_TOL) then
    begin
      Msg := Format('%s: point %d %s out of range 0..%s',
        [CurveName[Kind], I + 1, CurveUnit[Kind], FloatStr(CurveEngFull[Kind], 0)]);
      Exit(False);
    end;
    if (C.Volt[I] < -RANGE_TOL) or (C.Volt[I] > V_FULL + RANGE_TOL) then
    begin
      Msg := Format('%s: point %d voltage out of range 0..10 V', [CurveName[Kind], I + 1]);
      Exit(False);
    end;
    if (I > 0) and ((C.Eng[I] <= C.Eng[I - 1]) or (C.Volt[I] <= C.Volt[I - 1])) then
    begin
      Msg := Format('%s: point %d must be greater than point %d (curve must be strictly increasing)',
        [CurveName[Kind], I + 1, I]);
      Exit(False);
    end;
    if (I > 0) and not SpanOk(C.Eng[I] - C.Eng[I - 1], CurveEngFull[Kind] * MIN_ENG_SPAN_FRAC) then
    begin
      Msg := Format('%s: %s (points %d..%d)', [CurveName[Kind], CalErrorText[5], I, I + 1]);
      Exit(False);
    end;
    if (I > 0) and not SpanOk(C.Volt[I] - C.Volt[I - 1], MIN_VOLT_SPAN) then
    begin
      Msg := Format('%s: %s (points %d..%d)', [CurveName[Kind], CalErrorText[6], I, I + 1]);
      Exit(False);
    end;
  end;
  Result := True;
end;

function CurvesEqual(const A, B: TNLCurve): Boolean;
var
  I: Integer;
begin
  for I := 0 to NL_POINTS - 1 do
    if not SameValue(A.Eng[I], B.Eng[I], 1E-4) or not SameValue(A.Volt[I], B.Volt[I], 1E-4) then
      Exit(False);
  Result := True;
end;

procedure CurveToBytes(const C: TNLCurve; var B: TBytes; Ofs: Integer);
var
  I: Integer;
begin
  for I := 0 to NL_POINTS - 1 do
  begin
    S7SetReal(B, Ofs + I * 4, C.Eng[I]);
    S7SetReal(B, Ofs + NL_POINTS * 4 + I * 4, C.Volt[I]);
  end;
end;

procedure BytesToCurve(const B: TBytes; Ofs: Integer; out C: TNLCurve);
var
  I: Integer;
begin
  for I := 0 to NL_POINTS - 1 do
  begin
    C.Eng[I] := RoundTo(S7GetReal(B, Ofs + I * 4), -4);
    C.Volt[I] := RoundTo(S7GetReal(B, Ofs + NL_POINTS * 4 + I * 4), -4);
  end;
end;

function DefaultTags: TTagTable;
const
  Ofs: array[TTagId] of Integer = (
    0, 4, 8, 12, 16, 20, 24, 28, 32, 34, 36, 38,
    40, 40, 40, 40, 40, 40, 40, 42, 44, 124, 204, 284
    {$IFDEF LINEAR2}, 108, 110, 112, 114, 116, 116{$ENDIF});
  Bits: array[TTagId] of Integer = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 0
    {$IFDEF LINEAR2}, 0, 0, 0, 0, 0, 1{$ENDIF});
var
  T: TTagId;
begin
  for T := Low(TTagId) to High(TTagId) do
  begin
    Result[T].DB := 10;
    if TagType[T] = ttCurve then    // curves follow each other from byte 44
      Result[T].Offset := 44 + (Ord(T) - Ord(tgCurveVSP)) * CURVE_BYTES
    else
      Result[T].Offset := Ofs[T];
    Result[T].Bit := Bits[T];
  end;
end;

function DefaultNet: TNetConfig;
begin
  Result.Host := '192.168.0.1';
  Result.Rack := 0;
  Result.Slot := 1;
  Result.PollMs := 200;
  Result.TimeoutMs := 2000;
  Result.AutoConnect := False;
end;

function TagAddress(Id: TTagId; const T: TTagTable): string;
begin
  case TagType[Id] of
    ttReal: Result := Format('DB%d.DBD%d', [T[Id].DB, T[Id].Offset]);
    ttInt: Result := Format('DB%d.DBW%d', [T[Id].DB, T[Id].Offset]);
    ttBool: Result := Format('DB%d.DBX%d.%d', [T[Id].DB, T[Id].Offset, T[Id].Bit]);
  else
    Result := Format('DB%d.DBB%d..%d', [T[Id].DB, T[Id].Offset, T[Id].Offset + CURVE_BYTES - 1]);
  end;
end;

{ TNLProject }

constructor TNLProject.Create;
begin
  Reset;
end;

procedure TNLProject.Reset;
var
  K: TCurveKind;
begin
  for K := Low(TCurveKind) to High(TCurveKind) do
    Curves[K] := LinearCurve(K);
  Net := DefaultNet;
  Tags := DefaultTags;
  VoltSP := 0;
  CurSP := 0;
  VoltStep := 0.1;
  CurStep := 0.1;
  FileName := '';
  Modified := False;
end;

procedure TNLProject.LoadFromFile(const AFile: string);
var
  Ini: TMemIniFile;
  K: TCurveKind;
  T: TTagId;
  I: Integer;
  S: string;
  P: TStringArray;

  function RdF(const Sec, Key: string; Def: Double): Double;
  begin
    if not StrFloat(Ini.ReadString(Sec, Key, ''), Result) then Result := Def;
  end;

begin
  Reset;
  Ini := TMemIniFile.Create(AFile);
  try
    { a Set 1 project (10 points) does not fit a Set 2 HMI (2 points) and vice versa }
    if Ini.ReadInteger('Info', 'Points', NL_POINTS) <> NL_POINTS then
      raise Exception.CreateFmt('This project has %d points per curve, this HMI uses %d (%s).',
        [Ini.ReadInteger('Info', 'Points', 0), NL_POINTS, APP_KIND_LONG]);
    Net.Host := Ini.ReadString('Network', 'Host', Net.Host);
    Net.Rack := Ini.ReadInteger('Network', 'Rack', Net.Rack);
    Net.Slot := Ini.ReadInteger('Network', 'Slot', Net.Slot);
    Net.PollMs := Ini.ReadInteger('Network', 'PollMs', Net.PollMs);
    Net.TimeoutMs := Ini.ReadInteger('Network', 'TimeoutMs', Net.TimeoutMs);
    Net.AutoConnect := Ini.ReadBool('Network', 'AutoConnect', Net.AutoConnect);
    for T := Low(TTagId) to High(TTagId) do
    begin
      S := Ini.ReadString('Tags', TagName[T], '');
      P := S.Split([',']);
      if Length(P) >= 2 then
      begin
        Tags[T].DB := StrToIntDef(Trim(P[0]), Tags[T].DB);
        Tags[T].Offset := StrToIntDef(Trim(P[1]), Tags[T].Offset);
        if Length(P) >= 3 then Tags[T].Bit := StrToIntDef(Trim(P[2]), Tags[T].Bit);
      end;
    end;
    for K := Low(TCurveKind) to High(TCurveKind) do
      for I := 0 to NL_POINTS - 1 do
      begin
        Curves[K].Eng[I] := RdF(CurveName[K], 'Eng' + IntToStr(I), Curves[K].Eng[I]);
        Curves[K].Volt[I] := RdF(CurveName[K], 'Volt' + IntToStr(I), Curves[K].Volt[I]);
      end;
    VoltSP := RdF('Setpoint', 'VoltSP_kV', 0);
    CurSP := RdF('Setpoint', 'CurSP_mA', 0);
    VoltStep := RdF('Setpoint', 'VoltStep_kV', 0.1);
    CurStep := RdF('Setpoint', 'CurStep_mA', 0.1);
  finally
    Ini.Free;
  end;
  FileName := AFile;
  Modified := False;
end;

procedure TNLProject.SaveToFile(const AFile: string);
var
  Ini: TMemIniFile;
  K: TCurveKind;
  T: TTagId;
  I: Integer;
begin
  if FileExists(AFile) then DeleteFile(AFile);
  Ini := TMemIniFile.Create(AFile);
  try
    Ini.WriteString('Info', 'Format', APP_KIND + ' HV curve project 1.0');
    Ini.WriteInteger('Info', 'Points', NL_POINTS);
    Ini.WriteString('Info', 'Saved', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    Ini.WriteString('Network', 'Host', Net.Host);
    Ini.WriteInteger('Network', 'Rack', Net.Rack);
    Ini.WriteInteger('Network', 'Slot', Net.Slot);
    Ini.WriteInteger('Network', 'PollMs', Net.PollMs);
    Ini.WriteInteger('Network', 'TimeoutMs', Net.TimeoutMs);
    Ini.WriteBool('Network', 'AutoConnect', Net.AutoConnect);
    for T := Low(TTagId) to High(TTagId) do
      Ini.WriteString('Tags', TagName[T],
        Format('%d,%d,%d', [Tags[T].DB, Tags[T].Offset, Tags[T].Bit]));
    for K := Low(TCurveKind) to High(TCurveKind) do
      for I := 0 to NL_POINTS - 1 do
      begin
        Ini.WriteString(CurveName[K], 'Eng' + IntToStr(I), FloatStr(Curves[K].Eng[I], 4));
        Ini.WriteString(CurveName[K], 'Volt' + IntToStr(I), FloatStr(Curves[K].Volt[I], 4));
      end;
    Ini.WriteString('Setpoint', 'VoltSP_kV', FloatStr(VoltSP, 3));
    Ini.WriteString('Setpoint', 'CurSP_mA', FloatStr(CurSP, 3));
    Ini.WriteString('Setpoint', 'VoltStep_kV', FloatStr(VoltStep, 3));
    Ini.WriteString('Setpoint', 'CurStep_mA', FloatStr(CurStep, 3));
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
  FileName := AFile;
  Modified := False;
end;

initialization
  NLFmt := DefaultFormatSettings;
  NLFmt.DecimalSeparator := '.';
  NLFmt.ThousandSeparator := ',';

end.
