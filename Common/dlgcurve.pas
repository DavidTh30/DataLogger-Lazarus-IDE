{ ============================================================================
  dlgcurve - curve page dialogs (built in code, shared by both HMIs)
    ChoosePattern : pick one of the pattern curves with a live preview
    ShowCompare   : point-by-point comparison of two curve pairs
  ============================================================================ }
unit dlgcurve;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, Spin, Grids,
  ButtonPanel, Math, nlcore, nlcurvetools;

{ returns True and the new pair when the user presses OK }
function ChoosePattern(SPKind, ActKind: TCurveKind; const Cur: TCurvePair;
  out NewPair: TCurvePair): Boolean;

procedure ShowCompare(const ATitle, NameA, NameB: string; const A, B: TCurvePair;
  SPKind, ActKind: TCurveKind);

implementation

const
  CL_SP = clBlue;
  CL_ACT = $00008CFF;

{ draw curves into a rectangle: axes 0..Full / 0..10 V }
procedure DrawPlot(C: TCanvas; R: TRect; Full: Double; const AUnit: string);
var
  I, X, Y: Integer;
begin
  C.Brush.Color := clWhite;
  C.FillRect(R);
  C.Pen.Color := $00E0E0E0;
  C.Pen.Style := psSolid;
  C.Pen.Width := 1;
  for I := 0 to 10 do
  begin
    X := R.Left + Round(I / 10 * (R.Right - R.Left));
    Y := R.Bottom - Round(I / 10 * (R.Bottom - R.Top));
    C.Line(X, R.Top, X, R.Bottom);
    C.Line(R.Left, Y, R.Right, Y);
  end;
  C.Pen.Color := clSilver;
  C.Pen.Style := psDot;
  C.Line(R.Left, R.Bottom, R.Right, R.Top);
  C.Pen.Style := psSolid;
  C.Pen.Color := clGray;
  C.Frame(R);
  C.Font.Color := clGray;
  C.Font.Height := -11;
  C.TextOut(R.Left + 4, R.Top + 2, '10 V');
  C.TextOut(R.Right - C.TextWidth(FloatStr(Full, 0) + ' ' + AUnit) - 4, R.Bottom - 16,
    FloatStr(Full, 0) + ' ' + AUnit);
end;

procedure DrawCurve(C: TCanvas; R: TRect; Full: Double; const K: TNLCurve; AColor: TColor;
  AWidth: Integer; AStyle: TPenStyle; ADots: Boolean);
var
  I, X, Y: Integer;
  P: array[0..NL_POINTS - 1] of TPoint;
begin
  for I := 0 to NL_POINTS - 1 do
  begin
    X := R.Left + Round(EnsureRange(K.Eng[I] / Full, 0, 1) * (R.Right - R.Left));
    Y := R.Bottom - Round(EnsureRange(K.Volt[I] / V_FULL, 0, 1) * (R.Bottom - R.Top));
    P[I] := Point(X, Y);
  end;
  C.Pen.Color := AColor;
  C.Pen.Width := AWidth;
  C.Pen.Style := AStyle;
  C.Polyline(P);
  C.Pen.Style := psSolid;
  C.Pen.Width := 1;
  if ADots then
  begin
    C.Brush.Color := AColor;
    for I := 0 to NL_POINTS - 1 do
      C.Ellipse(P[I].X - 3, P[I].Y - 3, P[I].X + 4, P[I].Y + 4);
  end;
end;

{ ============================== pattern dialog ============================= }

type

  { TPatternDlg }

  TPatternDlg = class(TForm)
  public
    SPKind, ActKind: TCurveKind;
    Cur, Res: TCurvePair;
    List: TListBox;
    Param: TFloatSpinEdit;
    LblHint: TLabel;
    Target: TRadioGroup;
    Inverse: TCheckBox;
    Preview: TPaintBox;
    FBusy: Boolean;
    procedure Build;
    procedure Recalc(Sender: TObject);
    procedure ListClick(Sender: TObject);
    procedure PreviewPaint(Sender: TObject);
  end;

procedure TPatternDlg.Build;
var
  P: TCurvePattern;
  LeftP: TPanel;
  BP: TButtonPanel;
