{ ============================================================================
  udrivers - communication drivers of the data logger
    TS7Driver         S7 over TCP/IP (ISO-on-TCP 102)   -> ../Common/s7comm.pas
    TModbusTcpDriver  Modbus TCP (MBAP, port 502)
    TModbusRtuDriver  Modbus RTU over RS485 (serial port, CRC16)
  Fast reading:  Driver.SetTags(Addrs, Use) once, then Driver.ReadAll(Values) every cycle.
    - tags close to each other are read as ONE block (PlanBlocks)
    - S7: several blocks in ONE request (multi-item read, up to 20 items / PDU)
    - Modbus: one request per block (max 125 registers / 2000 coils)
    - a block the PLC refuses is split: its tags are read one by one from then on,
      so one bad tag gives an error for that tag only
  ReadTag(Addr) reads one tag alone.
    - EItemError : the PLC answered but refused this tag (connection is fine)
    - any other exception : communication error -> reconnect
  ============================================================================ }
unit udrivers;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, Math, ssockets, sockets, serial, s7comm, uaddress;

type
  { the PLC refused one tag (address not available, Modbus exception, ...) }
  EItemError = class(Exception);

  { value of one tag after a read }
  TTagValue = record
    Ok: Boolean;
    Value: Double;
    Err: string;
  end;
  TTagValues = array of TTagValue;

  { tags read together in one piece: S7 bytes, Modbus registers or coils }
  TReadBlock = record
    Area: TAddrArea;
    DB, Start, Size: Integer;
    Tags: array of Integer;   // indexes into the tag list
  end;
  TReadBlocks = array of TReadBlock;

  { network / serial settings, see uconfig }
  TDriverParams = record
    Protocol: TProtocol;
    Host: string;
    Port: Integer;          // Modbus TCP (S7 is always 102)
    Rack, Slot: Integer;    // S7
    UnitId: Integer;        // Modbus TCP unit id / RTU slave id
    ComPort: string;        // RTU, e.g. COM3
    Baud: Integer;
    DataBits: Integer;
    Parity: Char;           // N / E / O
    StopBits: Integer;
    TimeoutMs: Integer;
  end;

  { TPlcDriver }

  TPlcDriver = class
  protected
    FP: TDriverParams;
    FAddrs: array of TTagAddr;
    FUse: array of Boolean;
    FSingle: array of Boolean;   // tags that must be read alone (their block was refused)
    FBlocks: TReadBlocks;
    FPlanned: Boolean;
    FRequests: Integer;
    procedure Plan;
    { largest block (S7 bytes / Modbus registers), allowed hole between two tags }
    function MaxBlock(Area: TAddrArea): Integer; virtual;
    function MaxGap(Area: TAddrArea): Integer; virtual;
    { read all blocks; Errs[i] <> '' = the PLC refused block i; comm error -> exception }
    procedure ReadBlocks(var Data: array of TBytes; var Errs: array of string); virtual;
    procedure ReadBlock(const B: TReadBlock; out Data: TBytes); virtual;
  public
    constructor Create(const P: TDriverParams); virtual;
    procedure SetTags(const Addrs: array of TTagAddr; const Use: array of Boolean);
    { read every tag with Use[i]; tag errors in Vals[i].Err, comm error -> exception }
    procedure ReadAll(var Vals: TTagValues);
    property Blocks: TReadBlocks read FBlocks;
    property Requests: Integer read FRequests;     // requests of the last ReadAll
    procedure Connect; virtual; abstract;
    procedure Disconnect; virtual; abstract;
    function Connected: Boolean; virtual; abstract;
    function ReadTag(const A: TTagAddr): Double; virtual; abstract;
    function Description: string; virtual; abstract;
  end;

  { TS7Driver }

  TS7Driver = class(TPlcDriver)
  private
    FClient: TS7Client;
    FNoMulti: Boolean;       // the PLC refused multi-item reads: one block per request
  protected
    function MaxBlock(Area: TAddrArea): Integer; override;
    function MaxGap(Area: TAddrArea): Integer; override;
    procedure ReadBlocks(var Data: array of TBytes; var Errs: array of string); override;
    procedure ReadBlock(const B: TReadBlock; out Data: TBytes); override;
  public
    constructor Create(const P: TDriverParams); override;
    destructor Destroy; override;
    procedure Connect; override;
    procedure Disconnect; override;
    function Connected: Boolean; override;
    function ReadTag(const A: TTagAddr): Double; override;
    function Description: string; override;
  end;

  { TModbusDriver - common part of TCP and RTU: request / decode }

  TModbusDriver = class(TPlcDriver)
  protected
    { send a PDU (function code + data), return the response PDU }
    function Transact(const Pdu: TBytes): TBytes; virtual; abstract;
    function MaxBlock(Area: TAddrArea): Integer; override;
    function MaxGap(Area: TAddrArea): Integer; override;
    procedure ReadBlock(const B: TReadBlock; out Data: TBytes); override;
  public
    function ReadTag(const A: TTagAddr): Double; override;
  end;

  { TModbusTcpDriver }

  TModbusTcpDriver = class(TModbusDriver)
  private
    FSock: TInetSocket;
    FTid: Word;
    procedure RecvExact(var Buf; Count: Integer);
  protected
    function Transact(const Pdu: TBytes): TBytes; override;
  public
    destructor Destroy; override;
    procedure Connect; override;
    procedure Disconnect; override;
    function Connected: Boolean; override;
    function Description: string; override;
  end;

  { TModbusRtuDriver }

  TModbusRtuDriver = class(TModbusDriver)
  private
    FHandle: TSerialHandle;
    function ReadBytes(var Buf: TBytes; Ofs, Count: Integer; Deadline: QWord): Boolean;
  protected
    function Transact(const Pdu: TBytes): TBytes; override;
  public
    destructor Destroy; override;
    procedure Connect; override;
    procedure Disconnect; override;
    function Connected: Boolean; override;
    function Description: string; override;
  end;

