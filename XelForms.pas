unit XelForms;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// HTML form support: control state (text value, checked, selected option),
// building the form data set and encoding it for submission
// (application/x-www-form-urlencoded, UTF-8), as described in the HTML spec.
// The current value of a control is kept in the DOM (the value / checked /
// selected attributes, textarea text), so every change bumps the document
// version and the page is laid out and repainted.

interface

uses
  Classes, SysUtils, Generics.Collections, XelDom;

type
  TFormField = record
    Name: string;
    Value: string;
  end;
  TFormFields = TList<TFormField>;

// The form that owns the control: the form="id" attribute, else the nearest <form>.
function OwnerForm(E: TDOMElement): TDOMElement;

// input submit/image or <button> without type / with type=submit
function IsSubmitButton(E: TDOMElement): Boolean;
// single-line text inputs and <textarea> — controls that take keyboard input
function IsTextControl(E: TDOMElement): Boolean;
function IsCheckable(E: TDOMElement): Boolean; // checkbox / radio
function IsSelect(E: TDOMElement): Boolean;
function IsDisabled(E: TDOMElement): Boolean;

function GetControlValue(E: TDOMElement): string;
procedure SetControlValue(E: TDOMElement; const AValue: string);

// Click on a checkbox toggles it; click on a radio checks it and unchecks the
// other radios with the same name in the same form.
procedure ToggleCheckable(E: TDOMElement);

// <option> elements of a <select> (also inside <optgroup>)
procedure GetOptions(Select: TDOMElement; AList: TList<TDOMElement>);
function OptionValue(Opt: TDOMElement): string;
function OptionLabel(Opt: TDOMElement): string;
// the selected <option> (the first one when none is marked), or nil
function SelectedOption(Select: TDOMElement): TDOMElement;
procedure SelectOption(Select, Opt: TDOMElement);

// Builds the form data set: successful controls in document order.
// Submitter = the button that submitted the form (nil = implicit submission).
procedure CollectFormData(Form, Submitter: TDOMElement; Fields: TFormFields);
// application/x-www-form-urlencoded, UTF-8 (space -> '+')
function UrlEncodeForm(Fields: TFormFields): string;

// Resolved submission target: method (GET/POST), action URL and body.
// For GET the encoded data replaces the query string of the action URL.
procedure PrepareSubmission(Form, Submitter: TDOMElement; const BaseUrl: string;
  out Method, Url, Body: string);

implementation

uses
  StrUtils, XelUrl;

function Attr(E: TDOMElement; const AName: string): string;
begin
  Result := E.GetAttribute(AName);
end;

function InputType(E: TDOMElement): string;
begin
  Result := LowerCase(Trim(Attr(E, 'type')));
  if Result = '' then
    Result := 'text';
end;

function OwnerForm(E: TDOMElement): TDOMElement;
var
  N: TDOMNode;
  Id: string;
begin
  Result := nil;
  if E = nil then Exit;
  Id := Attr(E, 'form');
  if (Id <> '') and (E.OwnerDocument <> nil) then
  begin
    Result := E.OwnerDocument.GetElementById(Id);
    if (Result <> nil) and (Result.TagName = 'form') then
      Exit;
    Result := nil;
  end;
  N := E.ParentNode;
  while N <> nil do
  begin
    if (N is TDOMElement) and (TDOMElement(N).TagName = 'form') then
      Exit(TDOMElement(N));
    N := N.ParentNode;
  end;
end;

function IsSubmitButton(E: TDOMElement): Boolean;
var
  T: string;
begin
  Result := False;
  if E = nil then Exit;
  T := LowerCase(Trim(Attr(E, 'type')));
  if E.TagName = 'button' then
    Result := (T = '') or (T = 'submit')
  else if E.TagName = 'input' then
    Result := (T = 'submit') or (T = 'image');
end;

function IsTextControl(E: TDOMElement): Boolean;
begin
  Result := False;
  if E = nil then Exit;
  if E.TagName = 'textarea' then
    Exit(True);
  if E.TagName = 'input' then
    Result := MatchStr(InputType(E), ['text', 'password', 'search', 'email',
      'url', 'tel', 'number', 'date', 'time', 'datetime-local', 'month', 'week']);
end;

function IsCheckable(E: TDOMElement): Boolean;
begin
  Result := (E <> nil) and (E.TagName = 'input') and
    MatchStr(InputType(E), ['checkbox', 'radio']);
end;

function IsSelect(E: TDOMElement): Boolean;
begin
  Result := (E <> nil) and (E.TagName = 'select');
end;

function IsDisabled(E: TDOMElement): Boolean;
var
  N: TDOMNode;
