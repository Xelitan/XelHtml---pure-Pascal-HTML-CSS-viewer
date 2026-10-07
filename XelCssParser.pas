unit XelCssParser;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// CSS parser: style sheets, rules, selectors (tag, .class, #id, [attr],
// combinators ' ', '>', '+', '~'), specificity, declarations with !important.
// Also extracts resources: @font-face -> fonts, @import -> further CSS sheets,
// background url(...) -> images.
// Pseudo-classes: structural (:nth-child(An+B of S), :first-of-type...),
// logical (:not, :is, :where, :has), dynamic (:hover, :focus, :focus-within,
// :target — state supplied by the application through GHoverElement etc.),
// form states (:checked, :disabled, :required, :placeholder-shown, :invalid...)
// and :lang/:dir. An unknown pseudo-class drops the whole rule, as in browsers.

interface

uses
  Classes, SysUtils, StrUtils, Generics.Collections, XelDom;

var
  // viewport width (px) used to evaluate @media queries (min/max-width).
  // Set by the application layer before parsing CSS.
  GMediaWidth: Integer = 1024;

  // Dynamic state for :hover, :focus and :target. Set by the application layer
  // before styles are resolved (nil / '' = none).
  GHoverElement: TDOMElement = nil;  // element under the mouse (ancestors match too)
  GFocusElement: TDOMElement = nil;  // form control with keyboard focus
  GTargetId: string = '';            // fragment of the document URL (#id)

  // Set by the parser when a style sheet uses :hover / :focus*, so the
  // application re-styles on mouse moves and focus changes only when needed.
  GUsesHover: Boolean = False;
  GUsesFocus: Boolean = False;

type
  TAttrOp = (aoExists, aoEquals, aoIncludes, aoPrefix, aoSuffix, aoSubstr, aoDash);

  TPseudoElem = (peNone, peBefore, peAfter);

  TAttrTest = record
    Name: string;
    Op: TAttrOp;
    Value: string;
  end;

  TComplexSel = class;

  // a pseudo-class with its pre-parsed argument
  TPseudoClass = record
    Name: string;                    // lower case, without the argument
    Arg: string;                     // raw argument of name(...)
    Sels: TObjectList<TComplexSel>;  // :not/:is/:where/:has list, :nth-*(An+B of S)
    NthA, NthB: Integer;             // An+B of :nth-*
  end;

  // a single simple selector, e.g. "div#main.box[href]:hover"
  TCompoundSel = class
  public
    Tag: string;                  // '' or '*' = any
    Id: string;
    Classes: array of string;
    Attrs: array of TAttrTest;
    Pseudos: array of TPseudoClass;
    PseudoElem: TPseudoElem;      // ::before / ::after
    NeverMatches: Boolean;        // valid but unsupported pseudo-element (::marker...)
    Invalid: Boolean;             // unknown pseudo-class/element: drops the whole rule
    IsScope: Boolean;             // :has() anchor — matches only the :has() subject
    destructor Destroy; override;
    function Matches(E: TDOMElement): Boolean;
    function Specificity: Integer;
  end;

  TCombinator = (cbDescendant, cbChild, cbAdjacent, cbSibling);

  // complex selector, e.g. "ul > li a"
  TComplexSel = class
  public
    Parts: TObjectList<TCompoundSel>;
    Combs: array of TCombinator; // Combs[i] between Parts[i] and Parts[i+1]
    Specificity: Integer;
    Invalid: Boolean;            // contains an unknown pseudo-class/element
    constructor Create;
    destructor Destroy; override;
    function Matches(E: TDOMElement): Boolean;
    function PseudoElement: TPseudoElem; // ::before/::after from the last compound
  end;

  TCssDecl = class
  public
    Prop: string;
    Value: string;
    Important: Boolean;
  end;

  TCssRule = class
  public
    Selectors: TObjectList<TComplexSel>;
    Decls: TObjectList<TCssDecl>;
    constructor Create;
    destructor Destroy; override;
  end;

  TFontFace = record
    Family: string;
    Url: string;
  end;

  TCssStyleSheet = class
  public
    Rules: TObjectList<TCssRule>;
    FontFaces: array of TFontFace;
    Imports: TStringList;    // absolute URLs of style sheets from @import
    ImageUrls: TStringList;  // absolute URLs of background images
    BaseUrl: string;
    Loaded: Boolean;         // whether the content has already been parsed
    constructor Create;
    destructor Destroy; override;
  end;

procedure ParseCss(const Src, ABaseUrl: string; Sheet: TCssStyleSheet);
procedure ParseDeclarations(const S: string; Decls: TObjectList<TCssDecl>);
function ExtractFirstUrl(const Value: string): string;

implementation

uses
  Math, XelUrl, XelTextUtil;

type
  TSelListMode = (slmStrict, slmForgiving, slmRelative);

function ParseCompound(const S: string): TCompoundSel; forward;
function ParseSelectorList(const S: string; List: TObjectList<TComplexSel>;
  Mode: TSelListMode): Boolean; forward;

var
  // subject of the :has() being evaluated (matched by the IsScope anchor)
  GScopeElement: TDOMElement = nil;

// ---- element helpers for pseudo-classes ----

function IsAncestorOrSelf(A, E: TDOMElement): Boolean;
var
  N: TDOMNode;
begin
  N := E;
  while N <> nil do
  begin
    if N = A then
      Exit(True);
    N := N.ParentNode;
  end;
  Result := False;
end;

function AnyMatches(Sels: TObjectList<TComplexSel>; E: TDOMElement): Boolean;
var
  Sel: TComplexSel;
begin
  if Sels <> nil then
    for Sel in Sels do
      if Sel.Matches(E) then
        Exit(True);
  Result := False;
end;

// 1-based position among the element siblings; OfType = same tag only;
// Filter <> nil = only siblings matching the list (:nth-child(An+B of S)).
function ElementIndex(E: TDOMElement; FromEnd, OfType: Boolean;
  Filter: TObjectList<TComplexSel>): Integer;
var
  Sib: TDOMNode;
begin
  Result := 1;
  if FromEnd then
    Sib := E.NextSibling
  else
    Sib := E.PreviousSibling;
  while Sib <> nil do
  begin
    if (Sib is TDOMElement) and
       ((not OfType) or (TDOMElement(Sib).TagName = E.TagName)) and
       ((Filter = nil) or AnyMatches(Filter, TDOMElement(Sib))) then
      Inc(Result);
    if FromEnd then
      Sib := Sib.NextSibling
    else
      Sib := Sib.PreviousSibling;
  end;
end;

function HasElementSibling(E: TDOMElement; Forward_, OfType: Boolean): Boolean;
var
  Sib: TDOMNode;
begin
  Result := False;
  if Forward_ then
    Sib := E.NextSibling
  else
    Sib := E.PreviousSibling;
  while Sib <> nil do
  begin
    if (Sib is TDOMElement) and
       ((not OfType) or (TDOMElement(Sib).TagName = E.TagName)) then
      Exit(True);
    if Forward_ then
      Sib := Sib.NextSibling
    else
      Sib := Sib.PreviousSibling;
  end;
end;

