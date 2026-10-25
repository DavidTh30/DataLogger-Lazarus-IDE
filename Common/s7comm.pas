{ ============================================================================
  s7comm - minimal Siemens S7 (ISO-on-TCP / S7comm) client
  Supports: connect (rack/slot), DB read, DB write, DB bit write.
  Works with S7-1200/1500 when
    - the DB is "standard access" (Optimized block access = off)
    - PUT/GET access is permitted in the CPU protection settings
  ============================================================================ }
unit s7comm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ssockets, sockets;

type
  ES7Error = class(Exception);
  { the PLC answered, but does not offer this SZL (the connection itself is fine) }
  ES7SzlError = class(ES7Error);
  { the PLC answered, but does not offer this function (e.g. reading its clock) }
  ES7NotSupported = class(ES7Error);
  { the PLC answered, but refused this read / write item (address not available) }
  ES7ItemError = class(ES7Error);
  { the PLC answered the whole request with an error class (e.g. a function it does not support) }
  ES7Refused = class(ES7Error);

  { one item of a multi-item read (ReadMulti) }
  TS7ReadItem = record
    Area: Byte;
    DB, Start, Size: Integer;
  end;
const
  S7_MAX_ITEMS = 20;   // S7-1200 / 1500 accept at most 20 items per request

{ True when Count items with SumSize data bytes fit request + response of one PDU }
function MultiReadFits(PDULength, Count, SumSize: Integer): Boolean;

type
  { CPU operating mode (SZL 0x0424) }
  TS7CpuStatus = (csUnknown, csRun, csStop);

const
  { memory areas for ReadArea / ReadBit }
  S7AreaPE = $81;   // inputs  I
  S7AreaPA = $82;   // outputs Q
  S7AreaMK = $83;   // markers M
  S7AreaDB = $84;   // data blocks DB

type

  { TS7Client }

  TS7Client = class
  private
    FSock: TInetSocket;
    FPDULength: Integer;
    FPDURef: Word;
    procedure SendBytes(const B: TBytes);
    procedure RecvExact(var Buf; Count: Integer);
    function RecvTPKT: TBytes;
    function Exchange(const B: TBytes): TBytes;
    function NextRef: Word;
    procedure SetNoDelay;
    procedure CheckS7Header(const R: TBytes; MinLen: Integer);
    procedure ReadChunk(Area: Byte; DB, Start, Size: Integer; var Buf: TBytes; BufOfs: Integer);
    procedure WriteChunk(DB, Start: Integer; const Data: TBytes; DataOfs, Size: Integer);
  public
    destructor Destroy; override;
    procedure Connect(const AHost: string; ARack, ASlot, ATimeoutMs: Integer);
    procedure Disconnect;
    function Connected: Boolean;
    { read Size bytes from DB starting at byte Start into Buf[0..Size-1] }
    procedure DBRead(DB, Start, Size: Integer; out Buf: TBytes);
    procedure DBWrite(DB, Start: Integer; const Data: TBytes);
    procedure DBWriteBit(DB, ByteOfs, Bit: Integer; Value: Boolean);
    { read a system status list (SZL); returns the data records (without the 8-byte SZL header) }
    function ReadSZL(ID, Index: Word): TBytes;
    { RUN / STOP of the CPU, works with any PLC program }
    function GetCpuStatus: TS7CpuStatus;
    { read Size bytes of an area (S7AreaPE / PA / MK / DB; DB = 0 except for S7AreaDB) }
    procedure ReadArea(Area: Byte; DB, Start, Size: Integer; out Buf: TBytes);
    { one bit, e.g. I0.1 = ReadBit(S7AreaPE, 0, 0, 1) }
    function ReadBit(Area: Byte; DB, ByteOfs, Bit: Integer): Boolean;
    { date and time of the CPU clock (S7 time functions); raises ES7NotSupported if the PLC has none }
    function GetPlcClock: TDateTime;
    { several areas in ONE request / response (S7 read var with n items).
      Codes[i] = $FF ok, else the item error code (Data[i] empty).
      The caller keeps the request inside the PDU: MultiReadFits. }
    procedure ReadMulti(const Items: array of TS7ReadItem; var Data: array of TBytes;
      var Codes: array of Byte);    property PDULength: Integer read FPDULength;
  end;

{ big-endian helpers (S7 byte order) }
function S7GetReal(const B: TBytes; Ofs: Integer): Single;
procedure S7SetReal(var B: TBytes; Ofs: Integer; V: Single);
function S7GetInt(const B: TBytes; Ofs: Integer): SmallInt;
procedure S7SetInt(var B: TBytes; Ofs: Integer; V: SmallInt);
function S7GetBit(const B: TBytes; Ofs, Bit: Integer): Boolean;