function CreateDriver(const P: TDriverParams): TPlcDriver;
{ Modbus RTU CRC16 (poly A001, init FFFF) - low byte is sent first }
function ModbusCrc16(const B: TBytes; Count: Integer): Word;
{ big-endian bytes -> value of the given type (Modbus REALSW = word-swapped)
  date types -> TDateTime, TIME / TOD -> milliseconds }
function DecodeValue(DT: TDataType; const B: TBytes; Ofs: Integer): Double;
{ group the tags into blocks: same area (and DB), sorted, holes up to Gap,
  block size up to MaxSize. Single[i] = tag i alone in its block. }
function PlanBlocks(const Addrs: array of TTagAddr; const Use, Single: array of Boolean;
  const MaxSize, Gap: array of Integer): TReadBlocks;
{ size of a tag in block units: S7 bytes, Modbus registers, Modbus coils }
function TagUnits(const A: TTagAddr): Integer;
{ value of tag A out of the data of block B }
function ExtractValue(const A: TTagAddr; const B: TReadBlock; const Data: TBytes): Double;

implementation

const
  ModbusExText: array[1..11] of string = ('illegal function', 'illegal data address', 'illegal data value',
    'slave device failure', 'acknowledge', 'slave busy', '', '', '', 'gateway path unavailable',
    'gateway target failed');

function ModbusExceptionText(Code: Byte): string;
begin
  if (Code >= 1) and (Code <= 11) and (ModbusExText[Code] <> '') then
    Result := Format('Modbus exception %d: %s', [Code, ModbusExText[Code]])
  else
    Result := Format('Modbus exception %d', [Code]);
end;

{ send small telegrams at once (no Nagle delay) }
procedure SetNoDelay(H: LongInt);
var
  One: LongInt;
begin
  One := 1;
  fpsetsockopt(H, 6 {IPPROTO_TCP}, 1 {TCP_NODELAY}, @One, SizeOf(One));
end;

function TagUnits(const A: TTagAddr): Integer;
begin
  case A.Area of
    aaCoil, aaDiscrete: Result := 1;
    aaInputReg, aaHoldingReg: Result := (DTSize[A.DT] + 1) div 2;
  else
    Result := DTSize[A.DT];             // S7 bytes (BOOL: its byte)
  end;
end;

function PlanBlocks(const Addrs: array of TTagAddr; const Use, Single: array of Boolean;
  const MaxSize, Gap: array of Integer): TReadBlocks;
