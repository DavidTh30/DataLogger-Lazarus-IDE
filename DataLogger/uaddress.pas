{ ============================================================================
  uaddress - PLC addresses for the data logger
    S7     : I0.1  Q0.0  M10.3  IB0  MW20  MD24  DB10.DBX40.0  DB10.DBB5
             DB10.DBW42  DB10.DBD0          (+ optional :TYPE)
    Modbus : 00001 coil, 10001 discrete input, 30001 input register,
             40001 holding register (Modicon numbers, 5 or 6 digits)
             (+ optional :TYPE for registers)
    Types  : BOOL BYTE INT UINT DINT UDINT REAL REALSW (Modbus word-swapped)
             DATE TIME TOD DT DTL UNIXTIME (date / time values)
  ============================================================================ }
unit uaddress;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TProtocol = (prS7, prModbusTCP, prModbusRTU);

  TAddrArea = (aaS7I, aaS7Q, aaS7M, aaS7DB,                 // S7
               aaCoil, aaDiscrete, aaInputReg, aaHoldingReg); // Modbus

  TDataType = (dtBool, dtByte, dtInt, dtUInt, dtDInt, dtUDInt, dtReal, dtRealSw,
               dtDate,      // S7 DATE: days since 1990-01-01 (2 bytes)
               dtTime,      // TIME: DINT milliseconds (4 bytes)
               dtTOD,       // TIME_OF_DAY: UDINT ms since midnight (4 bytes)
               dtDT,        // S7 DATE_AND_TIME: 8 BCD bytes
               dtDTL,       // S7-1200/1500 DTL: 12 bytes
               dtUnixTime); // UDINT seconds since 1970-01-01 (4 bytes)

  TTagAddr = record
    Area: TAddrArea;
    DB: Integer;        // S7 data block number (aaS7DB only)
    Offset: Integer;    // S7: byte offset / Modbus: 0-based coil or register number
    Bit: Integer;       // S7 BOOL: 0..7
    DT: TDataType;
  end;

const
  ProtocolName: array[TProtocol] of string = ('S7 (TCP/IP)', 'Modbus TCP/IP', 'Modbus RTU (RS485)');
  DTName: array[TDataType] of string = ('BOOL', 'BYTE', 'INT', 'UINT', 'DINT', 'UDINT', 'REAL', 'REALSW',
    'DATE', 'TIME', 'TOD', 'DT', 'DTL', 'UNIXTIME');
  DTSize: array[TDataType] of Integer = (1, 1, 2, 2, 4, 4, 4, 4, 2, 4, 4, 8, 12, 4);   // bytes (BOOL = 1 bit)
  { S7 size letter of an address with this type: X bit, B byte (and structures), W word, D dword }
  DTSizeLetter: array[TDataType] of Char = ('X', 'B', 'W', 'W', 'D', 'D', 'D', 'D', 'W', 'D', 'D', 'B', 'B', 'D');

{ date / time types (shown as date, time or duration) }
function IsDateTimeType(DT: TDataType): Boolean;

function IsModbus(P: TProtocol): Boolean;
{ text -> address; False + Err when the text is not a valid address for this protocol }
function ParseAddress(P: TProtocol; const AText: string; out A: TTagAddr; out Err: string): Boolean;
{ address -> canonical text (type suffix only when it is not the default) }
function FormatAddress(P: TProtocol; const A: TTagAddr): string;
{ readable description, e.g. "Holding register 40003-40004, FC03, REAL" }
function DescribeAddress(P: TProtocol; const A: TTagAddr): string;
{ examples for the user }
function AddressExamples(P: TProtocol): string;
{ address of a new tag: S7 M0.0, Modbus 40001 }
function DefaultAddress(P: TProtocol): string;
{ the address right after Prev with the same type: M0.7 -> M1.0, MW20 -> MW22,
  DB10.DBD0 -> DB10.DBD4, 40003:REAL -> 40005:REAL; Prev empty / invalid -> DefaultAddress }
function NextAddress(P: TProtocol; const Prev: string): string;

implementation

function IsModbus(P: TProtocol): Boolean;
begin
  Result := P in [prModbusTCP, prModbusRTU];
