{ ============================================================================
  dlgconfig - Network Config and PLC Tag Config dialogs (built in code)
  ============================================================================ }
unit dlgconfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Spin, Grids, Dialogs,
  Graphics, ButtonPanel, nlcore;

function EditNetworkConfig(var Net: TNetConfig): Boolean;
function EditTagConfig(var Tags: TTagTable): Boolean;

implementation

type

  { TTagDlgHelper }

  TTagDlgHelper = class
    Grid: TStringGrid;
    procedure FillGrid(const T: TTagTable);
    procedure DefaultsClick(Sender: TObject);
    procedure GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer; AState: TGridDrawState);
  end;

function AddLabeled(AParent: TWinControl; const ACaption: string; ATop: Integer;
  AControl: TControl): TControl;
var
  L: TLabel;
begin
  L := TLabel.Create(AParent);
  L.Parent := AParent;
  L.Caption := ACaption;
  L.Left := 16;
  L.Top := ATop + 4;
  AControl.Parent := AParent;
  AControl.Left := 170;
  AControl.Top := ATop;
  AControl.Width := 180;
  Result := AControl;
end;

function EditNetworkConfig(var Net: TNetConfig): Boolean;
var
  F: TForm;
  EHost: TEdit;
  ERack, ESlot, EPoll, ETimeout: TSpinEdit;
  CAuto: TCheckBox;
  Info: TLabel;
  BP: TButtonPanel;
begin
  F := TForm.CreateNew(nil);
  try
    F.Caption := 'Network Config - S7-1200';
    F.BorderStyle := bsDialog;
    F.Position := poMainFormCenter;
    F.ClientWidth := 380;
    F.ClientHeight := 300;

    EHost := TEdit(AddLabeled(F, 'PLC IP address', 16, TEdit.Create(F)));
    EHost.Text := Net.Host;
    ERack := TSpinEdit(AddLabeled(F, 'Rack', 50, TSpinEdit.Create(F)));
    ERack.MaxValue := 7;
    ERack.Value := Net.Rack;
    ESlot := TSpinEdit(AddLabeled(F, 'Slot (S7-1200 = 1)', 84, TSpinEdit.Create(F)));
    ESlot.MaxValue := 31;
    ESlot.Value := Net.Slot;
    EPoll := TSpinEdit(AddLabeled(F, 'Poll interval (ms)', 118, TSpinEdit.Create(F)));
    EPoll.MinValue := 50;
    EPoll.MaxValue := 10000;
    EPoll.Increment := 50;
    EPoll.Value := Net.PollMs;
    ETimeout := TSpinEdit(AddLabeled(F, 'Timeout (ms)', 152, TSpinEdit.Create(F)));
    ETimeout.MinValue := 200;
    ETimeout.MaxValue := 30000;
    ETimeout.Increment := 100;
    ETimeout.Value := Net.TimeoutMs;
    CAuto := TCheckBox.Create(F);
    CAuto.Parent := F;
    CAuto.Left := 170;
    CAuto.Top := 186;
    CAuto.Caption := 'Connect on startup';
    CAuto.Checked := Net.AutoConnect;

    Info := TLabel.Create(F);
    Info.Parent := F;
    Info.Left := 16;
    Info.Top := 214;
    Info.Caption := 'TCP port 102 (ISO-on-TCP). Enable PUT/GET in the CPU' + LineEnding +
                    'and use a DB with standard (non-optimized) access.';
    Info.Font.Color := clGrayText;

    BP := TButtonPanel.Create(F);
    BP.Parent := F;
    BP.ShowButtons := [pbOK, pbCancel];

    Result := F.ShowModal = mrOK;
    if Result then
    begin
      Net.Host := Trim(EHost.Text);
      Net.Rack := ERack.Value;
      Net.Slot := ESlot.Value;
      Net.PollMs := EPoll.Value;
      Net.TimeoutMs := ETimeout.Value;
      Net.AutoConnect := CAuto.Checked;
    end;
  finally
    F.Free;
  end;
end;

{ TTagDlgHelper }

procedure TTagDlgHelper.FillGrid(const T: TTagTable);
var
  Id: TTagId;
  R: Integer;
begin
  for Id := Low(TTagId) to High(TTagId) do
  begin
    R := Ord(Id) + 1;
    Grid.Cells[0, R] := TagName[Id];
    Grid.Cells[1, R] := TagTypeName[TagType[Id]];
    Grid.Cells[2, R] := IntToStr(T[Id].DB);
    Grid.Cells[3, R] := IntToStr(T[Id].Offset);
    if TagType[Id] = ttBool then
      Grid.Cells[4, R] := IntToStr(T[Id].Bit)
    else
      Grid.Cells[4, R] := '-';
    Grid.Cells[5, R] := TagAddress(Id, T);
    Grid.Cells[6, R] := TagDesc[Id];
  end;
