{ ============================================================================
  uconfig - network configuration (DataLogger.ini next to the exe)
  Loaded automatically at every program start, saved by Network Config.
  ============================================================================ }
unit uconfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Math, uaddress, udrivers;

type
  TNetConfig = record
    Drv: TDriverParams;       // protocol, IP / COM port, ids, timeout
    AutoMonitor: Boolean;     // start monitoring when the program starts
    AutoRecord: Boolean;      // start recording when the program starts
    LastProject: string;      // tag list opened at the last start
  end;

function DefaultNetConfig: TNetConfig;
function AppIniName: string;
procedure LoadNetConfig(out C: TNetConfig);    // defaults when the file does not exist
procedure SaveNetConfig(const C: TNetConfig);
function NetSummary(const C: TNetConfig): string;

implementation

const
  SEC = 'Network';

function DefaultNetConfig: TNetConfig;
begin
  Result := Default(TNetConfig);
  with Result.Drv do
  begin
    Protocol := prS7;
    Host := '192.168.0.1';
    Port := 502;
    Rack := 0;
    Slot := 1;
    UnitId := 1;
    ComPort := 'COM1';
    Baud := 9600;
    DataBits := 8;
    Parity := 'E';
    StopBits := 1;
    TimeoutMs := 1000;
  end;
end;

function AppIniName: string;
begin
  Result := ChangeFileExt(ParamStr(0), '.ini');
end;

procedure LoadNetConfig(out C: TNetConfig);
var
  Ini: TIniFile;
  S: string;
begin
  C := DefaultNetConfig;
  if not FileExists(AppIniName) then Exit;
  Ini := TIniFile.Create(AppIniName);
  try
    with C.Drv do
    begin
      Protocol := TProtocol(EnsureRange(Ini.ReadInteger(SEC, 'Protocol', Ord(Protocol)),
        Ord(Low(TProtocol)), Ord(High(TProtocol))));
      Host := Ini.ReadString(SEC, 'Host', Host);
      Port := Ini.ReadInteger(SEC, 'Port', Port);
      Rack := Ini.ReadInteger(SEC, 'Rack', Rack);
      Slot := Ini.ReadInteger(SEC, 'Slot', Slot);
      UnitId := Ini.ReadInteger(SEC, 'UnitId', UnitId);
      ComPort := Ini.ReadString(SEC, 'ComPort', ComPort);
      Baud := Ini.ReadInteger(SEC, 'Baud', Baud);
      DataBits := Ini.ReadInteger(SEC, 'DataBits', DataBits);
      S := Ini.ReadString(SEC, 'Parity', Parity);
      if S <> '' then Parity := UpCase(S[1]);
      StopBits := Ini.ReadInteger(SEC, 'StopBits', StopBits);
      TimeoutMs := Ini.ReadInteger(SEC, 'TimeoutMs', TimeoutMs);
    end;
    C.AutoMonitor := Ini.ReadBool(SEC, 'AutoMonitor', C.AutoMonitor);
    C.AutoRecord := Ini.ReadBool(SEC, 'AutoRecord', C.AutoRecord);
    C.LastProject := Ini.ReadString('App', 'LastProject', '');
  finally
    Ini.Free;
  end;
end;

procedure SaveNetConfig(const C: TNetConfig);
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(AppIniName);
  try
    with C.Drv do
    begin
      Ini.WriteInteger(SEC, 'Protocol', Ord(Protocol));
      Ini.WriteString(SEC, 'ProtocolName', ProtocolName[Protocol]);
      Ini.WriteString(SEC, 'Host', Host);
      Ini.WriteInteger(SEC, 'Port', Port);
      Ini.WriteInteger(SEC, 'Rack', Rack);
      Ini.WriteInteger(SEC, 'Slot', Slot);
      Ini.WriteInteger(SEC, 'UnitId', UnitId);
      Ini.WriteString(SEC, 'ComPort', ComPort);
      Ini.WriteInteger(SEC, 'Baud', Baud);
      Ini.WriteInteger(SEC, 'DataBits', DataBits);
      Ini.WriteString(SEC, 'Parity', Parity);
      Ini.WriteInteger(SEC, 'StopBits', StopBits);
      Ini.WriteInteger(SEC, 'TimeoutMs', TimeoutMs);
    end;
    Ini.WriteBool(SEC, 'AutoMonitor', C.AutoMonitor);
    Ini.WriteBool(SEC, 'AutoRecord', C.AutoRecord);
    Ini.WriteString('App', 'LastProject', C.LastProject);
  finally
    Ini.Free;
  end;
end;

function NetSummary(const C: TNetConfig): string;
begin
  with C.Drv do
    case Protocol of
      prS7: Result := Format('S7  %s  rack %d slot %d', [Host, Rack, Slot]);
      prModbusTCP: Result := Format('Modbus TCP  %s:%d  unit %d', [Host, Port, UnitId]);
    else
      Result := Format('Modbus RTU  %s  %d %d%s%d  slave %d', [ComPort, Baud, DataBits, Parity, StopBits, UnitId]);
    end;
end;

end.