begin
  Caption := 'Pattern curve - ' + GroupNameOf(SPKind);
  Position := poMainFormCenter;
  Width := 820;
  Height := 560;
  BorderStyle := bsDialog;

  BP := TButtonPanel.Create(Self);
  BP.Parent := Self;
  BP.ShowButtons := [pbOK, pbCancel];
  BP.OKButton.Caption := 'Apply';

  LeftP := TPanel.Create(Self);
  LeftP.Parent := Self;
  LeftP.Align := alLeft;
  LeftP.Width := 300;
  LeftP.BevelOuter := bvNone;
  LeftP.Caption := '';

  with TLabel.Create(Self) do
  begin
    Parent := LeftP;
    SetBounds(10, 8, 280, 18);
    Caption := 'Pattern (' + IntToStr(Ord(High(TCurvePattern)) + 1) + ' shapes)';
    Font.Style := [fsBold];
  end;
  List := TListBox.Create(Self);
  List.Parent := LeftP;
  List.SetBounds(10, 28, 280, 250);
  for P := Low(TCurvePattern) to High(TCurvePattern) do
    List.Items.Add(PatternInfo[P].Name);
  List.ItemIndex := Ord(cpPower);
  List.OnClick := @ListClick;

  with TLabel.Create(Self) do
  begin
    Parent := LeftP;
    SetBounds(10, 292, 80, 18);
    Caption := 'Parameter k';
  end;
  Param := TFloatSpinEdit.Create(Self);
  Param.Parent := LeftP;
  Param.SetBounds(100, 288, 110, 26);
  Param.DecimalPlaces := 2;
  Param.Increment := 0.1;
  Param.OnChange := @Recalc;
  LblHint := TLabel.Create(Self);
  LblHint.Parent := LeftP;
  LblHint.SetBounds(10, 320, 280, 36);
  LblHint.AutoSize := False;
  LblHint.WordWrap := True;
  LblHint.Font.Color := clGrayText;

  Target := TRadioGroup.Create(Self);
  Target.Parent := LeftP;
  Target.SetBounds(10, 360, 280, 90);
  Target.Caption := ' Apply to ';
  Target.Items.Add('Setpoint curve');
  Target.Items.Add('Actual curve');
  Target.Items.Add('Both curves');
  Target.ItemIndex := 0;
  Target.OnClick := @Recalc;

  Inverse := TCheckBox.Create(Self);
  Inverse.Parent := LeftP;
  Inverse.SetBounds(14, 458, 270, 22);
  Inverse.Caption := 'Inverse (mirror around linear)';
  Inverse.OnChange := @Recalc;

  Preview := TPaintBox.Create(Self);
  Preview.Parent := Self;
  Preview.Align := alClient;
  Preview.BorderSpacing.Around := 10;
  Preview.OnPaint := @PreviewPaint;

  ListClick(nil);
end;

procedure TPatternDlg.ListClick(Sender: TObject);
var
  P: TCurvePattern;
begin
  P := TCurvePattern(Max(0, List.ItemIndex));
  FBusy := True;
  try
    Param.Enabled := PatternInfo[P].HasParam;
    Param.MinValue := PatternInfo[P].Min;
    Param.MaxValue := PatternInfo[P].Max;
    Param.Value := PatternInfo[P].Def;
    LblHint.Caption := PatternInfo[P].Hint;
  finally
    FBusy := False;
  end;
  Recalc(nil);
end;

procedure TPatternDlg.Recalc(Sender: TObject);
var
  P: TCurvePattern;
begin
  if FBusy or (List = nil) then Exit;
  P := TCurvePattern(Max(0, List.ItemIndex));
  Res := Cur;
  if Target.ItemIndex in [0, 2] then
    Res[PAIR_SP] := MakePatternCurve(P, Param.Value, Inverse.Checked, SPKind);
  if Target.ItemIndex in [1, 2] then
    Res[PAIR_ACT] := MakePatternCurve(P, Param.Value, Inverse.Checked, ActKind);
  Preview.Invalidate;
end;

procedure TPatternDlg.PreviewPaint(Sender: TObject);
var
  R: TRect;
  Full: Double;
  C: TCanvas;