// Parses An+B ("odd", "even", "3", "-n+2", "2n+1"...). False = invalid.
function ParseNth(const S: string; out A, B: Integer): Boolean;
var
  L, AStr, BStr: string;
  P: Integer;
begin
  L := StringReplace(LowerCase(Trim(S)), ' ', '', [rfReplaceAll]);
  Result := L <> '';
  A := 0;
  B := 0;
  if L = 'odd' then
  begin
    A := 2; B := 1;
  end
  else if L = 'even' then
  begin
    A := 2; B := 0;
  end
  else
  begin
    P := Pos('n', L);
    if P = 0 then
      Result := TryStrToInt(L, B)
    else
    begin
      AStr := Copy(L, 1, P - 1);
      BStr := Copy(L, P + 1, MaxInt);
      if (AStr = '') or (AStr = '+') then
        A := 1
      else if AStr = '-' then
        A := -1
      else
        Result := TryStrToInt(AStr, A);
      if Result and (BStr <> '') then
        Result := (BStr[1] in ['+', '-']) and TryStrToInt(BStr, B);
    end;
  end;
end;

function MatchNth(A, B, Idx: Integer): Boolean;
begin
  if A = 0 then
    Result := Idx = B
  else
    Result := ((Idx - B) mod A = 0) and (((Idx - B) div A) >= 0);
end;

function IsFormControl(E: TDOMElement): Boolean;
begin
  Result := MatchStr(E.TagName, ['input', 'button', 'select', 'textarea',
    'optgroup', 'option', 'fieldset']);
end;

function ControlDisabled(E: TDOMElement): Boolean;
var
  N: TDOMNode;
begin
  if E.HasAttribute('disabled') then
    Exit(True);
  N := E.ParentNode;
  while N is TDOMElement do
  begin
    // a disabled <fieldset> / <optgroup> disables its content
    if MatchStr(TDOMElement(N).TagName, ['fieldset', 'optgroup', 'select']) and
       TDOMElement(N).HasAttribute('disabled') then
      Exit(True);
    N := N.ParentNode;
  end;
  Result := False;
end;

function IsTextField(E: TDOMElement): Boolean;
begin
  Result := (E.TagName = 'textarea') or ((E.TagName = 'input') and
    MatchStr(LowerCase(E.GetAttribute('type')), ['', 'text', 'password',
      'search', 'email', 'url', 'tel', 'number', 'date', 'time',
      'datetime-local', 'month', 'week']));
end;

function ControlValue(E: TDOMElement): string;
begin
  if E.TagName = 'textarea' then
    Result := E.TextContent
  else
    Result := E.GetAttribute('value');
end;

function ParentSelect(Opt: TDOMElement): TDOMElement;
var
  N: TDOMNode;
begin
  N := Opt.ParentNode;
  while N is TDOMElement do
  begin
    if TDOMElement(N).TagName = 'select' then
      Exit(TDOMElement(N));
    N := N.ParentNode;
  end;
  Result := nil;
end;

// :checked for <option>: the selected one, or the first of a single <select>
function OptionChecked(Opt: TDOMElement): Boolean;
var
  Sel: TDOMElement;
  L: TList<TDOMElement>;
  O: TDOMElement;
begin
  if Opt.HasAttribute('selected') then
    Exit(True);
  Sel := ParentSelect(Opt);
  if (Sel = nil) or Sel.HasAttribute('multiple') then
    Exit(False);
  L := TList<TDOMElement>.Create;
  try
    Sel.GetElementsByTagName('option', L);
    for O in L do
      if O.HasAttribute('selected') then
        Exit(False);
    Result := (L.Count > 0) and (L[0] = Opt);
  finally
    L.Free;
  end;
end;

// constraint validation: only "required" is checked
function ControlInvalid(E: TDOMElement): Boolean;
var
  Typ: string;
begin
  Result := False;
  if not E.HasAttribute('required') or ControlDisabled(E) then
    Exit;
  Typ := LowerCase(E.GetAttribute('type'));
  if (E.TagName = 'input') and ((Typ = 'checkbox') or (Typ = 'radio')) then
    Result := not E.HasAttribute('checked')
  else if MatchStr(E.TagName, ['input', 'textarea']) then
    Result := ControlValue(E) = ''
  else if E.TagName = 'select' then
    Result := not E.HasAttribute('multiple') and
      (E.FindFirstByTag('option') <> nil) and
      (E.FindFirstByTag('option').GetAttribute('value') = '') and
      not E.FindFirstByTag('option').HasAttribute('selected');
end;

function InRange(E: TDOMElement; out Applies: Boolean): Boolean;
var
  V, Lo, Hi: Double;
  FS: TFormatSettings;
begin
  Result := True;
  Applies := (E.TagName = 'input') and
    MatchStr(LowerCase(E.GetAttribute('type')), ['number', 'range']) and
    (E.HasAttribute('min') or E.HasAttribute('max'));
  if not Applies then
    Exit;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if not TryStrToFloat(E.GetAttribute('value'), V, FS) then
    Exit;
  if TryStrToFloat(E.GetAttribute('min'), Lo, FS) and (V < Lo) then
    Result := False;
  if TryStrToFloat(E.GetAttribute('max'), Hi, FS) and (V > Hi) then
    Result := False;
end;

function LangMatches(E: TDOMElement; const Arg: string): Boolean;
var
  N: TDOMNode;
  Lang, R, Range: string;
  Ranges: TStringList;
