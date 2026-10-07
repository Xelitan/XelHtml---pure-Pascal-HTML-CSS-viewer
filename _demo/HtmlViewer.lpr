program HtmlViewer;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

uses
  Interfaces, // LCL widgetset initialization
  Forms,
  XelHtmlTls, // HTTPS (TlsLib4Pascal)
  frmMain;

begin
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
