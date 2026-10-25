{ ============================================================================
  uproject - the logger project (*.dlog, INI format): tag list, interval,
  log folder. File > Open / Save / Save As.
  ============================================================================ }
unit uproject;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles;

const
  DEFAULT_INTERVAL_MS = 500;
  MAX_TAGS = 64;

type
  TTagDef = record
    Name: string;
    Address: string;
    Format: string;       // display format, '' = default of the type (see uformat)
  end;

  TProject = record
    Tags: array of TTagDef;
    IntervalMs: Integer;
    LogFolder: string;
  end;

function DefaultProject: TProject;
function DefaultLogFolder: string;
procedure LoadProject(const AFile: string; out P: TProject);
procedure SaveProject(const AFile: string; const P: TProject);

implementation

function DefaultLogFolder: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'Logs';
end;

function DefaultProject: TProject;
begin
  Result := Default(TProject);
  Result.IntervalMs := DEFAULT_INTERVAL_MS;
  Result.LogFolder := DefaultLogFolder;
end;

procedure LoadProject(const AFile: string; out P: TProject);
var
  Ini: TIniFile;
  I, N: Integer;
begin
  P := DefaultProject;
  Ini := TIniFile.Create(AFile);
  try
    P.IntervalMs := Ini.ReadInteger('Logger', 'IntervalMs', P.IntervalMs);
    P.LogFolder := Ini.ReadString('Logger', 'Folder', P.LogFolder);
    N := Ini.ReadInteger('Tags', 'Count', 0);
    if N > MAX_TAGS then N := MAX_TAGS;
    SetLength(P.Tags, N);
    for I := 0 to N - 1 do
    begin
      P.Tags[I].Name := Ini.ReadString('Tags', 'Name' + IntToStr(I), 'Tag' + IntToStr(I + 1));
      P.Tags[I].Address := Ini.ReadString('Tags', 'Address' + IntToStr(I), '');
      P.Tags[I].Format := Ini.ReadString('Tags', 'Format' + IntToStr(I), '');
    end;
  finally
    Ini.Free;
  end;
end;

procedure SaveProject(const AFile: string; const P: TProject);
var
  Ini: TIniFile;
  I: Integer;
begin
  if FileExists(AFile) then DeleteFile(AFile);     // no old tag lines left behind
  Ini := TIniFile.Create(AFile);
  try
    Ini.WriteString('Info', 'Format', 'PLC Data Logger project 1.0');
    Ini.WriteInteger('Logger', 'IntervalMs', P.IntervalMs);
    Ini.WriteString('Logger', 'Folder', P.LogFolder);
    Ini.WriteInteger('Tags', 'Count', Length(P.Tags));
    for I := 0 to High(P.Tags) do
    begin
      Ini.WriteString('Tags', 'Name' + IntToStr(I), P.Tags[I].Name);
      Ini.WriteString('Tags', 'Address' + IntToStr(I), P.Tags[I].Address);
      if P.Tags[I].Format <> '' then Ini.WriteString('Tags', 'Format' + IntToStr(I), P.Tags[I].Format);
    end;
  finally
    Ini.Free;
  end;
end;

end.