begin
  C := Preview.Canvas;
  R := Rect(30, 30, Preview.Width - 10, Preview.Height - 30);
  Full := CurveEngFull[SPKind];
  DrawPlot(C, R, Full, CurveUnit[SPKind]);
  { current = thin dashed, new = thick }
  DrawCurve(C, R, Full, Cur[PAIR_SP], $00F0C0A0, 1, psDash, False);
  DrawCurve(C, R, Full, Cur[PAIR_ACT], $00A0D0FF, 1, psDash, False);
  DrawCurve(C, R, Full, Res[PAIR_SP], CL_SP, 2, psSolid, True);
  DrawCurve(C, R, Full, Res[PAIR_ACT], CL_ACT, 2, psSolid, True);
  C.Brush.Style := bsClear;
  C.Font.Height := -13;
  C.Font.Color := CL_SP;
  C.TextOut(30, 6, 'Setpoint');
  C.Font.Color := CL_ACT;
  C.TextOut(110, 6, 'Actual');
  C.Font.Color := clGray;
  C.TextOut(180, 6, 'dashed = current, solid = new');
  C.Brush.Style := bsSolid;
end;

function ChoosePattern(SPKind, ActKind: TCurveKind; const Cur: TCurvePair;
  out NewPair: TCurvePair): Boolean;
var
  D: TPatternDlg;
begin
  D := TPatternDlg.CreateNew(nil);
  try
    D.SPKind := SPKind;
    D.ActKind := ActKind;
    D.Cur := Cur;
    D.Res := Cur;
    D.Build;
    Result := D.ShowModal = mrOK;
    NewPair := D.Res;
  finally
    D.Free;
  end;
end;

{ ============================== compare dialog ============================= }

type

  { TCompareDlg }

  TCompareDlg = class(TForm)
  public
    A, B: TCurvePair;
    SPKind: TCurveKind;
    NameA, NameB: string;
    Grid: TStringGrid;
    Plot: TPaintBox;
    procedure Build(const ATitle: string; ActKind: TCurveKind);
    procedure GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer; AState: TGridDrawState);
    procedure PlotPaint(Sender: TObject);
    function RowDiffers(ARow: Integer): Boolean;
  end;

function TCompareDlg.RowDiffers(ARow: Integer): Boolean;
var
  J, I: Integer;
begin
  J := (ARow - 1) div NL_POINTS;
  I := (ARow - 1) mod NL_POINTS;
  Result := (Abs(A[J].Eng[I] - B[J].Eng[I]) > DIFF_TOL) or
            (Abs(A[J].Volt[I] - B[J].Volt[I]) > DIFF_TOL);
end;

procedure TCompareDlg.Build(const ATitle: string; ActKind: TCurveKind);
const
  CurveTitles: array[0..1] of string = ('Setpoint', 'Actual');
var
  PTop: TPanel;
  Sum: TLabel;
  BP: TButtonPanel;
  J, I, R, N, Total: Integer;
  ME, MV: Double;
  U, S: string;