end;

function IsDateTimeType(DT: TDataType): Boolean;
begin
  Result := DT in [dtDate, dtTime, dtTOD, dtDT, dtDTL, dtUnixTime];
end;

function DTFromName(const S: string; out DT: TDataType): Boolean;
var
  D: TDataType;
  U: string;
begin
  U := UpperCase(S);
  if U = 'WORD' then U := 'UINT';
  if U = 'DWORD' then U := 'UDINT';
  for D := Low(TDataType) to High(TDataType) do
    if DTName[D] = U then
    begin
      DT := D;
      Exit(True);
    end;
  Result := False;
end;

{ split "ADDR:TYPE" }
procedure SplitType(const S: string; out Addr, Typ: string);
var
  P: Integer;
begin
  P := Pos(':', S);
  if P > 0 then
  begin
    Addr := Copy(S, 1, P - 1);
    Typ := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    Addr := S;
    Typ := '';
  end;
end;

{ read a decimal number at position I, I moves behind it }
function ReadNum(const S: string; var I: Integer; out N: Integer): Boolean;
var
  St: Integer;
begin
  St := I;
  while (I <= Length(S)) and (S[I] in ['0'..'9']) do Inc(I);
  Result := (I > St) and (I - St <= 6) and TryStrToInt(Copy(S, St, I - St), N);
end;

function ParseS7(const S: string; out A: TTagAddr; out Err: string): Boolean;
var
  Addr, Typ: string;
  I, N: Integer;
  Size: Char;
  DT: TDataType;
begin
  Result := False;
  A := Default(TTagAddr);
  SplitType(UpperCase(StringReplace(Trim(S), ' ', '', [rfReplaceAll])), Addr, Typ);
  if (Addr <> '') and (Addr[1] = '%') then Delete(Addr, 1, 1);
  if Addr = '' then
  begin
    Err := 'empty address';
    Exit;
  end;
  I := 1;
  if Copy(Addr, 1, 2) = 'DB' then
  begin
    { DBn.DBXb.x / DBn.DBBb / DBn.DBWb / DBn.DBDb }
    I := 3;
    if not ReadNum(Addr, I, N) or (N < 1) or (N > 65535) then
    begin
      Err := 'DB number missing (e.g. DB10.DBD0)';
      Exit;
    end;
    A.Area := aaS7DB;
    A.DB := N;
    if Copy(Addr, I, 3) <> '.DB' then
    begin
      Err := 'expected ".DBX / .DBB / .DBW / .DBD" after the DB number';
      Exit;
    end;
    Inc(I, 3);
    if I > Length(Addr) then
    begin
      Err := 'size letter X / B / W / D missing';
      Exit;
    end;
    Size := Addr[I];
    Inc(I);
  end
  else
  begin
    { I / Q / M  (German E / A accepted too) }
    case Addr[1] of
      'I', 'E': A.Area := aaS7I;
      'Q', 'A': A.Area := aaS7Q;
      'M': A.Area := aaS7M;
    else
      Err := 'address must start with I, Q, M or DB';
      Exit;
    end;
    I := 2;
    if (I <= Length(Addr)) and (Addr[I] in ['X', 'B', 'W', 'D']) then
    begin
      Size := Addr[I];
      Inc(I);
    end
    else
      Size := 'X';
  end;
  if not (Size in ['X', 'B', 'W', 'D']) then
  begin
    Err := 'size letter must be X, B, W or D';
    Exit;
  end;
  if not ReadNum(Addr, I, N) or (N > 65535) then
  begin
    Err := 'byte number missing';
    Exit;
  end;
  A.Offset := N;
  if Size = 'X' then
  begin
    if (I > Length(Addr)) or (Addr[I] <> '.') then
    begin
      Err := 'bit address needs ".bit", e.g. I0.1';
      Exit;
    end;
    Inc(I);
    if not ReadNum(Addr, I, N) or (N > 7) then
    begin
      Err := 'bit must be 0..7';
      Exit;
    end;
    A.Bit := N;
    A.DT := dtBool;
  end;
  if I <= Length(Addr) then
  begin
    Err := 'unexpected "' + Copy(Addr, I, MaxInt) + '"';
    Exit;
  end;
  { default type by size }
  case Size of
    'B': A.DT := dtByte;
    'W': A.DT := dtInt;
    'D': A.DT := dtReal;
  end;
  if Typ <> '' then
  begin
    if not DTFromName(Typ, DT) or (DT = dtRealSw) then
    begin
      Err := 'unknown type "' + Typ + '"';
      Exit;
    end;
    if DTSizeLetter[DT] <> Size then
    begin
      Err := Format('type %s needs size letter %s (e.g. %s)', [DTName[DT], DTSizeLetter[DT],
        'DB1.DB' + DTSizeLetter[DT] + '0:' + DTName[DT]]);
      Exit;
    end;
    if (Size = 'X') <> (DT = dtBool) then
    begin
      Err := 'BOOL only for bit addresses';
      Exit;
    end;
    A.DT := DT;
  end;
  Result := True;