end;

procedure TTagDlgHelper.DefaultsClick(Sender: TObject);
begin
  FillGrid(DefaultTags);
end;

procedure TTagDlgHelper.GridPrepareCanvas(Sender: TObject; ACol, ARow: Integer;
  AState: TGridDrawState);
begin
  if (ARow > 0) and (ACol in [2, 3, 4]) then
    Grid.Canvas.Brush.Color := $00E8FFF0
  else if (ARow > 0) and (ACol = 5) then
    Grid.Canvas.Font.Color := clNavy;
end;

function EditTagConfig(var Tags: TTagTable): Boolean;
var
  F: TForm;
  H: TTagDlgHelper;
  PTop: TPanel;
  BDef: TButton;
  BP: TButtonPanel;
  Id: TTagId;
  R, V: Integer;
  T: TTagTable;
  Err: string;
begin
  F := TForm.CreateNew(nil);
  H := TTagDlgHelper.Create;
  try
    F.Caption := 'PLC Tag Config';
    F.Position := poMainFormCenter;
    F.Width := 900;
    F.Height := 640;

    PTop := TPanel.Create(F);
    PTop.Parent := F;
    PTop.Align := alTop;
    PTop.Height := 40;
    PTop.BevelOuter := bvNone;
    PTop.Caption := '';
    with TLabel.Create(F) do
    begin
      Parent := PTop;
      Left := 10;
      Top := 12;
      Caption := 'Edit DB number / byte offset / bit (green cells). Must match DB_HMI in TIA Portal.';
    end;
    BDef := TButton.Create(F);
    BDef.Parent := PTop;
    BDef.Anchors := [akTop, akRight];
    BDef.Width := 130;
    BDef.Left := PTop.ClientWidth - 140;
    BDef.Top := 7;
    BDef.Caption := 'Default layout';
    BDef.OnClick := @H.DefaultsClick;

    BP := TButtonPanel.Create(F);
    BP.Parent := F;
    BP.ShowButtons := [pbOK, pbCancel];

    H.Grid := TStringGrid.Create(F);
    with H.Grid do
    begin
      Parent := F;
      Align := alClient;
      ColCount := 7;
      RowCount := Ord(High(TTagId)) + 2;
      FixedCols := 0;
      Options := Options + [goEditing, goColSizing] - [goRangeSelect];
      Cells[0, 0] := 'Tag';
      Cells[1, 0] := 'Type';
      Cells[2, 0] := 'DB';
      Cells[3, 0] := 'Offset';
      Cells[4, 0] := 'Bit';
      Cells[5, 0] := 'Address';
      Cells[6, 0] := 'Description';
      ColWidths[0] := 110;
      ColWidths[1] := 90;
      ColWidths[2] := 50;
      ColWidths[3] := 60;
      ColWidths[4] := 40;
      ColWidths[5] := 150;
      ColWidths[6] := 330;
      OnPrepareCanvas := @H.GridPrepareCanvas;
    end;
    H.FillGrid(Tags);

    repeat
      Result := F.ShowModal = mrOK;
      if not Result then Exit;
      T := Tags;
      Err := '';
      for Id := Low(TTagId) to High(TTagId) do
      begin
        R := Ord(Id) + 1;
        if TryStrToInt(H.Grid.Cells[2, R], V) and (V >= 1) and (V <= 65535) then
          T[Id].DB := V
        else
          Err := Err + TagName[Id] + ': invalid DB number' + LineEnding;
        if TryStrToInt(H.Grid.Cells[3, R], V) and (V >= 0) and (V <= 65535) then
          T[Id].Offset := V
        else
          Err := Err + TagName[Id] + ': invalid offset' + LineEnding;
        if TagType[Id] = ttBool then
        begin
          if TryStrToInt(H.Grid.Cells[4, R], V) and (V >= 0) and (V <= 7) then
            T[Id].Bit := V
          else
            Err := Err + TagName[Id] + ': bit must be 0..7' + LineEnding;
        end
        else if Odd(T[Id].Offset) then
          Err := Err + TagName[Id] + ': Real/Int/Struct offset must be even' + LineEnding;
      end;
      if Err = '' then
      begin
        Tags := T;
        Exit(True);
      end;
      MessageDlg('Tag config', Err, mtError, [mbOK], 0);
    until False;
  finally
    H.Free;
    F.Free;
  end;
end;

end.
