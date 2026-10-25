{ ============================================================================
  nltable - 10-point table editor (TStringGrid based), shared by both HMIs
  Columns are ordered input -> output:
    setpoint curve : SP (kV|mA)  -> AO (V)
    actual curve   : AI (V)      -> Actual (kV|mA)
  ============================================================================ }
unit nltable;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, StdCtrls, Grids, Graphics, nlcore;

type

  { TNLTableEditor }

  TNLTableEditor = class(TPanel)
  private
    FTitle: TLabel;
    FGrid: TStringGrid;
    FInfo: TLabel;
    FKind: TCurveKind;
    FCurve: TNLCurve;
    FOnChange: TNotifyEvent;
    FUpdating: Boolean;
    FOkColor, FBadColor, FEditColor, FTextColor: TColor;
    procedure SetKind(AValue: TCurveKind);
    procedure GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer; AState: TGridDrawState);
    procedure GridEditingDone(Sender: TObject);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    function EngCol: Integer;
    function VoltCol: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetCurve(const C: TNLCurve);
    procedure Refresh;
    procedure SetColors(ABack, AText, AFixed, AOk, ABad, AEdit: TColor);
    property Curve: TNLCurve read FCurve;
    property Kind: TCurveKind read FKind write SetKind;
    property Grid: TStringGrid read FGrid;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  Math;

{ TNLTableEditor }

constructor TNLTableEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';
  FOkColor := $00F0FFF0;
  FBadColor := $00C0C0FF;
  FEditColor := clWindow;
  FTextColor := clWindowText;

  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Align := alTop;
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Height := -16;
  FTitle.BorderSpacing.Around := 4;

  FInfo := TLabel.Create(Self);
  FInfo.Parent := Self;
  FInfo.Align := alBottom;
  FInfo.BorderSpacing.Around := 4;
  FInfo.WordWrap := True;

  FGrid := TStringGrid.Create(Self);
  with FGrid do
  begin
    Parent := Self;
    Align := alClient;
    ColCount := 4;
    RowCount := NL_POINTS + 1;
    FixedCols := 1;
    DefaultRowHeight := 30;
    Font.Height := -15;
    Options := Options + [goEditing, goAlwaysShowEditor, goTabs] - [goRangeSelect];
    ColWidths[0] := 60;
    ColWidths[1] := 120;
    ColWidths[2] := 120;
    ColWidths[3] := 120;
    AutoFillColumns := True;
    OnPrepareCanvas := @GridPrepareCanvas;
    OnEditingDone := @GridEditingDone;
    OnSelectCell := @GridSelectCell;
  end;
  FKind := ckVoltSP;
  FCurve := LinearCurve(FKind);
  SetKind(ckVoltSP);
end;

function TNLTableEditor.EngCol: Integer;
begin
  if CurveIsActual[FKind] then Result := 2 else Result := 1;
end;

function TNLTableEditor.VoltCol: Integer;
begin
  if CurveIsActual[FKind] then Result := 1 else Result := 2;
end;

procedure TNLTableEditor.SetKind(AValue: TCurveKind);
var
  U: string;
begin
  FKind := AValue;
  U := CurveUnit[FKind];
  FTitle.Caption := CurveTitle[FKind];
  FGrid.Cells[0, 0] := 'Point';
  if CurveIsActual[FKind] then
  begin
    FGrid.Cells[1, 0] := 'AI input (V)';
    FGrid.Cells[2, 0] := 'Actual (' + U + ')';
    FGrid.Cells[3, 0] := 'vs linear (' + U + ')';
  end
  else
  begin
    FGrid.Cells[1, 0] := 'Setpoint (' + U + ')';
    FGrid.Cells[2, 0] := 'AO output (V)';
    FGrid.Cells[3, 0] := 'vs linear (V)';
  end;
  FInfo.Caption := Format('Range: %s 0..%s, voltage 0..10 V. Both columns must be strictly increasing. ' +
    'Red row = invalid point (PLC falls back to linear).', [U, FloatStr(CurveEngFull[FKind], 0)]);
  Refresh;