var
  Idx: array of Integer;
  N, I, J, K, T, NB, TEnd: Integer;

  function Less(X, Y: Integer): Boolean;
  begin
    if Addrs[X].Area <> Addrs[Y].Area then Exit(Addrs[X].Area < Addrs[Y].Area);
    if Addrs[X].DB <> Addrs[Y].DB then Exit(Addrs[X].DB < Addrs[Y].DB);
    Result := Addrs[X].Offset < Addrs[Y].Offset;
  end;

begin
  Result := nil;
  { used tags, sorted by area / DB / offset (insertion sort: at most 64 tags) }
  N := 0;
  SetLength(Idx, Length(Addrs));
  for I := 0 to High(Addrs) do
    if Use[I] then
    begin
      J := N;
      while (J > 0) and Less(I, Idx[J - 1]) do
      begin
        Idx[J] := Idx[J - 1];
        Dec(J);
      end;
      Idx[J] := I;
      Inc(N);
    end;
  NB := 0;
  for K := 0 to N - 1 do
  begin
    T := Idx[K];
    TEnd := Addrs[T].Offset + TagUnits(Addrs[T]);
    if (NB > 0) and not Single[T] and (Result[NB - 1].Size > 0) then
      with Result[NB - 1] do
        if (Area = Addrs[T].Area) and (DB = Addrs[T].DB) and
          (Addrs[T].Offset <= Start + Size + Gap[Ord(Area)]) and
          (Max(Start + Size, TEnd) - Start <= MaxSize[Ord(Area)]) then
        begin
          Size := Max(Start + Size, TEnd) - Start;
          SetLength(Tags, Length(Tags) + 1);
          Tags[High(Tags)] := T;
          Continue;
        end;
    SetLength(Result, NB + 1);
    Result[NB].Area := Addrs[T].Area;
    Result[NB].DB := Addrs[T].DB;
    Result[NB].Start := Addrs[T].Offset;
    Result[NB].Size := TagUnits(Addrs[T]);
    Result[NB].Tags := [T];
    if Single[T] then Result[NB].Size := -Result[NB].Size;   // marker: closed for other tags
    Inc(NB);
  end;
  for I := 0 to NB - 1 do Result[I].Size := Abs(Result[I].Size);
end;

function ExtractValue(const A: TTagAddr; const B: TReadBlock; const Data: TBytes): Double;
var
  O: Integer;
begin
  O := A.Offset - B.Start;
  case A.Area of
    aaCoil, aaDiscrete:
      begin
        if O div 8 >= Length(Data) then raise EItemError.Create('response too short');
        Result := Ord((Data[O div 8] shr (O mod 8)) and 1 <> 0);
      end;
    aaInputReg, aaHoldingReg:
      begin
        if 2 * (O + TagUnits(A)) > Length(Data) then raise EItemError.Create('response too short');
        Result := DecodeValue(A.DT, Data, 2 * O);
      end;
  else
    if O + TagUnits(A) > Length(Data) then raise EItemError.Create('response too short');
    if A.DT = dtBool then Result := Ord((Data[O] shr (A.Bit and 7)) and 1 <> 0)
    else Result := DecodeValue(A.DT, Data, O);
  end;
end;

function CreateDriver(const P: TDriverParams): TPlcDriver;
begin
  case P.Protocol of
    prS7: Result := TS7Driver.Create(P);
    prModbusTCP: Result := TModbusTcpDriver.Create(P);
  else
    Result := TModbusRtuDriver.Create(P);
  end;
end;

function ModbusCrc16(const B: TBytes; Count: Integer): Word;
var
  I, J: Integer;
begin
  Result := $FFFF;
  for I := 0 to Count - 1 do
  begin
    Result := Result xor B[I];
    for J := 1 to 8 do
      if (Result and 1) <> 0 then Result := (Result shr 1) xor $A001
      else Result := Result shr 1;
  end;
end;

function DecodeValue(DT: TDataType; const B: TBytes; Ofs: Integer): Double;
var
  W: Word;
  L: LongWord;
  S: Single;
  Y, Ms: Integer;
  D: TDateTime;

  function Bcd(V: Byte): Integer;
  begin
    Result := (V shr 4) * 10 + (V and $0F);
  end;

  function BE32(P: Integer): LongWord;
  begin
    Result := (LongWord(B[P]) shl 24) or (LongWord(B[P + 1]) shl 16) or
              (LongWord(B[P + 2]) shl 8) or B[P + 3];
  end;

