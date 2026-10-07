unit frmMain;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Browser window of the FP HTML Viewer demo: a navigation bar around the
// TXelHtml control. All the HTML/CSS work happens inside TXelHtml

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls,
  Dialogs, LCLType, XelHtml;

type

  // TMainForm

  TMainForm = class(TForm)
    BtnBack: TButton;
    BtnForward: TButton;
    BtnGo: TButton;
    BtnOpen: TButton;
    EdUrl: TEdit;
    Html: TXelHtml;
    OpenDialog: TOpenDialog;
    PanelTop: TPanel;
    StatusBar: TStatusBar;
    procedure BtnBackClick(Sender: TObject);
    procedure BtnForwardClick(Sender: TObject);
    procedure BtnGoClick(Sender: TObject);
    procedure BtnOpenClick(Sender: TObject);
    procedure EdUrlKeyPress(Sender: TObject; var Key: Char);
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HtmlHistoryChange(Sender: TObject);
    procedure HtmlLocationChange(Sender: TObject; const URL: string);
    procedure HtmlStatusChange(Sender: TObject; const Text: string);
    procedure HtmlTitleChange(Sender: TObject; const Text: string);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

// TMainForm

procedure TMainForm.FormCreate(Sender: TObject);
begin
  // file/URL from the command line
  if ParamCount >= 1 then
    Html.Navigate(ParamStr(1));
end;

// Browser shortcuts that work everywhere, also while the address bar has focus.
procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_F5 then
    Html.Reload
  else if (ssCtrl in Shift) and (Key = VK_L) then
  begin
    EdUrl.SetFocus;
    EdUrl.SelectAll;
  end
  else if (ssAlt in Shift) and (Key = VK_LEFT) then
    Html.GoBack
  else if (ssAlt in Shift) and (Key = VK_RIGHT) then
    Html.GoForward
  else
    Exit;
  Key := 0;
end;

procedure TMainForm.BtnGoClick(Sender: TObject);
begin
  Html.Navigate(EdUrl.Text);
end;

procedure TMainForm.EdUrlKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;
    Html.Navigate(EdUrl.Text);
  end;
end;

procedure TMainForm.BtnOpenClick(Sender: TObject);
begin
  if OpenDialog.Execute then
    Html.Navigate(OpenDialog.FileName);
end;

procedure TMainForm.BtnBackClick(Sender: TObject);
begin
  Html.GoBack;
end;

procedure TMainForm.BtnForwardClick(Sender: TObject);
begin
  Html.GoForward;
end;

procedure TMainForm.HtmlHistoryChange(Sender: TObject);
begin
  BtnBack.Enabled := Html.CanGoBack;
  BtnForward.Enabled := Html.CanGoForward;
end;

procedure TMainForm.HtmlLocationChange(Sender: TObject; const URL: string);
begin
  EdUrl.Text := URL;
end;

procedure TMainForm.HtmlStatusChange(Sender: TObject; const Text: string);
begin
  StatusBar.SimpleText := Text;
end;

procedure TMainForm.HtmlTitleChange(Sender: TObject; const Text: string);
begin
  if Text <> '' then
    Caption := Text + ' — FP HTML Viewer'
  else
    Caption := 'FP HTML Viewer';
end;

end.
