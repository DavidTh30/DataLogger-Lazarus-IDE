{ ============================================================================
  PLC Data Logger - main window (normal Lazarus form, umain.lfm)
    - protocols: S7 TCP/IP, Modbus TCP/IP, Modbus RTU (RS485)
    - tag list: right-click menu (address helper, display format, add / delete / move)
    - display formats per tag (DEC / HEX / BIN, date LONG / ISO, ...) in grid and CSV
    - Monitor before Record
    - CSV: <folder>\mm-yyyy\dd-mm-yyyy.csv, new file every day / month / year
    - network config loaded automatically at every start (DataLogger.ini)
    - keeps logging in the background (tray icon)
  ============================================================================ }
unit umain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls,
  Grids, Spin, ComCtrls, LCLIntf, LCLType, Clipbrd, Math,
  uaddress, udrivers, uconfig, uproject, ulogger, uformat, unetform, uaddrhelper;

type
  TIntArray = array of Integer;

  { TMainForm }

  TMainForm = class(TForm)
    BtnMonitor: TButton;
    BtnRecord: TButton;
    BtnStop: TButton;
    GridTags: TStringGrid;
    LabelConn: TLabel;
    LabelExamples: TLabel;
    LabelInterval: TLabel;
    LabelMs: TLabel;
    LabelRec: TLabel;
    MainMenu1: TMainMenu;
    MenuAbout: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuHelp: TMenuItem;
    MenuLogFolder: TMenuItem;
    MenuNetSettings: TMenuItem;
    MenuNetwork: TMenuItem;
    MenuOpen: TMenuItem;
    MenuOpenFolder: TMenuItem;
    MenuSave: TMenuItem;
    MenuSaveAs: TMenuItem;
    MenuSep1: TMenuItem;
    MenuSep2: TMenuItem;
    MenuTray: TMenuItem;
    MenuView: TMenuItem;
    OpenDialog1: TOpenDialog;
    PanelStatus: TPanel;
    PanelTags: TPanel;
    PanelTop: TPanel;
    PopupTray: TPopupMenu;
    SaveDialog1: TSaveDialog;
    SelectDirectoryDialog1: TSelectDirectoryDialog;
    ShapeConn: TShape;
    ShapeRec: TShape;
    SpinInterval: TSpinEdit;
    StatusBar1: TStatusBar;
    Timer1: TTimer;
    TrayExit: TMenuItem;
    TraySep: TMenuItem;
    TrayShow: TMenuItem;
    TrayStop: TMenuItem;
    TrayIcon1: TTrayIcon;
    procedure BtnMonitorClick(Sender: TObject);
    procedure BtnRecordClick(Sender: TObject);
    procedure BtnStopClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridTagsEditingDone(Sender: TObject);
    procedure GridTagsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure GridTagsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure GridTagsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure GridTagsMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure GridTagsSetEditText(Sender: TObject; ACol, ARow: Integer; const Value: string);
    procedure GridTagsSelectEditor(Sender: TObject; aCol, aRow: Integer; var Editor: TWinControl);
    procedure GridTagsPrepareCanvas(Sender: TObject; aCol, aRow: Integer; aState: TGridDrawState);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuLogFolderClick(Sender: TObject);
    procedure MenuNetSettingsClick(Sender: TObject);
    procedure MenuOpenClick(Sender: TObject);
    procedure MenuOpenFolderClick(Sender: TObject);
    procedure MenuSaveAsClick(Sender: TObject);
    procedure MenuSaveClick(Sender: TObject);
    procedure MenuTrayClick(Sender: TObject);
    procedure SpinIntervalChange(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure TrayIcon1DblClick(Sender: TObject);
    procedure TrayShowClick(Sender: TObject);
    procedure TrayStopClick(Sender: TObject);
  private
    FCfg: TNetConfig;
    FProject: TProject;
    FProjectFile: string;
    FModified: Boolean;
    FThread: TLoggerThread;
    FMode: TLogMode;
    FBlink: Boolean;
    FLoading: Boolean;
    FTypes: array of TDataType;
    FTagErr: array of string;
    FLast: TTagValues;           // last values per tag (format examples in the menu)
    FLogRow: array of Integer;   // logger tag k = FProject.Tags[FLogRow[k]] (empty rows skipped)
    FRowSel: array of Boolean;   // rows selected with the # column (index = grid row)
    FAnchor: Integer;            // first row of a Shift / drag selection
    FDragSel: Boolean;    PopupGrid: TPopupMenu;
    MenuTags: TMenuItem;
    procedure BuildTagMenu(Root: TMenuItem);
    procedure TagMenuPopup(Sender: TObject);
    procedure UpdateTagMenu(Root: TMenuItem);
    procedure TagHelperClick(Sender: TObject);
    procedure TagAddClick(Sender: TObject);
    procedure TagInsertClick(Sender: TObject);
    procedure TagDeleteClick(Sender: TObject);
    procedure TagUpClick(Sender: TObject);
    procedure TagDownClick(Sender: TObject);
    procedure TagFormatClick(Sender: TObject);
    procedure TagCutClick(Sender: TObject);
    procedure TagCopyClick(Sender: TObject);
    procedure TagPasteClick(Sender: TObject);
    function IsBlankTag(const T: TTagDef): Boolean;
    procedure TrimBlankTags;
    function IsRowSel(R: Integer): Boolean;
    function HasRowSel: Boolean;
    procedure ClearRowSel;
    procedure SelectRows(A, B: Integer; Add: Boolean);
    function SelTags: TIntArray;
    function TargetIndex: Integer;
    procedure InsertTags(At: Integer; const New: array of TTagDef);    function CurTag: Integer;
    function NewTag(Index: Integer): TTagDef;
    procedure TagsChanged(SelRow: Integer; SelCount: Integer = 0);
    procedure ShowFolder;
    procedure AppMinimize(Sender: TObject);
    procedure ProjectToGrid;
    procedure GridToProject;
    procedure Validate;
    procedure ApplyToThread;
    procedure SetMode(M: TLogMode);
    procedure UpdateTitle;
    function DoSave(AsNew: Boolean): Boolean;
    procedure LoadProjectFile(const AFile: string);
    function CanRecord(out Why: string): Boolean;
    procedure ShowFromTray;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  COL_NAME = 1;
  COL_ADDR = 2;
  COL_FMT = 3;
  COL_VALUE = 4;
  COL_INFO = 5;
  ModeText: array[TLogMode] of string = ('Stopped', 'Monitor', 'RECORD');

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Application.OnMinimize := @AppMinimize;
  TrayIcon1.Icon.Assign(Application.Icon);
  GridTags.Cells[0, 0] := '#';
  GridTags.Cells[COL_NAME, 0] := 'Name';
  GridTags.Cells[COL_ADDR, 0] := 'Address';
  GridTags.Cells[COL_FMT, 0] := 'Format';
  GridTags.Cells[COL_VALUE, 0] := 'Value';
  GridTags.Cells[COL_INFO, 0] := 'Meaning of the address';
  GridTags.ColWidths[0] := 30;
  GridTags.ColWidths[COL_NAME] := 115;
  GridTags.ColWidths[COL_ADDR] := 150;
  GridTags.ColWidths[COL_FMT] := 95;
  GridTags.ColWidths[COL_VALUE] := 165;
  GridTags.ColWidths[COL_INFO] := 250;
  { tag menu: right-click on the table, and the same items in the main menu "Tags" }
  PopupGrid := TPopupMenu.Create(Self);
  PopupGrid.OnPopup := @TagMenuPopup;
  BuildTagMenu(PopupGrid.Items);
  GridTags.PopupMenu := PopupGrid;
  MenuTags := TMenuItem.Create(Self);
  MenuTags.Caption := '&Tags';
  MenuTags.OnClick := @TagMenuPopup;
  MainMenu1.Items.Insert(1, MenuTags);
  BuildTagMenu(MenuTags);
  FThread := TLoggerThread.Create;

  { network config: loaded automatically at every start }
  LoadNetConfig(FCfg);
  if not FileExists(AppIniName) then SaveNetConfig(FCfg);

  { last tag list }
  if (FCfg.LastProject <> '') and FileExists(FCfg.LastProject) then
    LoadProjectFile(FCfg.LastProject)
  else
  begin
    FProject := DefaultProject;
    FProjectFile := '';
    ProjectToGrid;
  end;
  ApplyToThread;
  SetMode(lmIdle);

  if FCfg.AutoRecord then BtnRecordClick(nil)
  else if FCfg.AutoMonitor then BtnMonitorClick(nil);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Timer1.Enabled := False;
  FThread.Free;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FMode = lmRecord then
  begin
    ShowFromTray;
    CanClose := MessageDlg('Exit', 'Recording is running.' + LineEnding +
      'Stop recording and exit?', mtConfirmation, [mbYes, mbNo], 0) = mrYes;
    if not CanClose then Exit;
  end;
  if FModified then
    case MessageDlg('Exit', 'The tag list was changed. Save it?', mtConfirmation,
      [mbYes, mbNo, mbCancel], 0) of
      mrYes: CanClose := DoSave(False);
      mrCancel: CanClose := False;
    end;
end;

{ ------------------------------ tag grid -------------------------------- }

procedure TMainForm.ProjectToGrid;
var
  I: Integer;
begin
  FLoading := True;
  try
    { the tags + one empty row at the end: typing into it makes a new tag }
    GridTags.RowCount := Length(FProject.Tags) + 2;
    GridTags.Rows[GridTags.RowCount - 1].Clear;
    GridTags.Cells[0, GridTags.RowCount - 1] := '*';
    SetLength(FRowSel, GridTags.RowCount);
    for I := 0 to High(FProject.Tags) do
    begin
      GridTags.Cells[0, I + 1] := IntToStr(I + 1);
      GridTags.Cells[COL_NAME, I + 1] := FProject.Tags[I].Name;
      GridTags.Cells[COL_ADDR, I + 1] := FProject.Tags[I].Address;
      GridTags.Cells[COL_FMT, I + 1] := FProject.Tags[I].Format;
      GridTags.Cells[COL_VALUE, I + 1] := '';
    end;
    SpinInterval.Value := FProject.IntervalMs;
    ShowFolder;
  finally
    FLoading := False;
  end;
  Validate;
end;

procedure TMainForm.GridToProject;
var
  Old, R, N: Integer;
  OldTags: array of TTagDef;
  TagName, Addr: string;
  WasBlank: Boolean;
begin
  { - existing tag: Name or Address cleared -> the whole row becomes empty
    - empty row (in the list or the "*" row at the end) gets text -> new tag,
      the missing name / address is filled in }
  OldTags := Copy(FProject.Tags);
  Old := Length(OldTags);
  N := 0;
  SetLength(FProject.Tags, 0);
  for R := 1 to GridTags.RowCount - 1 do
  begin
    TagName := Trim(GridTags.Cells[COL_NAME, R]);
    Addr := Trim(GridTags.Cells[COL_ADDR, R]);
    if (R > Old) and (TagName = '') and (Addr = '') then Continue;
    if N >= MAX_TAGS then Break;
    SetLength(FProject.Tags, N + 1);
    WasBlank := (R > Old) or IsBlankTag(OldTags[R - 1]);
    if (TagName = '') and (Addr = '') then
      FProject.Tags[N] := Default(TTagDef)
    else if WasBlank then
    begin
      FProject.Tags[N] := NewTag(N);
      if TagName <> '' then FProject.Tags[N].Name := TagName;
      if Addr <> '' then FProject.Tags[N].Address := Addr;
      FProject.Tags[N].Format := Trim(GridTags.Cells[COL_FMT, R]);
    end
    else if (TagName = '') or (Addr = '') then
      FProject.Tags[N] := Default(TTagDef)
    else
    begin
      FProject.Tags[N].Name := TagName;
      FProject.Tags[N].Address := Addr;
      FProject.Tags[N].Format := Trim(GridTags.Cells[COL_FMT, R]);
    end;
    Inc(N);
  end;
  TrimBlankTags;
  FProject.IntervalMs := SpinInterval.Value;
end;

function TMainForm.IsBlankTag(const T: TTagDef): Boolean;
begin
  Result := (T.Name = '') and (T.Address = '');
end;

{ empty rows at the end of the list are not kept (the "*" row is there anyway) }
procedure TMainForm.TrimBlankTags;
var
  N: Integer;
begin
  N := Length(FProject.Tags);
  while (N > 0) and IsBlankTag(FProject.Tags[N - 1]) do Dec(N);
  SetLength(FProject.Tags, N);
end;

{ check every address for the current protocol and show what it means }
procedure TMainForm.Validate;
var
  I: Integer;
  A: TTagAddr;
  Err, F: string;
begin
  SetLength(FTypes, Length(FProject.Tags));
  SetLength(FTagErr, Length(FProject.Tags));
  for I := 0 to High(FProject.Tags) do
  begin
    if IsBlankTag(FProject.Tags[I]) then
    begin
      FTypes[I] := dtReal;           // empty row: not read, not logged
      FTagErr[I] := '';
      GridTags.Cells[COL_FMT, I + 1] := '';
      GridTags.Cells[COL_INFO, I + 1] := '';
    end
    else if ParseAddress(FCfg.Drv.Protocol, FProject.Tags[I].Address, A, Err) then
    begin
      FTypes[I] := A.DT;
      FTagErr[I] := '';
      { a format that does not fit the (new) type -> default of the type }
      F := NormalizeFormat(A.DT, FProject.Tags[I].Format);
      if F <> UpperCase(Trim(FProject.Tags[I].Format)) then FProject.Tags[I].Format := ''
      else FProject.Tags[I].Format := F;
      GridTags.Cells[COL_FMT, I + 1] := F;
      GridTags.Cells[COL_INFO, I + 1] := DescribeAddress(FCfg.Drv.Protocol, A);
    end
    else
    begin
      FTypes[I] := dtReal;
      FTagErr[I] := Err;
      GridTags.Cells[COL_FMT, I + 1] := FProject.Tags[I].Format;
      GridTags.Cells[COL_INFO, I + 1] := 'ERROR: ' + Err;
    end;
  end;
  LabelExamples.Caption := 'Right-click the table: Address helper, Format, Cut / Copy / Paste.  ' +
    'Click # to select rows (Ctrl / Shift / drag = more rows).   ' + AddressExamples(FCfg.Drv.Protocol);
  LabelExamples.Hint := LabelExamples.Caption;
  StatusBar1.Panels[0].Text := NetSummary(FCfg);
end;

{ the logger gets the tags without the empty rows; FLogRow maps them back }
procedure TMainForm.ApplyToThread;
var
  Act: array of TTagDef;
  I, N: Integer;
begin
  SetLength(Act, Length(FProject.Tags));
  SetLength(FLogRow, Length(FProject.Tags));
  N := 0;
  for I := 0 to High(FProject.Tags) do
    if not IsBlankTag(FProject.Tags[I]) then
    begin
      Act[N] := FProject.Tags[I];
      FLogRow[N] := I;
      Inc(N);
    end;
  SetLength(Act, N);
  SetLength(FLogRow, N);
  FThread.Configure(FCfg.Drv, Act, FProject.IntervalMs, FProject.LogFolder);
end;

procedure TMainForm.GridTagsEditingDone(Sender: TObject);
var
  R, C, I: Integer;
  Before: array of TTagDef;
  Same: Boolean;
begin
  if FLoading or (FMode = lmRecord) then Exit;
  Before := Copy(FProject.Tags);
  GridToProject;
  { the grid also calls this when the current cell just moves: nothing to do then }
  Same := (Length(Before) = Length(FProject.Tags)) and (GridTags.RowCount = Length(FProject.Tags) + 2);
  if Same then
    for I := 0 to High(Before) do
      if (Before[I].Name <> FProject.Tags[I].Name) or (Before[I].Address <> FProject.Tags[I].Address) or
        (NormalizeFormat(FTypes[I], Before[I].Format) <> NormalizeFormat(FTypes[I], FProject.Tags[I].Format)) or
        (Trim(GridTags.Cells[COL_NAME, I + 1]) <> FProject.Tags[I].Name) or
        (Trim(GridTags.Cells[COL_ADDR, I + 1]) <> FProject.Tags[I].Address) then
      begin
        Same := False;
        Break;
      end;
  if Same then Exit;
  { show filled-in / emptied cells, numbers and the "*" row }
  R := GridTags.Row;
  C := GridTags.Col;
  ProjectToGrid;
  GridTags.Row := Min(R, GridTags.RowCount - 1);
  GridTags.Col := C;
  ApplyToThread;
  FModified := True;
  UpdateTitle;
end;

procedure TMainForm.GridTagsPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
  aState: TGridDrawState);