begin
  case DT of
    dtBool: Result := Ord(B[Ofs] <> 0);
    dtByte: Result := B[Ofs];
    dtInt, dtUInt:
      begin
        W := (Word(B[Ofs]) shl 8) or B[Ofs + 1];
        if DT = dtInt then Result := SmallInt(W) else Result := W;
      end;
    dtDate:                    // days since 1990-01-01
      Result := EncodeDate(1990, 1, 1) + ((Word(B[Ofs]) shl 8) or B[Ofs + 1]);
    dtTime: Result := LongInt(BE32(Ofs));          // ms, signed
    dtTOD: Result := BE32(Ofs);                    // ms since midnight
    dtUnixTime: Result := UnixToDateTime(BE32(Ofs), False);   // UTC seconds -> local time
    dtDT:                      // BCD: YY MM DD hh mm ss ms(3 digits) + weekday
      begin
        Y := Bcd(B[Ofs]);
        if Y >= 90 then Inc(Y, 1900) else Inc(Y, 2000);
        Ms := Bcd(B[Ofs + 6]) * 10 + (B[Ofs + 7] shr 4);
        if not TryEncodeDateTime(Y, Bcd(B[Ofs + 1]), Bcd(B[Ofs + 2]), Bcd(B[Ofs + 3]),
          Bcd(B[Ofs + 4]), Bcd(B[Ofs + 5]), Ms, D) then
          raise EItemError.Create('DT value is not a valid date');
        Result := D;
      end;
    dtDTL:                     // UINT year, month, day, weekday, hour, min, sec, UDINT ns
      begin
        Y := (Word(B[Ofs]) shl 8) or B[Ofs + 1];
        Ms := BE32(Ofs + 8) div 1000000;
        if not TryEncodeDateTime(Y, B[Ofs + 2], B[Ofs + 3], B[Ofs + 5], B[Ofs + 6], B[Ofs + 7],
          Ms, D) then
          raise EItemError.Create('DTL value is not a valid date');
        Result := D;
      end;
  else
    if DT = dtRealSw then      // CDAB: low word first
      L := (LongWord(B[Ofs + 2]) shl 24) or (LongWord(B[Ofs + 3]) shl 16) or
           (LongWord(B[Ofs]) shl 8) or B[Ofs + 1]
    else                       // ABCD: big-endian
      L := BE32(Ofs);
    case DT of
      dtDInt: Result := LongInt(L);
      dtUDInt: Result := L;
    else
      Move(L, S, 4);
      Result := S;
    end;
  end;
end;

{ TPlcDriver }

constructor TPlcDriver.Create(const P: TDriverParams);
begin
  inherited Create;
  FP := P;
end;

procedure TPlcDriver.SetTags(const Addrs: array of TTagAddr; const Use: array of Boolean);
var
  I: Integer;
begin
  SetLength(FAddrs, Length(Addrs));
  SetLength(FUse, Length(Addrs));
  SetLength(FSingle, 0);
  SetLength(FSingle, Length(Addrs));
  for I := 0 to High(Addrs) do
  begin
    FAddrs[I] := Addrs[I];
    FUse[I] := Use[I];
  end;
  FPlanned := False;
end;

procedure TPlcDriver.Plan;
var
  MaxSize, Gap: array of Integer;
  A: TAddrArea;
begin
  SetLength(MaxSize, Ord(High(TAddrArea)) + 1);
  SetLength(Gap, Ord(High(TAddrArea)) + 1);
  for A := Low(TAddrArea) to High(TAddrArea) do
  begin
    MaxSize[Ord(A)] := MaxBlock(A);
    Gap[Ord(A)] := MaxGap(A);
  end;
  FBlocks := PlanBlocks(FAddrs, FUse, FSingle, MaxSize, Gap);
  FPlanned := True;
end;

function TPlcDriver.MaxBlock(Area: TAddrArea): Integer;
begin
  Result := 0;          // no merging
end;

function TPlcDriver.MaxGap(Area: TAddrArea): Integer;
begin
  Result := 0;
end;