begin
  Lang := '';
  N := E;
  while N is TDOMElement do
  begin
    if TDOMElement(N).HasAttribute('lang') then
    begin
      Lang := LowerCase(TDOMElement(N).GetAttribute('lang'));
      Break;
    end;
    N := N.ParentNode;
  end;
  Result := False;
  if Lang = '' then
    Exit;
  Ranges := TStringList.Create;
  try
    Ranges.StrictDelimiter := True;
    Ranges.Delimiter := ',';
    Ranges.DelimitedText := Arg;
    for R in Ranges do
    begin
      Range := LowerCase(Trim(R));
      if (Length(Range) >= 2) and (Range[1] in ['"', '''']) then
        Range := Copy(Range, 2, Length(Range) - 2);
      // "en" matches "en" and "en-US"; "*" matches any language
      if (Range = '*') or (Range = Lang) or
         ((Range <> '') and StartsStr(Range + '-', Lang)) then
        Exit(True);
    end;
  finally
    Ranges.Free;
  end;
end;

function DirIs(E: TDOMElement; const Dir: string): Boolean;
var
  N: TDOMNode;
  D: string;
begin
  D := 'ltr';
  N := E;
  while N is TDOMElement do
  begin
    if MatchStr(LowerCase(TDOMElement(N).GetAttribute('dir')), ['ltr', 'rtl']) then
    begin
      D := LowerCase(TDOMElement(N).GetAttribute('dir'));
      Break;
    end;
    N := N.ParentNode;
  end;
  Result := SameText(Trim(Dir), D);
end;

function IsSubmit(E: TDOMElement): Boolean;
var
  T: string;
begin
  T := LowerCase(E.GetAttribute('type'));
  Result := ((E.TagName = 'button') and ((T = '') or (T = 'submit'))) or
    ((E.TagName = 'input') and ((T = 'submit') or (T = 'image')));
end;

// the first submit button inside N, in document order (nil = none)
function FirstSubmit(N: TDOMNode): TDOMElement;
var
  I: Integer;
begin
  for I := 0 to N.ChildCount - 1 do
    if N[I] is TDOMElement then
    begin
      if IsSubmit(TDOMElement(N[I])) then
        Exit(TDOMElement(N[I]));
      Result := FirstSubmit(N[I]);
      if Result <> nil then
        Exit;
    end;
  Result := nil;
end;

// :default for buttons: the form's default (first) submit button
function IsDefaultButton(E: TDOMElement): Boolean;
var
  N: TDOMNode;
begin
  Result := False;
  if not IsSubmit(E) then
    Exit;
  N := E.ParentNode;
  while (N is TDOMElement) and (TDOMElement(N).TagName <> 'form') do
    N := N.ParentNode;
  if N is TDOMElement then
    Result := FirstSubmit(N) = E;
end;

// :has(): a relative selector starts at the subject (the IsScope anchor)
function HasMatches(E: TDOMElement; Sels: TObjectList<TComplexSel>): Boolean;
var
  Saved: TDOMElement;
  Sel: TComplexSel;

  function Subtree(N: TDOMNode): Boolean;
  var
    I: Integer;
  begin
    for I := 0 to N.ChildCount - 1 do
      if N[I] is TDOMElement then
      begin
        if Sel.Matches(TDOMElement(N[I])) or Subtree(N[I]) then
          Exit(True);
      end;
    Result := False;
  end;

  function Following: Boolean;
  var
    Sib: TDOMNode;
  begin
    Sib := E.NextSibling;
    while Sib <> nil do
    begin
      if Sib is TDOMElement then
        if Sel.Matches(TDOMElement(Sib)) or Subtree(Sib) then
          Exit(True);
      Sib := Sib.NextSibling;
    end;
    Result := False;
  end;

begin
  Result := False;
  if Sels = nil then
    Exit;
  Saved := GScopeElement;
  GScopeElement := E;
  try
    for Sel in Sels do
    begin
      if Sel.Combs[0] in [cbDescendant, cbChild] then
        Result := Subtree(E)
      else
        Result := Following;
      if Result then
        Exit;
    end;
  finally
    GScopeElement := Saved;
  end;
end;

function MatchPseudo(const P: TPseudoClass; E: TDOMElement): Boolean;
var
  Node: TDOMNode;
  Typ: string;
  Applies: Boolean;
begin
  case IndexStr(P.Name, [
    'first-child', 'last-child', 'only-child',                       // 0..2
    'first-of-type', 'last-of-type', 'only-of-type',                  // 3..5
    'nth-child', 'nth-last-child', 'nth-of-type', 'nth-last-of-type', // 6..9
    'not', 'is', 'where', 'matches', '-webkit-any', 'has',            // 10..15
    'empty', 'root', 'scope',                                         // 16..18
    'link', 'any-link', '-webkit-any-link', 'visited',                // 19..22
    'hover', 'focus', 'focus-visible', 'focus-within', 'target',      // 23..27
    'checked', 'default', 'disabled', 'enabled',                      // 28..31
    'required', 'optional', 'read-only', 'read-write',                // 32..35
    'placeholder-shown', 'valid', 'invalid', 'in-range', 'out-of-range', // 36..40
    'lang', 'dir', 'defined', 'open', 'closed']) of                   // 41..45
    0: Result := not HasElementSibling(E, False, False);
    1: Result := not HasElementSibling(E, True, False);
    2: Result := not HasElementSibling(E, False, False) and
                 not HasElementSibling(E, True, False);
    3: Result := not HasElementSibling(E, False, True);
    4: Result := not HasElementSibling(E, True, True);
    5: Result := not HasElementSibling(E, False, True) and
                 not HasElementSibling(E, True, True);
    6, 7: Result := ((P.Sels = nil) or AnyMatches(P.Sels, E)) and
            MatchNth(P.NthA, P.NthB, ElementIndex(E, P.Name = 'nth-last-child', False, P.Sels));
    8, 9: Result := MatchNth(P.NthA, P.NthB,
            ElementIndex(E, P.Name = 'nth-last-of-type', True, nil));
    10: Result := not AnyMatches(P.Sels, E);
    11..14: Result := AnyMatches(P.Sels, E);
    15: Result := HasMatches(E, P.Sels);
    16:
      begin
        // whitespace-only text counts as empty (Selectors level 4)
        Result := True;
        Node := E.FirstChild;
        while Node <> nil do
        begin
          if (Node is TDOMElement) or
             ((Node.NodeType = ntText) and (Trim(Node.NodeValue) <> '')) then
            Exit(False);
          Node := Node.NextSibling;
        end;
      end;
    17, 18: Result := (E.TagName = 'html') and (E.ParentNode is TDOMDocument);
    19..21: Result := MatchStr(E.TagName, ['a', 'area']) and E.HasAttribute('href');
    22: Result := False; // history is private: links are never :visited
    23: Result := (GHoverElement <> nil) and IsAncestorOrSelf(E, GHoverElement);
    24, 25: Result := (GFocusElement <> nil) and (E = GFocusElement);
    26: Result := (GFocusElement <> nil) and IsAncestorOrSelf(E, GFocusElement);
    27: Result := (GTargetId <> '') and ((E.GetId = GTargetId) or
          ((E.TagName = 'a') and (E.GetAttribute('name') = GTargetId)));
    28:
      begin
        Typ := LowerCase(E.GetAttribute('type'));
        if E.TagName = 'option' then
          Result := OptionChecked(E)
        else
          Result := (E.TagName = 'input') and ((Typ = 'checkbox') or (Typ = 'radio')) and
            E.HasAttribute('checked');
      end;
    29:
      begin
        Typ := LowerCase(E.GetAttribute('type'));
        Result := ((E.TagName = 'input') and ((Typ = 'checkbox') or (Typ = 'radio')) and
            E.HasAttribute('checked')) or
          ((E.TagName = 'option') and E.HasAttribute('selected')) or
          IsDefaultButton(E);
      end;
    30: Result := IsFormControl(E) and ControlDisabled(E);
    31: Result := IsFormControl(E) and not ControlDisabled(E);
    32: Result := MatchStr(E.TagName, ['input', 'select', 'textarea']) and
          E.HasAttribute('required');
    33: Result := MatchStr(E.TagName, ['input', 'select', 'textarea']) and
          not E.HasAttribute('required');
    34, 35:
      begin
        Result := (IsTextField(E) and not E.HasAttribute('readonly') and
          not ControlDisabled(E)) or
          SameText(E.GetAttribute('contenteditable'), 'true') or
          (E.HasAttribute('contenteditable') and (E.GetAttribute('contenteditable') = ''));
        if P.Name = 'read-only' then
          Result := not Result;
      end;
    36: Result := IsTextField(E) and (E.GetAttribute('placeholder') <> '') and
          (ControlValue(E) = '');
    37: Result := (MatchStr(E.TagName, ['input', 'select', 'textarea']) and
          not ControlInvalid(E)) or MatchStr(E.TagName, ['form', 'fieldset']);
    38: Result := MatchStr(E.TagName, ['input', 'select', 'textarea']) and
          ControlInvalid(E);
    39: Result := InRange(E, Applies) and Applies;
    40: Result := not InRange(E, Applies) and Applies;
    41: Result := LangMatches(E, P.Arg);
    42: Result := DirIs(E, P.Arg);
    43: Result := True;  // every element is defined (no custom elements)
    44: Result := MatchStr(E.TagName, ['details', 'dialog']) and E.HasAttribute('open');
    45: Result := MatchStr(E.TagName, ['details', 'dialog']) and not E.HasAttribute('open');
  else
    // known pseudo-classes for states this browser never has
    // (:active, :fullscreen, :autofill, :playing...)
    Result := False;
  end;
end;

// Pseudo-classes this browser understands. Any other name makes the selector
// invalid, which drops the whole rule — as in real browsers.
function KnownPseudoClass(const Name: string; HasArg: Boolean): Boolean;
begin
  if HasArg then
    Result := MatchStr(Name, ['not', 'is', 'where', 'matches', '-webkit-any',
      'has', 'nth-child', 'nth-last-child', 'nth-of-type', 'nth-last-of-type',
      'lang', 'dir'])
  else
    Result := MatchStr(Name, ['first-child', 'last-child', 'only-child',
      'first-of-type', 'last-of-type', 'only-of-type', 'empty', 'root', 'scope',
      'link', 'any-link', '-webkit-any-link', 'visited', 'hover', 'active',
      'focus', 'focus-visible', 'focus-within', 'target', 'checked', 'default',
      'indeterminate', 'disabled', 'enabled', 'required', 'optional',
      'read-only', 'read-write', 'placeholder-shown', 'valid', 'invalid',
      'in-range', 'out-of-range', 'user-valid', 'user-invalid', 'autofill',
      '-webkit-autofill', 'defined', 'open', 'closed', 'modal', 'fullscreen',
      'popover-open', 'picture-in-picture', 'playing', 'paused', 'seeking',
      'buffering', 'stalled', 'muted', 'volume-locked', 'host']);
end;

// Pseudo-elements that are valid but not rendered (the selector never matches).
function KnownPseudoElement(const Name: string): Boolean;
begin
  Result := MatchStr(Name, ['first-line', 'first-letter', 'marker',
    'placeholder', 'selection', 'backdrop', 'file-selector-button', 'cue',
    'spelling-error', 'grammar-error', 'target-text', 'details-content']) or
    StartsStr('-webkit-', Name) or StartsStr('view-transition', Name) or
    MatchStr(Copy(Name, 1, Pos('(', Name + '(') - 1),
      ['highlight', 'part', 'slotted', 'cue']);
end;

// ---- TCompoundSel ----

destructor TCompoundSel.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Pseudos) do
    Pseudos[I].Sels.Free;
  inherited Destroy;
end;

function TCompoundSel.Matches(E: TDOMElement): Boolean;
var
  I: Integer;
  AV: string;
begin
  Result := False;
  if NeverMatches then
    Exit;
  if IsScope then
    Exit(E = GScopeElement);

  if (Tag <> '') and (Tag <> '*') and (E.TagName <> Tag) then
    Exit;
  if (Id <> '') and (E.GetId <> Id) then
    Exit;
  for I := 0 to High(Classes) do
    if not E.HasClass(Classes[I]) then
      Exit;
  for I := 0 to High(Attrs) do
  begin
    if not E.HasAttribute(Attrs[I].Name) then
      Exit;
    AV := E.GetAttribute(Attrs[I].Name);
    case Attrs[I].Op of
      aoExists: ;
      aoEquals:
        if not SameText(AV, Attrs[I].Value) then Exit;
      aoIncludes:
        if Pos(' ' + LowerCase(Attrs[I].Value) + ' ',
               ' ' + LowerCase(AV) + ' ') = 0 then Exit;
      aoPrefix:
        if not SameText(Copy(AV, 1, Length(Attrs[I].Value)), Attrs[I].Value) then Exit;
      aoSuffix:
        if not SameText(Copy(AV, Length(AV) - Length(Attrs[I].Value) + 1, MaxInt),
                        Attrs[I].Value) then Exit;
      aoSubstr:
        if Pos(LowerCase(Attrs[I].Value), LowerCase(AV)) = 0 then Exit;
      aoDash:
        if not (SameText(AV, Attrs[I].Value) or
                SameText(Copy(AV, 1, Length(Attrs[I].Value) + 1),
                         Attrs[I].Value + '-')) then Exit;
    end;
  end;
  for I := 0 to High(Pseudos) do
    if not MatchPseudo(Pseudos[I], E) then
      Exit;
  Result := True;
end;

function MaxSpecificity(Sels: TObjectList<TComplexSel>): Integer;
var
  Sel: TComplexSel;
begin
  Result := 0;
  if Sels <> nil then
    for Sel in Sels do
      Result := Max(Result, Sel.Specificity);
end;

function TCompoundSel.Specificity: Integer;
var
  I: Integer;
begin
  Result := 0;
  if Id <> '' then
    Inc(Result, $10000);
  Inc(Result, (Length(Classes) + Length(Attrs)) * $100);
  for I := 0 to High(Pseudos) do
    if Pseudos[I].Name = 'where' then
      // :where() adds nothing
    else if MatchStr(Pseudos[I].Name, ['not', 'is', 'matches', '-webkit-any', 'has']) then
      Inc(Result, MaxSpecificity(Pseudos[I].Sels))
    else
      Inc(Result, $100 + MaxSpecificity(Pseudos[I].Sels)); // nth-*(... of S) too
  if (Tag <> '') and (Tag <> '*') then
    Inc(Result, 1);
  if (PseudoElem <> peNone) or NeverMatches then
    Inc(Result, 1);
end;

// ---- TComplexSel ----

constructor TComplexSel.Create;
begin
  inherited Create;
  Parts := TObjectList<TCompoundSel>.Create(True);
end;

destructor TComplexSel.Destroy;
begin
  Parts.Free;
  inherited Destroy;
end;

function TComplexSel.Matches(E: TDOMElement): Boolean;

  function MatchFrom(PartIdx: Integer; Elem: TDOMElement): Boolean;
  var
    Node: TDOMNode;
  begin
    Result := False;
    if not Parts[PartIdx].Matches(Elem) then
      Exit;
    if PartIdx = 0 then
      Exit(True);
    case Combs[PartIdx - 1] of
      cbDescendant:
        begin
          Node := Elem.ParentNode;
          while (Node <> nil) and (Node is TDOMElement) do
          begin
            if MatchFrom(PartIdx - 1, TDOMElement(Node)) then
              Exit(True);
            Node := Node.ParentNode;
          end;
        end;
      cbChild:
        begin
          Node := Elem.ParentNode;
          if (Node <> nil) and (Node is TDOMElement) then
            Result := MatchFrom(PartIdx - 1, TDOMElement(Node));
        end;
      cbAdjacent:
        begin
          Node := Elem.PreviousSibling;
          while (Node <> nil) and not (Node is TDOMElement) do
            Node := Node.PreviousSibling;
          if Node <> nil then
            Result := MatchFrom(PartIdx - 1, TDOMElement(Node));
        end;
      cbSibling:
        begin
          Node := Elem.PreviousSibling;
          while Node <> nil do
          begin
            if (Node is TDOMElement) and
               MatchFrom(PartIdx - 1, TDOMElement(Node)) then
              Exit(True);
            Node := Node.PreviousSibling;
          end;
        end;
    end;
  end;

begin
  if Parts.Count = 0 then
    Exit(False);
  Result := MatchFrom(Parts.Count - 1, E);
end;

function TComplexSel.PseudoElement: TPseudoElem;
begin
  if Parts.Count > 0 then
    Result := Parts[Parts.Count - 1].PseudoElem
  else
    Result := peNone;
end;

// ---- TCssRule / TCssStyleSheet ----

constructor TCssRule.Create;
begin
  inherited Create;
  Selectors := TObjectList<TComplexSel>.Create(True);
  Decls := TObjectList<TCssDecl>.Create(True);
end;

destructor TCssRule.Destroy;
begin
  Selectors.Free;
  Decls.Free;
  inherited Destroy;
end;

constructor TCssStyleSheet.Create;
begin
  inherited Create;
  Rules := TObjectList<TCssRule>.Create(True);
  Imports := TStringList.Create;
  ImageUrls := TStringList.Create;
  Imports.Duplicates := dupIgnore;
  ImageUrls.Duplicates := dupIgnore;
end;

destructor TCssStyleSheet.Destroy;
begin
  Rules.Free;
  Imports.Free;
  ImageUrls.Free;
  inherited Destroy;
end;

// ---- helpers ----

function StripComments(const S: string): string;
var
  I, Len: Integer;
begin
  Result := '';
  Len := Length(S);
  I := 1;
  while I <= Len do
  begin
    if (I < Len) and (S[I] = '/') and (S[I + 1] = '*') then
    begin
      Inc(I, 2);
      while (I < Len) and not ((S[I] = '*') and (S[I + 1] = '/')) do
        Inc(I);
      Inc(I, 2);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

// extracts the content of the first url(...) — skips data:
// Evaluates an @media query against the GMediaWidth width. Supports a list
// (commas = OR), screen/all types (print/speech are rejected) and conditions
// (min-width: N) / (max-width: N). Other features are ignored (they do not block).
function MediaQueryMatches(const Prelude: string): Boolean;

  function NumAfter(const S: string; From: Integer): Integer;
  var I: Integer; Num: string;
  begin
    I := From;
    while (I <= Length(S)) and not (S[I] in ['0'..'9']) do Inc(I);
    Num := '';
    while (I <= Length(S)) and (S[I] in ['0'..'9']) do
    begin Num := Num + S[I]; Inc(I); end;
    Result := StrToIntDef(Num, -1);
  end;

  function QueryOK(const Q: string): Boolean;
  var P, V: Integer;
  begin
    Result := True;
    if (Pos('print', Q) > 0) or (Pos('speech', Q) > 0) then Exit(False);
    P := Pos('min-width', Q);
    while P > 0 do
    begin
      V := NumAfter(Q, P + 9);
      if (V >= 0) and (GMediaWidth < V) then Exit(False);
      P := PosEx('min-width', Q, P + 9);
    end;
    P := Pos('max-width', Q);
    while P > 0 do
    begin
      V := NumAfter(Q, P + 9);
      if (V >= 0) and (GMediaWidth > V) then Exit(False);
      P := PosEx('max-width', Q, P + 9);
    end;
  end;

var
  Parts: TStringList;
  I: Integer;
begin
  Result := False;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := LowerCase(Prelude);
    if Parts.Count = 0 then Exit(True);
    for I := 0 to Parts.Count - 1 do
      if QueryOK(Trim(Parts[I])) then Exit(True);
  finally
    Parts.Free;
  end;
end;

function ExtractFirstUrl(const Value: string): string;
var
  P, E: Integer;
  U: string;
begin
  Result := '';
  P := Pos('url(', LowerCase(Value));
  if P = 0 then
    Exit;
  P := P + 4;
  E := P;
  while (E <= Length(Value)) and (Value[E] <> ')') do
    Inc(E);
  U := Trim(Copy(Value, P, E - P));
  if (U <> '') and (U[1] in ['"', '''']) then
    U := Copy(U, 2, Length(U) - 2);
  U := Trim(U);
  if SameText(Copy(U, 1, 5), 'data:') then
    Exit;
  Result := U;
end;

// Removes simple CSS escapes (\x -> x) from a property name (e.g. m\argin).
function UnescapeIdent(const S: string): string;
var I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) then
    begin
      Result := Result + S[I + 1];
      Inc(I, 2);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

procedure ParseDeclarations(const S: string; Decls: TObjectList<TCssDecl>);
var
  I, Len, Start, Depth, CP, K: Integer;
  Part, Prop, Value: string;
  D: TCssDecl;
  Imp, BadBang: Boolean;
begin
  Len := Length(S);
  I := 1;
  Start := 1;
  Depth := 0;
  while I <= Len + 1 do
  begin
    if I <= Len then
    begin
      if S[I] = '\' then begin Inc(I, 2); Continue; end; // escape
      if S[I] = '(' then Inc(Depth)
      else if S[I] = ')' then Dec(Depth);
    end;
    if (I > Len) or ((I <= Len) and (S[I] = ';') and (Depth = 0)) then
    begin
      Part := Trim(Copy(S, Start, I - Start));
      Start := I + 1;
      if Part <> '' then
      begin
        CP := Pos(':', Part);
        if CP > 0 then
        begin
          Prop := UnescapeIdent(LowerCase(Trim(Copy(Part, 1, CP - 1))));
          Value := Trim(Copy(Part, CP + 1, MaxInt));
          Imp := False;
          if (Length(Value) > 10) and
             SameText(Copy(Value, Length(Value) - 9, 10), '!important') then
          begin
            Imp := True;
            Value := Trim(Copy(Value, 1, Length(Value) - 10));
            if (Value <> '') and (Value[Length(Value)] = '!') then
              Value := Trim(Copy(Value, 1, Length(Value) - 1));
          end;
          // '!' other than '!important' => invalid declaration (e.g. `! error`)
          BadBang := False;
          for K := 1 to Length(Value) do
            if Value[K] = '!' then begin BadBang := True; Break; end;
          if (Prop <> '') and (Value <> '') and (not BadBang) then
          begin
            D := TCssDecl.Create;
            D.Prop := Prop;
            D.Important := Imp;
            D.Value := Value;
            Decls.Add(D);
          end;
        end;
      end;
    end;
    Inc(I);
  end;
end;

// ---- selector parser ----

function ParseCompound(const S: string): TCompoundSel;
var
  I, Len, Start: Integer;
  Name, Val, Arg: string;
  AT: TAttrTest;
  N: Integer;
  IsElement, HasArg: Boolean;

  procedure AddClass(const C: string);
  begin
    SetLength(Result.Classes, Length(Result.Classes) + 1);
    Result.Classes[High(Result.Classes)] := C;
  end;

  procedure AddPseudo(const AName, AArg: string; AHasArg: Boolean);
  var
    P: TPseudoClass;
    OfPos: Integer;
    Nth: string;
  begin
    if not KnownPseudoClass(AName, AHasArg) then
    begin
      Result.Invalid := True;
      Exit;
    end;
    P.Name := AName;
    P.Arg := AArg;
    P.Sels := nil;
    P.NthA := 0;
    P.NthB := 0;
    if MatchStr(AName, ['hover']) then
      GUsesHover := True
    else if MatchStr(AName, ['focus', 'focus-visible', 'focus-within']) then
      GUsesFocus := True;
    if MatchStr(AName, ['not', 'is', 'where', 'matches', '-webkit-any', 'has']) then
    begin
      P.Sels := TObjectList<TComplexSel>.Create(True);
      if AName = 'has' then
      begin
        if not ParseSelectorList(AArg, P.Sels, slmRelative) then
          Result.Invalid := True;
      end
      else if AName = 'not' then
      begin
        if not ParseSelectorList(AArg, P.Sels, slmStrict) then
          Result.Invalid := True;
      end
      else
        ParseSelectorList(AArg, P.Sels, slmForgiving); // :is/:where forgive bad entries
    end
    else if StartsStr('nth-', AName) then
    begin
      // An+B, and for nth-child / nth-last-child an optional "of <selector list>"
      Nth := AArg;
      OfPos := Pos(' of ', LowerCase(AArg));
      if (OfPos > 0) and MatchStr(AName, ['nth-child', 'nth-last-child']) then
      begin
        Nth := Copy(AArg, 1, OfPos - 1);
        P.Sels := TObjectList<TComplexSel>.Create(True);
        if not ParseSelectorList(Copy(AArg, OfPos + 4, MaxInt), P.Sels, slmStrict) then
          Result.Invalid := True;
      end;
      if not ParseNth(Nth, P.NthA, P.NthB) then
        Result.Invalid := True;
    end;
    SetLength(Result.Pseudos, Length(Result.Pseudos) + 1);
    Result.Pseudos[High(Result.Pseudos)] := P;
  end;

begin
  Result := TCompoundSel.Create;
  Len := Length(S);
  I := 1;
  while I <= Len do
  begin
    case S[I] of
      '*':
        begin
          Result.Tag := '*';
          Inc(I);
        end;
      '#':
        begin
          Inc(I);
          Start := I;
          while (I <= Len) and not (S[I] in ['.', '#', '[', ':']) do
            Inc(I);
          Result.Id := Copy(S, Start, I - Start);
        end;
      '.':
        begin
          Inc(I);
          Start := I;
          while (I <= Len) and not (S[I] in ['.', '#', '[', ':']) do
            Inc(I);
          AddClass(Copy(S, Start, I - Start));
        end;
      '[':
        begin
          Inc(I);
          Start := I;
          while (I <= Len) and (S[I] <> ']') do
            Inc(I);
          Val := Copy(S, Start, I - Start);
          Inc(I); // after ']'
          // split into name op value
          AT.Op := aoExists;
          AT.Value := '';
          N := Pos('=', Val);
          if N = 0 then
            AT.Name := LowerCase(Trim(Val))
          else
          begin
            if (N > 1) and (Val[N - 1] in ['~', '^', '$', '*', '|']) then
            begin
              case Val[N - 1] of
                '~': AT.Op := aoIncludes;
                '^': AT.Op := aoPrefix;
                '$': AT.Op := aoSuffix;
                '*': AT.Op := aoSubstr;
                '|': AT.Op := aoDash;
              end;
              AT.Name := LowerCase(Trim(Copy(Val, 1, N - 2)));
            end
            else
            begin
              AT.Op := aoEquals;
              AT.Name := LowerCase(Trim(Copy(Val, 1, N - 1)));
            end;
            AT.Value := Trim(Copy(Val, N + 1, MaxInt));
            if (AT.Value <> '') and (AT.Value[1] in ['"', '''']) then
              AT.Value := Copy(AT.Value, 2, Length(AT.Value) - 2);
          end;
          SetLength(Result.Attrs, Length(Result.Attrs) + 1);
          Result.Attrs[High(Result.Attrs)] := AT;
        end;
      ':':
        begin
          Inc(I);
          IsElement := (I <= Len) and (S[I] = ':');
          if IsElement then
            Inc(I);
          Start := I;
          while (I <= Len) and not (S[I] in ['.', '#', '[', ':', '(']) do
            Inc(I);
          Name := LowerCase(Copy(S, Start, I - Start));
          Arg := '';
          HasArg := (I <= Len) and (S[I] = '(');
          // the argument of :not(...), :nth-child(...) — balanced parentheses
          if HasArg then
          begin
            N := 1;
            Inc(I);
            Start := I;
            while (I <= Len) and (N > 0) do
            begin
              if S[I] = '(' then
                Inc(N)
              else if S[I] = ')' then
                Dec(N);
              Inc(I);
            end;
            Arg := Trim(Copy(S, Start, I - Start - 1));
          end;
          // ::before/::after (also the legacy one-colon form) are rendered;
          // other known pseudo-elements are valid but never match
          if (Name = 'before') and not HasArg then
            Result.PseudoElem := peBefore
          else if (Name = 'after') and not HasArg then
            Result.PseudoElem := peAfter
          else if IsElement or MatchStr(Name, ['first-line', 'first-letter']) then
          begin
            if HasArg then
              Name := Name + '(';
            if KnownPseudoElement(Name) then
              Result.NeverMatches := True
            else
              Result.Invalid := True;
          end
          else
            AddPseudo(Name, Arg, HasArg);
        end;
    else
      begin
        Start := I;
        while (I <= Len) and not (S[I] in ['.', '#', '[', ':', '*']) do
          Inc(I);
        Result.Tag := LowerCase(Copy(S, Start, I - Start));
      end;
    end;
  end;
end;

function ParseComplexSelector(const S: string): TComplexSel;
var
  I, Len, Start: Integer;
  Tokens: TStringList; // alternating: compound, combinator, compound...
  InBracket: Integer;
  Cur: string;
  Sel: TComplexSel;
  K: Integer;

  procedure FlushCompound;
  begin
    if Trim(Cur) <> '' then
      Tokens.Add(Trim(Cur));
    Cur := '';
  end;

begin
  Result := nil;
  Tokens := TStringList.Create;
  try
    Len := Length(S);
    I := 1;
    Cur := '';
    InBracket := 0;
    while I <= Len do
    begin
      case S[I] of
        '[', '(':
          begin
            Inc(InBracket);
            Cur := Cur + S[I];
          end;
        ']', ')':
          begin
            Dec(InBracket);
            Cur := Cur + S[I];
          end;
        ' ', #9, #10, #13:
          if InBracket > 0 then
            Cur := Cur + S[I]
          else
          begin
            FlushCompound;
            // check whether > + ~ follows
            Start := I;
            while (Start <= Len) and (S[Start] in [' ', #9, #10, #13]) do
              Inc(Start);
            if (Start <= Len) and (S[Start] in ['>', '+', '~']) then
            begin
              if (Tokens.Count > 0) and (Tokens[Tokens.Count - 1] <> '>') and
                 (Tokens[Tokens.Count - 1] <> '+') and
                 (Tokens[Tokens.Count - 1] <> '~') then
                Tokens.Add(S[Start]);
              I := Start;
            end
            else if (Tokens.Count > 0) and (Start <= Len) then
            begin
              // descendant combinator — only if the last token is a compound
              if (Tokens[Tokens.Count - 1] <> '>') and
                 (Tokens[Tokens.Count - 1] <> '+') and
                 (Tokens[Tokens.Count - 1] <> '~') and
                 (Tokens[Tokens.Count - 1] <> ' ') then
                Tokens.Add(' ');
              I := Start - 1;
            end;
          end;
        '>', '+', '~':
          if InBracket > 0 then
            Cur := Cur + S[I]
          else
          begin
            FlushCompound;
            // replace a possible descendant combinator
            if (Tokens.Count > 0) and (Tokens[Tokens.Count - 1] = ' ') then
              Tokens[Tokens.Count - 1] := S[I]
            else
              Tokens.Add(S[I]);
          end;
      else
        Cur := Cur + S[I];
      end;
      Inc(I);
    end;
    FlushCompound;

    // remove a dangling combinator at the end
    while (Tokens.Count > 0) and
          ((Tokens[Tokens.Count - 1] = ' ') or (Tokens[Tokens.Count - 1] = '>') or
           (Tokens[Tokens.Count - 1] = '+') or (Tokens[Tokens.Count - 1] = '~')) do
      Tokens.Delete(Tokens.Count - 1);
    if Tokens.Count = 0 then
      Exit;

    Sel := TComplexSel.Create;
    K := 0;
    I := 0;
    while I < Tokens.Count do
    begin
      Sel.Parts.Add(ParseCompound(Tokens[I]));
      Inc(I);
      if I < Tokens.Count then
      begin
        SetLength(Sel.Combs, K + 1);
        case Tokens[I][1] of
          '>': Sel.Combs[K] := cbChild;
          '+': Sel.Combs[K] := cbAdjacent;
          '~': Sel.Combs[K] := cbSibling;
        else
          Sel.Combs[K] := cbDescendant;
        end;
        Inc(K);
        Inc(I);
      end;
    end;
    Sel.Specificity := 0;
    for I := 0 to Sel.Parts.Count - 1 do
    begin
      Inc(Sel.Specificity, Sel.Parts[I].Specificity);
      if Sel.Parts[I].Invalid then
        Sel.Invalid := True;
    end;
    Result := Sel;
  finally
    Tokens.Free;
  end;
end;

// Splits a selector list on top-level commas (not inside (), [] or quotes).
function SplitSelectorList(const S: string): TStringList;
var
  I, Start, Depth: Integer;
  Quote: Char;
begin
  Result := TStringList.Create;
  Start := 1;
  Depth := 0;
  Quote := #0;
  for I := 1 to Length(S) + 1 do
    if I > Length(S) then
      Result.Add(Trim(Copy(S, Start, I - Start)))
    else if Quote <> #0 then
    begin
      if S[I] = Quote then
        Quote := #0;
    end
    else if S[I] in ['"', ''''] then
      Quote := S[I]
    else if S[I] in ['[', '('] then
      Inc(Depth)
    else if S[I] in [']', ')'] then
      Dec(Depth)
    else if (S[I] = ',') and (Depth = 0) then
    begin
      Result.Add(Trim(Copy(S, Start, I - Start)));
      Start := I + 1;
    end;
end;

// Parses "a, b > c" into List. slmStrict: one bad selector invalidates the
// list (returns False); slmForgiving (:is/:where): bad entries are skipped;
// slmRelative (:has): entries may start with > + ~ and are anchored at the
// :has() subject through a leading IsScope compound.
function ParseSelectorList(const S: string; List: TObjectList<TComplexSel>;
  Mode: TSelListMode): Boolean;
var
  Items: TStringList;
  Item: string;
  Sel: TComplexSel;
  Scope: TCompoundSel;
  Comb: TCombinator;
  K: Integer;
begin
  Result := True;
  Items := SplitSelectorList(S);
  try
    for Item in Items do
    begin
      Comb := cbDescendant;
      Sel := nil;
      if (Mode = slmRelative) and (Item <> '') and (Item[1] in ['>', '+', '~']) then
      begin
        case Item[1] of
          '>': Comb := cbChild;
          '+': Comb := cbAdjacent;
          '~': Comb := cbSibling;
        end;
        Sel := ParseComplexSelector(Trim(Copy(Item, 2, MaxInt)));
      end
      else if Item <> '' then
        Sel := ParseComplexSelector(Item);
      if (Sel = nil) or Sel.Invalid then
      begin
        Sel.Free;
        if Mode <> slmForgiving then
          Result := False;
        Continue;
      end;
      if Mode = slmRelative then
      begin
        Scope := TCompoundSel.Create;
        Scope.IsScope := True;
        Sel.Parts.Insert(0, Scope);
        SetLength(Sel.Combs, Length(Sel.Combs) + 1);
        for K := High(Sel.Combs) downto 1 do
          Sel.Combs[K] := Sel.Combs[K - 1];
        Sel.Combs[0] := Comb;
      end;
      List.Add(Sel);
    end;
  finally
    Items.Free;
  end;
  if (Mode <> slmForgiving) and (List.Count = 0) then
    Result := False;
end;

// ---- style sheet parser ----

type
  TCssScanner = class
  private
    FSrc: string;
    FPos, FLen: Integer;
    FSheet: TCssStyleSheet;
    procedure SkipWs;
    function SkipStringOrComment: Boolean; // skips "..." '...' /*...*/
    function ReadUntil(const Stops: TSysCharSet): string;
    function ReadBlock: string; // from the opening brace to the matching closing one
    procedure ParseAtRule;
    procedure ParseRule;
    procedure CollectResources(Decls: TObjectList<TCssDecl>);
  public
    procedure Run(const Src: string; Sheet: TCssStyleSheet);
  end;

procedure TCssScanner.SkipWs;
begin
  while (FPos <= FLen) and (FSrc[FPos] in [' ', #9, #10, #13]) do
    Inc(FPos);
end;

// When FPos is at the start of a string ("..."/'...') or a /*...*/ comment,
// skips it entirely and returns True (braces/commas inside are ignored
// by ReadUntil/ReadBlock — otherwise minified CSS with `[attr*="{"]` or `content`
// would desynchronize the brace counter).
function TCssScanner.SkipStringOrComment: Boolean;
var
  Q: Char;
begin
  Result := False;
  if FPos > FLen then Exit;
  if (FSrc[FPos] = '"') or (FSrc[FPos] = '''') then
  begin
    Q := FSrc[FPos];
    Inc(FPos);
    while FPos <= FLen do
    begin
      if FSrc[FPos] = '\' then
        Inc(FPos, 2)
      else if FSrc[FPos] = Q then
      begin Inc(FPos); Break; end
      else
        Inc(FPos);
    end;
    Result := True;
  end
  else if (FSrc[FPos] = '/') and (FPos < FLen) and (FSrc[FPos + 1] = '*') then
  begin
    Inc(FPos, 2);
    while (FPos < FLen) and not ((FSrc[FPos] = '*') and (FSrc[FPos + 1] = '/')) do
      Inc(FPos);
    Inc(FPos, 2); // after */
    Result := True;
  end;
end;

function TCssScanner.ReadUntil(const Stops: TSysCharSet): string;
var
  Start: Integer;
begin
  Start := FPos;
  while FPos <= FLen do
  begin
    if FSrc[FPos] = '\' then   // CSS escape: \x — skip the special character
    begin
      Inc(FPos, 2);
      Continue;
    end;
    if (FSrc[FPos] in ['"', '''']) or
       ((FSrc[FPos] = '/') and (FPos < FLen) and (FSrc[FPos + 1] = '*')) then
    begin
      SkipStringOrComment;
      Continue;
    end;
    if FSrc[FPos] in Stops then
      Break;
    Inc(FPos);
  end;
  Result := Copy(FSrc, Start, FPos - Start);
end;

function TCssScanner.ReadBlock: string;
var
  Depth, Start: Integer;
begin
  Result := '';
  if (FPos > FLen) or (FSrc[FPos] <> '{') then
    Exit;
  Inc(FPos);
  Start := FPos;
  Depth := 1;
  while (FPos <= FLen) and (Depth > 0) do
  begin
    if FSrc[FPos] = '\' then   // CSS escape: an escaped brace does not end the block
    begin
      Inc(FPos, 2);
      Continue;
    end;
    if (FSrc[FPos] in ['"', '''']) or
       ((FSrc[FPos] = '/') and (FPos < FLen) and (FSrc[FPos + 1] = '*')) then
    begin
      SkipStringOrComment;
      Continue;
    end;
    if FSrc[FPos] = '{' then
      Inc(Depth)
    else if FSrc[FPos] = '}' then
      Dec(Depth);
    Inc(FPos);
  end;
  Result := Copy(FSrc, Start, FPos - Start - 1);
end;

procedure TCssScanner.CollectResources(Decls: TObjectList<TCssDecl>);
var
  I: Integer;
  U: string;
begin
  for I := 0 to Decls.Count - 1 do
    if StrIn(Decls[I].Prop, ['background', 'background-image',
      'list-style', 'list-style-image', 'border-image']) then
    begin
      U := ExtractFirstUrl(Decls[I].Value);
      if U <> '' then
        FSheet.ImageUrls.Add(ResolveUrl(FSheet.BaseUrl, U));
    end;
end;

procedure TCssScanner.ParseAtRule;
var
  Name, Prelude, Block, U, Fam: string;
  Decls: TObjectList<TCssDecl>;
  I: Integer;
  Sub: TCssScanner;
  FF: TFontFace;
begin
  Inc(FPos); // after '@'
  Name := LowerCase(ReadUntil([' ', #9, #10, #13, '{', ';']));
  Prelude := Trim(ReadUntil(['{', ';']));

  if Name = 'import' then
  begin
    // @import url("...") or @import "..."
    U := ExtractFirstUrl(Prelude);
    if U = '' then
    begin
      U := Trim(Prelude);
      // cut off media conditions after the address
      I := Pos(' ', U);
      if I > 0 then
        U := Copy(U, 1, I - 1);
      if (U <> '') and (U[1] in ['"', '''']) then
        U := Copy(U, 2, Length(U) - 2);
    end;
    if U <> '' then
      FSheet.Imports.Add(ResolveUrl(FSheet.BaseUrl, U));
    if (FPos <= FLen) and (FSrc[FPos] = ';') then
      Inc(FPos);
    Exit;
  end;

  if (FPos <= FLen) and (FSrc[FPos] = ';') then
  begin
    Inc(FPos);
    Exit;
  end;

  Block := ReadBlock;

  if Name = 'font-face' then
  begin
    Decls := TObjectList<TCssDecl>.Create(True);
    try
      ParseDeclarations(Block, Decls);
      FF.Family := '';
      FF.Url := '';
      for I := 0 to Decls.Count - 1 do
      begin
        if Decls[I].Prop = 'font-family' then
        begin
          Fam := Trim(Decls[I].Value);
          if (Fam <> '') and (Fam[1] in ['"', '''']) then
            Fam := Copy(Fam, 2, Length(Fam) - 2);
          FF.Family := Fam;
        end
        else if (Decls[I].Prop = 'src') and (FF.Url = '') then
        begin
          U := ExtractFirstUrl(Decls[I].Value);
          if U <> '' then
            FF.Url := ResolveUrl(FSheet.BaseUrl, U);
        end;
      end;
      if (FF.Family <> '') and (FF.Url <> '') then
      begin
        SetLength(FSheet.FontFaces, Length(FSheet.FontFaces) + 1);
        FSheet.FontFaces[High(FSheet.FontFaces)] := FF;
      end;
    finally
      Decls.Free;
    end;
    Exit;
  end;

  if Name = 'media' then
  begin
    // pull in rules only when the query matches the viewport width —
    // otherwise mobile rules (max-width) would override the desktop ones
    if MediaQueryMatches(Prelude) then
    begin
      Sub := TCssScanner.Create;
      try
        Sub.Run(Block, FSheet); // the rules land in the same style sheet
      finally
        Sub.Free;
      end;
    end;
    Exit;
  end;
  // other @-rules (keyframes, supports...) — skipped
end;

procedure TCssScanner.ParseRule;
var
  SelText, Block: string;
  Rule: TCssRule;
begin
  SelText := Trim(ReadUntil(['{']));
  if FPos > FLen then
    Exit;
  Block := ReadBlock;
  if SelText = '' then
    Exit;

  Rule := TCssRule.Create;
  ParseDeclarations(Block, Rule.Decls);
  CollectResources(Rule.Decls);

  // comma-separated selectors; as in browsers, one invalid selector
  // (e.g. an unknown pseudo-class) drops the whole rule
  if not ParseSelectorList(SelText, Rule.Selectors, slmStrict) then
    Rule.Selectors.Clear;

  if (Rule.Selectors.Count > 0) and (Rule.Decls.Count > 0) then
    FSheet.Rules.Add(Rule)
  else
    Rule.Free;
end;

procedure TCssScanner.Run(const Src: string; Sheet: TCssStyleSheet);
begin
  FSrc := Src;
  FLen := Length(FSrc);
  FPos := 1;
  FSheet := Sheet;
  while FPos <= FLen do
  begin
    SkipWs;
    if FPos > FLen then
      Break;
    if FSrc[FPos] = '@' then
      ParseAtRule
    else if FSrc[FPos] = '}' then
      Inc(FPos) // stray bracket
    else
      ParseRule;
  end;
end;

procedure ParseCss(const Src, ABaseUrl: string; Sheet: TCssStyleSheet);
var
  Scanner: TCssScanner;
begin
  Sheet.BaseUrl := ABaseUrl;
  Scanner := TCssScanner.Create;
  try
    Scanner.Run(StripComments(Src), Sheet);
    Sheet.Loaded := True;
  finally
    Scanner.Free;
  end;
end;

end.