end;

function ParseModbus(const S: string; out A: TTagAddr; out Err: string): Boolean;
var
  Addr, Typ: string;
  N: Integer;
  DT: TDataType;
begin
  Result := False;
  A := Default(TTagAddr);
  SplitType(UpperCase(StringReplace(Trim(S), ' ', '', [rfReplaceAll])), Addr, Typ);
  if (Length(Addr) < 5) or (Length(Addr) > 6) or not TryStrToInt(Addr, N) or (Pos('-', Addr) > 0) then
  begin
    Err := 'use a 5 or 6 digit Modbus number: 00001 coil, 10001 input, 30001 input reg., 40001 holding reg.';
    Exit;
  end;
  N := StrToInt(Copy(Addr, 2, MaxInt));       // 1-based number after the table digit
  if (N < 1) or (N > 65536) then
  begin
    Err := 'number after the first digit must be 1..65536';
    Exit;
  end;
  case Addr[1] of
    '0': A.Area := aaCoil;
    '1': A.Area := aaDiscrete;
    '3': A.Area := aaInputReg;
    '4': A.Area := aaHoldingReg;
  else
    Err := 'first digit must be 0 (coil), 1 (input), 3 (input register) or 4 (holding register)';
    Exit;
  end;
  A.Offset := N - 1;
  if A.Area in [aaCoil, aaDiscrete] then A.DT := dtBool else A.DT := dtInt;
  if Typ <> '' then
  begin
    if not DTFromName(Typ, DT) then
    begin
      Err := 'unknown type "' + Typ + '"';
      Exit;
    end;
    if (A.Area in [aaCoil, aaDiscrete]) <> (DT = dtBool) then
    begin
      Err := 'coils / inputs are BOOL, registers are INT, UINT, DINT, UDINT, REAL, REALSW, TIME, TOD or UNIXTIME';
      Exit;
    end;
    if DT in [dtByte, dtDate, dtDT, dtDTL] then
    begin
      Err := DTName[DT] + ' is not a Modbus register type (use INT UINT DINT UDINT REAL REALSW TIME TOD UNIXTIME)';
      Exit;
    end;
    A.DT := DT;
  end;
  if (DTSize[A.DT] = 4) and (A.Offset > 65534) then
  begin
    Err := '32-bit value needs 2 registers';
    Exit;
  end;
  Result := True;
end;

function ParseAddress(P: TProtocol; const AText: string; out A: TTagAddr; out Err: string): Boolean;
begin
  Err := '';
  if IsModbus(P) then Result := ParseModbus(AText, A, Err)
  else Result := ParseS7(AText, A, Err);
end;

function ModbusRef(Area: TAddrArea; Offset: Integer): string; forward;

function FormatAddress(P: TProtocol; const A: TTagAddr): string;
const
  AreaCh: array[aaS7I..aaS7M] of string = ('I', 'Q', 'M');