procedure TPlcDriver.ReadBlock(const B: TReadBlock; out Data: TBytes);
begin
  raise EItemError.Create('block read not supported');
end;

procedure TPlcDriver.ReadBlocks(var Data: array of TBytes; var Errs: array of string);
var
  I: Integer;
begin
  for I := 0 to High(FBlocks) do
  begin
    Errs[I] := '';
    try
      Inc(FRequests);
      ReadBlock(FBlocks[I], Data[I]);
    except
      on E: EItemError do Errs[I] := E.Message;
    end;
  end;
end;

procedure TPlcDriver.ReadAll(var Vals: TTagValues);
var
  Data: array of TBytes;
  Errs: array of string;
  B, K, T, Req: Integer;
  Split: Boolean;
begin
  if not FPlanned then Plan;
  FRequests := 0;
  SetLength(Data, Length(FBlocks));
  SetLength(Errs, Length(FBlocks));
  ReadBlocks(Data, Errs);
  Split := False;
  for B := 0 to High(FBlocks) do
    if Errs[B] <> '' then
    begin
      if Length(FBlocks[B].Tags) > 1 then
      begin
        { refused block of several tags: read them one by one from now on }
        for K := 0 to High(FBlocks[B].Tags) do FSingle[FBlocks[B].Tags[K]] := True;
        Split := True;
      end
      else
      begin
        T := FBlocks[B].Tags[0];
        Vals[T].Ok := False;
        Vals[T].Err := Errs[B];
      end;
    end
    else
      for K := 0 to High(FBlocks[B].Tags) do
      begin
        T := FBlocks[B].Tags[K];
        try
          Vals[T].Value := ExtractValue(FAddrs[T], FBlocks[B], Data[B]);
          Vals[T].Ok := True;
          Vals[T].Err := '';
        except
          on E: Exception do
          begin
            Vals[T].Ok := False;
            Vals[T].Err := E.Message;
          end;
        end;
      end;
  if Split then
  begin
    Req := FRequests;
    FPlanned := False;
    ReadAll(Vals);
    Inc(FRequests, Req);
  end;
end;

{ ============================== S7 ===================================== }

constructor TS7Driver.Create(const P: TDriverParams);
begin
  inherited Create(P);
  FClient := TS7Client.Create;
end;

destructor TS7Driver.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

procedure TS7Driver.Connect;
begin
  FClient.Connect(FP.Host, FP.Rack, FP.Slot, FP.TimeoutMs);
  FPlanned := False;          // block size depends on the PDU size of this PLC
end;

procedure TS7Driver.Disconnect;
begin
  FClient.Disconnect;
end;

function TS7Driver.Connected: Boolean;
begin
  Result := FClient.Connected;
end;

function TS7Driver.ReadTag(const A: TTagAddr): Double;
const
  AreaCode: array[aaS7I..aaS7DB] of Byte = (S7AreaPE, S7AreaPA, S7AreaMK, S7AreaDB);
var
  B: TBytes;
  DB: Integer;
begin
  if not (A.Area in [aaS7I..aaS7DB]) then raise EItemError.Create('not an S7 address');
  if A.Area = aaS7DB then DB := A.DB else DB := 0;
  try
    if A.DT = dtBool then
      Exit(Ord(FClient.ReadBit(AreaCode[A.Area], DB, A.Offset, A.Bit)));
    FClient.ReadArea(AreaCode[A.Area], DB, A.Offset, DTSize[A.DT], B);
  except
    on E: ES7ItemError do raise EItemError.Create(E.Message);   // the PLC refused this address
  end;
  Result := DecodeValue(A.DT, B, 0);
end;

const
  S7AreaCode: array[aaS7I..aaS7DB] of Byte = (S7AreaPE, S7AreaPA, S7AreaMK, S7AreaDB);

function TS7Driver.MaxBlock(Area: TAddrArea): Integer;
begin
  if FClient.PDULength > 0 then Result := FClient.PDULength - 18   // one item in one PDU
  else Result := 222;
end;

function TS7Driver.MaxGap(Area: TAddrArea): Integer;
begin
  Result := 32;        // reading up to 32 unused bytes is cheaper than one more item
end;