begin
  Result := False;
  if E = nil then Exit;
  if E.HasAttribute('disabled') then
    Exit(True);
  // a disabled <fieldset> disables its controls
  N := E.ParentNode;
  while N <> nil do
  begin
    if (N is TDOMElement) and (TDOMElement(N).TagName = 'fieldset') and
       TDOMElement(N).HasAttribute('disabled') then
      Exit(True);
    N := N.ParentNode;
  end;
end;

function GetControlValue(E: TDOMElement): string;
begin
  if E.TagName = 'textarea' then
    Result := E.TextContent
  else
    Result := Attr(E, 'value');
end;

procedure SetControlValue(E: TDOMElement; const AValue: string);
begin
  if E.TagName = 'textarea' then
  begin
    E.ClearChildren;
    if AValue <> '' then
      E.AppendChild(E.OwnerDocument.CreateTextNode(AValue));
  end
  else
    E.SetAttribute('value', AValue);
end;

procedure CollectElements(N: TDOMNode; AList: TList<TDOMElement>);
var
  I: Integer;
begin
  for I := 0 to N.ChildCount - 1 do
    if N[I] is TDOMElement then
    begin
      AList.Add(TDOMElement(N[I]));
      CollectElements(N[I], AList);
    end;
end;

procedure ToggleCheckable(E: TDOMElement);
var
  All: TList<TDOMElement>;
  Other, Form: TDOMElement;
  Scope: TDOMNode;
begin
  if InputType(E) = 'checkbox' then
  begin
    if E.HasAttribute('checked') then
      E.RemoveAttribute('checked')
    else
      E.SetAttribute('checked', 'checked');
    Exit;
  end;
  // radio: uncheck the rest of the group
  if E.HasAttribute('checked') then
    Exit;
  Form := OwnerForm(E);
  if Form <> nil then
    Scope := Form
  else
    Scope := E.OwnerDocument;
  All := TList<TDOMElement>.Create;
  try
    CollectElements(Scope, All);
    for Other in All do
      if (Other <> E) and IsCheckable(Other) and (InputType(Other) = 'radio') and
         (Attr(Other, 'name') = Attr(E, 'name')) and (OwnerForm(Other) = Form) then
        Other.RemoveAttribute('checked');
  finally
    All.Free;
  end;
  E.SetAttribute('checked', 'checked');
end;

procedure GetOptions(Select: TDOMElement; AList: TList<TDOMElement>);
var
  All: TList<TDOMElement>;
  E: TDOMElement;
begin
  All := TList<TDOMElement>.Create;
  try
    CollectElements(Select, All);
    for E in All do
      if E.TagName = 'option' then
        AList.Add(E);
  finally
    All.Free;
  end;
end;

function OptionLabel(Opt: TDOMElement): string;
begin
  if Opt.HasAttribute('label') then
    Result := Attr(Opt, 'label')
  else
    Result := Trim(Opt.TextContent);
end;

function OptionValue(Opt: TDOMElement): string;
begin
  if Opt.HasAttribute('value') then
    Result := Attr(Opt, 'value')
  else
    Result := Trim(Opt.TextContent);
end;

function SelectedOption(Select: TDOMElement): TDOMElement;
var
  Opts: TList<TDOMElement>;
  O: TDOMElement;
begin
  Result := nil;
  Opts := TList<TDOMElement>.Create;
  try
    GetOptions(Select, Opts);
    for O in Opts do
      if O.HasAttribute('selected') then
        Exit(O);
    if (Opts.Count > 0) and not Select.HasAttribute('multiple') then
      Result := Opts[0];
  finally
    Opts.Free;
  end;
end;

procedure SelectOption(Select, Opt: TDOMElement);
var
  Opts: TList<TDOMElement>;
  O: TDOMElement;
begin
  Opts := TList<TDOMElement>.Create;
  try
    GetOptions(Select, Opts);
    for O in Opts do
      if (O <> Opt) and O.HasAttribute('selected') then
        O.RemoveAttribute('selected');
  finally
    Opts.Free;
  end;
  if (Opt <> nil) and not Opt.HasAttribute('selected') then
    Opt.SetAttribute('selected', 'selected');
end;

procedure AddField(Fields: TFormFields; const AName, AValue: string);
var
  F: TFormField;
begin
  F.Name := AName;
  F.Value := AValue;
  Fields.Add(F);
end;

procedure CollectFormData(Form, Submitter: TDOMElement; Fields: TFormFields);
var
  All, Opts: TList<TDOMElement>;
  E, O: TDOMElement;
  Name, T: string;