end;

procedure TNLTableEditor.SetCurve(const C: TNLCurve);
begin
  FCurve := C;
  Refresh;
end;

procedure TNLTableEditor.Refresh;
var
  I: Integer;
  Dev: Double;
begin
  FUpdating := True;
  try
    for I := 0 to NL_POINTS - 1 do
    begin
      FGrid.Cells[0, I + 1] := IntToStr(I + 1);
      FGrid.Cells[EngCol, I + 1] := FloatStr(FCurve.Eng[I], 3);
      FGrid.Cells[VoltCol, I + 1] := FloatStr(FCurve.Volt[I], 3);
      if CurveIsActual[FKind] then
        Dev := FCurve.Eng[I] - FCurve.Volt[I] * CurveEngFull[FKind] / V_FULL
      else
        Dev := FCurve.Volt[I] - FCurve.Eng[I] * V_FULL / CurveEngFull[FKind];
      if Abs(Dev) < 0.0005 then
        FGrid.Cells[3, I + 1] := '0.000'
      else if Dev > 0 then
        FGrid.Cells[3, I + 1] := '+' + FloatStr(Dev, 3)
      else
        FGrid.Cells[3, I + 1] := FloatStr(Dev, 3);
    end;
  finally
    FUpdating := False;
  end;
  FGrid.Invalidate;
end;

procedure TNLTableEditor.SetColors(ABack, AText, AFixed, AOk, ABad, AEdit: TColor);
begin
  Color := ABack;
  FTitle.Font.Color := AText;
  FInfo.Font.Color := AText;
  FGrid.Color := AEdit;
  FGrid.FixedColor := AFixed;
  FGrid.Font.Color := AText;
  FGrid.AlternateColor := AEdit;
  FOkColor := AOk;
  FBadColor := ABad;
  FEditColor := AEdit;
  FTextColor := AText;
  FGrid.Invalidate;
end;

procedure TNLTableEditor.GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
  AState: TGridDrawState);
begin
  if (ARow = 0) or (ACol = 0) then Exit;
  FGrid.Canvas.Font.Color := FTextColor;
  if not PointOk(FCurve, FKind, ARow - 1) then
    FGrid.Canvas.Brush.Color := FBadColor
  else if ACol = 3 then
    FGrid.Canvas.Brush.Color := FEditColor
  else
    FGrid.Canvas.Brush.Color := FOkColor;
  if gdSelected in AState then
    FGrid.Canvas.Font.Style := [fsBold];
end;

procedure TNLTableEditor.GridSelectCell(Sender: TObject; ACol, ARow: Integer;
  var CanSelect: Boolean);
begin
  { column 3 is computed - not editable }
  if ACol = 3 then
    FGrid.Options := FGrid.Options - [goEditing]
  else
    FGrid.Options := FGrid.Options + [goEditing];
end;

procedure TNLTableEditor.GridEditingDone(Sender: TObject);
var
  R, C: Integer;
  V: Double;
  IsChanged: Boolean;
begin
  if FUpdating then Exit;
  IsChanged := False;
  for R := 1 to NL_POINTS do
    for C := 1 to 2 do
      if StrFloat(FGrid.Cells[C, R], V) then
      begin
        if C = EngCol then
        begin
          V := EnsureRange(V, 0, CurveEngFull[FKind]);
          if not SameValue(V, FCurve.Eng[R - 1], 1E-6) then
          begin
            FCurve.Eng[R - 1] := V;
            IsChanged := True;
          end;
        end
        else
        begin
          V := EnsureRange(V, 0, V_FULL);
          if not SameValue(V, FCurve.Volt[R - 1], 1E-6) then
          begin
            FCurve.Volt[R - 1] := V;
            IsChanged := True;
          end;
        end;
      end;
  Refresh;
  if IsChanged and Assigned(FOnChange) then FOnChange(Self);
end;

end.