procedure TS7Driver.ReadBlock(const B: TReadBlock; out Data: TBytes);
begin
  try
    FClient.ReadArea(S7AreaCode[B.Area], B.DB, B.Start, B.Size, Data);
  except
    on E: ES7ItemError do raise EItemError.Create(E.Message);
  end;
end;

{ pack as many blocks as fit into one request (multi-item read) }
procedure TS7Driver.ReadBlocks(var Data: array of TBytes; var Errs: array of string);
var
  I, J, K, Sum: Integer;
  Items: array of TS7ReadItem;
  Codes: array of Byte;
  Part: array of TBytes;
  What: string;
begin
  if FNoMulti then
  begin
    inherited ReadBlocks(Data, Errs);
    Exit;
  end;
  I := 0;
  while I <= High(FBlocks) do
  begin
    J := I;
    Sum := 0;
    while (J <= High(FBlocks)) and MultiReadFits(FClient.PDULength, J - I + 1, Sum + FBlocks[J].Size) do
    begin
      Inc(Sum, FBlocks[J].Size);
      Inc(J);
    end;
    if J = I then
    begin
      { block too big for a multi read: alone (ReadArea splits it into PDU chunks) }
      Errs[I] := '';
      Inc(FRequests);
      try
        ReadBlock(FBlocks[I], Data[I]);
      except
        on E: EItemError do Errs[I] := E.Message;
      end;
      Inc(I);
      Continue;
    end;
    SetLength(Items, J - I);
    SetLength(Codes, J - I);
    SetLength(Part, J - I);
    for K := 0 to J - I - 1 do
      with FBlocks[I + K] do
      begin
        Items[K].Area := S7AreaCode[Area];
        if Area = aaS7DB then Items[K].DB := DB else Items[K].DB := 0;
        Items[K].Start := Start;
        Items[K].Size := Size;
      end;
    Inc(FRequests);
    try
      FClient.ReadMulti(Items, Part, Codes);
    except
      on E: ES7Refused do
        if J - I > 1 then
        begin
          { this PLC does not take several items: one block per request from now on }
          FNoMulti := True;
          inherited ReadBlocks(Data, Errs);
          Exit;
        end
        else
          raise;
    end;
    for K := 0 to J - I - 1 do
    begin
      Data[I + K] := Part[K];
      if Codes[K] = $FF then
        Errs[I + K] := ''
      else
      begin
        if FBlocks[I + K].Area = aaS7DB then
          What := Format('DB%d.DBB%d', [FBlocks[I + K].DB, FBlocks[I + K].Start]) + ' (DB missing / too short / optimized?)'
        else
          What := Format('byte %d', [FBlocks[I + K].Start]);
        Errs[I + K] := Format('PLC refused the read of %s, item code %.2x', [What, Codes[K]]);
      end;
    end;
    I := J;
  end;
end;

function TS7Driver.Description: string;
begin
  Result := Format('S7 %s rack %d slot %d', [FP.Host, FP.Rack, FP.Slot]);
end;

{ ============================== Modbus (common) ======================== }

function TModbusDriver.ReadTag(const A: TTagAddr): Double;
const
  ExText: array[1..11] of string = ('illegal function', 'illegal data address', 'illegal data value',
    'slave device failure', 'acknowledge', 'slave busy', '', '', '', 'gateway path unavailable',
    'gateway target failed');
var
  Fc: Byte;
  Qty: Integer;
  Req, Res: TBytes;
  Code: Byte;
begin
  case A.Area of
    aaCoil: Fc := 1;
    aaDiscrete: Fc := 2;
    aaInputReg: Fc := 4;
    aaHoldingReg: Fc := 3;
  else
    raise EItemError.Create('not a Modbus address');
  end;
  if Fc <= 2 then Qty := 1 else Qty := (DTSize[A.DT] + 1) div 2;
  Req := TBytes.Create(Fc, Hi(Word(A.Offset)), Lo(Word(A.Offset)), Hi(Word(Qty)), Lo(Word(Qty)));
  Res := Transact(Req);
  if Length(Res) < 2 then raise Exception.Create('Modbus response too short');
  if Res[0] = Fc or $80 then
  begin
    Code := Res[1];
    if (Code >= 1) and (Code <= 11) and (ExText[Code] <> '') then
      raise EItemError.CreateFmt('Modbus exception %d: %s', [Code, ExText[Code]])
    else
      raise EItemError.CreateFmt('Modbus exception %d', [Code]);
  end;
  if Res[0] <> Fc then raise Exception.Create('Modbus response: wrong function code');
  if Fc <= 2 then
  begin
    if Length(Res) < 3 then raise Exception.Create('Modbus response too short');
    Result := Res[2] and 1;
  end
  else
  begin
    if (Res[1] <> Qty * 2) or (Length(Res) < 2 + Qty * 2) then
      raise Exception.Create('Modbus response: wrong byte count');
    Result := DecodeValue(A.DT, Res, 2);
  end;