begin
  All := TList<TDOMElement>.Create;
  Opts := TList<TDOMElement>.Create;
  try
    // controls inside the form plus controls elsewhere with form="<id>"
    if Form.OwnerDocument <> nil then
      CollectElements(Form.OwnerDocument, All)
    else
      CollectElements(Form, All);
    for E in All do
    begin
      if not MatchStr(E.TagName, ['input', 'button', 'select', 'textarea']) then
        Continue;
      if OwnerForm(E) <> Form then
        Continue;
      if IsDisabled(E) then
        Continue;
      Name := Attr(E, 'name');
      if E.TagName = 'input' then
      begin
        T := InputType(E);
        if (T = 'image') and (E = Submitter) then
        begin
          // the click position is not tracked: report the top-left corner
          if Name <> '' then
          begin
            AddField(Fields, Name + '.x', '0');
            AddField(Fields, Name + '.y', '0');
          end
          else
          begin
            AddField(Fields, 'x', '0');
            AddField(Fields, 'y', '0');
          end;
          Continue;
        end;
        if Name = '' then
          Continue;
        if MatchStr(T, ['submit', 'image', 'button', 'reset']) then
        begin
          if (E = Submitter) and (T = 'submit') then
            AddField(Fields, Name, Attr(E, 'value'));
          Continue;
        end;
        if T = 'file' then
          Continue; // file upload is not supported
        if MatchStr(T, ['checkbox', 'radio']) then
        begin
          if E.HasAttribute('checked') then
            if E.HasAttribute('value') then
              AddField(Fields, Name, Attr(E, 'value'))
            else
              AddField(Fields, Name, 'on');
          Continue;
        end;
        AddField(Fields, Name, Attr(E, 'value'));
      end
      else if E.TagName = 'button' then
      begin
        if (E = Submitter) and (Name <> '') then
          AddField(Fields, Name, Attr(E, 'value'));
      end
      else if E.TagName = 'select' then
      begin
        if Name = '' then
          Continue;
        if E.HasAttribute('multiple') then
        begin
          Opts.Clear;
          GetOptions(E, Opts);
          for O in Opts do
            if O.HasAttribute('selected') and not O.HasAttribute('disabled') then
              AddField(Fields, Name, OptionValue(O));
        end
        else
        begin
          O := SelectedOption(E);
          if O <> nil then
            AddField(Fields, Name, OptionValue(O));
        end;
      end
      else if (E.TagName = 'textarea') and (Name <> '') then
        // the spec normalizes line breaks to CRLF
        AddField(Fields, Name, StringReplace(
          StringReplace(GetControlValue(E), #13#10, #10, [rfReplaceAll]),
          #10, #13#10, [rfReplaceAll]));
    end;
  finally
    Opts.Free;
    All.Free;
  end;
end;

function UrlEncodeComponent(const S: string): string;
const
  Hex = '0123456789ABCDEF';
var
  U: RawByteString;
  I: Integer;
  C: AnsiChar;
begin
  // strings are UTF-8 throughout the program (LCL convention): encode the bytes as they are
  U := S;
  SetCodePage(U, CP_UTF8, False);
  Result := '';
  for I := 1 to Length(U) do
  begin
    C := U[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '*', '-', '.', '_'] then
      Result := Result + Char(C)
    else if C = ' ' then
      Result := Result + '+'
    else
      Result := Result + '%' + Hex[Ord(C) shr 4 + 1] + Hex[Ord(C) and 15 + 1];
  end;
end;

function UrlEncodeForm(Fields: TFormFields): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Fields.Count - 1 do
  begin
    if I > 0 then
      Result := Result + '&';
    Result := Result + UrlEncodeComponent(Fields[I].Name) + '=' +
      UrlEncodeComponent(Fields[I].Value);
  end;
end;

procedure PrepareSubmission(Form, Submitter: TDOMElement; const BaseUrl: string;
  out Method, Url, Body: string);
var
  Action: string;
  Fields: TFormFields;
  P: Integer;
begin
  // the submitter's formaction/formmethod override the form's attributes
  Action := '';
  Method := '';
  if Submitter <> nil then
  begin
    Action := Attr(Submitter, 'formaction');
    Method := Attr(Submitter, 'formmethod');
  end;
  if Action = '' then
    Action := Attr(Form, 'action');
  if Method = '' then
    Method := Attr(Form, 'method');
  Method := UpperCase(Trim(Method));
  if Method <> 'POST' then
    Method := 'GET';
  // an empty action submits to the document itself
  if Trim(Action) = '' then
    Url := StripFragment(BaseUrl)
  else
    Url := StripFragment(ResolveUrl(BaseUrl, Trim(Action)));

  Fields := TFormFields.Create;
  try
    CollectFormData(Form, Submitter, Fields);
    Body := UrlEncodeForm(Fields);
  finally
    Fields.Free;
  end;

  if Method = 'GET' then
  begin
    P := Pos('?', Url);
    if P > 0 then
      SetLength(Url, P - 1);
    Url := Url + '?' + Body;
    Body := '';
  end;
end;

end.
