{ ============================================================================
  uaddrhelper - "Address helper" dialog (uaddrhelper.lfm)
  Build a PLC address step by step: area / table, number, data type.
  Use:  if TAddrHelperForm.Execute(Self, Protocol, AddrText) then ...
  ============================================================================ }
unit uaddrhelper;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Spin, ButtonPanel, Graphics, Math,
  uaddress;

type

  { TAddrHelperForm }

  TAddrHelperForm = class(TForm)
    ButtonPanel1: TButtonPanel;
    ComboArea: TComboBox;
    ComboMType: TComboBox;
    ComboTable: TComboBox;
    ComboType: TComboBox;
    GroupResult: TGroupBox;
    LabelAddr: TLabel;
    LabelArea: TLabel;
    LabelBit: TLabel;
    LabelByte: TLabel;
    LabelDB: TLabel;
    LabelDesc: TLabel;
    LabelHint: TLabel;
    LabelMType: TLabel;
    LabelProto: TLabel;
    LabelReg: TLabel;
    LabelTable: TLabel;
    LabelType: TLabel;
    PanelModbus: TPanel;
    PanelS7: TPanel;
    SpinBit: TSpinEdit;
    SpinByte: TSpinEdit;
    SpinDB: TSpinEdit;
    SpinReg: TSpinEdit;
    procedure AnyChange(Sender: TObject);
  private
    FProto: TProtocol;
    FUpdating: Boolean;
    FResult: string;
    procedure LoadFrom(const AText: string);
  public
    class function Execute(AOwner: TComponent; AProto: TProtocol; var AText: string): Boolean;
  end;

implementation

{$R *.lfm}

const
  { types offered in the two type lists (index = list position) }
  S7Types: array[0..12] of TDataType = (dtBool, dtByte, dtInt, dtUInt, dtDInt, dtUDInt, dtReal,
    dtDate, dtTime, dtTOD, dtDT, dtDTL, dtUnixTime);
  S7TypeText: array[0..12] of string = ('BOOL', 'BYTE', 'INT', 'UINT (WORD)', 'DINT', 'UDINT (DWORD)',
    'REAL', 'DATE (W)', 'TIME (D, ms)', 'TOD (D, ms)', 'DT (8 bytes)', 'DTL (12 bytes)',
    'UNIXTIME (D, s)');
  MbTypes: array[0..8] of TDataType = (dtInt, dtUInt, dtDInt, dtUDInt, dtReal, dtRealSw,
    dtTime, dtTOD, dtUnixTime);
  MbTypeText: array[0..8] of string = ('INT (1 register)', 'UINT (1 register)', 'DINT (2 registers)',
    'UDINT (2 registers)', 'REAL (2 registers, ABCD)', 'REALSW (2 registers, CDAB)',
    'TIME (2 registers, ms)', 'TOD (2 registers, ms since 00:00)', 'UNIXTIME (2 registers, s since 1970)');

function IndexOfType(const L: array of TDataType; DT: TDataType): Integer;
var
  I: Integer;
begin
  for I := 0 to High(L) do
    if L[I] = DT then Exit(I);
  Result := 0;
end;

{ TAddrHelperForm }

procedure TAddrHelperForm.LoadFrom(const AText: string);
var
  A: TTagAddr;
  Err: string;
begin
  FUpdating := True;
  try
    if not ParseAddress(FProto, AText, A, Err) then
    begin
      { a sensible start for an empty / wrong address }
      if IsModbus(FProto) then ParseAddress(FProto, '40001', A, Err)
      else ParseAddress(FProto, 'DB1.DBD0', A, Err);
    end;
    if IsModbus(FProto) then
    begin
      ComboTable.ItemIndex := Ord(A.Area) - Ord(aaCoil);
      SpinReg.Value := A.Offset + 1;
      ComboMType.ItemIndex := IndexOfType(MbTypes, A.DT);
    end
    else
    begin
      ComboArea.ItemIndex := Ord(A.Area);
      SpinDB.Value := Max(1, A.DB);
      SpinByte.Value := A.Offset;
      SpinBit.Value := A.Bit;
      ComboType.ItemIndex := IndexOfType(S7Types, A.DT);
    end;
  finally
    FUpdating := False;
  end;
  AnyChange(nil);
end;

procedure TAddrHelperForm.AnyChange(Sender: TObject);
var
  A, Check: TTagAddr;
  Err: string;
  Ok: Boolean;
begin
  if FUpdating then Exit;
  A := Default(TTagAddr);
  if IsModbus(FProto) then
  begin
    A.Area := TAddrArea(Ord(aaCoil) + Max(0, ComboTable.ItemIndex));
    A.Offset := SpinReg.Value - 1;
    ComboMType.Enabled := A.Area in [aaInputReg, aaHoldingReg];
    if ComboMType.Enabled then A.DT := MbTypes[Max(0, ComboMType.ItemIndex)]
    else A.DT := dtBool;
  end
  else
  begin
    A.Area := TAddrArea(Max(0, ComboArea.ItemIndex));
    SpinDB.Enabled := A.Area = aaS7DB;
    A.DB := SpinDB.Value;
    A.Offset := SpinByte.Value;
    A.DT := S7Types[Max(0, ComboType.ItemIndex)];
    SpinBit.Enabled := A.DT = dtBool;
    A.Bit := SpinBit.Value;
  end;
  FResult := FormatAddress(FProto, A);
  { check the text the same way the logger will read it }
  Ok := ParseAddress(FProto, FResult, Check, Err);
  if Ok then
  begin
    LabelAddr.Caption := FResult;
    LabelAddr.Font.Color := clNavy;
    LabelDesc.Caption := DescribeAddress(FProto, Check);
  end
  else
  begin
    LabelAddr.Caption := FResult;
    LabelAddr.Font.Color := clRed;
    LabelDesc.Caption := Err;
  end;
  ButtonPanel1.OKButton.Enabled := Ok;
end;

class function TAddrHelperForm.Execute(AOwner: TComponent; AProto: TProtocol; var AText: string): Boolean;
var
  F: TAddrHelperForm;
  I: Integer;
begin
  F := TAddrHelperForm.Create(AOwner);
  try
    F.ComboType.Items.Clear;
    for I := 0 to High(S7TypeText) do F.ComboType.Items.Add(S7TypeText[I]);
    F.ComboMType.Items.Clear;
    for I := 0 to High(MbTypeText) do F.ComboMType.Items.Add(MbTypeText[I]);
    F.ComboType.DropDownCount := 16;
    F.FProto := AProto;
    F.LabelProto.Caption := 'Protocol: ' + ProtocolName[AProto];
    F.PanelS7.Visible := not IsModbus(AProto);
    F.PanelModbus.Visible := IsModbus(AProto);
    if IsModbus(AProto) then
      F.LabelHint.Caption := 'Number = Modicon number: 40001 is the first holding register (offset 0). ' +
        'If the device manual counts from 0, add 1. 32-bit types use 2 registers. ' +
        'REALSW = float with the low word first.'
    else
      F.LabelHint.Caption := 'I / Q / M can always be read. For DB addresses the DB needs ' +
        '"Optimized block access" OFF. The CPU must allow PUT/GET access.';
    F.LoadFrom(AText);
    Result := F.ShowModal = mrOK;
    if Result then AText := F.FResult;
  finally
    F.Free;
  end;
end;

end.