end;

function TModbusDriver.MaxBlock(Area: TAddrArea): Integer;
begin
  if Area in [aaCoil, aaDiscrete] then Result := 2000 else Result := 125;   // Modbus limits
end;

function TModbusDriver.MaxGap(Area: TAddrArea): Integer;
begin
  if Area in [aaCoil, aaDiscrete] then Result := 32 else Result := 8;
end;

procedure TModbusDriver.ReadBlock(const B: TReadBlock; out Data: TBytes);
var
  Fc: Byte;
  Res: TBytes;
  Count: Integer;
begin
  case B.Area of
    aaCoil: Fc := 1;
    aaDiscrete: Fc := 2;
    aaInputReg: Fc := 4;
  else
    Fc := 3;
  end;
  Res := Transact(TBytes.Create(Fc, Hi(Word(B.Start)), Lo(Word(B.Start)), Hi(Word(B.Size)), Lo(Word(B.Size))));
  if Length(Res) < 2 then raise Exception.Create('Modbus response too short');
  if Res[0] = Fc or $80 then raise EItemError.Create(ModbusExceptionText(Res[1]));
  if Res[0] <> Fc then raise Exception.Create('Modbus response: wrong function code');
  if Fc <= 2 then Count := (B.Size + 7) div 8 else Count := B.Size * 2;
  if (Res[1] <> Count) or (Length(Res) < 2 + Count) then
    raise Exception.Create('Modbus response: wrong byte count');
  Data := Copy(Res, 2, Count);
end;

{ ============================== Modbus TCP ============================= }

destructor TModbusTcpDriver.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

procedure TModbusTcpDriver.Connect;
begin
  Disconnect;
  FSock := TInetSocket.Create(FP.Host, FP.Port, FP.TimeoutMs);
  FSock.IOTimeout := FP.TimeoutMs;
  SetNoDelay(FSock.Handle);
end;

procedure TModbusTcpDriver.Disconnect;
begin
  FreeAndNil(FSock);
end;

function TModbusTcpDriver.Connected: Boolean;
begin
  Result := FSock <> nil;
end;

procedure TModbusTcpDriver.RecvExact(var Buf; Count: Integer);
var
  P: PByte;
  Got, N: Integer;
begin
  P := @Buf;
  Got := 0;
  while Got < Count do
  begin
    N := FSock.Read(P[Got], Count - Got);
    if N <= 0 then raise Exception.Create('Modbus TCP: receive timeout / connection closed');
    Inc(Got, N);
  end;
end;

function TModbusTcpDriver.Transact(const Pdu: TBytes): TBytes;
var
  Q: TBytes;
  Hdr: array[0..6] of Byte;
  Len: Integer;
begin
  if FSock = nil then raise Exception.Create('not connected');
  Inc(FTid);
  { MBAP header: transaction id, protocol 0, length, unit id }
  Q := TBytes.Create(Hi(FTid), Lo(FTid), 0, 0, Hi(Word(Length(Pdu) + 1)), Lo(Word(Length(Pdu) + 1)),
    Byte(FP.UnitId));
  Q := Concat(Q, Pdu);
  if FSock.Write(Q[0], Length(Q)) <> Length(Q) then raise Exception.Create('Modbus TCP: send error');
  RecvExact(Hdr, 7);
  Len := (Hdr[4] shl 8) or Hdr[5];
  if (Len < 2) or (Len > 260) then raise Exception.Create('Modbus TCP: invalid length');
  if (Hdr[0] <> Hi(FTid)) or (Hdr[1] <> Lo(FTid)) then
    raise Exception.Create('Modbus TCP: transaction id mismatch');
  Result := nil;
  SetLength(Result, Len - 1);
  RecvExact(Result[0], Len - 1);