implementation

const
  ISO_TCP_PORT = 102;
  AREA_DB = $84;
  TS_BIT = $01;
  TS_BYTE = $02;

function HB(V: Integer): Byte; inline;
begin
  Result := (V shr 8) and $FF;
end;

function LB(V: Integer): Byte; inline;
begin
  Result := V and $FF;
end;

function MultiReadFits(PDULength, Count, SumSize: Integer): Boolean;
begin
  { request: S7 header 10 + 2 + 12 per item; response: header 12 + 2 + per item 4 + data (+ pad) }
  Result := (Count <= S7_MAX_ITEMS) and (12 + 12 * Count <= PDULength) and
    (14 + 5 * Count + SumSize <= PDULength);
end;

function S7GetReal(const B: TBytes; Ofs: Integer): Single;
var
  C: LongWord;
begin
  C := (LongWord(B[Ofs]) shl 24) or (LongWord(B[Ofs + 1]) shl 16) or
       (LongWord(B[Ofs + 2]) shl 8) or LongWord(B[Ofs + 3]);
  Move(C, Result, 4);
end;

procedure S7SetReal(var B: TBytes; Ofs: Integer; V: Single);
var
  C: LongWord;
begin
  Move(V, C, 4);
  B[Ofs] := (C shr 24) and $FF;
  B[Ofs + 1] := (C shr 16) and $FF;
  B[Ofs + 2] := (C shr 8) and $FF;
  B[Ofs + 3] := C and $FF;
end;

function S7GetInt(const B: TBytes; Ofs: Integer): SmallInt;
begin
  Result := SmallInt((Word(B[Ofs]) shl 8) or B[Ofs + 1]);
end;

procedure S7SetInt(var B: TBytes; Ofs: Integer; V: SmallInt);
begin
  B[Ofs] := (Word(V) shr 8) and $FF;
  B[Ofs + 1] := Word(V) and $FF;
end;

function S7GetBit(const B: TBytes; Ofs, Bit: Integer): Boolean;
begin
  Result := (B[Ofs] and (1 shl Bit)) <> 0;
end;

{ TS7Client }

destructor TS7Client.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

function TS7Client.Connected: Boolean;
begin
  Result := FSock <> nil;
end;

procedure TS7Client.Disconnect;
begin
  FreeAndNil(FSock);
end;

{ small request / response telegrams: send at once (no Nagle delay) }
procedure TS7Client.SetNoDelay;
var
  One: LongInt;
begin
  One := 1;
  fpsetsockopt(FSock.Handle, 6 {IPPROTO_TCP}, 1 {TCP_NODELAY}, @One, SizeOf(One));
end;

procedure TS7Client.ReadMulti(const Items: array of TS7ReadItem; var Data: array of TBytes;
  var Codes: array of Byte);
var
  Q, R: TBytes;
  N, I, P, Len, Total: Integer;
  Addr: LongWord;
  Ref: Word;
begin
  N := Length(Items);
  if N = 0 then Exit;
  Ref := NextRef;
  Total := 4 + 3 + 10 + 2 + 12 * N;
  SetLength(Q, Total);
  Q[0] := $03; Q[1] := $00; Q[2] := HB(Total); Q[3] := LB(Total);
  Q[4] := $02; Q[5] := $F0; Q[6] := $80;
  Q[7] := $32; Q[8] := $01; Q[9] := 0; Q[10] := 0; Q[11] := Hi(Ref); Q[12] := Lo(Ref);
  Q[13] := HB(2 + 12 * N); Q[14] := LB(2 + 12 * N); Q[15] := 0; Q[16] := 0;
  Q[17] := $04; Q[18] := N;                                // read var, n items
  for I := 0 to N - 1 do
  begin
    P := 19 + 12 * I;
    Addr := LongWord(Items[I].Start) * 8;
    Q[P] := $12; Q[P + 1] := $0A; Q[P + 2] := $10; Q[P + 3] := TS_BYTE;
    Q[P + 4] := HB(Items[I].Size); Q[P + 5] := LB(Items[I].Size);
    Q[P + 6] := HB(Items[I].DB); Q[P + 7] := LB(Items[I].DB);
    Q[P + 8] := Items[I].Area;
    Q[P + 9] := (Addr shr 16) and $FF; Q[P + 10] := (Addr shr 8) and $FF; Q[P + 11] := Addr and $FF;
  end;
  R := Exchange(Q);
  CheckS7Header(R, 21);
  if (R[19] <> $04) or (R[20] <> N) then raise ES7Error.Create('Read response: wrong item count');
  P := 21;
  for I := 0 to N - 1 do
  begin
    if P + 4 > Length(R) then raise ES7Error.Create('Read response truncated');
    Codes[I] := R[P];
    Len := (R[P + 2] shl 8) or R[P + 3];
    if R[P + 1] in [$03, $04, $05] then Len := (Len + 7) div 8;   // length given in bits
    Data[I] := nil;
    if Codes[I] = $FF then
    begin
      if P + 4 + Len > Length(R) then raise ES7Error.Create('Read response truncated');
      SetLength(Data[I], Len);
      if Len > 0 then Move(R[P + 4], Data[I][0], Len);
    end
    else
      Len := 0;
    P := P + 4 + Len;
    if Odd(Len) and (I < N - 1) then Inc(P);                 // fill byte between items
  end;