begin
  Caption := ATitle;
  Position := poMainFormCenter;
  Width := 1060;
  Height := 640;
  U := CurveUnit[SPKind];

  PTop := TPanel.Create(Self);
  PTop.Parent := Self;
  PTop.Align := alTop;
  PTop.Height := 70;
  PTop.BevelOuter := bvNone;
  PTop.Caption := '';
  Sum := TLabel.Create(Self);
  Sum.Parent := PTop;
  Sum.SetBounds(10, 6, 1000, 60);
  Sum.AutoSize := False;
  Sum.WordWrap := True;
  Sum.Font.Height := -14;

  Total := 0;
  S := 'A = ' + NameA + LineEnding + 'B = ' + NameB + LineEnding;
  for J := 0 to 1 do
  begin
    N := MaxDiff(A[J], B[J], ME, MV);
    Inc(Total, N);
    if N = 0 then
      S := S + CurveTitles[J] + ': identical     '
    else
      S := S + Format('%s: %d point(s) differ (max %s %s / %s V)     ',
        [CurveTitles[J], N, FloatStr(ME, 3), U, FloatStr(MV, 3)]);
  end;
  Sum.Caption := S;
  if Total = 0 then Sum.Font.Color := clGreen else Sum.Font.Color := clRed;

  BP := TButtonPanel.Create(Self);
  BP.Parent := Self;
  BP.ShowButtons := [pbClose];
  BP.CloseButton.Cancel := True;   // Esc closes

  Plot := TPaintBox.Create(Self);
  Plot.Parent := Self;
  Plot.Align := alRight;
  Plot.Width := 400;
  Plot.OnPaint := @PlotPaint;

  Grid := TStringGrid.Create(Self);
  Grid.Parent := Self;
  Grid.Align := alClient;
  Grid.ColCount := 8;
  Grid.RowCount := 2 * NL_POINTS + 1;
  Grid.FixedCols := 0;
  Grid.DefaultRowHeight := 22;
  Grid.Options := Grid.Options - [goEditing];
  Grid.Cells[0, 0] := 'Curve';
  Grid.Cells[1, 0] := 'Pt';
  Grid.Cells[2, 0] := 'A ' + U;
  Grid.Cells[3, 0] := 'A V';
  Grid.Cells[4, 0] := 'B ' + U;
  Grid.Cells[5, 0] := 'B V';
  Grid.Cells[6, 0] := 'Diff ' + U;
  Grid.Cells[7, 0] := 'Diff V';
  Grid.ColWidths[0] := 80;
  Grid.ColWidths[1] := 36;
  for I := 2 to 7 do Grid.ColWidths[I] := 82;
  for J := 0 to 1 do
    for I := 0 to NL_POINTS - 1 do
    begin
      R := J * NL_POINTS + I + 1;
      Grid.Cells[0, R] := CurveTitles[J];
      Grid.Cells[1, R] := IntToStr(I + 1);
      Grid.Cells[2, R] := FloatStr(A[J].Eng[I], 3);
      Grid.Cells[3, R] := FloatStr(A[J].Volt[I], 3);
      Grid.Cells[4, R] := FloatStr(B[J].Eng[I], 3);
      Grid.Cells[5, R] := FloatStr(B[J].Volt[I], 3);
      Grid.Cells[6, R] := FloatStr(B[J].Eng[I] - A[J].Eng[I], 3);
      Grid.Cells[7, R] := FloatStr(B[J].Volt[I] - A[J].Volt[I], 3);
    end;
  Grid.OnPrepareCanvas := @GridPrepareCanvas;
end;

procedure TCompareDlg.GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
  AState: TGridDrawState);
begin
  if ARow = 0 then Exit;
  if RowDiffers(ARow) then
    Grid.Canvas.Brush.Color := $00C8C8FF
  else
    Grid.Canvas.Brush.Color := $00E8FFE8;
  if (ARow - 1) div NL_POINTS = 1 then Grid.Canvas.Font.Color := $00004080;
end;

procedure TCompareDlg.PlotPaint(Sender: TObject);
var
  R: TRect;
  Full: Double;
  C: TCanvas;
begin
  C := Plot.Canvas;
  C.Brush.Color := clBtnFace;
  C.FillRect(0, 0, Plot.Width, Plot.Height);
  R := Rect(20, 40, Plot.Width - 14, Plot.Height - 30);
  Full := CurveEngFull[SPKind];
  DrawPlot(C, R, Full, CurveUnit[SPKind]);
  DrawCurve(C, R, Full, A[PAIR_SP], CL_SP, 2, psSolid, True);
  DrawCurve(C, R, Full, A[PAIR_ACT], CL_ACT, 2, psSolid, True);
  DrawCurve(C, R, Full, B[PAIR_SP], clNavy, 1, psDash, False);
  DrawCurve(C, R, Full, B[PAIR_ACT], clMaroon, 1, psDash, False);
  C.Brush.Style := bsClear;
  C.Font.Height := -12;
  C.Font.Color := clBlack;
  C.TextOut(20, 6, 'A = solid with dots,  B = dashed');
  C.Font.Color := CL_SP;
  C.TextOut(20, 22, 'Setpoint');
  C.Font.Color := CL_ACT;
  C.TextOut(90, 22, 'Actual');
  C.Brush.Style := bsSolid;
end;

procedure ShowCompare(const ATitle, NameA, NameB: string; const A, B: TCurvePair;
  SPKind, ActKind: TCurveKind);
var
  D: TCompareDlg;
begin
  D := TCompareDlg.CreateNew(nil);
  try
    D.A := A;
    D.B := B;
    D.SPKind := SPKind;
    D.NameA := NameA;
    D.NameB := NameB;
    D.Build(ATitle, ActKind);
    D.ShowModal;
  finally
    D.Free;
  end;
end;

end.