end;

function TModbusTcpDriver.Description: string;
begin
  Result := Format('Modbus TCP %s:%d unit %d', [FP.Host, FP.Port, FP.UnitId]);
end;

{ ============================== Modbus RTU (RS485) ===================== }

destructor TModbusRtuDriver.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

procedure TModbusRtuDriver.Connect;
var
  Par: TParityType;
  Dev: string;
begin
  Disconnect;
  {$IFDEF WINDOWS}
  Dev := '\\.\' + FP.ComPort;           // needed for COM10 and higher
  {$ELSE}
  Dev := FP.ComPort;                    // e.g. /dev/ttyUSB0
  {$ENDIF}
  FHandle := SerOpen(Dev);
  if FHandle = 0 then raise Exception.CreateFmt('cannot open %s', [FP.ComPort]);
  case UpCase(FP.Parity) of
    'E': Par := EvenParity;
    'O': Par := OddParity;
  else
    Par := NoneParity;
  end;
  SerSetParams(FHandle, FP.Baud, FP.DataBits, Par, FP.StopBits, []);
end;

procedure TModbusRtuDriver.Disconnect;
begin
  if FHandle <> 0 then SerClose(FHandle);
  FHandle := 0;
end;

function TModbusRtuDriver.Connected: Boolean;
begin
  Result := FHandle <> 0;
end;

function TModbusRtuDriver.ReadBytes(var Buf: TBytes; Ofs, Count: Integer; Deadline: QWord): Boolean;
var
  Tmp: array[0..259] of Byte;
  N, Left: Integer;
begin
  while Count > 0 do
  begin
    if GetTickCount64 >= Deadline then Exit(False);
    Left := Deadline - GetTickCount64;
    N := SerReadTimeout(FHandle, Tmp, Count, Left);
    if N > 0 then
    begin
      Move(Tmp[0], Buf[Ofs], N);
      Inc(Ofs, N);
      Dec(Count, N);
    end;
  end;
  Result := True;
end;

function TModbusRtuDriver.Transact(const Pdu: TBytes): TBytes;
var
  Frame, R: TBytes;
  Crc: Word;
  Deadline: QWord;
  Need: Integer;
begin
  if FHandle = 0 then raise Exception.Create('not connected');
  { frame = slave id + PDU + CRC (low byte first) }
  Frame := Concat(TBytes.Create(Byte(FP.UnitId)), Pdu);
  Crc := ModbusCrc16(Frame, Length(Frame));
  Frame := Concat(Frame, TBytes.Create(Lo(Crc), Hi(Crc)));
  { silent interval of 3.5 characters between frames }
  Sleep(1 + (38500 div FP.Baud));
  SerFlushInput(FHandle);
  if SerWrite(FHandle, Frame[0], Length(Frame)) <> Length(Frame) then
    raise Exception.Create('RS485: send error');
  R := nil;
  SetLength(R, 260);
  Deadline := GetTickCount64 + QWord(FP.TimeoutMs);
  { slave id + function code first, then the rest depends on the function }
  if not ReadBytes(R, 0, 3, Deadline) then
    raise Exception.CreateFmt('RS485: no answer from slave %d (timeout)', [FP.UnitId]);
  if R[0] <> FP.UnitId then raise Exception.Create('RS485: answer from wrong slave id');
  if (R[1] and $80) <> 0 then
    Need := 5                                  // exception: id fc code crc crc
  else
    Need := 3 + R[2] + 2;                      // id fc count data.. crc crc
  if not ReadBytes(R, 3, Need - 3, Deadline) then
    raise Exception.Create('RS485: answer incomplete (timeout)');
  Crc := ModbusCrc16(R, Need - 2);
  if (R[Need - 2] <> Lo(Crc)) or (R[Need - 1] <> Hi(Crc)) then
    raise Exception.Create('RS485: CRC error');
  Result := Copy(R, 1, Need - 3);              // PDU without id and CRC
end;

function TModbusRtuDriver.Description: string;
begin
  Result := Format('Modbus RTU %s %d %d%s%d slave %d',
    [FP.ComPort, FP.Baud, FP.DataBits, FP.Parity, FP.StopBits, FP.UnitId]);
end;

end.