end;

function TS7Client.NextRef: Word;
begin
  Inc(FPDURef);
  if FPDURef = 0 then FPDURef := 1;
  Result := FPDURef;
end;

procedure TS7Client.SendBytes(const B: TBytes);
var
  Sent, N: Integer;
begin
  Sent := 0;
  while Sent < Length(B) do
  begin
    N := FSock.Write(B[Sent], Length(B) - Sent);
    if N <= 0 then raise ES7Error.Create('Socket send error');
    Inc(Sent, N);
  end;
end;

procedure TS7Client.RecvExact(var Buf; Count: Integer);
var
  P: PByte;
  Got, N: Integer;
begin
  P := @Buf;
  Got := 0;
  while Got < Count do
  begin
    N := FSock.Read(P[Got], Count - Got);
    if N <= 0 then raise ES7Error.Create('Socket receive timeout / connection closed');
    Inc(Got, N);
  end;
end;

function TS7Client.RecvTPKT: TBytes;
var
  Hdr: array[0..3] of Byte;
  Len: Integer;
begin
  RecvExact(Hdr, 4);
  if Hdr[0] <> 3 then raise ES7Error.Create('Invalid TPKT header');
  Len := (Hdr[2] shl 8) or Hdr[3];
  if (Len < 7) or (Len > 4096) then raise ES7Error.Create('Invalid TPKT length');
  SetLength(Result, Len);
  Move(Hdr, Result[0], 4);
  RecvExact(Result[4], Len - 4);
end;

function TS7Client.Exchange(const B: TBytes): TBytes;
begin
  if FSock = nil then raise ES7Error.Create('Not connected');
  SendBytes(B);
  Result := RecvTPKT;
end;

procedure TS7Client.CheckS7Header(const R: TBytes; MinLen: Integer);
begin
  if Length(R) < MinLen then raise ES7Error.Create('S7 response too short');
  if R[7] <> $32 then raise ES7Error.Create('Invalid S7 protocol id');
  if (R[17] <> 0) or (R[18] <> 0) then
    raise ES7Refused.CreateFmt('S7 error class %.2x code %.2x', [R[17], R[18]]);
end;

procedure TS7Client.Connect(const AHost: string; ARack, ASlot, ATimeoutMs: Integer);
var
  CR, Setup, R: TBytes;
  RemoteTSAP: Word;
begin
  Disconnect;
  FSock := TInetSocket.Create(AHost, ISO_TCP_PORT, ATimeoutMs);
  try
    FSock.IOTimeout := ATimeoutMs;
    SetNoDelay;
    { --- COTP connection request --- }
    RemoteTSAP := $0100 + (ARack * $20) + ASlot;   // $01xx = PG connection
    CR := TBytes.Create(
      $03, $00, $00, $16,                 // TPKT, length 22
      $11, $E0, $00, $00, $00, $01, $00,  // COTP CR
      $C0, $01, $0A,                      // TPDU size 1024
      $C1, $02, $01, $00,                 // calling TSAP
      $C2, $02, Hi(RemoteTSAP), Lo(RemoteTSAP)); // called TSAP
    R := Exchange(CR);
    if (Length(R) < 6) or (R[5] <> $D0) then
      raise ES7Error.Create('ISO connection refused (check rack/slot)');
    { --- S7 setup communication --- }
    Setup := TBytes.Create(
      $03, $00, $00, $19,
      $02, $F0, $80,
      $32, $01, $00, $00, $00, $00, $00, $08, $00, $00,
      $F0, $00, $00, $01, $00, $01, $03, $C0);   // request PDU 960
    R := Exchange(Setup);
    CheckS7Header(R, 27);
    FPDULength := (R[25] shl 8) or R[26];
    if FPDULength < 64 then raise ES7Error.Create('Invalid negotiated PDU length');
  except
    Disconnect;
    raise;
  end;
