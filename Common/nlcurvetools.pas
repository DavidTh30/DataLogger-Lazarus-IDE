{ ============================================================================
  nlcurvetools - tools for the curve pages (shared by both HMIs)
    - pattern curves (18 shapes, parameter, inverse)
    - curve files *.nlc (setpoint + actual curve of one group)
    - undo / redo history
    - curve comparison
  ============================================================================ }
unit nlcurvetools;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Math, nlcore;

type
  { the two curves of one page: [0] = setpoint, [1] = actual }
  TCurvePair = array[0..1] of TNLCurve;

  TCurvePattern = (
    cpLinear, cpPower, cpRoot, cpExponential, cpLogarithmic, cpSaturation,
    cpSCurve, cpInverseS, cpSmoothstep, cpSmootherstep, cpSineIn, cpSineOut,
    cpCircIn, cpCircOut, cpTanh, cpKnee, cpOffset, cpQuadBlend);

  TPatternInfo = record
    Name: string;
    HasParam: Boolean;
    Def, Min, Max: Double;
    Hint: string;
  end;

const
  PatternInfo: array[TCurvePattern] of TPatternInfo = (
    (Name: 'Linear';                 HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = x'),
    (Name: 'Power (convex)';         HasParam: True;  Def: 1.5; Min: 1.05; Max: 5;   Hint: 'y = x^k'),
    (Name: 'Root (concave)';         HasParam: True;  Def: 1.5; Min: 1.05; Max: 5;   Hint: 'y = x^(1/k)'),
    (Name: 'Exponential';            HasParam: True;  Def: 2;   Min: 0.1;  Max: 8;   Hint: 'y = (e^(kx)-1)/(e^k-1)'),
    (Name: 'Logarithmic';            HasParam: True;  Def: 5;   Min: 0.2;  Max: 50;  Hint: 'y = ln(1+kx)/ln(1+k)'),
    (Name: 'Saturation';             HasParam: True;  Def: 3;   Min: 0.1;  Max: 8;   Hint: 'y = (1-e^(-kx))/(1-e^(-k))'),
    (Name: 'S-curve (logistic)';     HasParam: True;  Def: 8;   Min: 1;    Max: 20;  Hint: 'normalized logistic, k = steepness'),
    (Name: 'Inverse S';              HasParam: True;  Def: 8;   Min: 1;    Max: 20;  Hint: 'inverse logistic, k = steepness'),
    (Name: 'Smoothstep';             HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = 3x^2 - 2x^3'),
    (Name: 'Smootherstep';           HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = 6x^5 - 15x^4 + 10x^3'),
    (Name: 'Sine ease-in';           HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = 1 - cos(pi x / 2)'),
    (Name: 'Sine ease-out';          HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = sin(pi x / 2)'),
    (Name: 'Circular ease-in';       HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = 1 - sqrt(1 - x^2)'),
    (Name: 'Circular ease-out';      HasParam: False; Def: 0;   Min: 0;    Max: 0;   Hint: 'y = sqrt(1 - (1-x)^2)'),
    (Name: 'Tanh';                   HasParam: True;  Def: 2;   Min: 0.1;  Max: 6;   Hint: 'y = tanh(kx)/tanh(k)'),
    (Name: 'Knee (2 slopes)';        HasParam: True;  Def: 2;   Min: 0.2;  Max: 5;   Hint: 'knee at 50 %, k = upper slope / lower slope'),
    (Name: 'Offset start';           HasParam: True;  Def: 5;   Min: 0.5;  Max: 40;  Hint: 'y = d + (1-d)x for x > 0, k = offset d in %'),
    (Name: 'Quadratic blend';        HasParam: True;  Def: 0.5; Min: 0.05; Max: 1.95; Hint: 'y = kx + (1-k)x^2'));

  PAIR_SP = 0;
  PAIR_ACT = 1;

function PatternValue(P: TCurvePattern; K, X: Double): Double;
{ Volt = 10*f(i/9) at Eng = Full*i/9; Inverse swaps the axes (Eng = Full*f(i/9) at Volt = 10*i/9) }
function MakePatternCurve(P: TCurvePattern; K: Double; Inverse: Boolean; Kind: TCurveKind): TNLCurve;

{ curve files *.nlc }
procedure SaveCurveFile(const AFile: string; const C: TCurvePair; SPKind: TCurveKind);
function LoadCurveFile(const AFile: string; out C: TCurvePair; out FileGroup: string): Boolean;
function GroupNameOf(SPKind: TCurveKind): string;

{ comparison }
function MaxDiff(const A, B: TNLCurve; out MaxEng, MaxVolt: Double): Integer;  // returns differing point count

type

  { TCurveHistory - undo / redo of one curve page }

  TCurveHistory = class
  private
    FUndo, FRedo: array of TCurvePair;
  public
    procedure Push(const Current: TCurvePair);
    function Undo(const Current: TCurvePair; out Prev: TCurvePair): Boolean;
    function Redo(const Current: TCurvePair; out Next: TCurvePair): Boolean;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    procedure Clear;
  end;

const
  DIFF_TOL = 0.0005;
  HISTORY_MAX = 100;

implementation

function Logistic(Z: Double): Double;
begin
  Result := 1 / (1 + Exp(-Z));
end;

function PatternValue(P: TCurvePattern; K, X: Double): Double;
var
  A, B, U: Double;
begin
  X := EnsureRange(X, 0, 1);
  case P of
    cpLinear: Result := X;
    cpPower: Result := Power(X, K);
    cpRoot: Result := Power(X, 1 / K);
    cpExponential: Result := (Exp(K * X) - 1) / (Exp(K) - 1);
    cpLogarithmic: Result := Ln(1 + K * X) / Ln(1 + K);
    cpSaturation: Result := (1 - Exp(-K * X)) / (1 - Exp(-K));
    cpSCurve:
      begin
        A := Logistic(-K / 2);
        B := Logistic(K / 2);
        Result := (Logistic(K * (X - 0.5)) - A) / (B - A);
      end;
    cpInverseS:
      begin
        A := Logistic(-K / 2);
        B := Logistic(K / 2);
        U := A + X * (B - A);
        Result := 0.5 + Ln(U / (1 - U)) / K;
      end;
    cpSmoothstep: Result := X * X * (3 - 2 * X);
    cpSmootherstep: Result := X * X * X * (X * (6 * X - 15) + 10);
    cpSineIn: Result := 1 - Cos(Pi * X / 2);
    cpSineOut: Result := Sin(Pi * X / 2);
    cpCircIn: Result := 1 - Sqrt(Max(0, 1 - X * X));
    cpCircOut: Result := Sqrt(Max(0, 1 - Sqr(1 - X)));
    cpTanh: Result := Tanh(K * X) / Tanh(K);
    cpKnee:
      begin
        A := 2 / (1 + K);              // lower slope, upper = K * A
        if X <= 0.5 then Result := A * X
        else Result := 0.5 * A + K * A * (X - 0.5);
      end;
    cpOffset:
      if X <= 0 then Result := 0
      else Result := K / 100 + (1 - K / 100) * X;
    cpQuadBlend: Result := K * X + (1 - K) * X * X;
  else
    Result := X;
  end;
  Result := EnsureRange(Result, 0, 1);
end;

function MakePatternCurve(P: TCurvePattern; K: Double; Inverse: Boolean; Kind: TCurveKind): TNLCurve;
var
  I: Integer;
  T, F, Full: Double;
begin
  Full := CurveEngFull[Kind];
  for I := 0 to NL_POINTS - 1 do
  begin
    T := I / (NL_POINTS - 1);
    F := PatternValue(P, K, T);
    if Inverse then
    begin
      Result.Eng[I] := RoundTo(Full * F, -4);
      Result.Volt[I] := RoundTo(V_FULL * T, -4);
    end
    else
    begin
      Result.Eng[I] := RoundTo(Full * T, -4);
      Result.Volt[I] := RoundTo(V_FULL * F, -4);
    end;
  end;
  { force a strictly increasing table (very flat shapes can round to equal values) }
  for I := 1 to NL_POINTS - 1 do
  begin
    if Result.Eng[I] <= Result.Eng[I - 1] then Result.Eng[I] := Result.Eng[I - 1] + 0.001;
    if Result.Volt[I] <= Result.Volt[I - 1] then Result.Volt[I] := Result.Volt[I - 1] + 0.001;
  end;
  { end points exactly on the range (RoundTo can leave 15.000000000000002) }
  Result.Eng[0] := 0;
  Result.Volt[0] := 0;
  Result.Eng[NL_POINTS - 1] := Full;
  Result.Volt[NL_POINTS - 1] := V_FULL;
end;

function GroupNameOf(SPKind: TCurveKind): string;
begin
  if SPKind in [ckVoltSP, ckVoltAct] then Result := 'Voltage' else Result := 'Current';
end;

procedure SaveCurveFile(const AFile: string; const C: TCurvePair; SPKind: TCurveKind);
const
  Sec: array[0..1] of string = ('Setpoint', 'Actual');
var
  Ini: TMemIniFile;
  J, I: Integer;
begin
  if FileExists(AFile) then DeleteFile(AFile);
  Ini := TMemIniFile.Create(AFile);
  try
    Ini.WriteString('Info', 'Format', APP_KIND + ' curve file 1.0');
    Ini.WriteInteger('Info', 'Points', NL_POINTS);
    Ini.WriteString('Info', 'Group', GroupNameOf(SPKind));
    Ini.WriteString('Info', 'Unit', CurveUnit[SPKind]);
    Ini.WriteString('Info', 'Saved', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    for J := 0 to 1 do
      for I := 0 to NL_POINTS - 1 do
      begin
        Ini.WriteString(Sec[J], 'Eng' + IntToStr(I), FloatStr(C[J].Eng[I], 4));
        Ini.WriteString(Sec[J], 'Volt' + IntToStr(I), FloatStr(C[J].Volt[I], 4));
      end;
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function LoadCurveFile(const AFile: string; out C: TCurvePair; out FileGroup: string): Boolean;
const
  Sec: array[0..1] of string = ('Setpoint', 'Actual');
var
  Ini: TMemIniFile;
  J, I: Integer;
  V: Double;
begin
  Result := False;
  C[0] := LinearCurve(ckVoltSP);
  C[1] := LinearCurve(ckVoltAct);
  Ini := TMemIniFile.Create(AFile);
  try
    FileGroup := Ini.ReadString('Info', 'Group', '');
    if Ini.ReadInteger('Info', 'Points', NL_POINTS) <> NL_POINTS then
      raise Exception.CreateFmt('This curve file has %d points per curve, this HMI uses %d (%s).',
        [Ini.ReadInteger('Info', 'Points', 0), NL_POINTS, APP_KIND_LONG]);
    if not Ini.SectionExists('Setpoint') then Exit;
    for J := 0 to 1 do
      for I := 0 to NL_POINTS - 1 do
      begin
        if StrFloat(Ini.ReadString(Sec[J], 'Eng' + IntToStr(I), ''), V) then C[J].Eng[I] := V else Exit;
        if StrFloat(Ini.ReadString(Sec[J], 'Volt' + IntToStr(I), ''), V) then C[J].Volt[I] := V else Exit;
      end;
    Result := True;
  finally
    Ini.Free;
  end;
end;

function MaxDiff(const A, B: TNLCurve; out MaxEng, MaxVolt: Double): Integer;
var
  I: Integer;
  DE, DV: Double;
begin
  Result := 0;
  MaxEng := 0;
  MaxVolt := 0;
  for I := 0 to NL_POINTS - 1 do
  begin
    DE := Abs(A.Eng[I] - B.Eng[I]);
    DV := Abs(A.Volt[I] - B.Volt[I]);
    MaxEng := Max(MaxEng, DE);
    MaxVolt := Max(MaxVolt, DV);
    if (DE > DIFF_TOL) or (DV > DIFF_TOL) then Inc(Result);
  end;
end;

{ TCurveHistory }

procedure TCurveHistory.Push(const Current: TCurvePair);
begin
  if Length(FUndo) >= HISTORY_MAX then Delete(FUndo, 0, 1);
  SetLength(FUndo, Length(FUndo) + 1);
  FUndo[High(FUndo)] := Current;
  FRedo := nil;
end;

function TCurveHistory.Undo(const Current: TCurvePair; out Prev: TCurvePair): Boolean;
begin
  Result := Length(FUndo) > 0;
  if not Result then Exit;
  Prev := FUndo[High(FUndo)];
  SetLength(FUndo, Length(FUndo) - 1);
  SetLength(FRedo, Length(FRedo) + 1);
  FRedo[High(FRedo)] := Current;
end;

function TCurveHistory.Redo(const Current: TCurvePair; out Next: TCurvePair): Boolean;
begin
  Result := Length(FRedo) > 0;
  if not Result then Exit;
  Next := FRedo[High(FRedo)];
  SetLength(FRedo, Length(FRedo) - 1);
  SetLength(FUndo, Length(FUndo) + 1);
  FUndo[High(FUndo)] := Current;
end;

function TCurveHistory.CanUndo: Boolean;
begin
  Result := Length(FUndo) > 0;
end;

function TCurveHistory.CanRedo: Boolean;
begin
  Result := Length(FRedo) > 0;
end;

procedure TCurveHistory.Clear;
begin
  FUndo := nil;
  FRedo := nil;
end;

end.