begin
  if IsModbus(P) then
  begin
    Result := ModbusRef(A.Area, A.Offset);
    if (A.Area in [aaInputReg, aaHoldingReg]) and (A.DT <> dtInt) then
      Result := Result + ':' + DTName[A.DT];
    Exit;
  end;
  if A.Area = aaS7DB then
  begin
    if A.DT = dtBool then
      Result := Format('DB%d.DBX%d.%d', [A.DB, A.Offset, A.Bit])
    else
      Result := Format('DB%d.DB%s%d', [A.DB, DTSizeLetter[A.DT], A.Offset]);
  end
  else if A.DT = dtBool then
    Result := Format('%s%d.%d', [AreaCh[A.Area], A.Offset, A.Bit])
  else
    Result := Format('%s%s%d', [AreaCh[A.Area], DTSizeLetter[A.DT], A.Offset]);
  { type suffix only when it differs from the default of the size }
  if not (A.DT in [dtBool, dtByte, dtInt, dtReal]) then Result := Result + ':' + DTName[A.DT];
end;

{ Modicon number of a coil / register, e.g. 40003 }
function ModbusRef(Area: TAddrArea; Offset: Integer): string;
const
  TableDigit: array[aaCoil..aaHoldingReg] of string = ('0', '1', '3', '4');
begin
  if Offset + 1 <= 9999 then Result := TableDigit[Area] + Format('%.4d', [Offset + 1])
  else Result := TableDigit[Area] + Format('%.5d', [Offset + 1]);
end;

function DescribeAddress(P: TProtocol; const A: TTagAddr): string;
const
  S7AreaName: array[aaS7I..aaS7DB] of string = ('Input I', 'Output Q', 'Marker M', 'Data block');
var
  Kind, Fc, Regs: string;
begin
  if IsModbus(P) then
  begin
    case A.Area of
      aaCoil: Exit(Format('Coil %s, FC01, BOOL', [ModbusRef(A.Area, A.Offset)]));
      aaDiscrete: Exit(Format('Discrete input %s, FC02, BOOL', [ModbusRef(A.Area, A.Offset)]));
      aaInputReg:
        begin
          Kind := 'Input register';
          Fc := 'FC04';
        end;
    else
      Kind := 'Holding register';
      Fc := 'FC03';
    end;
    Regs := ModbusRef(A.Area, A.Offset);
    if DTSize[A.DT] = 4 then Regs := Regs + '-' + ModbusRef(A.Area, A.Offset + 1);
    Exit(Format('%s %s, %s, %s (offset %d)', [Kind, Regs, Fc, DTName[A.DT], A.Offset]));
  end;
  if A.Area = aaS7DB then Result := Format('DB%d, ', [A.DB]) else Result := S7AreaName[A.Area] + ', ';
  if A.DT = dtBool then
    Result := Result + Format('byte %d bit %d, BOOL', [A.Offset, A.Bit])
  else
    Result := Result + Format('byte %d..%d, %s', [A.Offset, A.Offset + DTSize[A.DT] - 1, DTName[A.DT]]);
end;

function AddressExamples(P: TProtocol): string;
begin
  if IsModbus(P) then
    Result := 'Examples: 40001  40003:REAL  40005:DINT  40010:UNIXTIME  30001  00001 (coil)  10001 (input)'
  else
    Result := 'Examples: DB10.DBD0  DB10.DBW42  DB10.DBX40.0  I0.1  IW64  MD24:DINT  DB5.DBB0:DTL';
end;

function DefaultAddress(P: TProtocol): string;
begin
  if IsModbus(P) then Result := '40001' else Result := 'M0.0';
end;

function NextAddress(P: TProtocol; const Prev: string): string;
var
  A: TTagAddr;
  Err: string;
begin
  if not ParseAddress(P, Prev, A, Err) then Exit(DefaultAddress(P));
  if IsModbus(P) then
  begin
    if A.Area in [aaCoil, aaDiscrete] then Inc(A.Offset)
    else Inc(A.Offset, (DTSize[A.DT] + 1) div 2);      // registers of the type
  end
  else if A.DT = dtBool then
  begin
    Inc(A.Bit);
    if A.Bit > 7 then
    begin
      A.Bit := 0;
      Inc(A.Offset);
    end;
  end
  else
    Inc(A.Offset, DTSize[A.DT]);
  Result := FormatAddress(P, A);
end;
end.