begin
  if aRow = 0 then Exit;
  if IsRowSel(aRow) then
  begin
    GridTags.Canvas.Brush.Color := clHighlight;
    GridTags.Canvas.Font.Color := clHighlightText;
    if aCol = COL_VALUE then GridTags.Canvas.Font.Style := [fsBold];
    Exit;
  end;
  if (aCol = COL_INFO) and (aRow - 1 <= High(FTagErr)) and (FTagErr[aRow - 1] <> '') then
    GridTags.Canvas.Font.Color := clRed
  else if aCol = COL_INFO then
    GridTags.Canvas.Font.Color := clGrayText
  else if aCol = COL_VALUE then
  begin
    GridTags.Canvas.Font.Style := [fsBold];
    if FMode = lmRecord then GridTags.Canvas.Brush.Color := $00E8E8FF;
  end;
end;

{ ------------------------------ row selection (# column) --------------- }

function TMainForm.IsRowSel(R: Integer): Boolean;
begin
  Result := (R >= 1) and (R <= High(FRowSel)) and FRowSel[R];
end;

function TMainForm.HasRowSel: Boolean;
var
  R: Integer;
begin
  for R := 1 to High(FRowSel) do
    if FRowSel[R] then Exit(True);
  Result := False;
end;

procedure TMainForm.ClearRowSel;
begin
  if not HasRowSel then Exit;
  FillChar(FRowSel[0], Length(FRowSel) * SizeOf(Boolean), 0);
  GridTags.Invalidate;
end;

{ select grid rows A..B (either order); Add = keep the rows selected so far }
procedure TMainForm.SelectRows(A, B: Integer; Add: Boolean);
var
  R: Integer;
begin
  if Length(FRowSel) <> GridTags.RowCount then SetLength(FRowSel, GridTags.RowCount);
  if not Add then FillChar(FRowSel[0], Length(FRowSel) * SizeOf(Boolean), 0);
  for R := Max(1, Min(A, B)) to Min(GridTags.RowCount - 1, Max(A, B)) do FRowSel[R] := True;
  GridTags.Invalidate;
end;

{ tag indexes the row commands work on: the selected rows, else the current row }
function TMainForm.SelTags: TIntArray;
var
  R, N: Integer;
begin
  Result := nil;
  N := 0;
  for R := 1 to Min(High(FRowSel), Length(FProject.Tags)) do
    if FRowSel[R] then
    begin
      SetLength(Result, N + 1);
      Result[N] := R - 1;
      Inc(N);
    end;
  if (N = 0) and not HasRowSel and (CurTag >= 0) then Result := [CurTag];
end;

{ first selected row (may be the "*" row), else the current row - as tag index }
function TMainForm.TargetIndex: Integer;
var
  R: Integer;
begin
  for R := 1 to High(FRowSel) do
    if FRowSel[R] then Exit(R - 1);
  Result := Max(0, GridTags.Row - 1);
end;

procedure TMainForm.GridTagsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  C, R: Integer;
begin
  GridTags.MouseToCell(X, Y, C, R);
  if (R < 1) or (R >= GridTags.RowCount) then Exit;
  if Button = mbRight then
  begin
    { right-click: keep a row selection under the mouse, else select that row }
    if not IsRowSel(R) then
    begin
      ClearRowSel;
      GridTags.Row := R;
    end;
    Exit;
  end;
  if Button <> mbLeft then Exit;
  if C = 0 then
  begin
    { # column: whole rows. Ctrl = add / remove a row, Shift = range, drag = range }
    if (ssShift in Shift) and (FAnchor >= 1) then
      SelectRows(FAnchor, R, ssCtrl in Shift)
    else if ssCtrl in Shift then
    begin
      if Length(FRowSel) <> GridTags.RowCount then SetLength(FRowSel, GridTags.RowCount);
      FRowSel[R] := not FRowSel[R];
      FAnchor := R;
      GridTags.Invalidate;
    end
    else
    begin
      SelectRows(R, R, False);
      FAnchor := R;
    end;
    FDragSel := not (ssCtrl in Shift);
    GridTags.Row := R;
    if GridTags.CanFocus then GridTags.SetFocus;
  end
  else
    ClearRowSel;                   // a normal cell: back to cell editing
end;

procedure TMainForm.GridTagsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  C, R: Integer;
begin
  if not FDragSel or not (ssLeft in Shift) then Exit;
  GridTags.MouseToCell(X, Y, C, R);
  if (R >= 1) and (R < GridTags.RowCount) then SelectRows(FAnchor, R, False);
end;

procedure TMainForm.GridTagsMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  FDragSel := False;
end;

{ keys when no cell is being edited (in a cell editor the keys stay normal text keys) }
procedure TMainForm.GridTagsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  R: Integer;
begin
  if GridTags.EditorMode then Exit;
  if ssCtrl in Shift then
    case Key of
      VK_C: TagCopyClick(nil);
      VK_X: TagCutClick(nil);
      VK_V: TagPasteClick(nil);
      VK_H: TagHelperClick(nil);
      VK_INSERT: TagAddClick(nil);
      VK_UP: TagUpClick(nil);
      VK_DOWN: TagDownClick(nil);
    else
      Exit;
    end
  else if Shift = [] then
    case Key of
      VK_INSERT: TagInsertClick(nil);
      VK_DELETE:
        if HasRowSel then TagDeleteClick(nil)
        else
        begin
          { Del on a cell: Name or Address -> the whole row empty, other cells: nothing }
          R := CurTag;
          if (FMode = lmRecord) or (R < 0) or not (GridTags.Col in [COL_NAME, COL_ADDR]) then Exit;
          GridToProject;
          FProject.Tags[R] := Default(TTagDef);
          TagsChanged(R);
        end;
      VK_ESCAPE: ClearRowSel;
    else
      Exit;
    end
  else
    Exit;
  Key := 0;
end;

{ typing into the empty last row: the next empty row is there at once }
procedure TMainForm.GridTagsSetEditText(Sender: TObject; ACol, ARow: Integer; const Value: string);
begin
  if FLoading or (Value = '') or (ARow <> GridTags.RowCount - 1) then Exit;
  if GridTags.RowCount - 1 > MAX_TAGS then Exit;
  GridTags.RowCount := GridTags.RowCount + 1;
  GridTags.Cells[0, ARow] := IntToStr(ARow);
  GridTags.Cells[0, ARow + 1] := '*';
end;

procedure TMainForm.GridTagsSelectEditor(Sender: TObject; aCol, aRow: Integer;
  var Editor: TWinControl);
var
  L: TFormatList;
  I: Integer;
  Pick: TPickListCellEditor;
begin
  if aCol <> COL_FMT then Exit;
  if (aRow < 1) or (aRow - 1 > High(FTypes)) or IsBlankTag(FProject.Tags[aRow - 1]) then
  begin
    Editor := nil;                 // no format before the tag has an address
    Exit;
  end;
  Pick := GridTags.EditorByStyle(cbsPickList) as TPickListCellEditor;
  Pick.Style := csDropDownList;
  Pick.Items.Clear;
  L := FormatsFor(FTypes[aRow - 1]);
  for I := 0 to High(L) do Pick.Items.Add(L[I]);
  Editor := Pick;
end;

{ ------------------------------ tag menu (right-click / Tags) ----------- }

const
  { menu item ids (TMenuItem.Tag) }
  ID_HELPER = 1; ID_FORMAT = 2; ID_CUT = 3; ID_COPY = 4; ID_PASTE = 5;
  ID_ADD = 6; ID_INSERT = 7; ID_DELETE = 8; ID_UP = 9; ID_DOWN = 10;

procedure TMainForm.BuildTagMenu(Root: TMenuItem);

  function Add(const ACaption, AKey: string; AClick: TNotifyEvent; Id: Integer): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    if AKey <> '' then Result.Caption := ACaption + '     (' + AKey + ')';   // the grid handles the key
    Result.OnClick := AClick;
    Result.Tag := Id;
    Root.Add(Result);
  end;

begin
  Add('&Address helper...', 'Ctrl+H', @TagHelperClick, ID_HELPER).Default := True;
  Add('Display &format', '', nil, ID_FORMAT).Add(TMenuItem.Create(Self));  // filled on open
  Add('-', '', nil, 0);
  Add('Cu&t', 'Ctrl+X', @TagCutClick, ID_CUT);
  Add('&Copy', 'Ctrl+C', @TagCopyClick, ID_COPY);
  Add('&Paste', 'Ctrl+V', @TagPasteClick, ID_PASTE);
  Add('-', '', nil, 0);
  Add('A&dd tag', 'Ctrl+Ins', @TagAddClick, ID_ADD);
  Add('&Insert row(s) above', 'Ins', @TagInsertClick, ID_INSERT);
  Add('D&elete row(s)', 'Del', @TagDeleteClick, ID_DELETE);
  Add('-', '', nil, 0);
  Add('Move &up', 'Ctrl+Up', @TagUpClick, ID_UP);
  Add('Move do&wn', 'Ctrl+Down', @TagDownClick, ID_DOWN);
end;

procedure TMainForm.TagMenuPopup(Sender: TObject);
begin
  if Sender = PopupGrid then UpdateTagMenu(PopupGrid.Items) else UpdateTagMenu(MenuTags);
end;

{ enable the items for the selected rows and fill the format list
  (each format with an example of the current value) }
procedure TMainForm.UpdateTagMenu(Root: TMenuItem);
var
  Editing, One, Room: Boolean;
  R, I, N: Integer;
  L: TFormatList;
  Cur: string;
  Sub, It: TMenuItem;
begin
  Editing := FMode <> lmRecord;
  N := Length(SelTags);
  R := CurTag;
  if N = 1 then R := SelTags[0];
  One := (N = 1) and not IsBlankTag(FProject.Tags[R]);
  Room := Length(FProject.Tags) < MAX_TAGS;
  Sub := nil;
  for I := 0 to Root.Count - 1 do
    case Root.Items[I].Tag of
      ID_HELPER: Root.Items[I].Enabled := Editing and (N <= 1) and (GridTags.Row >= 1);
      ID_FORMAT: Sub := Root.Items[I];
      ID_CUT, ID_DELETE: Root.Items[I].Enabled := Editing and (N > 0);
      ID_COPY: Root.Items[I].Enabled := N > 0;
      ID_PASTE: Root.Items[I].Enabled := Editing and Room and (Clipboard.AsText <> '');
      ID_ADD: Root.Items[I].Enabled := Editing and Room;
      ID_INSERT: Root.Items[I].Enabled := Editing and Room and (N > 0);
      ID_UP: Root.Items[I].Enabled := Editing and (N = 1) and (SelTags[0] > 0);
      ID_DOWN: Root.Items[I].Enabled := Editing and (N = 1) and (SelTags[0] < High(FProject.Tags));
    end;
  if Sub = nil then Exit;
  Sub.Clear;
  Sub.Enabled := Editing and One and (FTagErr[R] = '');
  if not Sub.Enabled then
  begin
    Sub.Add(TMenuItem.Create(Self));       // keeps the sub-menu arrow
    Sub.Items[0].Caption := '(one tag with a valid address)';
    Sub.Items[0].Enabled := False;
    Exit;
  end;
  L := FormatsFor(FTypes[R]);
  Cur := NormalizeFormat(FTypes[R], FProject.Tags[R].Format);
  for I := 0 to High(L) do
  begin
    It := TMenuItem.Create(Self);
    It.Caption := L[I];
    if (R <= High(FLast)) and FLast[R].Ok and (FMode <> lmIdle) then
      It.Caption := It.Caption + #9 + FormatValue(FTypes[R], L[I], FLast[R].Value);
    if I = 0 then It.Caption := It.Caption + '  (default)';
    It.Tag := I;
    It.RadioItem := True;
    It.Checked := L[I] = Cur;
    It.OnClick := @TagFormatClick;
    Sub.Add(It);
  end;
end;

{ a new tag at position Index: address right after the last tag above it
  (none: M0.0 / 40001), same display format as that tag }
function TMainForm.NewTag(Index: Integer): TTagDef;
var
  J: Integer;
begin
  Result := Default(TTagDef);
  Result.Name := 'Tag' + IntToStr(Index + 1);
  Result.Address := DefaultAddress(FCfg.Drv.Protocol);
  for J := Min(Index, Length(FProject.Tags)) - 1 downto 0 do
    if not IsBlankTag(FProject.Tags[J]) then
    begin
      Result.Address := NextAddress(FCfg.Drv.Protocol, FProject.Tags[J].Address);
      Result.Format := FProject.Tags[J].Format;
      Break;
    end;
end;

function TMainForm.CurTag: Integer;
begin
  Result := GridTags.Row - 1;
  if (Result < 0) or (Result > High(FProject.Tags)) then Result := -1;
end;

{ after a change of the tag list: grid, check, logger, title.
  SelCount > 0: those rows from SelRow are selected (row selection) }
procedure TMainForm.TagsChanged(SelRow: Integer; SelCount: Integer);
begin
  TrimBlankTags;
  ProjectToGrid;
  ClearRowSel;
  if SelRow >= 0 then GridTags.Row := Min(SelRow + 1, GridTags.RowCount - 1);
  if SelCount > 0 then
  begin
    SelectRows(SelRow + 1, SelRow + SelCount, False);
    FAnchor := SelRow + 1;
  end;
  FModified := True;
  UpdateTitle;
  ApplyToThread;
end;

procedure TMainForm.InsertTags(At: Integer; const New: array of TTagDef);
var
  I, N, K: Integer;
begin
  N := Length(FProject.Tags);
  K := Length(New);
  SetLength(FProject.Tags, N + K);
  for I := N - 1 downto At do FProject.Tags[I + K] := FProject.Tags[I];
  for I := 0 to K - 1 do FProject.Tags[At + I] := New[I];
end;

procedure TMainForm.TagHelperClick(Sender: TObject);
var
  S: string;
  R: Integer;
begin
  R := GridTags.Row - 1;
  if (FMode = lmRecord) or (R < 0) or (Length(SelTags) > 1) then Exit;
  S := GridTags.Cells[COL_ADDR, R + 1];
  if TAddrHelperForm.Execute(Self, FCfg.Drv.Protocol, S) then
  begin
    GridToProject;
    if R > High(FProject.Tags) then
    begin
      { helper on the "*" row (or an empty row at the end): new tag }
      R := Length(FProject.Tags);
      SetLength(FProject.Tags, R + 1);
      FProject.Tags[R] := NewTag(R);
    end
    else if IsBlankTag(FProject.Tags[R]) then
      FProject.Tags[R] := NewTag(R);
    FProject.Tags[R].Address := S;
    TagsChanged(R);
  end;
end;

procedure TMainForm.TagFormatClick(Sender: TObject);
var
  R: Integer;
begin
  R := CurTag;
  if Length(SelTags) = 1 then R := SelTags[0];
  if (FMode = lmRecord) or (R < 0) then Exit;
  GridToProject;
  FProject.Tags[R].Format := FormatsFor(FTypes[R])[(Sender as TMenuItem).Tag];
  TagsChanged(R);
end;

procedure TMainForm.TagAddClick(Sender: TObject);
var
  N: Integer;
begin
  if FMode = lmRecord then Exit;
  GridToProject;
  N := Length(FProject.Tags);
  if N >= MAX_TAGS then Exit;
  SetLength(FProject.Tags, N + 1);
  FProject.Tags[N] := NewTag(N);
  TagsChanged(N, 1);
end;

{ as many new rows as rows are selected, above the first one; addresses go on from the tag above }
procedure TMainForm.TagInsertClick(Sender: TObject);
var
  At, K, I: Integer;
begin
  if FMode = lmRecord then Exit;
  GridToProject;
  At := Min(TargetIndex, Length(FProject.Tags));
  K := Max(1, Length(SelTags));
  K := Min(K, MAX_TAGS - Length(FProject.Tags));
  if K <= 0 then Exit;
  for I := 0 to K - 1 do InsertTags(At + I, [NewTag(At + I)]);
  for I := 0 to K - 1 do FProject.Tags[At + I].Name := 'Tag' + IntToStr(Length(FProject.Tags) - K + I + 1);
  TagsChanged(At, K);
end;

procedure TMainForm.TagDeleteClick(Sender: TObject);
var
  Sel: TIntArray;
  I, J: Integer;
begin
  if FMode = lmRecord then Exit;
  Sel := SelTags;
  if Length(Sel) = 0 then Exit;
  GridToProject;
  for I := High(Sel) downto 0 do                // from the bottom: indexes stay valid
    if Sel[I] <= High(FProject.Tags) then
    begin
      for J := Sel[I] to High(FProject.Tags) - 1 do FProject.Tags[J] := FProject.Tags[J + 1];
      SetLength(FProject.Tags, Length(FProject.Tags) - 1);
    end;
  ClearRowSel;
  TagsChanged(Min(Sel[0], Length(FProject.Tags)));
end;

{ clipboard text: one line per row, Name <TAB> Address <TAB> Format (pastes into Excel too) }
procedure TMainForm.TagCopyClick(Sender: TObject);
var
  Sel: TIntArray;
  S: string;
  I: Integer;
begin
  Sel := SelTags;
  if Length(Sel) = 0 then Exit;
  GridToProject;
  S := '';
  for I := 0 to High(Sel) do
    if Sel[I] <= High(FProject.Tags) then
      S := S + FProject.Tags[Sel[I]].Name + #9 + FProject.Tags[Sel[I]].Address + #9 +
        FProject.Tags[Sel[I]].Format + LineEnding;
  Clipboard.AsText := S;
end;

procedure TMainForm.TagCutClick(Sender: TObject);
begin
  if (FMode = lmRecord) or (Length(SelTags) = 0) then Exit;
  TagCopyClick(nil);
  TagDeleteClick(nil);
end;

{ paste rows at the first selected row: empty rows there are filled, otherwise the rows
  are inserted. A line with one column = address only. }
procedure TMainForm.TagPasteClick(Sender: TObject);
var
  L, F: TStringList;
  At, I, N: Integer;
  T: TTagDef;
begin
  if FMode = lmRecord then Exit;
  L := TStringList.Create;
  F := TStringList.Create;
  try
    L.Text := Clipboard.AsText;
    while (L.Count > 0) and (Trim(L[L.Count - 1]) = '') do L.Delete(L.Count - 1);
    if L.Count = 0 then Exit;
    GridToProject;
    At := Min(TargetIndex, Length(FProject.Tags));
    N := 0;
    F.StrictDelimiter := True;
    F.Delimiter := #9;
    for I := 0 to L.Count - 1 do
    begin
      if Length(FProject.Tags) >= MAX_TAGS then
        if (At + N > High(FProject.Tags)) or not IsBlankTag(FProject.Tags[At + N]) then Break;
      F.DelimitedText := L[I];
      if Trim(L[I]) = '' then
        T := Default(TTagDef)
      else
      begin
        T := NewTag(At + N);
        if F.Count = 1 then
          T.Address := Trim(F[0])
        else
        begin
          if Trim(F[0]) <> '' then T.Name := Trim(F[0]);
          if Trim(F[1]) <> '' then T.Address := Trim(F[1]);
          if F.Count > 2 then T.Format := Trim(F[2]) else T.Format := '';
        end;
      end;
      if (At + N <= High(FProject.Tags)) and IsBlankTag(FProject.Tags[At + N]) then
        FProject.Tags[At + N] := T
      else
        InsertTags(At + N, [T]);
      Inc(N);
    end;
    TagsChanged(At, N);
  finally
    F.Free;
    L.Free;
  end;
end;

procedure TMainForm.TagUpClick(Sender: TObject);
var
  Sel: TIntArray;
  R: Integer;
  T: TTagDef;
begin
  Sel := SelTags;
  if (FMode = lmRecord) or (Length(Sel) <> 1) or (Sel[0] < 1) then Exit;
  R := Sel[0];
  GridToProject;
  T := FProject.Tags[R - 1];
  FProject.Tags[R - 1] := FProject.Tags[R];
  FProject.Tags[R] := T;
  TagsChanged(R - 1, Ord(HasRowSel));
end;

procedure TMainForm.TagDownClick(Sender: TObject);
var
  Sel: TIntArray;
  R: Integer;
  T: TTagDef;
begin
  Sel := SelTags;
  if (FMode = lmRecord) or (Length(Sel) <> 1) or (Sel[0] >= High(FProject.Tags)) then Exit;
  R := Sel[0];
  GridToProject;
  T := FProject.Tags[R + 1];
  FProject.Tags[R + 1] := FProject.Tags[R];
  FProject.Tags[R] := T;
  TagsChanged(R + 1, Ord(HasRowSel));
end;

procedure TMainForm.SpinIntervalChange(Sender: TObject);
begin
  if FLoading then Exit;
  FProject.IntervalMs := SpinInterval.Value;
  FModified := True;
  UpdateTitle;
  ApplyToThread;
end;

{ ------------------------------ Monitor / Record ------------------------ }

function TMainForm.CanRecord(out Why: string): Boolean;
var
  I: Integer;
begin
  Why := '';
  if Length(FLogRow) = 0 then Why := 'Add at least one tag.';
  for I := 0 to High(FTagErr) do
    if FTagErr[I] <> '' then
      Why := Why + Format('Tag %d (%s): %s', [I + 1, FProject.Tags[I].Name, FTagErr[I]]) + LineEnding;
  Result := Why = '';
end;

procedure TMainForm.SetMode(M: TLogMode);
var
  Editing: Boolean;
begin
  FMode := M;
  FThread.SetMode(M);
  Editing := M <> lmRecord;           // no tag changes while recording
  if Editing then
    GridTags.Options := GridTags.Options + [goEditing]
  else
    GridTags.Options := GridTags.Options - [goEditing];
  SpinInterval.Enabled := Editing;
  MenuLogFolder.Enabled := Editing;
  MenuNetSettings.Enabled := Editing;
  MenuOpen.Enabled := Editing;
  BtnMonitor.Enabled := M = lmIdle;
  BtnRecord.Enabled := M <> lmRecord;
  BtnStop.Enabled := M <> lmIdle;
  TrayStop.Enabled := M <> lmIdle;
  UpdateTitle;
end;

procedure TMainForm.BtnMonitorClick(Sender: TObject);
begin
  GridToProject;
  ApplyToThread;
  SetMode(lmMonitor);
end;

procedure TMainForm.BtnRecordClick(Sender: TObject);
var
  Why: string;
begin
  GridToProject;
  Validate;
  if not CanRecord(Why) then
  begin
    MessageDlg('Record', 'Cannot start recording:' + LineEnding + Why, mtWarning, [mbOK], 0);
    Exit;
  end;
  ForceDirectories(FProject.LogFolder);
  ApplyToThread;
  SetMode(lmRecord);
end;

procedure TMainForm.BtnStopClick(Sender: TObject);
begin
  SetMode(lmIdle);
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
var
  S: TLogSnapshot;
  I, K: Integer;
  Rec: string;
begin
  S := FThread.Snapshot;
  FBlink := not FBlink;

  { connection }
  if FMode = lmIdle then ShapeConn.Brush.Color := clSilver
  else if S.Connected then ShapeConn.Brush.Color := clLime
  else ShapeConn.Brush.Color := clRed;
  LabelConn.Caption := S.Status;
  if S.Connected and (FMode <> lmIdle) then
    LabelConn.Caption := S.Status + Format('   |  %d req  %.1f ms  %.1f /s',
      [S.Requests, S.CycleMs, S.RatePerS], DisplayFmt);

  { record status: blinking red dot }
  if FMode = lmRecord then
  begin
    if FBlink then ShapeRec.Brush.Color := clRed else ShapeRec.Brush.Color := $000000A0;
    Rec := Format('RECORDING  %s  rows %d', [ExtractFileName(S.RecFile), S.Rows]);
    if S.Pending > 0 then Rec := Rec + Format('  (%d waiting: file locked)', [S.Pending]);
    if S.Overrun then Rec := Rec + '  (reading slower than interval)';
    LabelRec.Caption := Rec;
    LabelRec.Font.Color := clRed;
    StatusBar1.Panels[1].Text := S.RecFile;
  end
  else
  begin
    ShapeRec.Brush.Color := clSilver;
    ShowFolder;
    LabelRec.Caption := ModeText[FMode] + ' - not recording';
    LabelRec.Font.Color := clGrayText;
  end;
  TrayIcon1.Hint := 'PLC Data Logger - ' + ModeText[FMode] + LineEnding + S.Status;

  { values: logger tag K belongs to row FLogRow[K] + 1 (empty rows are not read) }
  SetLength(FLast, 0);
  SetLength(FLast, Length(FProject.Tags));
  for K := 0 to Min(High(S.Values), High(FLogRow)) do
    if FLogRow[K] <= High(FLast) then FLast[FLogRow[K]] := S.Values[K];
  for I := 0 to Min(High(FLast), GridTags.RowCount - 2) do
    if (FMode = lmIdle) or IsBlankTag(FProject.Tags[I]) then
      GridTags.Cells[COL_VALUE, I + 1] := ''
    else if FLast[I].Ok and (I <= High(FTypes)) then
      GridTags.Cells[COL_VALUE, I + 1] := FormatValue(FTypes[I], FProject.Tags[I].Format, FLast[I].Value)
    else if FLast[I].Err <> '' then
      GridTags.Cells[COL_VALUE, I + 1] := '? ' + FLast[I].Err
    else
      GridTags.Cells[COL_VALUE, I + 1] := '---';
end;

{ ------------------------------ File menu ------------------------------- }

procedure TMainForm.UpdateTitle;
var
  N: string;
begin
  if FProjectFile = '' then N := 'untitled' else N := ExtractFileName(FProjectFile);
  if FModified then N := N + ' *';
  Caption := Format('PLC Data Logger - %s  [%s]', [N, ModeText[FMode]]);
end;

procedure TMainForm.LoadProjectFile(const AFile: string);
begin
  LoadProject(AFile, FProject);
  SetLength(FRowSel, 0);
  FProjectFile := AFile;
  FModified := False;
  ProjectToGrid;
  FCfg.LastProject := AFile;
  SaveNetConfig(FCfg);
  UpdateTitle;
end;

function TMainForm.DoSave(AsNew: Boolean): Boolean;
begin
  Result := False;
  GridToProject;
  if AsNew or (FProjectFile = '') then
  begin
    if FProjectFile <> '' then SaveDialog1.FileName := FProjectFile;
    if not SaveDialog1.Execute then Exit;
    FProjectFile := SaveDialog1.FileName;
  end;
  SaveProject(FProjectFile, FProject);
  FModified := False;
  FCfg.LastProject := FProjectFile;
  SaveNetConfig(FCfg);
  UpdateTitle;
  Result := True;
end;

procedure TMainForm.MenuOpenClick(Sender: TObject);
begin
  if FModified and (MessageDlg('Open', 'The tag list was changed. Save it first?',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes) then
    if not DoSave(False) then Exit;
  if not OpenDialog1.Execute then Exit;
  LoadProjectFile(OpenDialog1.FileName);
  ApplyToThread;
end;

procedure TMainForm.MenuSaveClick(Sender: TObject);
begin
  DoSave(False);
end;

procedure TMainForm.MenuSaveAsClick(Sender: TObject);
begin
  DoSave(True);
end;

procedure TMainForm.MenuOpenFolderClick(Sender: TObject);
var
  D: string;
begin
  { the folder of the current month if it exists, else the log folder }
  D := LogFolderOf(FProject.LogFolder, Now);
  if not DirectoryExists(D) then
  begin
    D := FProject.LogFolder;
    ForceDirectories(D);
  end;
  OpenDocument(D);
end;

procedure TMainForm.MenuLogFolderClick(Sender: TObject);
begin
  if FMode = lmRecord then Exit;
  SelectDirectoryDialog1.InitialDir := FProject.LogFolder;
  if not SelectDirectoryDialog1.Execute then Exit;
  FProject.LogFolder := SelectDirectoryDialog1.FileName;
  ShowFolder;
  FModified := True;
  UpdateTitle;
  ApplyToThread;
end;

{ status bar: where the CSV files go (while recording: the file itself) }
procedure TMainForm.ShowFolder;
begin
  StatusBar1.Panels[1].Text := 'Log folder: ' + FProject.LogFolder;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  Close;
end;

{ ------------------------------ Network / Help -------------------------- }

procedure TMainForm.MenuNetSettingsClick(Sender: TObject);
var
  C: TNetConfig;
begin
  C := FCfg;
  if not TNetForm.Execute(Self, C) then Exit;
  FCfg := C;
  SaveNetConfig(FCfg);          // loaded again automatically at the next start
  Validate;                     // addresses depend on the protocol
  ApplyToThread;
end;

procedure TMainForm.MenuAboutClick(Sender: TObject);
begin
  MessageDlg('About', 'PLC Data Logger' + LineEnding +
    'S7 TCP/IP, Modbus TCP/IP, Modbus RTU (RS485)' + LineEnding +
    'CSV: <folder>\mm-yyyy\dd-mm-yyyy.csv' + LineEnding +
    'Network config: ' + AppIniName, mtInformation, [mbOK], 0);
end;

{ ------------------------------ background (tray) ----------------------- }

procedure TMainForm.AppMinimize(Sender: TObject);
begin
  MenuTrayClick(nil);
end;

procedure TMainForm.MenuTrayClick(Sender: TObject);
begin
  TrayIcon1.Visible := True;
  Hide;                          // the logger thread keeps running
  TrayIcon1.ShowBalloonHint;
end;

procedure TMainForm.ShowFromTray;
begin
  Show;
  WindowState := wsNormal;
  Application.Restore;
  BringToFront;
  TrayIcon1.Visible := False;
end;

procedure TMainForm.TrayIcon1DblClick(Sender: TObject);
begin
  ShowFromTray;
end;

procedure TMainForm.TrayShowClick(Sender: TObject);
begin
  ShowFromTray;
end;

procedure TMainForm.TrayStopClick(Sender: TObject);
begin
  SetMode(lmIdle);
end;

end.
