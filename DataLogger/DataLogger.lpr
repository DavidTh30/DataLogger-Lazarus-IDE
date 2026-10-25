program DataLogger;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, umain, unetform, uaddrhelper, uaddress, udrivers, uconfig, uproject, ulogger, s7comm;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'PLC Data Logger';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
