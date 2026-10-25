{ ============================================================================
  uformat - display formats of the tag values (grid + CSV)
    integers   DEC  HEX (16#00FF)  BIN (2#0000_0101)
    BOOL       0/1  TRUE/FALSE  ON/OFF
    REAL       AUTO  0  0.0  0.00  0.000  0.0000  SCI
    TIME       T# (T#1h_2m_3s_400ms)  MS  S  HH:MM:SS.ZZZ
    TOD        HH:MM:SS.ZZZ  HH:MM:SS  MS
    DATE       SHORT (25-10-2026)  LONG (Sunday 25 October 2026)  ISO (2026-10-25)  D#
    DT / DTL / UNIXTIME
               SHORT  LONG  ISO   (+ UNIX = seconds since 1970 for UNIXTIME)
  The first format of each list is the default (an empty format = default).
  ============================================================================ }
unit uformat;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, uaddress;

type
  TFormatList = array of string;

{ the formats that fit the type; [0] is the default }
function FormatsFor(DT: TDataType): TFormatList;
{ valid upper-case format for the type ('' or unknown -> default) }
function NormalizeFormat(DT: TDataType; const Fmt: string): string;
function FormatValue(DT: TDataType; const Fmt: string; V: Double): string;

var
  DisplayFmt: TFormatSettings;   // '.' decimal point, English day / month names

implementation

const
  IntFormats: array[0..2] of string = ('DEC', 'HEX', 'BIN');
  BoolFormats: array[0..2] of string = ('0/1', 'TRUE/FALSE', 'ON/OFF');
  RealFormats: array[0..6] of string = ('AUTO', '0', '0.0', '0.00', '0.000', '0.0000', 'SCI');
  TimeFormats: array[0..3] of string = ('T#', 'MS', 'S', 'HH:MM:SS.ZZZ');
  TodFormats: array[0..2] of string = ('HH:MM:SS.ZZZ', 'HH:MM:SS', 'MS');
  DateFormats: array[0..3] of string = ('SHORT', 'LONG', 'ISO', 'D#');
  DTFormats: array[0..2] of string = ('SHORT', 'LONG', 'ISO');
  UnixFormats: array[0..3] of string = ('SHORT', 'LONG', 'ISO', 'UNIX');

function ToList(const A: array of string): TFormatList;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function FormatsFor(DT: TDataType): TFormatList;
begin
  case DT of
    dtBool: Result := ToList(BoolFormats);
    dtByte, dtInt, dtUInt, dtDInt, dtUDInt: Result := ToList(IntFormats);
    dtReal, dtRealSw: Result := ToList(RealFormats);
    dtTime: Result := ToList(TimeFormats);
    dtTOD: Result := ToList(TodFormats);
    dtDate: Result := ToList(DateFormats);
    dtUnixTime: Result := ToList(UnixFormats);
  else
    Result := ToList(DTFormats);         // DT, DTL
  end;
end;

function NormalizeFormat(DT: TDataType; const Fmt: string): string;
var
  L: TFormatList;
  F: string;
  I: Integer;
begin
  L := FormatsFor(DT);
  F := UpperCase(Trim(Fmt));
  for I := 0 to High(L) do
    if L[I] = F then Exit(F);
  Result := L[0];
end;

{ 2#0000_0101 / 16#05 with the width of the type; negative values as two's complement }
function RadixText(V: Int64; Bytes: Integer; Bin: Boolean): string;
var
  U: QWord;
  I: Integer;
begin
  U := QWord(V) and ((QWord(1) shl (8 * Bytes)) - 1);
  if not Bin then Exit('16#' + IntToHex(U, 2 * Bytes));
  Result := '';
  for I := 8 * Bytes - 1 downto 0 do
  begin
    if (U shr I) and 1 <> 0 then Result := Result + '1' else Result := Result + '0';
    if (I > 0) and (I mod 4 = 0) then Result := Result + '_';
  end;
  Result := '2#' + Result;
end;

{ T#1d_2h_3m_4s_500ms (IEC / TIA style) }
function IecTime(Ms: Int64): string;
const
  Units: array[0..4] of string = ('d', 'h', 'm', 's', 'ms');
  Divs: array[0..4] of Int64 = (86400000, 3600000, 60000, 1000, 1);
var
  I: Integer;
  Part: Int64;
begin
  Result := '';
  if Ms < 0 then
  begin
    Result := '-';
    Ms := -Ms;
  end;
  if Ms = 0 then Exit('T#0ms');
  for I := 0 to 4 do
  begin
    Part := Ms div Divs[I];
    Ms := Ms mod Divs[I];
    if Part <> 0 then
    begin
      if (Result <> '') and (Result <> '-') then Result := Result + '_';
      Result := Result + IntToStr(Part) + Units[I];
    end;
  end;
  Result := 'T#' + Result;
end;

function HmsText(Ms: Int64; WithMs: Boolean): string;
var
  Neg: Boolean;
begin
  Neg := Ms < 0;
  if Neg then Ms := -Ms;
  Result := Format('%.2d:%.2d:%.2d', [Ms div 3600000, Ms div 60000 mod 60, Ms div 1000 mod 60]);
  if WithMs then Result := Result + Format('.%.3d', [Ms mod 1000]);
  if Neg then Result := '-' + Result;
end;

function FormatValue(DT: TDataType; const Fmt: string; V: Double): string;
var
  F: string;
  N: Int64;
begin
  F := NormalizeFormat(DT, Fmt);
  case DT of
    dtBool:
      if F = 'TRUE/FALSE' then
        if V <> 0 then Result := 'TRUE' else Result := 'FALSE'
      else if F = 'ON/OFF' then
        if V <> 0 then Result := 'ON' else Result := 'OFF'
      else
        Result := IntToStr(Ord(V <> 0));
    dtByte, dtInt, dtUInt, dtDInt, dtUDInt:
      begin
        N := Round(V);
        if F = 'HEX' then Result := RadixText(N, DTSize[DT], False)
        else if F = 'BIN' then Result := RadixText(N, DTSize[DT], True)
        else Result := IntToStr(N);
      end;
    dtReal, dtRealSw:
      if F = 'AUTO' then Result := FloatToStrF(V, ffGeneral, 7, 0, DisplayFmt)
      else if F = 'SCI' then Result := FloatToStrF(V, ffExponent, 5, 2, DisplayFmt)
      else Result := FormatFloat(F, V, DisplayFmt);
    dtTime:
      begin
        N := Round(V);
        if F = 'MS' then Result := IntToStr(N)
        else if F = 'S' then Result := FormatFloat('0.000', N / 1000, DisplayFmt)
        else if F = 'HH:MM:SS.ZZZ' then Result := HmsText(N, True)
        else Result := IecTime(N);
      end;
    dtTOD:
      begin
        N := Round(V);
        if F = 'MS' then Result := IntToStr(N)
        else Result := HmsText(N, F = 'HH:MM:SS.ZZZ');
      end;
    dtDate:
      if F = 'LONG' then Result := FormatDateTime('dddd d mmmm yyyy', V, DisplayFmt)
      else if F = 'ISO' then Result := FormatDateTime('yyyy"-"mm"-"dd', V, DisplayFmt)
      else if F = 'D#' then Result := FormatDateTime('"D#"yyyy"-"mm"-"dd', V, DisplayFmt)
      else Result := FormatDateTime('dd"-"mm"-"yyyy', V, DisplayFmt);
  else                                   // DT, DTL, UNIXTIME
    if F = 'UNIX' then Result := IntToStr(DateTimeToUnix(V, False))
    else if F = 'LONG' then Result := FormatDateTime('dddd d mmmm yyyy hh":"nn":"ss"."zzz', V, DisplayFmt)
    else if F = 'ISO' then Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss"."zzz', V, DisplayFmt)
    else Result := FormatDateTime('dd"-"mm"-"yyyy hh":"nn":"ss', V, DisplayFmt);
  end;
end;

const
  EnLongDays: array[1..7] of string = ('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday');
  EnLongMonths: array[1..12] of string = ('January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December');

var
  I: Integer;

initialization
  DisplayFmt := DefaultFormatSettings;
  DisplayFmt.DecimalSeparator := '.';
  DisplayFmt.ThousandSeparator := ',';
  { fixed English names: the same text on every PC, no code page trouble in the CSV }
  for I := 1 to 7 do
  begin
    DisplayFmt.LongDayNames[I] := EnLongDays[I];
    DisplayFmt.ShortDayNames[I] := Copy(EnLongDays[I], 1, 3);
  end;
  for I := 1 to 12 do
  begin
    DisplayFmt.LongMonthNames[I] := EnLongMonths[I];
    DisplayFmt.ShortMonthNames[I] := Copy(EnLongMonths[I], 1, 3);
  end;
end.