end;

procedure TS7Client.ReadChunk(Area: Byte; DB, Start, Size: Integer; var Buf: TBytes; BufOfs: Integer);
var
  Q, R: TBytes;
  Addr: LongWord;
  Ref: Word;
begin
  Ref := NextRef;
  Addr := LongWord(Start) * 8;
  Q := TBytes.Create(
    $03, $00, $00, $1F,
    $02, $F0, $80,
    $32, $01, $00, $00, Hi(Ref), Lo(Ref), $00, $0E, $00, $00,
    $04, $01,                                   // read var, 1 item
    $12, $0A, $10, TS_BYTE,
    HB(Size), LB(Size), HB(DB), LB(DB), Area,
    (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF);
  R := Exchange(Q);
  CheckS7Header(R, 25);
  if R[21] <> $FF then
    if Area = AREA_DB then
      raise ES7ItemError.CreateFmt('Read DB%d.DBB%d failed, item code %.2x ' +
        '(DB missing / optimized / PUT-GET disabled?)', [DB, Start, R[21]])
    else
      raise ES7ItemError.CreateFmt('Read area %.2x byte %d failed, item code %.2x', [Area, Start, R[21]]);
  if Length(R) < 25 + Size then raise ES7Error.Create('Read response truncated');
  Move(R[25], Buf[BufOfs], Size);
end;

procedure TS7Client.WriteChunk(DB, Start: Integer; const Data: TBytes; DataOfs, Size: Integer);
var
  Q, R: TBytes;
  Addr: LongWord;
  Ref: Word;
  Total, DataLen, Bits: Integer;
begin
  Ref := NextRef;
  Addr := LongWord(Start) * 8;
  DataLen := 4 + Size;
  Total := 4 + 3 + 10 + 14 + DataLen;
  Bits := Size * 8;
  Q := TBytes.Create(
    $03, $00, HB(Total), LB(Total),
    $02, $F0, $80,
    $32, $01, $00, $00, Hi(Ref), Lo(Ref), $00, $0E, HB(DataLen), LB(DataLen),
    $05, $01,                                   // write var, 1 item
    $12, $0A, $10, TS_BYTE,
    HB(Size), LB(Size), HB(DB), LB(DB), AREA_DB,
    (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF,
    $00, $04, HB(Bits), LB(Bits));              // data header, length in bits
  SetLength(Q, Total);
  Move(Data[DataOfs], Q[Total - Size], Size);
  R := Exchange(Q);
  CheckS7Header(R, 22);
  if R[21] <> $FF then
    raise ES7Error.CreateFmt('Write DB%d.DBB%d failed, item code %.2x', [DB, Start, R[21]]);
end;

procedure TS7Client.DBRead(DB, Start, Size: Integer; out Buf: TBytes);
begin
  ReadArea(AREA_DB, DB, Start, Size, Buf);
end;

function TS7Client.ReadBit(Area: Byte; DB, ByteOfs, Bit: Integer): Boolean;
var
  B: TBytes;
begin
  ReadArea(Area, DB, ByteOfs, 1, B);
  Result := (B[0] and (1 shl (Bit and 7))) <> 0;
end;

function TS7Client.GetPlcClock: TDateTime;
var
  Q, R: TBytes;
  Ref: Word;
  PLen, D, Y, Ms: Integer;

  function Bcd(V: Byte): Integer;
  begin
    Result := (V shr 4) * 10 + (V and $0F);
  end;

begin
  Ref := NextRef;
  { userdata PDU: time functions (group 7), read clock (subfunction 1) }
  Q := TBytes.Create(
    $03, $00, $00, $1D,
    $02, $F0, $80,
    $32, $07, $00, $00, Hi(Ref), Lo(Ref), $00, $08, $00, $04,
    $00, $01, $12, $04, $11, $47, $01, $00,
    $0A, $00, $00, $00);
  R := Exchange(Q);
  if (Length(R) < 17) or (R[7] <> $32) then raise ES7Error.Create('Invalid clock response');
  PLen := (R[13] shl 8) or R[14];
  D := 17 + PLen;
  if (Length(R) < D + 14) or (R[D] <> $FF) then
    raise ES7NotSupported.Create('reading the clock is not supported by this PLC');
  { 10 BCD bytes: reserved, year (2 bytes), month, day, hour, min, sec, ms (12 bit) + weekday }
  D := D + 4;
  Y := Bcd(R[D + 1]) * 100 + Bcd(R[D + 2]);
  if Y < 100 then if Y >= 90 then Inc(Y, 1900) else Inc(Y, 2000);
  Ms := Bcd(R[D + 8]) * 10 + (R[D + 9] shr 4);
  Result := EncodeDate(Y, Bcd(R[D + 3]), Bcd(R[D + 4])) +
            EncodeTime(Bcd(R[D + 5]), Bcd(R[D + 6]), Bcd(R[D + 7]), Ms);
end;

procedure TS7Client.ReadArea(Area: Byte; DB, Start, Size: Integer; out Buf: TBytes);
var
  MaxChunk, Done, N: Integer;
begin
  Buf := nil;
  SetLength(Buf, Size);
  MaxChunk := FPDULength - 18;
  Done := 0;
  while Done < Size do
  begin
    N := Size - Done;
    if N > MaxChunk then N := MaxChunk;
    ReadChunk(Area, DB, Start + Done, N, Buf, Done);
    Inc(Done, N);
  end;
end;

procedure TS7Client.DBWrite(DB, Start: Integer; const Data: TBytes);
var
  MaxChunk, Done, N: Integer;
begin
  MaxChunk := FPDULength - 35;
  Done := 0;
  while Done < Length(Data) do
  begin
    N := Length(Data) - Done;
    if N > MaxChunk then N := MaxChunk;
    WriteChunk(DB, Start + Done, Data, Done, N);
    Inc(Done, N);
  end;
end;

function TS7Client.ReadSZL(ID, Index: Word): TBytes;
var
  Q, R: TBytes;
  Ref: Word;
  PLen, D, N: Integer;
begin
  Ref := NextRef;
  { userdata PDU: CPU functions (group 4), read SZL (subfunction 1) }
  Q := TBytes.Create(
    $03, $00, $00, $21,
    $02, $F0, $80,
    $32, $07, $00, $00, Hi(Ref), Lo(Ref), $00, $08, $00, $08,
    $00, $01, $12, $04, $11, $44, $01, $00,
    $FF, $09, $00, $04, Hi(ID), Lo(ID), Hi(Index), Lo(Index));
  R := Exchange(Q);
  if (Length(R) < 17) or (R[7] <> $32) then raise ES7Error.Create('Invalid SZL response');
  PLen := (R[13] shl 8) or R[14];
  D := 17 + PLen;                              // start of the data part
  if (Length(R) < D + 12) or (R[D] <> $FF) then
    raise ES7SzlError.CreateFmt('SZL %.4x not available', [ID]);
  N := ((R[D + 2] shl 8) or R[D + 3]) - 8;     // data length minus SZL header
  if (N < 0) or (Length(R) < D + 12 + N) then raise ES7Error.Create('SZL response truncated');
  Result := Copy(R, D + 12, N);
end;

function TS7Client.GetCpuStatus: TS7CpuStatus;
var
  B: TBytes;
begin
  { record of SZL 0x0424: ereig(2) ae(1) bzu-id(1) ...; RUN is always $08,
    STOP is $04 (older CPUs $03) - same rule as Snap7 }
  B := ReadSZL($0424, $0000);
  if Length(B) < 4 then Exit(csUnknown);
  case B[3] of
    $00: Result := csUnknown;
    $08: Result := csRun;
  else
    Result := csStop;
  end;
end;

procedure TS7Client.DBWriteBit(DB, ByteOfs, Bit: Integer; Value: Boolean);
var
  Q, R: TBytes;
  Addr: LongWord;
  Ref: Word;
begin
  Ref := NextRef;
  Addr := LongWord(ByteOfs) * 8 + LongWord(Bit and 7);
  Q := TBytes.Create(
    $03, $00, $00, $24,                          // 36 bytes
    $02, $F0, $80,
    $32, $01, $00, $00, Hi(Ref), Lo(Ref), $00, $0E, $00, $05,
    $05, $01,
    $12, $0A, $10, TS_BIT,
    $00, $01, HB(DB), LB(DB), AREA_DB,
    (Addr shr 16) and $FF, (Addr shr 8) and $FF, Addr and $FF,
    $00, $03, $00, $01, Ord(Value));             // transport BIT, length 1
  R := Exchange(Q);
  CheckS7Header(R, 22);
  if R[21] <> $FF then
    raise ES7Error.CreateFmt('Write DB%d.DBX%d.%d failed, item code %.2x',
      [DB, ByteOfs, Bit, R[21]]);
end;

end.
