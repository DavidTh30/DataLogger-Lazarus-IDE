{ ============================================================================
  unetform - "Network Config" dialog (unetform.lfm)
    protocol S7 TCP/IP / Modbus TCP/IP / Modbus RTU (RS485)
  Use:  if TNetForm.Execute(Self, Cfg) then SaveNetConfig(Cfg);
  ============================================================================ }
unit unetform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Spin, ButtonPanel,
  {$IFDEF WINDOWS} Registry, Windows, {$ENDIF}
  uaddress, uconfig;

type

  { TNetForm }

  TNetForm = class(TForm)
    ButtonPanel1: TButtonPanel;
    CheckAutoMonitor: TCheckBox;
    CheckAutoRecord: TCheckBox;
    ComboBaud: TComboBox;
    ComboCom: TComboBox;
    ComboData: TComboBox;
    ComboParity: TComboBox;
    ComboStop: TComboBox;
    EditHost: TEdit;
    GroupGeneral: TGroupBox;
    GroupId: TGroupBox;
    GroupS7: TGroupBox;
    GroupSerial: TGroupBox;
    GroupTcp: TGroupBox;
    LabelBaud: TLabel;
    LabelCom: TLabel;
    LabelData: TLabel;
    LabelHost: TLabel;
    LabelParity: TLabel;
    LabelPort: TLabel;
    LabelRack: TLabel;
    LabelSlot: TLabel;
    LabelStop: TLabel;
    LabelTimeout: TLabel;
    LabelUnit: TLabel;
    RadioProto: TRadioGroup;
    SpinPort: TSpinEdit;
    SpinRack: TSpinEdit;
    SpinSlot: TSpinEdit;
    SpinTimeout: TSpinEdit;
    SpinUnit: TSpinEdit;
    procedure RadioProtoClick(Sender: TObject);
  private
    procedure FillComPorts(const Current: string);
  public
    class function Execute(AOwner: TComponent; var C: TNetConfig): Boolean;
  end;

implementation

{$R *.lfm}

{ TNetForm }

procedure TNetForm.FillComPorts(const Current: string);
var
  L: TStringList;
  I: Integer;
  {$IFDEF WINDOWS}
  R: TRegistry;
  Names: TStringList;
  {$ENDIF}
begin
  L := TStringList.Create;
  try
    L.Sorted := True;
    L.Duplicates := dupIgnore;
    {$IFDEF WINDOWS}
    { the serial ports Windows has right now }
    R := TRegistry.Create(KEY_READ);
    Names := TStringList.Create;
    try
      R.RootKey := HKEY_LOCAL_MACHINE;
      if R.OpenKeyReadOnly('HARDWARE\DEVICEMAP\SERIALCOMM') then
      begin
        R.GetValueNames(Names);
        for I := 0 to Names.Count - 1 do L.Add(R.ReadString(Names[I]));
      end;
    finally
      Names.Free;
      R.Free;
    end;
    {$ENDIF}
    if L.Count = 0 then
      for I := 1 to 8 do L.Add('COM' + IntToStr(I));
    if Current <> '' then L.Add(Current);
    ComboCom.Items.Assign(L);
    ComboCom.Text := Current;
  finally
    L.Free;
  end;
end;

procedure TNetForm.RadioProtoClick(Sender: TObject);
var
  P: TProtocol;
begin
  P := TProtocol(RadioProto.ItemIndex);
  GroupTcp.Enabled := P in [prS7, prModbusTCP];
  GroupS7.Enabled := P = prS7;
  GroupId.Enabled := P in [prModbusTCP, prModbusRTU];
  GroupSerial.Enabled := P = prModbusRTU;
  SpinPort.Enabled := P = prModbusTCP;          // S7 always uses port 102
  if P = prS7 then SpinPort.Value := 102
  else if (P = prModbusTCP) and (SpinPort.Value = 102) then SpinPort.Value := 502;
  if P = prModbusRTU then LabelUnit.Caption := 'Slave ID' else LabelUnit.Caption := 'Unit ID';
end;

class function TNetForm.Execute(AOwner: TComponent; var C: TNetConfig): Boolean;
var
  F: TNetForm;
begin
  F := TNetForm.Create(AOwner);
  try
    with C.Drv do
    begin
      F.RadioProto.ItemIndex := Ord(Protocol);
      F.EditHost.Text := Host;
      F.SpinPort.Value := Port;
      F.SpinRack.Value := Rack;
      F.SpinSlot.Value := Slot;
      F.SpinUnit.Value := UnitId;
      F.FillComPorts(ComPort);
      F.ComboBaud.Text := IntToStr(Baud);
      F.ComboData.Text := IntToStr(DataBits);
      case Parity of
        'E': F.ComboParity.ItemIndex := 1;
        'O': F.ComboParity.ItemIndex := 2;
      else
        F.ComboParity.ItemIndex := 0;
      end;
      F.ComboStop.Text := IntToStr(StopBits);
      F.SpinTimeout.Value := TimeoutMs;
    end;
    F.CheckAutoMonitor.Checked := C.AutoMonitor;
    F.CheckAutoRecord.Checked := C.AutoRecord;
    F.RadioProtoClick(nil);
    Result := F.ShowModal = mrOK;
    if Result then
      with C.Drv do
      begin
        Protocol := TProtocol(F.RadioProto.ItemIndex);
        Host := Trim(F.EditHost.Text);
        if Protocol = prModbusTCP then Port := F.SpinPort.Value;
        Rack := F.SpinRack.Value;
        Slot := F.SpinSlot.Value;
        UnitId := F.SpinUnit.Value;
        ComPort := UpperCase(Trim(F.ComboCom.Text));
        Baud := StrToIntDef(F.ComboBaud.Text, 9600);
        DataBits := StrToIntDef(F.ComboData.Text, 8);
        Parity := 'NEO'[F.ComboParity.ItemIndex + 1];
        StopBits := StrToIntDef(F.ComboStop.Text, 1);
        TimeoutMs := F.SpinTimeout.Value;
        C.AutoMonitor := F.CheckAutoMonitor.Checked;
        C.AutoRecord := F.CheckAutoRecord.Checked;
      end;
  finally
    F.Free;
  end;
end;

end.
