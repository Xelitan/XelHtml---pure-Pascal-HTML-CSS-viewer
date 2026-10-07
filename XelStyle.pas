unit XelStyle;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Computed style and the CSS cascade.
// Cascade order: browser style sheet (UA) -> presentational attributes
// (width/height/align/bgcolor...) -> author style sheets (in order)
// -> inline styles -> author !important -> UA !important.
// Inherited: colour, font, line-height, text-align, list-style,
// white-space, text decorations.

interface

uses
  Classes, SysUtils, Graphics, Generics.Collections, XelDom, XelCssParser;

type
  TCssDisplay = (cdNone, cdBlock, cdInline, cdInlineBlock, cdListItem,
    cdTable, cdTableRow, cdTableCell, cdFlex, cdGrid);
  TCssJustify = (cjStart, cjCenter, cjEnd, cjSpaceBetween, cjSpaceAround);
  TCssAlign = (caStretch, caStart, caCenter, caEnd);
  TCssFloat = (cfNone, cfLeft, cfRight);
  TCssClear = (ccNone, ccLeft, ccRight, ccBoth);
  TCssTextAlign = (ctaLeft, ctaCenter, ctaRight);
  TCssVertAlign = (cvaBaseline, cvaTop, cvaMiddle, cvaBottom);
  TCssBorderStyle = (cbsNone, cbsSolid, cbsDashed, cbsDotted, cbsDouble);
  TCssListType = (cltDisc, cltCircle, cltSquare, cltDecimal, cltNone);
  TCssBoxSizing = (cbsContentBox, cbsBorderBox);
  TCssPosition = (cpStatic, cpRelative, cpAbsolute, cpFixed);
  TCssOverflow = (coVisible, coHidden, coScroll, coAuto);
  TCssGradientKind = (gkNone, gkLinear, gkRadial);
  TCssTextTransform = (cttNone, cttUpper, cttLower, cttCapitalize);
  TCssCursor = (ccrAuto, ccrDefault, ccrPointer, ccrText, ccrMove, ccrWait,
    ccrProgress, ccrHelp, ccrCrosshair, ccrNotAllowed, ccrGrab,
    ccrColResize, ccrRowResize);

  // TComputedStyle

  TComputedStyle = class
  public
    Display: TCssDisplay;
    Float_: TCssFloat;
    Clear_: TCssClear;
    Position: TCssPosition;

    Color: TColor;
    HasBgColor: Boolean;
    BgColor: TColor;
    BgImage: string; // absolute URL
    BgRepeat: Boolean;
    BgSizeW, BgSizeH: Integer; // -1 = natural size
    BgPosXPct, BgPosYPct: Double;

    GradKind: TCssGradientKind;     // gradient background (linear/radial)
    GradAngle: Double;              // CSS angle in degrees (linear)
    GradColors: array of TColor;    // stop colours (evenly distributed)

    Opacity: Double;                // 0..1 (1 = opaque)

    // flexbox / grid
    FlexDirCol: Boolean;            // flex-direction: column
    FlexWrapOn: Boolean;            // flex-wrap: wrap
    JustifyContent: TCssJustify;    // distribution along the main axis
    AlignItems: TCssAlign;          // alignment along the cross axis
    JustifyItems: TCssAlign;        // grid: horizontal alignment of cells
    AlignSelf: TCssAlign;
    JustifySelf: TCssAlign;
    AlignSelfAuto, JustifySelfAuto: Boolean;
    FlexGrow: Double;               // flex-grow
    FlexBasis: Integer;             // px, -1 = auto
    ColGap, RowGap: Integer;        // column-gap / row-gap
    GridTemplate: string;           // raw grid-template-columns
    GridTemplateRows: string;       // raw grid-template-rows
    GridTemplateAreas: string;      // grid-template-areas (rows separated by |)
    GridAreaName: string;           // grid-area: <name> (when not line-based)
    GridColStart, GridColEnd: Integer; // 0 = auto; lines are 1-based
    GridRowStart, GridRowEnd: Integer;
    GridColSpan, GridRowSpan: Integer; // from "span N"; 0 = none
    ColumnCount: Integer;           // CSS column-count; 0 = none
    ColumnWidthPx: Integer;         // CSS column-width in px; 0 = none
    Content: string;                // text from `content` (generated content)
    HasContent: Boolean;            // whether `content` is set (<>none)

    FontFamily: string;
    FontSizePx: Integer;
    Bold, Italic, Underline, Strike: Boolean;
    LineHeight: Double; // font size multiplier

    MarginL, MarginT, MarginR, MarginB: Integer;
    MarginLAuto, MarginRAuto: Boolean;
    // percentage margins/paddings (-1 = none); computed from the width
    // of the containing block during layout
    MarginLPct, MarginTPct, MarginRPct, MarginBPct: Double;
    PadLPct, PadTPct, PadRPct, PadBPct: Double;
    PadL, PadT, PadR, PadB: Integer;
    BordL, BordT, BordR, BordB: Integer;
    BorderColor: TColor;                       // main one (also for controls)
    BorderColorT, BorderColorR, BorderColorB, BorderColorL: TColor; // per side
    BorderStyle: TCssBorderStyle;

    WidthPx: Integer;   // -1 = auto
    MaxWidthPx: Integer; // -1 = no limit
    MaxWidthPct: Double; // -1 = none; percentage of the parent's width
    MinWidthPx: Integer; // -1 = none
    MinWidthPct: Double; // -1 = none; percentage of the parent's width
    WidthPct: Double;   // -1 = none; percentage of the parent's width
    HeightPx: Integer;  // -1 = auto
    MinHeightPx: Integer; // -1 = none
    MaxHeightPx: Integer; // -1 = none
    BoxSizing: TCssBoxSizing;
    PosLeft, PosTop, PosRight, PosBottom: Integer; // Low(Integer) = auto
    ZIndex: Integer;
    OverflowX, OverflowY: TCssOverflow;
    BorderRadius: Integer;
    BorderRadiusPct: Integer;  // -1 = none; radius in % of min(w,h) — e.g. 50% = oval

    TextAlign: TCssTextAlign;
    VertAlign: TCssVertAlign; // used for table cells
    ListType: TCssListType;
    ListImage: string;        // absolute URL of the list marker (list-style-image)
    ListInside: Boolean;      // list-style-position: inside
    PreWhiteSpace: Boolean;
    NoWrap: Boolean;

    TextTransform: TCssTextTransform;
    LetterSpacing: Integer;   // px added after every character (may be negative)
    WordSpacing: Integer;     // px added to every space
    Cursor: TCssCursor;

    BorderCollapse: Boolean;            // tables: collapse vs separate
    BorderSpacingH, BorderSpacingV: Integer; // cell spacing (separate model)

    HasTextShadow: Boolean;
    TextShadowX, TextShadowY, TextShadowBlur: Integer;
    TextShadowColor: TColor;

    HasBoxShadow: Boolean;
    BoxShadowInset: Boolean;
    BoxShadowX, BoxShadowY, BoxShadowBlur, BoxShadowSpread: Integer;
    BoxShadowColor: TColor;

    constructor Create;
    procedure InheritFrom(Parent: TComputedStyle);
  end;

  // TStyleResolver — computes an element's style according to the cascade

  TStyleResolver = class
  private
    FUASheet: TCssStyleSheet;
    FSheets: TList<TCssStyleSheet>; // author style sheets, in document order
    procedure ApplyDecl(CS: TComputedStyle; const Prop, Value: string;
      ParentFontSize: Integer; Parent: TComputedStyle = nil);
    procedure CollectFromSheet(Sheet: TCssStyleSheet; E: TDOMElement;
      Band: Integer; var Seq: Integer; Entries: Classes.TList;
      AWantPseudo: TPseudoElem = peNone);
    procedure ApplyPresentationalAttrs(E: TDOMElement; CS: TComputedStyle);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ClearAuthorSheets;
    procedure AddAuthorSheet(Sheet: TCssStyleSheet); // does not take ownership
    // style of the ::before/::after pseudo-element for E; nil when there is no `content`
    function ComputePseudo(E: TDOMElement; Parent: TComputedStyle;
      Which: TPseudoElem): TComputedStyle;
    function Compute(E: TDOMElement; Parent: TComputedStyle): TComputedStyle;
  end;

function ParseCssColor(const Value: string; out Color: TColor): Boolean;

implementation

uses
  Math, XelUrl, XelTextUtil;

const
  // Browser default style sheet — parsed with our own CSS parser
  UA_STYLESHEET =
    'html,body,div,p,h1,h2,h3,h4,h5,h6,ul,ol,dl,dt,dd,blockquote,pre,hr,' +
    'thead,tbody,tfoot,form,header,footer,nav,section,article,' +
    'aside,main,figure,figcaption,fieldset,address,center,noscript' +
    '{display:block}' +
    'head,script,style,meta,link,title,base,template{display:none}' +
    'li{display:list-item}' +
    'table{display:table}' +
    'tr{display:table-row}' +
    'td,th{display:table-cell}' +
    'caption{display:block}' +
    'body{margin:8px}' +
    'p,blockquote,ul,ol,dl,pre,table,figure{margin-top:1em;margin-bottom:1em}' +
    'blockquote{margin-left:40px;margin-right:40px}' +
    'figure{margin-left:40px;margin-right:40px}' +
    'h1{font-size:2em;font-weight:bold;margin-top:0.67em;margin-bottom:0.67em}' +
    'h2{font-size:1.5em;font-weight:bold;margin-top:0.83em;margin-bottom:0.83em}' +
    'h3{font-size:1.17em;font-weight:bold;margin-top:1em;margin-bottom:1em}' +
    'h4{font-weight:bold;margin-top:1.33em;margin-bottom:1.33em}' +
    'h5{font-size:0.83em;font-weight:bold;margin-top:1.67em;margin-bottom:1.67em}' +
    'h6{font-size:0.67em;font-weight:bold;margin-top:2.33em;margin-bottom:2.33em}' +
    'b,strong,th{font-weight:bold}' +
    'i,em,cite,var,dfn,address{font-style:italic}' +
    'u,ins{text-decoration:underline}' +
    's,strike,del{text-decoration:line-through}' +
    'a{color:#0000EE;text-decoration:underline}' +
    'ul,ol{padding-left:40px}' +
    'ol{list-style-type:decimal}' +
    'dd{margin-left:40px}' +
    'pre,code,kbd,samp,tt{font-family:monospace}' +
    'pre{white-space:pre}' +
    'small{font-size:0.83em}' +
    'big{font-size:1.2em}' +
    'sub,sup{font-size:0.83em}' +
    'center{text-align:center}' +
    'th,caption{text-align:center}' +
    'img{display:inline-block}' +
    'hr{height:2px;background-color:#9A9A9A;margin-top:8px;margin-bottom:8px}' +
    'input,button,select,textarea' +
    '{display:inline-block;border:1px solid #767676;background-color:#FFFFFF;' +
    'padding:2px 6px}' +
    'button,select{background-color:#E1E1E1}' +
    'table,td,th{border-color:#808080}' +
    'td,th{padding:2px 4px;vertical-align:middle}';

var
  GUASheet: TCssStyleSheet = nil;

function GetUASheet: TCssStyleSheet;
begin
  if GUASheet = nil then
  begin
    GUASheet := TCssStyleSheet.Create;
    ParseCss(UA_STYLESHEET, '', GUASheet);
  end;
  Result := GUASheet;
end;

// ---- colours ----

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := 0;
  end;
end;

type
  TColorDef = record
    N: string;
    C: Cardinal; // BGR format like TColor
  end;

const
  NAMED_COLORS: array[0..68] of TColorDef = (
    (N: 'black';   C: $000000), (N: 'white';   C: $FFFFFF),
    (N: 'red';     C: $0000FF), (N: 'green';   C: $008000),
    (N: 'blue';    C: $FF0000), (N: 'yellow';  C: $00FFFF),
    (N: 'cyan';    C: $FFFF00), (N: 'aqua';    C: $FFFF00),
    (N: 'magenta'; C: $FF00FF), (N: 'fuchsia'; C: $FF00FF),
    (N: 'gray';    C: $808080), (N: 'grey';    C: $808080),
    (N: 'silver';  C: $C0C0C0), (N: 'maroon';  C: $000080),
    (N: 'olive';   C: $008080), (N: 'lime';    C: $00FF00),
    (N: 'navy';    C: $800000), (N: 'purple';  C: $800080),
    (N: 'teal';    C: $808000), (N: 'orange';  C: $00A5FF),
    (N: 'brown';   C: $2A2AA5), (N: 'pink';    C: $CBC0FF),
    (N: 'gold';    C: $00D7FF), (N: 'beige';   C: $DCF5F5),
    (N: 'ivory';   C: $F0FFFF), (N: 'khaki';   C: $8CE6F0),
    (N: 'violet';  C: $EE82EE), (N: 'indigo';  C: $82004B),
    (N: 'coral';   C: $507FFF), (N: 'salmon';  C: $7280FA),
    (N: 'tomato';  C: $4763FF), (N: 'crimson'; C: $3C14DC),
    (N: 'lavender'; C: $FAE6E6), (N: 'plum';   C: $DDA0DD),
    (N: 'orchid';  C: $D670DA), (N: 'tan';     C: $8CB4D2),
    (N: 'wheat';   C: $B3DEF5), (N: 'snow';    C: $FAFAFF),
    (N: 'seashell'; C: $EEF5FF), (N: 'skyblue'; C: $EBCE87),
    (N: 'lightblue'; C: $E6D8AD), (N: 'lightgray'; C: $D3D3D3),
    (N: 'lightgrey'; C: $D3D3D3), (N: 'darkgray'; C: $A9A9A9),
    (N: 'darkgrey'; C: $A9A9A9), (N: 'dimgray'; C: $696969),
    (N: 'dimgrey'; C: $696969), (N: 'gainsboro'; C: $DCDCDC),
    (N: 'whitesmoke'; C: $F5F5F5), (N: 'darkred'; C: $00008B),
    (N: 'darkblue'; C: $8B0000), (N: 'darkgreen'; C: $006400),
    (N: 'darkorange'; C: $008CFF), (N: 'lightgreen'; C: $90EE90),
    (N: 'lightyellow'; C: $E0FFFF), (N: 'lightpink'; C: $C1B6FF),
    (N: 'lightcyan'; C: $FFFFE0), (N: 'steelblue'; C: $B48246),
    (N: 'royalblue'; C: $E16941), (N: 'dodgerblue'; C: $FF901E),
    (N: 'cornflowerblue'; C: $ED9564), (N: 'midnightblue'; C: $701919),
    (N: 'forestgreen'; C: $228B22), (N: 'seagreen'; C: $578B2E),
    (N: 'olivedrab'; C: $238E6B), (N: 'goldenrod'; C: $20A5DA),
    (N: 'chocolate'; C: $1E69D2), (N: 'firebrick'; C: $2222B2),
    (N: 'slategray'; C: $908070)
  );

function NamedColor(const S: string; out Color: TColor): Boolean;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(S);
  for I := 0 to High(NAMED_COLORS) do
    if NAMED_COLORS[I].N = L then
    begin
      Color := TColor(NAMED_COLORS[I].C);
      Exit(True);
    end;
  Color := clBlack;
  Result := False;
end;

function ParseCssColor(const Value: string; out Color: TColor): Boolean;
var
  S: string;
  R, G, B: Integer;
  Parts: TStringList;
  Inner: string;
  P: Integer;

  function PartToByte(const T: string): Integer;
  var
    V: Double;
    TS: string;
  begin
    TS := Trim(T);
    if (TS <> '') and (TS[Length(TS)] = '%') then
    begin
      V := StrToFloatDef(Copy(TS, 1, Length(TS) - 1), 0,
        DefaultFormatSettings);
      Result := EnsureRange(Round(V * 255 / 100), 0, 255);
    end
    else
      Result := EnsureRange(Round(StrToFloatDef(TS, 0, DefaultFormatSettings)),
        0, 255);
  end;

var
  FS: TFormatSettings;
begin
  Result := False;
  Color := clBlack;
  S := Trim(Value);
  if S = '' then
    Exit;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  // light-dark(<light>, <dark>): the renderer uses a light colour scheme,
  // so take the first argument (split at the top-level comma)
  if SameText(Copy(S, 1, 11), 'light-dark(') and (S[Length(S)] = ')') then
  begin
    Inner := Copy(S, 12, Length(S) - 12);
    R := 0;
    for P := 1 to Length(Inner) do
      if Inner[P] = '(' then
        Inc(R)
      else if Inner[P] = ')' then
        Dec(R)
      else if (Inner[P] = ',') and (R = 0) then
        Exit(ParseCssColor(Copy(Inner, 1, P - 1), Color));
    Exit;
  end;

  if S[1] = '#' then
  begin
    Delete(S, 1, 1);
    if Length(S) = 3 then
    begin
      R := HexVal(S[1]) * 17;
      G := HexVal(S[2]) * 17;
      B := HexVal(S[3]) * 17;
    end
    else if Length(S) >= 6 then
    begin
      R := HexVal(S[1]) * 16 + HexVal(S[2]);
      G := HexVal(S[3]) * 16 + HexVal(S[4]);
      B := HexVal(S[5]) * 16 + HexVal(S[6]);
    end
    else
      Exit;
    Color := TColor(R or (G shl 8) or (B shl 16));
    Exit(True);
  end;

  if SameText(Copy(S, 1, 4), 'rgb(') or SameText(Copy(S, 1, 5), 'rgba(') then
  begin
    P := Pos('(', S);
    Inner := Copy(S, P + 1, Length(S) - P - 1);
    Inner := StringReplace(Inner, '/', ',', [rfReplaceAll]);
    Parts := TStringList.Create;
    try
      Parts.Delimiter := ',';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := StringReplace(Inner, ' ', ',', [rfReplaceAll]);
      // remove empty ones after replacing spaces
      for P := Parts.Count - 1 downto 0 do
        if Trim(Parts[P]) = '' then
          Parts.Delete(P);
      if Parts.Count >= 3 then
      begin
        R := PartToByte(Parts[0]);
        G := PartToByte(Parts[1]);
        B := PartToByte(Parts[2]);
        Color := TColor(R or (G shl 8) or (B shl 16));
        Result := True;
      end;
    finally
      Parts.Free;
    end;
    Exit;
  end;

  Result := NamedColor(S, Color);
end;

// ---- lengths ----

type
  TLengthKind = (lkPx, lkPct, lkAuto, lkInvalid);

function ParseLength(const Value: string; FontSizePx: Integer;
  out Px: Integer; out Pct: Double): TLengthKind;
var
  S, NumS, UnitS: string;
  I: Integer;
  V: Double;
  FS: TFormatSettings;
begin
  Px := 0;
  Pct := 0;
  S := LowerCase(Trim(Value));
  if S = '' then
    Exit(lkInvalid);
  if S = 'auto' then
    Exit(lkAuto);
  if S = '0' then
  begin
    Px := 0;
    Exit(lkPx);
  end;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  I := 1;
  while (I <= Length(S)) and (S[I] in ['0'..'9', '.', '-', '+']) do
    Inc(I);
  NumS := Copy(S, 1, I - 1);
  if NumS = '' then
    Exit(lkInvalid);
  if not TryStrToFloat(NumS, V, FS) then
    Exit(lkInvalid);

  Result := lkPx;
  UnitS := Copy(S, I, MaxInt);
  if (UnitS = 'px') or (UnitS = '') then
    Px := Round(V)
  else if UnitS = 'pt' then
    Px := Round(V * 96 / 72)
  else if UnitS = 'em' then
    Px := Round(V * FontSizePx)
  else if UnitS = 'rem' then
    Px := Round(V * 16)
  else if (UnitS = 'ex') or (UnitS = 'ch') then
    Px := Round(V * FontSizePx * 0.5)
  else if UnitS = '%' then
  begin
    Pct := V;
    Result := lkPct;
  end
  else if UnitS = 'cm' then
    Px := Round(V * 96 / 2.54)
  else if UnitS = 'mm' then
    Px := Round(V * 96 / 25.4)
  else if UnitS = 'in' then
    Px := Round(V * 96)
  else if (UnitS = 'vw') or (UnitS = 'vh') then
    Px := Round(V * 8) // rough approximation
  else
    Result := lkInvalid;
end;

// ---- TComputedStyle ----

constructor TComputedStyle.Create;
begin
  inherited Create;
  Display := cdInline;
  Float_ := cfNone;
  Clear_ := ccNone;
  Position := cpStatic;
  Color := clBlack;
  HasBgColor := False;
  BgColor := clWhite;
  BgRepeat := True;
  BgSizeW := -1;
  BgSizeH := -1;
  BgPosXPct := 0;
  BgPosYPct := 0;
  GradKind := gkNone;
  GradAngle := 180;
  Opacity := 1.0;
  FlexDirCol := False;
  FlexWrapOn := False;
  JustifyContent := cjStart;
  AlignItems := caStretch;
  JustifyItems := caStretch;
  AlignSelf := caStretch;
  JustifySelf := caStretch;
  AlignSelfAuto := True;
  JustifySelfAuto := True;
  FlexGrow := 0;
  FlexBasis := -1;
  ColGap := 0;
  RowGap := 0;
  GridTemplate := '';
  GridTemplateRows := '';
  GridTemplateAreas := '';
  GridAreaName := '';
  GridColStart := 0; GridColEnd := 0;
  GridRowStart := 0; GridRowEnd := 0;
  GridColSpan := 0; GridRowSpan := 0;
  ColumnCount := 0;
  ColumnWidthPx := 0;
  Content := '';
  HasContent := False;
  FontFamily := 'serif';
  FontSizePx := 16;
  LineHeight := 1.25;
  WidthPx := -1;
  MaxWidthPx := -1;
  MaxWidthPct := -1;
  MinWidthPx := -1;
  MinWidthPct := -1;
  WidthPct := -1;
  HeightPx := -1;
  MinHeightPx := -1;
  MaxHeightPx := -1;
  BoxSizing := cbsContentBox;
  PosLeft := Low(Integer);
  PosTop := Low(Integer);
  PosRight := Low(Integer);
  PosBottom := Low(Integer);
  ZIndex := 0;
  OverflowX := coVisible;
  OverflowY := coVisible;
  BorderRadius := 0;
  BorderRadiusPct := -1;
  TextAlign := ctaLeft;
  BorderColor := clBlack;
  BorderColorT := clBlack;
  BorderColorR := clBlack;
  BorderColorB := clBlack;
  BorderColorL := clBlack;
  BorderStyle := cbsNone;
  MarginLPct := -1;
  MarginTPct := -1;
  MarginRPct := -1;
  MarginBPct := -1;
  PadLPct := -1;
  PadTPct := -1;
  PadRPct := -1;
  PadBPct := -1;
  ListType := cltDisc;
  ListImage := '';
  ListInside := False;
  NoWrap := False;
  TextTransform := cttNone;
  LetterSpacing := 0;
  WordSpacing := 0;
  Cursor := ccrAuto;
  BorderCollapse := False;
  BorderSpacingH := 2;
  BorderSpacingV := 2;
  HasTextShadow := False;
  TextShadowX := 0;
  TextShadowY := 0;
  TextShadowBlur := 0;
  TextShadowColor := clBlack;
  HasBoxShadow := False;
  BoxShadowInset := False;
  BoxShadowX := 0;
  BoxShadowY := 0;
  BoxShadowBlur := 0;
  BoxShadowSpread := 0;
  BoxShadowColor := clBlack;
end;

procedure TComputedStyle.InheritFrom(Parent: TComputedStyle);
begin
  if Parent = nil then
    Exit;
  Color := Parent.Color;
  FontFamily := Parent.FontFamily;
  FontSizePx := Parent.FontSizePx;
  Bold := Parent.Bold;
  Italic := Parent.Italic;
  Underline := Parent.Underline;
  Strike := Parent.Strike;
  LineHeight := Parent.LineHeight;
  TextAlign := Parent.TextAlign;
  ListType := Parent.ListType;
  ListImage := Parent.ListImage;
  ListInside := Parent.ListInside;
  PreWhiteSpace := Parent.PreWhiteSpace;
  NoWrap := Parent.NoWrap;
  // inherited according to the CSS specification
  TextTransform := Parent.TextTransform;
  LetterSpacing := Parent.LetterSpacing;
  WordSpacing := Parent.WordSpacing;
  Cursor := Parent.Cursor;
  BorderCollapse := Parent.BorderCollapse;
  BorderSpacingH := Parent.BorderSpacingH;
  BorderSpacingV := Parent.BorderSpacingV;
  HasTextShadow := Parent.HasTextShadow;
  TextShadowX := Parent.TextShadowX;
  TextShadowY := Parent.TextShadowY;
  TextShadowBlur := Parent.TextShadowBlur;
  TextShadowColor := Parent.TextShadowColor;
end;

// ---- applying declarations ----

procedure SplitValueTokens(const Value: string; Tokens: TStringList);
var
  I, Start, Depth: Integer;
begin
  Tokens.Clear;
  Start := 1;
  Depth := 0;
  for I := 1 to Length(Value) + 1 do
    if (I > Length(Value)) or ((Value[I] in [' ', #9]) and (Depth = 0)) then
    begin
      if I > Start then
        Tokens.Add(Copy(Value, Start, I - Start));
      Start := I + 1;
    end
    else if Value[I] = '(' then
      Inc(Depth)
    else if Value[I] = ')' then
      Dec(Depth);
end;

// first shadow of a comma-separated list (at the top level)
function FirstShadowSegment(const V: string): string;
var
  I, Depth: Integer;
begin
  Depth := 0;
  for I := 1 to Length(V) do
    if V[I] = '(' then Inc(Depth)
    else if V[I] = ')' then Dec(Depth)
    else if (V[I] = ',') and (Depth = 0) then
      Exit(Copy(V, 1, I - 1));
  Result := V;
end;

// Parses "offX offY [blur] [spread] [inset] [color]" -> components.
// Returns True when at least offX and offY are present.
function ParseShadowSpec(const V: string; FontSize: Integer;
  AllowInsetSpread: Boolean; out X, Y, Blur, Spread: Integer;
  out Col: TColor; out HasCol, Inset: Boolean): Boolean;
var
  T: TStringList;
  I, NumCount, P: Integer;
  Pc: Double;
  Nums: array[0..3] of Integer;
begin
  X := 0; Y := 0; Blur := 0; Spread := 0; Col := clBlack;
  HasCol := False; Inset := False;
  NumCount := 0;
  T := TStringList.Create;
  try
    SplitValueTokens(FirstShadowSegment(V), T);
    for I := 0 to T.Count - 1 do
    begin
      if AllowInsetSpread and SameText(T[I], 'inset') then
        Inset := True
      else if ParseLength(T[I], FontSize, P, Pc) = lkPx then
      begin
        if NumCount <= High(Nums) then
        begin
          Nums[NumCount] := P;
          Inc(NumCount);
        end;
      end
      else if ParseCssColor(T[I], Col) then
        HasCol := True;
    end;
  finally
    T.Free;
  end;
  Result := NumCount >= 2;
  if Result then
  begin
    X := Nums[0];
    Y := Nums[1];
    if NumCount >= 3 then
      Blur := Nums[2];
    if AllowInsetSpread and (NumCount >= 4) then
      Spread := Nums[3];
  end;
end;

// splits into parts on top-level commas (outside parentheses)
procedure SplitTopLevel(const S: string; Dest: TStringList);
var
  I, Start, Depth: Integer;
begin
  Dest.Clear;
  Start := 1;
  Depth := 0;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or ((S[I] = ',') and (Depth = 0)) then
    begin
      Dest.Add(Trim(Copy(S, Start, I - Start)));
      Start := I + 1;
    end
    else if S[I] = '(' then Inc(Depth)
    else if S[I] = ')' then Dec(Depth);
end;

// parses linear-gradient(...)/radial-gradient(...) into CS fields; True if OK
function ParseGradientValue(const V: string; CS: TComputedStyle): Boolean;
var
  L, Inner, First, S: string;
  Parts: TStringList;
  I, P, Sp, StartIdx: Integer;
  Col: TColor;
  FSx: TFormatSettings;
begin
  Result := False;
  L := LowerCase(Trim(V));
  if Pos('linear-gradient(', L) = 1 then CS.GradKind := gkLinear
  else if Pos('radial-gradient(', L) = 1 then CS.GradKind := gkRadial
  else Exit;

  P := Pos('(', V);
  Inner := Copy(V, P + 1, Length(V) - P);
  if (Inner <> '') and (Inner[Length(Inner)] = ')') then
    SetLength(Inner, Length(Inner) - 1);

  FSx := DefaultFormatSettings;
  FSx.DecimalSeparator := '.';
  CS.GradAngle := 180;
  StartIdx := 0;

  Parts := TStringList.Create;
  try
    SplitTopLevel(Inner, Parts);
    if Parts.Count = 0 then Exit;
    First := LowerCase(Trim(Parts[0]));

    if CS.GradKind = gkLinear then
    begin
      if Pos('deg', First) > 0 then
      begin
        CS.GradAngle := StrToFloatDef(
          Trim(StringReplace(First, 'deg', '', [rfReplaceAll])), 180, FSx);
        StartIdx := 1;
      end
      else if Pos('to ', First) = 1 then
      begin
        if (Pos('right', First) > 0) and (Pos('bottom', First) > 0) then CS.GradAngle := 135
        else if (Pos('right', First) > 0) and (Pos('top', First) > 0) then CS.GradAngle := 45
        else if (Pos('left', First) > 0) and (Pos('bottom', First) > 0) then CS.GradAngle := 225
        else if (Pos('left', First) > 0) and (Pos('top', First) > 0) then CS.GradAngle := 315
        else if Pos('right', First) > 0 then CS.GradAngle := 90
        else if Pos('left', First) > 0 then CS.GradAngle := 270
        else if Pos('top', First) > 0 then CS.GradAngle := 0
        else if Pos('bottom', First) > 0 then CS.GradAngle := 180;
        StartIdx := 1;
      end;
    end
    else // radial: skip shape/size/position keywords if they are not a colour
      if (Pos('circle', First) > 0) or (Pos('ellipse', First) > 0) or
         (Pos('at ', First) > 0) or (Pos('closest', First) > 0) or
         (Pos('farthest', First) > 0) then
        StartIdx := 1;

    SetLength(CS.GradColors, 0);
    for I := StartIdx to Parts.Count - 1 do
    begin
      S := Trim(Parts[I]);
      // cut off the stop position (e.g. "#abc 50%") when it is not a colour function
      if (Pos('(', S) = 0) then
      begin
        Sp := Pos(' ', S);
        if Sp > 0 then S := Copy(S, 1, Sp - 1);
      end;
      if ParseCssColor(S, Col) then
      begin
        SetLength(CS.GradColors, Length(CS.GradColors) + 1);
        CS.GradColors[High(CS.GradColors)] := Col;
      end;
    end;
  finally
    Parts.Free;
  end;

  if Length(CS.GradColors) >= 2 then
    Result := True
  else
    CS.GradKind := gkNone;
end;

function ParseJustify(const V: string): TCssJustify;
var L: string;
begin
  L := LowerCase(Trim(V));
  if (L = 'center') then Result := cjCenter
  else if (L = 'flex-end') or (L = 'end') or (L = 'right') then Result := cjEnd
  else if (L = 'space-between') then Result := cjSpaceBetween
  else if (L = 'space-around') or (L = 'space-evenly') then Result := cjSpaceAround
  else Result := cjStart;
end;

function ParseAlign(const V: string): TCssAlign;
var L: string;
begin
  L := LowerCase(Trim(V));
  if (L = 'center') then Result := caCenter
  else if (L = 'flex-start') or (L = 'start') then Result := caStart
  else if (L = 'flex-end') or (L = 'end') then Result := caEnd
  else Result := caStretch;
end;

// parses grid-column/grid-row: "a / b", "span N", or "a".
// StartL/EndL = line numbers (0 = auto), Span = N (0 = none)
// Extracts the grid-template-areas rows from quoted strings
// ('a a' 'b c') and joins them with '|' -> "a a|b c".
function ExtractGridAreaRows(const V: string): string;
var
  I: Integer;
  C, Q: Char;
  Cur: string;
  InStr: Boolean;
begin
  Result := '';
  InStr := False;
  Q := '"';
  Cur := '';
  for I := 1 to Length(V) do
  begin
    C := V[I];
    if not InStr then
    begin
      if (C = '"') or (C = '''') then
      begin InStr := True; Q := C; Cur := ''; end;
    end
    else
    begin
      if C = Q then
      begin
        InStr := False;
        Cur := Trim(Cur);
        while Pos('  ', Cur) > 0 do Cur := StringReplace(Cur, '  ', ' ', [rfReplaceAll]);
        if Cur <> '' then
        begin
          if Result <> '' then Result := Result + '|';
          Result := Result + Cur;
        end;
      end
      else
        Cur := Cur + C;
    end;
  end;
end;

// Splits the `font` shorthand into size, line height and family.
// CSS syntax: [style||variant||weight]? font-size[/line-height] font-family
// Returns False when no size can be found (e.g. 'inherit', 'caption').
function ParseFontShorthand(const V: string;
  out SizeS, LHs, FamS: string): Boolean;
var
  W: TStringList;
  I, SizeIdx, P: Integer;
  T: string;

  function EndsWithStr(const S, Suf: string): Boolean;
  begin
    Result := (Length(S) >= Length(Suf)) and
      SameText(Copy(S, Length(S) - Length(Suf) + 1, Length(Suf)), Suf);
  end;

  function IsSizeTok(const S: string): Boolean;
  begin
    Result := False;
    if S = '' then Exit;
    if Pos('/', S) > 0 then Exit(True);   // size/line height
    if StrIn(S, ['xx-small', 'x-small', 'small', 'medium', 'large',
                 'x-large', 'xx-large', 'larger', 'smaller']) then Exit(True);
    if not (S[1] in ['0'..'9', '.']) then Exit;
    Result := EndsWithStr(S, 'px') or EndsWithStr(S, 'em') or EndsWithStr(S, 'rem')
      or EndsWithStr(S, 'ex') or EndsWithStr(S, 'pt') or EndsWithStr(S, 'pc')
      or EndsWithStr(S, '%') or EndsWithStr(S, 'cm') or EndsWithStr(S, 'mm')
      or EndsWithStr(S, 'in');
  end;

begin
  Result := False; SizeS := ''; LHs := ''; FamS := '';
  W := TStringList.Create;
  try
    W.Delimiter := ' '; W.StrictDelimiter := False;
    W.DelimitedText := LowerCase(Trim(V));
    SizeIdx := -1;
    for I := 0 to W.Count - 1 do
      if IsSizeTok(Trim(W[I])) then begin SizeIdx := I; Break; end;
    if SizeIdx < 0 then Exit;
    T := Trim(W[SizeIdx]);
    P := Pos('/', T);
    if P > 0 then
    begin
      SizeS := Copy(T, 1, P - 1);
      LHs := Copy(T, P + 1, MaxInt);
    end
    else
      SizeS := T;
    for I := SizeIdx + 1 to W.Count - 1 do
    begin
      if FamS <> '' then FamS := FamS + ' ';
      FamS := FamS + Trim(W[I]);
    end;
    Result := SizeS <> '';
  finally
    W.Free;
  end;
end;

procedure ParseGridLine(const V: string; out StartL, EndL, Span: Integer);
var
  L, A, B: string;
  P: Integer;
begin
  StartL := 0; EndL := 0; Span := 0;
  L := LowerCase(Trim(V));
  P := Pos('/', L);
  if P > 0 then
  begin
    A := Trim(Copy(L, 1, P - 1));
    B := Trim(Copy(L, P + 1, MaxInt));
  end
  else
  begin
    A := L; B := '';
  end;
  if Pos('span', A) = 1 then
    Span := StrToIntDef(Trim(Copy(A, 5, MaxInt)), 1)
  else
    StartL := StrToIntDef(A, 0);
  if Pos('span', B) = 1 then
    Span := StrToIntDef(Trim(Copy(B, 5, MaxInt)), 1)
  else if B <> '' then
    EndL := StrToIntDef(B, 0);
end;

// Copies from 'Parent' (the source — the parent for inherit, the default instance for
// initial) the fields corresponding to the given property (for shorthands — all
// component fields). Used by inherit/initial/unset.
procedure CopyProp(CS, Parent: TComputedStyle; const Prop: string);
begin
  if Parent = nil then
    Exit;
  if Prop = 'color' then CS.Color := Parent.Color
  else if Prop = 'background-color' then
    begin CS.HasBgColor := Parent.HasBgColor; CS.BgColor := Parent.BgColor; end
  else if Prop = 'background-image' then CS.BgImage := Parent.BgImage
  else if Prop = 'font-family' then CS.FontFamily := Parent.FontFamily
  else if Prop = 'font-size' then CS.FontSizePx := Parent.FontSizePx
  else if Prop = 'font-weight' then CS.Bold := Parent.Bold
  else if Prop = 'font-style' then CS.Italic := Parent.Italic
  else if (Prop = 'text-decoration') or (Prop = 'text-decoration-line') then
    begin CS.Underline := Parent.Underline; CS.Strike := Parent.Strike; end
  else if Prop = 'text-align' then CS.TextAlign := Parent.TextAlign
  else if Prop = 'line-height' then CS.LineHeight := Parent.LineHeight
  else if Prop = 'white-space' then
    begin CS.PreWhiteSpace := Parent.PreWhiteSpace; CS.NoWrap := Parent.NoWrap; end
  else if (Prop = 'list-style') or (Prop = 'list-style-type') then
    CS.ListType := Parent.ListType
  else if Prop = 'list-style-image' then CS.ListImage := Parent.ListImage
  else if Prop = 'list-style-position' then CS.ListInside := Parent.ListInside
  else if Prop = 'text-transform' then CS.TextTransform := Parent.TextTransform
  else if Prop = 'letter-spacing' then CS.LetterSpacing := Parent.LetterSpacing
  else if Prop = 'word-spacing' then CS.WordSpacing := Parent.WordSpacing
  else if Prop = 'cursor' then CS.Cursor := Parent.Cursor
  else if Prop = 'vertical-align' then CS.VertAlign := Parent.VertAlign
  else if Prop = 'box-sizing' then CS.BoxSizing := Parent.BoxSizing
  else if Prop = 'position' then CS.Position := Parent.Position
  else if Prop = 'z-index' then CS.ZIndex := Parent.ZIndex
  else if Prop = 'display' then CS.Display := Parent.Display
  else if Prop = 'float' then CS.Float_ := Parent.Float_
  else if Prop = 'border-collapse' then CS.BorderCollapse := Parent.BorderCollapse
  else if Prop = 'border-spacing' then
    begin CS.BorderSpacingH := Parent.BorderSpacingH;
          CS.BorderSpacingV := Parent.BorderSpacingV; end
  else if Prop = 'width' then
    begin CS.WidthPx := Parent.WidthPx; CS.WidthPct := Parent.WidthPct; end
  else if Prop = 'height' then CS.HeightPx := Parent.HeightPx
  else if Prop = 'min-width' then
    begin CS.MinWidthPx := Parent.MinWidthPx; CS.MinWidthPct := Parent.MinWidthPct; end
  else if Prop = 'max-width' then
    begin CS.MaxWidthPx := Parent.MaxWidthPx; CS.MaxWidthPct := Parent.MaxWidthPct; end
  else if Prop = 'min-height' then CS.MinHeightPx := Parent.MinHeightPx
  else if Prop = 'max-height' then CS.MaxHeightPx := Parent.MaxHeightPx
  else if Prop = 'overflow' then
    begin CS.OverflowX := Parent.OverflowX; CS.OverflowY := Parent.OverflowY; end
  else if Prop = 'overflow-x' then CS.OverflowX := Parent.OverflowX
  else if Prop = 'overflow-y' then CS.OverflowY := Parent.OverflowY
  else if Prop = 'border-radius' then
    begin CS.BorderRadius := Parent.BorderRadius;
          CS.BorderRadiusPct := Parent.BorderRadiusPct; end
  else if (Prop = 'border-color') then
  begin
    CS.BorderColor := Parent.BorderColor;
    CS.BorderColorT := Parent.BorderColorT; CS.BorderColorR := Parent.BorderColorR;
    CS.BorderColorB := Parent.BorderColorB; CS.BorderColorL := Parent.BorderColorL;
  end
  else if Prop = 'border-top-color' then CS.BorderColorT := Parent.BorderColorT
  else if Prop = 'border-right-color' then CS.BorderColorR := Parent.BorderColorR
  else if Prop = 'border-bottom-color' then CS.BorderColorB := Parent.BorderColorB
  else if Prop = 'border-left-color' then CS.BorderColorL := Parent.BorderColorL
  else if Prop = 'border-style' then CS.BorderStyle := Parent.BorderStyle
  else if (Prop = 'border') or (Prop = 'border-width') then
  begin
    CS.BordL := Parent.BordL; CS.BordT := Parent.BordT;
    CS.BordR := Parent.BordR; CS.BordB := Parent.BordB;
    if Prop = 'border' then
    begin
      CS.BorderColor := Parent.BorderColor;
      CS.BorderColorT := Parent.BorderColorT; CS.BorderColorR := Parent.BorderColorR;
      CS.BorderColorB := Parent.BorderColorB; CS.BorderColorL := Parent.BorderColorL;
      CS.BorderStyle := Parent.BorderStyle;
    end;
  end
  else if Prop = 'border-top' then
    begin CS.BordT := Parent.BordT; CS.BorderColorT := Parent.BorderColorT; end
  else if Prop = 'border-right' then
    begin CS.BordR := Parent.BordR; CS.BorderColorR := Parent.BorderColorR; end
  else if Prop = 'border-bottom' then
    begin CS.BordB := Parent.BordB; CS.BorderColorB := Parent.BorderColorB; end
  else if Prop = 'border-left' then
    begin CS.BordL := Parent.BordL; CS.BorderColorL := Parent.BorderColorL; end
  else if Prop = 'margin' then
    begin CS.MarginL := Parent.MarginL; CS.MarginT := Parent.MarginT;
          CS.MarginR := Parent.MarginR; CS.MarginB := Parent.MarginB;
          CS.MarginLPct := Parent.MarginLPct; CS.MarginTPct := Parent.MarginTPct;
          CS.MarginRPct := Parent.MarginRPct; CS.MarginBPct := Parent.MarginBPct; end
  else if Prop = 'margin-left' then
    begin CS.MarginL := Parent.MarginL; CS.MarginLAuto := Parent.MarginLAuto;
          CS.MarginLPct := Parent.MarginLPct; end
  else if Prop = 'margin-top' then
    begin CS.MarginT := Parent.MarginT; CS.MarginTPct := Parent.MarginTPct; end
  else if Prop = 'margin-right' then
    begin CS.MarginR := Parent.MarginR; CS.MarginRAuto := Parent.MarginRAuto;
          CS.MarginRPct := Parent.MarginRPct; end
  else if Prop = 'margin-bottom' then
    begin CS.MarginB := Parent.MarginB; CS.MarginBPct := Parent.MarginBPct; end
  else if Prop = 'padding' then
    begin CS.PadL := Parent.PadL; CS.PadT := Parent.PadT;
          CS.PadR := Parent.PadR; CS.PadB := Parent.PadB;
          CS.PadLPct := Parent.PadLPct; CS.PadTPct := Parent.PadTPct;
          CS.PadRPct := Parent.PadRPct; CS.PadBPct := Parent.PadBPct; end
  else if Prop = 'padding-left' then
    begin CS.PadL := Parent.PadL; CS.PadLPct := Parent.PadLPct; end
  else if Prop = 'padding-top' then
    begin CS.PadT := Parent.PadT; CS.PadTPct := Parent.PadTPct; end
  else if Prop = 'padding-right' then
    begin CS.PadR := Parent.PadR; CS.PadRPct := Parent.PadRPct; end
  else if Prop = 'padding-bottom' then
    begin CS.PadB := Parent.PadB; CS.PadBPct := Parent.PadBPct; end
  else if Prop = 'text-shadow' then
  begin
    CS.HasTextShadow := Parent.HasTextShadow;
    CS.TextShadowX := Parent.TextShadowX; CS.TextShadowY := Parent.TextShadowY;
    CS.TextShadowBlur := Parent.TextShadowBlur;
    CS.TextShadowColor := Parent.TextShadowColor;
  end
  else if Prop = 'box-shadow' then
  begin
    CS.HasBoxShadow := Parent.HasBoxShadow; CS.BoxShadowInset := Parent.BoxShadowInset;
    CS.BoxShadowX := Parent.BoxShadowX; CS.BoxShadowY := Parent.BoxShadowY;
    CS.BoxShadowBlur := Parent.BoxShadowBlur; CS.BoxShadowSpread := Parent.BoxShadowSpread;
    CS.BoxShadowColor := Parent.BoxShadowColor;
  end;
end;

var
  GDefaultStyle: TComputedStyle = nil;

// shared style instance with initial values (for initial/unset)
function DefaultStyle: TComputedStyle;
begin
  if GDefaultStyle = nil then
    GDefaultStyle := TComputedStyle.Create;
  Result := GDefaultStyle;
end;

// whether the property is inherited according to CSS (for 'unset')
function IsInheritedProp(const Prop: string): Boolean;
begin
  Result := StrIn(Prop, ['color', 'font-family', 'font-size', 'font-weight',
    'font-style', 'text-align', 'text-decoration', 'text-decoration-line',
    'line-height', 'white-space', 'list-style', 'list-style-type',
    'list-style-image', 'list-style-position', 'text-transform',
    'letter-spacing', 'word-spacing', 'cursor', 'border-collapse',
    'border-spacing', 'text-shadow', 'visibility']);
end;

procedure TStyleResolver.ApplyDecl(CS: TComputedStyle;
  const Prop, Value: string; ParentFontSize: Integer; Parent: TComputedStyle);
var
  V: string;
  Px: Integer;
  Pct: Double;
  LK: TLengthKind;
  Col: TColor;
  Tokens: TStringList;
  I, N: Integer;
  FS: TFormatSettings;
  D: Double;

  procedure SetSidePct(Side: Integer; V: Double);
  begin
    case Side of
      0: CS.MarginLPct := V;
      1: CS.MarginTPct := V;
      2: CS.MarginRPct := V;
      3: CS.MarginBPct := V;
      4: CS.PadLPct := V;
      5: CS.PadTPct := V;
      6: CS.PadRPct := V;
      7: CS.PadBPct := V;
    end;
  end;

  procedure SetSide(Side: Integer; const SValue: string; AllowAuto: Boolean);
  var
    K: TLengthKind;
    P: Integer;
    Pc: Double;
  begin
    K := ParseLength(SValue, CS.FontSizePx, P, Pc);
    if K = lkAuto then
    begin
      SetSidePct(Side, -1);
      if AllowAuto then
        case Side of
          0: begin CS.MarginL := 0; CS.MarginLAuto := True; end;
          2: begin CS.MarginR := 0; CS.MarginRAuto := True; end;
        end;
      Exit;
    end;
    if K = lkPct then
    begin
      SetSidePct(Side, Pc); // resolved against the block width during layout
      P := 0;
    end
    else if K = lkPx then
      SetSidePct(Side, -1); // explicit px clears the percentage
    if K in [lkPx, lkPct] then
      case Side of
        0: begin CS.MarginL := P; CS.MarginLAuto := False; end;
        1: CS.MarginT := P;
        2: begin CS.MarginR := P; CS.MarginRAuto := False; end;
        3: CS.MarginB := P;
        4: CS.PadL := P;
        5: CS.PadT := P;
        6: CS.PadR := P;
        7: CS.PadB := P;
      end;
  end;

  procedure ApplyBox(Base: Integer; const AValue: string; AllowAuto: Boolean);
  var
    T: TStringList;
  begin
    // 1-4 value shorthands: top right bottom left
    T := TStringList.Create;
    try
      SplitValueTokens(AValue, T);
      case T.Count of
        1: begin
             SetSide(Base + 1, T[0], AllowAuto);
             SetSide(Base + 3, T[0], AllowAuto);
             SetSide(Base + 0, T[0], AllowAuto);
             SetSide(Base + 2, T[0], AllowAuto);
           end;
        2: begin
             SetSide(Base + 1, T[0], AllowAuto);
             SetSide(Base + 3, T[0], AllowAuto);
             SetSide(Base + 0, T[1], AllowAuto);
             SetSide(Base + 2, T[1], AllowAuto);
           end;
        3: begin
             SetSide(Base + 1, T[0], AllowAuto);
             SetSide(Base + 0, T[1], AllowAuto);
             SetSide(Base + 2, T[1], AllowAuto);
             SetSide(Base + 3, T[2], AllowAuto);
           end;
        4: begin
             SetSide(Base + 1, T[0], AllowAuto);
             SetSide(Base + 2, T[1], AllowAuto);
             SetSide(Base + 3, T[2], AllowAuto);
             SetSide(Base + 0, T[3], AllowAuto);
           end;
      end;
    finally
      T.Free;
    end;
  end;

  procedure SetAllBorderW(W: Integer);
  begin
    CS.BordL := W; CS.BordT := W; CS.BordR := W; CS.BordB := W;
  end;

  procedure SetAllBorderColor(C: TColor);
  begin
    CS.BorderColor := C;
    CS.BorderColorT := C; CS.BorderColorR := C;
    CS.BorderColorB := C; CS.BorderColorL := C;
  end;

  // NOTE: var (not out), and BS is assigned ONLY on a match — otherwise
  // a token that is not a style (e.g. a colour) would reset an already set style.
  function ParseBorderStyleWord(const W: string; var BS: TCssBorderStyle): Boolean;
  var
    L: string;
  begin
    Result := True;
    L := LowerCase(W);
    if (L = 'none') or (L = 'hidden') then
      BS := cbsNone
    else if L = 'double' then
      BS := cbsDouble
    else if StrIn(L, ['solid', 'inset', 'outset', 'groove', 'ridge']) then
      BS := cbsSolid
    else if L = 'dashed' then
      BS := cbsDashed
    else if L = 'dotted' then
      BS := cbsDotted
    else
      Result := False;
  end;

var
  BS: TCssBorderStyle;
  W: Integer;
  VL: string;
  BoolTmp, BoolTmp2: Boolean;
  FSizeS, FLhS, FFamS: string;
begin
  V := Trim(Value);
  if V = '' then
    Exit;
  // inherit: copy from the parent; initial: from the default value;
  // unset: for inherited properties = inherit, otherwise = initial.
  // Must override what the cascade set earlier (e.g. the UA sheet).
  if SameText(V, 'inherit') then
  begin
    CopyProp(CS, Parent, Prop);
    Exit;
  end;
  if SameText(V, 'initial') then
  begin
    CopyProp(CS, DefaultStyle, Prop);
    Exit;
  end;
  if SameText(V, 'unset') then
  begin
    if IsInheritedProp(Prop) then
      CopyProp(CS, Parent, Prop)
    else
      CopyProp(CS, DefaultStyle, Prop);
    Exit;
  end;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  if Prop = 'display' then
  begin
    VL := LowerCase(V);
    if VL = 'none' then
      CS.Display := cdNone
    else if (VL = 'flex') or (VL = 'inline-flex') then
      CS.Display := cdFlex
    else if (VL = 'grid') or (VL = 'inline-grid') then
      CS.Display := cdGrid
    else if StrIn(VL, ['block', 'flow-root',
      'table-row-group', 'table-header-group', 'table-footer-group']) then
      CS.Display := cdBlock
    else if VL = 'table' then
      CS.Display := cdTable
    else if VL = 'table-row' then
      CS.Display := cdTableRow
    else if VL = 'table-cell' then
      CS.Display := cdTableCell
    else if VL = 'inline' then
      CS.Display := cdInline
    else if StrIn(VL, ['inline-block', 'inline-table']) then
      CS.Display := cdInlineBlock
    else if VL = 'list-item' then
      CS.Display := cdListItem;
  end

  else if Prop = 'float' then
  begin
    VL := LowerCase(V);
    if VL = 'left' then
      CS.Float_ := cfLeft
    else if VL = 'right' then
      CS.Float_ := cfRight
    else if VL = 'none' then
      CS.Float_ := cfNone;
  end

  else if Prop = 'clear' then
  begin
    VL := LowerCase(V);
    if VL = 'left' then
      CS.Clear_ := ccLeft
    else if VL = 'right' then
      CS.Clear_ := ccRight
    else if VL = 'both' then
      CS.Clear_ := ccBoth
    else if VL = 'none' then
      CS.Clear_ := ccNone;
  end

  else if Prop = 'color' then
  begin
    if ParseCssColor(V, Col) then
      CS.Color := Col;
  end

  else if Prop = 'background-color' then
  begin
    if SameText(V, 'transparent') then
      CS.HasBgColor := False
    else if ParseCssColor(V, Col) then
    begin
      CS.BgColor := Col;
      CS.HasBgColor := True;
    end;
  end

  else if Prop = 'background' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      for I := 0 to Tokens.Count - 1 do
      begin
        if (Pos('linear-gradient(', LowerCase(Tokens[I])) = 1) or
           (Pos('radial-gradient(', LowerCase(Tokens[I])) = 1) then
          ParseGradientValue(Tokens[I], CS)
        else if SameText(Copy(Tokens[I], 1, 4), 'url(') then
          CS.BgImage := ExtractFirstUrl(Tokens[I])
        else if SameText(Tokens[I], 'none') then
        begin
          CS.BgImage := '';
          CS.HasBgColor := False;
          CS.GradKind := gkNone;
        end
        else if ParseCssColor(Tokens[I], Col) then
        begin
          CS.BgColor := Col;
          CS.HasBgColor := True;
        end;
      end;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'background-image' then
  begin
    if SameText(V, 'none') then
    begin
      CS.BgImage := '';
      CS.GradKind := gkNone;
    end
    else if (Pos('linear-gradient(', LowerCase(V)) = 1) or
            (Pos('radial-gradient(', LowerCase(V)) = 1) then
      ParseGradientValue(V, CS)
    else
      CS.BgImage := ExtractFirstUrl(V);
  end

  else if Prop = 'background-repeat' then
  begin
    VL := LowerCase(V);
    if VL = 'no-repeat' then
      CS.BgRepeat := False
    else if StrIn(VL, ['repeat', 'repeat-x', 'repeat-y']) then
      CS.BgRepeat := True;
  end

  else if Prop = 'background-size' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if Tokens.Count >= 1 then
      begin
        LK := ParseLength(Tokens[0], CS.FontSizePx, Px, Pct);
        if LK = lkPx then
          CS.BgSizeW := Max(1, Px);
      end;
      if Tokens.Count >= 2 then
      begin
        LK := ParseLength(Tokens[1], CS.FontSizePx, Px, Pct);
        if LK = lkPx then
          CS.BgSizeH := Max(1, Px);
      end
      else
        CS.BgSizeH := CS.BgSizeW;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'background-position' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if Tokens.Count >= 1 then
      begin
        LK := ParseLength(Tokens[0], CS.FontSizePx, Px, Pct);
        if LK = lkPct then
          CS.BgPosXPct := Pct
        else if SameText(Tokens[0], 'center') then
          CS.BgPosXPct := 50
        else if SameText(Tokens[0], 'right') then
          CS.BgPosXPct := 100
        else if SameText(Tokens[0], 'left') then
          CS.BgPosXPct := 0;
      end;
      if Tokens.Count >= 2 then
      begin
        LK := ParseLength(Tokens[1], CS.FontSizePx, Px, Pct);
        if LK = lkPct then
          CS.BgPosYPct := Pct
        else if SameText(Tokens[1], 'center') then
          CS.BgPosYPct := 50
        else if SameText(Tokens[1], 'bottom') then
          CS.BgPosYPct := 100
        else if SameText(Tokens[1], 'top') then
          CS.BgPosYPct := 0;
      end;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'font-family' then
    CS.FontFamily := V

  else if Prop = 'font' then
  begin
    // font shorthand: [style||variant||weight]? size[/lh] family
    if ParseFontShorthand(V, FSizeS, FLhS, FFamS) then
    begin
      if FSizeS <> '' then
        ApplyDecl(CS, 'font-size', FSizeS, ParentFontSize, Parent);
      if FLhS <> '' then
        ApplyDecl(CS, 'line-height', FLhS, ParentFontSize, Parent);
      if FFamS <> '' then
        ApplyDecl(CS, 'font-family', FFamS, ParentFontSize, Parent);
    end;
  end

  else if Prop = 'font-size' then
  begin
    VL := LowerCase(V);
    N := StrIndex(VL, ['xx-small', 'x-small', 'small', 'medium', 'large',
      'x-large', 'xx-large']);
    if N >= 0 then
      case N of
        0: CS.FontSizePx := 9;
        1: CS.FontSizePx := 10;
        2: CS.FontSizePx := 13;
        3: CS.FontSizePx := 16;
        4: CS.FontSizePx := 18;
        5: CS.FontSizePx := 24;
        6: CS.FontSizePx := 32;
      end
    else if VL = 'smaller' then
      CS.FontSizePx := Round(ParentFontSize * 0.83)
    else if VL = 'larger' then
      CS.FontSizePx := Round(ParentFontSize * 1.2)
    else
    begin
      LK := ParseLength(V, ParentFontSize, Px, Pct);
      if LK = lkPx then
        CS.FontSizePx := Max(6, Px)
      else if LK = lkPct then
        CS.FontSizePx := Max(6, Round(ParentFontSize * Pct / 100));
    end;
  end

  else if Prop = 'font-weight' then
  begin
    N := StrToIntDef(V, -1);
    if N >= 0 then
      CS.Bold := N >= 600
    else
    begin
      VL := LowerCase(V);
      if (VL = 'bold') or (VL = 'bolder') then
        CS.Bold := True
      else if (VL = 'normal') or (VL = 'lighter') then
        CS.Bold := False;
    end;
  end

  else if Prop = 'font-style' then
  begin
    VL := LowerCase(V);
    if (VL = 'italic') or (VL = 'oblique') then
      CS.Italic := True
    else if VL = 'normal' then
      CS.Italic := False;
  end

  else if (Prop = 'text-decoration') or (Prop = 'text-decoration-line') then
  begin
    if Pos('underline', LowerCase(V)) > 0 then
      CS.Underline := True;
    if Pos('line-through', LowerCase(V)) > 0 then
      CS.Strike := True;
    if SameText(V, 'none') then
    begin
      CS.Underline := False;
      CS.Strike := False;
    end;
  end

  else if Prop = 'text-align' then
  begin
    VL := LowerCase(V);
    if StrIn(VL, ['left', 'start', 'justify']) then
      CS.TextAlign := ctaLeft
    else if VL = 'center' then
      CS.TextAlign := ctaCenter
    else if (VL = 'right') or (VL = 'end') then
      CS.TextAlign := ctaRight;
  end

  else if Prop = 'line-height' then
  begin
    if SameText(V, 'normal') then
      CS.LineHeight := 1.25
    else if TryStrToFloat(V, D, FS) then
      CS.LineHeight := D
    else
    begin
      LK := ParseLength(V, CS.FontSizePx, Px, Pct);
      if (LK = lkPx) and (CS.FontSizePx > 0) then
        CS.LineHeight := Px / CS.FontSizePx
      else if LK = lkPct then
        CS.LineHeight := Pct / 100;
    end;
  end

  else if Prop = 'white-space' then
  begin
    VL := LowerCase(V);
    if StrIn(VL, ['pre', 'pre-wrap', 'pre-line']) then
    begin
      CS.PreWhiteSpace := True
    end
    else if VL = 'nowrap' then
    begin
      CS.PreWhiteSpace := False;
      CS.NoWrap := True;
    end
    else if VL = 'normal' then
    begin
      CS.PreWhiteSpace := False;
      CS.NoWrap := False;
    end;
  end

  else if (Prop = 'list-style') or (Prop = 'list-style-type') then
  begin
    VL := LowerCase(V);
    if Pos('none', VL) > 0 then
      CS.ListType := cltNone
    else if Pos('decimal', VL) > 0 then
      CS.ListType := cltDecimal
    else if Pos('circle', VL) > 0 then
      CS.ListType := cltCircle
    else if Pos('square', VL) > 0 then
      CS.ListType := cltSquare
    else if Pos('disc', VL) > 0 then
      CS.ListType := cltDisc;
    // the list-style shorthand may also carry an image and a position
    if Prop = 'list-style' then
    begin
      if Pos('url(', VL) > 0 then
        CS.ListImage := ExtractFirstUrl(V)
      else if Pos('none', VL) > 0 then
        CS.ListImage := '';
      if Pos('inside', VL) > 0 then
        CS.ListInside := True
      else if Pos('outside', VL) > 0 then
        CS.ListInside := False;
    end;
  end

  else if Prop = 'list-style-image' then
  begin
    if SameText(V, 'none') then
      CS.ListImage := ''
    else
      CS.ListImage := ExtractFirstUrl(V);
  end

  else if Prop = 'list-style-position' then
  begin
    VL := LowerCase(V);
    if VL = 'inside' then
      CS.ListInside := True
    else if VL = 'outside' then
      CS.ListInside := False;
  end

  else if Prop = 'margin' then
    ApplyBox(0, V, True)
  else if Prop = 'margin-left' then
    SetSide(0, V, True)
  else if Prop = 'margin-top' then
    SetSide(1, V, False)
  else if Prop = 'margin-right' then
    SetSide(2, V, True)
  else if Prop = 'margin-bottom' then
    SetSide(3, V, False)

  else if Prop = 'padding' then
    ApplyBox(4, V, False)
  else if Prop = 'padding-left' then
    SetSide(4, V, False)
  else if Prop = 'padding-top' then
    SetSide(5, V, False)
  else if Prop = 'padding-right' then
    SetSide(6, V, False)
  else if Prop = 'padding-bottom' then
    SetSide(7, V, False)

  else if Prop = 'width' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    case LK of
      lkPx: begin CS.WidthPx := Max(0, Px); CS.WidthPct := -1; end;
      lkPct: begin CS.WidthPct := Pct; CS.WidthPx := -1; end;
      lkAuto: begin CS.WidthPx := -1; CS.WidthPct := -1; end;
    end;
  end

  else if Prop = 'height' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    if LK = lkPx then
      CS.HeightPx := Max(0, Px)
    else if LK = lkAuto then
      CS.HeightPx := -1;
    // height in % — ignored (auto)
  end

  else if Prop = 'min-height' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    if LK = lkPx then
      CS.MinHeightPx := Max(0, Px)
    else if LK = lkAuto then
      CS.MinHeightPx := -1;
  end

  else if Prop = 'max-height' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    if LK = lkPx then
      CS.MaxHeightPx := Max(0, Px)
    else if SameText(V, 'none') then
      CS.MaxHeightPx := -1;
  end

  else if Prop = 'max-width' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    case LK of
      lkPx: begin CS.MaxWidthPx := Max(0, Px); CS.MaxWidthPct := -1; end;
      lkPct: begin CS.MaxWidthPct := Pct; CS.MaxWidthPx := -1; end;
      lkAuto, lkInvalid:
        if SameText(V, 'none') then
        begin
          CS.MaxWidthPx := -1;
          CS.MaxWidthPct := -1;
        end;
    end;
  end

  else if Prop = 'min-width' then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    case LK of
      lkPx: begin CS.MinWidthPx := Max(0, Px); CS.MinWidthPct := -1; end;
      lkPct: begin CS.MinWidthPct := Pct; CS.MinWidthPx := -1; end;
      lkAuto: begin CS.MinWidthPx := -1; CS.MinWidthPct := -1; end;
    end;
  end

  else if Prop = 'box-sizing' then
  begin
    VL := LowerCase(V);
    if VL = 'border-box' then
      CS.BoxSizing := cbsBorderBox
    else if VL = 'content-box' then
      CS.BoxSizing := cbsContentBox;
  end

  else if Prop = 'position' then
  begin
    VL := LowerCase(V);
    if VL = 'absolute' then
      CS.Position := cpAbsolute
    else if VL = 'relative' then
      CS.Position := cpRelative
    else if VL = 'fixed' then
      CS.Position := cpFixed
    else if (VL = 'static') or (VL = 'sticky') then
      CS.Position := cpStatic;
  end

  else if Prop = 'z-index' then
  begin
    if SameText(V, 'auto') then
      CS.ZIndex := 0
    else
      CS.ZIndex := StrToIntDef(V, CS.ZIndex);
  end

  else if Prop = 'opacity' then
  begin
    if TryStrToFloat(V, D, FS) then
      CS.Opacity := Max(0, Min(1, D));
  end

  else if Prop = 'flex-direction' then
    CS.FlexDirCol := Pos('column', LowerCase(V)) > 0

  else if Prop = 'flex-wrap' then
    CS.FlexWrapOn := Pos('wrap', LowerCase(V)) > 0

  else if Prop = 'justify-content' then
    CS.JustifyContent := ParseJustify(V)

  else if Prop = 'align-items' then
    CS.AlignItems := ParseAlign(V)

  else if Prop = 'justify-items' then
    CS.JustifyItems := ParseAlign(V)

  else if Prop = 'align-self' then
    begin CS.AlignSelf := ParseAlign(V); CS.AlignSelfAuto := SameText(V, 'auto'); end

  else if Prop = 'justify-self' then
    begin CS.JustifySelf := ParseAlign(V); CS.JustifySelfAuto := SameText(V, 'auto'); end

  else if Prop = 'gap' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if (Tokens.Count >= 1) and (ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) = lkPx) then
      begin CS.RowGap := Max(0, Px); CS.ColGap := Max(0, Px); end;
      if (Tokens.Count >= 2) and (ParseLength(Tokens[1], CS.FontSizePx, Px, Pct) = lkPx) then
        CS.ColGap := Max(0, Px);
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'row-gap' then
    begin if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then CS.RowGap := Max(0, Px); end
  else if Prop = 'column-gap' then
    begin if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then CS.ColGap := Max(0, Px); end

  else if Prop = 'flex' then
  begin
    // flex: <grow> [shrink] [basis] — we take grow and an optional basis in px
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if SameText(V, 'none') then
        begin CS.FlexGrow := 0; CS.FlexBasis := -1; end
      else if Tokens.Count >= 1 then
      begin
        if TryStrToFloat(Tokens[0], D, FS) then CS.FlexGrow := D
        else CS.FlexGrow := 1;
        CS.FlexBasis := 0; // flex:N -> basis 0 (grows proportionally)
        for I := 1 to Tokens.Count - 1 do
          if ParseLength(Tokens[I], CS.FontSizePx, Px, Pct) = lkPx then
            CS.FlexBasis := Px;
      end;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'flex-grow' then
    begin if TryStrToFloat(V, D, FS) then CS.FlexGrow := D; end
  else if Prop = 'flex-basis' then
  begin
    if SameText(V, 'auto') then CS.FlexBasis := -1
    else if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then CS.FlexBasis := Px;
  end

  else if Prop = 'grid-template-columns' then
    CS.GridTemplate := V
  else if Prop = 'grid-template-rows' then
    CS.GridTemplateRows := V
  else if Prop = 'grid-template-areas' then
    CS.GridTemplateAreas := ExtractGridAreaRows(V)
  else if Prop = 'grid-template' then
  begin
    // shorthand: [areas/rows] / columns
    if (Pos('"', V) > 0) or (Pos('''', V) > 0) then
      CS.GridTemplateAreas := ExtractGridAreaRows(V);
    N := Pos('/', V);
    if N > 0 then
    begin
      if (Pos('"', V) = 0) and (Pos('''', V) = 0) then
        CS.GridTemplateRows := Trim(Copy(V, 1, N - 1));
      CS.GridTemplate := Trim(Copy(V, N + 1, MaxInt));
    end;
  end

  else if Prop = 'grid-area' then
  begin
    // area name (e.g. pageContent) or line notation r/c/r/c
    if (Pos('/', V) = 0) and (Trim(V) <> '') and
       not (V[1] in ['0'..'9']) then
      CS.GridAreaName := Trim(V);
  end
  else if (Prop = 'grid-column') or (Prop = 'grid-row') then
  begin
    ParseGridLine(V, N, I, Px); // N=start, I=end, Px=span(0 none)
    if Prop = 'grid-column' then
      begin CS.GridColStart := N; CS.GridColEnd := I; CS.GridColSpan := Px; end
    else
      begin CS.GridRowStart := N; CS.GridRowEnd := I; CS.GridRowSpan := Px; end;
  end

  else if Prop = 'content' then
  begin
    VL := Trim(V);
    if SameText(VL, 'none') or SameText(VL, 'normal') then
      CS.HasContent := False
    else if (Length(VL) >= 2) and (VL[1] in ['"', '''']) and
            (VL[Length(VL)] = VL[1]) then
    begin
      CS.HasContent := True;
      CS.Content := Copy(VL, 2, Length(VL) - 2);
    end
    else
    begin
      // counters/attr()/url() unsupported — treat as empty content,
      // which still generates a box (Acid2 uses content:'')
      CS.HasContent := True;
      CS.Content := '';
    end;
  end

  else if Prop = 'column-count' then
    CS.ColumnCount := Max(0, StrToIntDef(Trim(V), 0))
  else if Prop = 'column-width' then
  begin
    if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then CS.ColumnWidthPx := Max(0, Px);
  end
  else if (Prop = 'columns') or (Prop = '-moz-columns') or (Prop = '-webkit-columns') then
  begin
    // columns shorthand: <width> || <count> — a token with a unit = width,
    // a bare integer = number of columns
    Tokens := TStringList.Create;
    try
      Tokens.Delimiter := ' '; Tokens.StrictDelimiter := False;
      Tokens.DelimitedText := LowerCase(Trim(V));
      for I := 0 to Tokens.Count - 1 do
      begin
        VL := Trim(Tokens[I]);
        if VL = '' then Continue;
        if (VL[1] in ['0'..'9']) and (Pos('px', VL) = 0) and (Pos('em', VL) = 0) and
           (Pos('.', VL) = 0) and (StrToIntDef(VL, -1) >= 1) then
          CS.ColumnCount := StrToIntDef(VL, 0)
        else if ParseLength(VL, CS.FontSizePx, Px, Pct) = lkPx then
          CS.ColumnWidthPx := Max(0, Px);
      end;
    finally
      Tokens.Free;
    end;
  end

  else if StrIn(Prop, ['overflow', 'overflow-x', 'overflow-y']) then
  begin
    VL := LowerCase(V);
    if VL = 'hidden' then
    begin
      if Prop <> 'overflow-y' then CS.OverflowX := coHidden;
      if Prop <> 'overflow-x' then CS.OverflowY := coHidden;
    end
    else if VL = 'scroll' then
    begin
      if Prop <> 'overflow-y' then CS.OverflowX := coScroll;
      if Prop <> 'overflow-x' then CS.OverflowY := coScroll;
    end
    else if VL = 'auto' then
    begin
      if Prop <> 'overflow-y' then CS.OverflowX := coAuto;
      if Prop <> 'overflow-x' then CS.OverflowY := coAuto;
    end
    else if VL = 'visible' then
    begin
      if Prop <> 'overflow-y' then CS.OverflowX := coVisible;
      if Prop <> 'overflow-x' then CS.OverflowY := coVisible;
    end;
  end

  else if StrIn(Prop, ['border-radius', 'border-top-left-radius',
    'border-top-right-radius', 'border-bottom-right-radius',
    'border-bottom-left-radius']) then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if Tokens.Count > 0 then
        case ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) of
          lkPx: begin CS.BorderRadius := Max(0, Px); CS.BorderRadiusPct := -1; end;
          lkPct: CS.BorderRadiusPct := Max(0, Round(Pct));
        end;
    finally
      Tokens.Free;
    end;
  end

  else if StrIn(Prop, ['left', 'top', 'right', 'bottom']) then
  begin
    LK := ParseLength(V, CS.FontSizePx, Px, Pct);
    if LK = lkPx then
    begin
      if Prop = 'left' then
        CS.PosLeft := Px
      else if Prop = 'top' then
        CS.PosTop := Px
      else if Prop = 'right' then
        CS.PosRight := Px
      else if Prop = 'bottom' then
        CS.PosBottom := Px;
    end
    else if LK = lkAuto then
    begin
      if Prop = 'left' then
        CS.PosLeft := Low(Integer)
      else if Prop = 'top' then
        CS.PosTop := Low(Integer)
      else if Prop = 'right' then
        CS.PosRight := Low(Integer)
      else if Prop = 'bottom' then
        CS.PosBottom := Low(Integer);
    end;
  end

  else if StrIn(Prop, ['border', 'border-top', 'border-right',
    'border-bottom', 'border-left']) then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      W := 1;
      BS := cbsSolid;
      Col := CS.BorderColor;
      BoolTmp := False; // whether a colour was given
      for I := 0 to Tokens.Count - 1 do
      begin
        if ParseBorderStyleWord(Tokens[I], BS) then
          Continue;
        if ParseCssColor(Tokens[I], Col) then
        begin
          BoolTmp := True;
          Continue;
        end;
        VL := LowerCase(Tokens[I]);
        if VL = 'thin' then
          W := 1
        else if VL = 'medium' then
          W := 3
        else if VL = 'thick' then
          W := 5
        else if ParseLength(Tokens[I], CS.FontSizePx, Px, Pct) = lkPx then
          W := Px;
      end;
      if BS = cbsNone then
        W := 0;
      CS.BorderStyle := BS;
      if Prop = 'border' then
      begin
        SetAllBorderW(W);
        if BoolTmp then SetAllBorderColor(Col);
      end
      else if Prop = 'border-top' then
      begin
        CS.BordT := W;
        if BoolTmp then CS.BorderColorT := Col;
      end
      else if Prop = 'border-right' then
      begin
        CS.BordR := W;
        if BoolTmp then CS.BorderColorR := Col;
      end
      else if Prop = 'border-bottom' then
      begin
        CS.BordB := W;
        if BoolTmp then CS.BorderColorB := Col;
      end
      else if Prop = 'border-left' then
      begin
        CS.BordL := W;
        if BoolTmp then CS.BorderColorL := Col;
      end;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'border-width' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      case Tokens.Count of
        1: if ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) = lkPx then
             SetAllBorderW(Px);
        2: begin
             if ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) = lkPx then
             begin
               CS.BordT := Px;
               CS.BordB := Px;
             end;
             if ParseLength(Tokens[1], CS.FontSizePx, Px, Pct) = lkPx then
             begin
               CS.BordL := Px;
               CS.BordR := Px;
             end;
           end;
        4: begin
             if ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) = lkPx then
               CS.BordT := Px;
             if ParseLength(Tokens[1], CS.FontSizePx, Px, Pct) = lkPx then
               CS.BordR := Px;
             if ParseLength(Tokens[2], CS.FontSizePx, Px, Pct) = lkPx then
               CS.BordB := Px;
             if ParseLength(Tokens[3], CS.FontSizePx, Px, Pct) = lkPx then
               CS.BordL := Px;
           end;
      end;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'border-style' then
  begin
    if ParseBorderStyleWord(V, BS) then
    begin
      CS.BorderStyle := BS;
      if BS = cbsNone then
        SetAllBorderW(0)
      else if (CS.BordL = 0) and (CS.BordT = 0) and (CS.BordR = 0) and
              (CS.BordB = 0) then
        SetAllBorderW(3); // medium — default width
    end;
  end

  else if Prop = 'border-color' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      // 1-4 values: top right bottom left (like border-width)
      case Tokens.Count of
        1: if ParseCssColor(Tokens[0], Col) then SetAllBorderColor(Col);
        2: begin
             if ParseCssColor(Tokens[0], Col) then
               begin CS.BorderColorT := Col; CS.BorderColorB := Col; end;
             if ParseCssColor(Tokens[1], Col) then
               begin CS.BorderColorL := Col; CS.BorderColorR := Col; end;
           end;
        3: begin
             if ParseCssColor(Tokens[0], Col) then CS.BorderColorT := Col;
             if ParseCssColor(Tokens[1], Col) then
               begin CS.BorderColorL := Col; CS.BorderColorR := Col; end;
             if ParseCssColor(Tokens[2], Col) then CS.BorderColorB := Col;
           end;
        4: begin
             if ParseCssColor(Tokens[0], Col) then CS.BorderColorT := Col;
             if ParseCssColor(Tokens[1], Col) then CS.BorderColorR := Col;
             if ParseCssColor(Tokens[2], Col) then CS.BorderColorB := Col;
             if ParseCssColor(Tokens[3], Col) then CS.BorderColorL := Col;
           end;
      end;
      // keep BorderColor (controls) as the top edge colour
      CS.BorderColor := CS.BorderColorT;
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'border-top-color' then
    begin if ParseCssColor(V, Col) then CS.BorderColorT := Col; end
  else if Prop = 'border-right-color' then
    begin if ParseCssColor(V, Col) then CS.BorderColorR := Col; end
  else if Prop = 'border-bottom-color' then
    begin if ParseCssColor(V, Col) then CS.BorderColorB := Col; end
  else if Prop = 'border-left-color' then
    begin if ParseCssColor(V, Col) then CS.BorderColorL := Col; end

  else if Prop = 'visibility' then
  begin
    if SameText(V, 'hidden') or SameText(V, 'collapse') then
      CS.Display := cdNone; // simplification: hidden = none
  end

  else if Prop = 'text-transform' then
  begin
    VL := LowerCase(V);
    if VL = 'uppercase' then
      CS.TextTransform := cttUpper
    else if VL = 'lowercase' then
      CS.TextTransform := cttLower
    else if VL = 'capitalize' then
      CS.TextTransform := cttCapitalize
    else if VL = 'none' then
      CS.TextTransform := cttNone;
  end

  else if Prop = 'letter-spacing' then
  begin
    if SameText(V, 'normal') then
      CS.LetterSpacing := 0
    else if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then
      CS.LetterSpacing := Px;
  end

  else if Prop = 'word-spacing' then
  begin
    if SameText(V, 'normal') then
      CS.WordSpacing := 0
    else if ParseLength(V, CS.FontSizePx, Px, Pct) = lkPx then
      CS.WordSpacing := Px;
  end

  else if Prop = 'cursor' then
  begin
    VL := LowerCase(V);
    // the value may be a list with url(...) and a keyword at the end
    if Pos('not-allowed', VL) > 0 then CS.Cursor := ccrNotAllowed
    else if Pos('pointer', VL) > 0 then CS.Cursor := ccrPointer
    else if Pos('col-resize', VL) > 0 then CS.Cursor := ccrColResize
    else if Pos('row-resize', VL) > 0 then CS.Cursor := ccrRowResize
    else if Pos('crosshair', VL) > 0 then CS.Cursor := ccrCrosshair
    else if Pos('progress', VL) > 0 then CS.Cursor := ccrProgress
    else if Pos('grab', VL) > 0 then CS.Cursor := ccrGrab
    else if Pos('move', VL) > 0 then CS.Cursor := ccrMove
    else if Pos('wait', VL) > 0 then CS.Cursor := ccrWait
    else if Pos('help', VL) > 0 then CS.Cursor := ccrHelp
    else if Pos('text', VL) > 0 then CS.Cursor := ccrText
    else if Pos('default', VL) > 0 then CS.Cursor := ccrDefault
    else if Pos('auto', VL) > 0 then CS.Cursor := ccrAuto;
  end

  else if Prop = 'border-collapse' then
  begin
    VL := LowerCase(V);
    if VL = 'collapse' then
      CS.BorderCollapse := True
    else if VL = 'separate' then
      CS.BorderCollapse := False;
  end

  else if Prop = 'border-spacing' then
  begin
    Tokens := TStringList.Create;
    try
      SplitValueTokens(V, Tokens);
      if (Tokens.Count >= 1) and
         (ParseLength(Tokens[0], CS.FontSizePx, Px, Pct) = lkPx) then
      begin
        CS.BorderSpacingH := Max(0, Px);
        CS.BorderSpacingV := Max(0, Px);
      end;
      if (Tokens.Count >= 2) and
         (ParseLength(Tokens[1], CS.FontSizePx, Px, Pct) = lkPx) then
        CS.BorderSpacingV := Max(0, Px);
    finally
      Tokens.Free;
    end;
  end

  else if Prop = 'text-shadow' then
  begin
    if SameText(V, 'none') then
      CS.HasTextShadow := False
    else
      CS.HasTextShadow := ParseShadowSpec(V, CS.FontSizePx, False,
        CS.TextShadowX, CS.TextShadowY, CS.TextShadowBlur, N, // N = spread (ignored)
        CS.TextShadowColor, BoolTmp, BoolTmp2);
  end

  else if Prop = 'box-shadow' then
  begin
    if SameText(V, 'none') then
      CS.HasBoxShadow := False
    else
      CS.HasBoxShadow := ParseShadowSpec(V, CS.FontSizePx, True,
        CS.BoxShadowX, CS.BoxShadowY, CS.BoxShadowBlur, CS.BoxShadowSpread,
        CS.BoxShadowColor, BoolTmp, CS.BoxShadowInset);
  end

  else if Prop = 'vertical-align' then
  begin
    VL := LowerCase(V);
    if (VL = 'top') or (VL = 'text-top') then
      CS.VertAlign := cvaTop
    else if VL = 'middle' then
      CS.VertAlign := cvaMiddle
    else if (VL = 'bottom') or (VL = 'text-bottom') then
      CS.VertAlign := cvaBottom;
    // baseline and numeric offsets are not supported
  end;
  // remaining properties (position, overflow...) —
  // known, but deliberately ignored
end;

// ---- presentational attributes ----

// width/height attributes accept plain pixels or percentages
procedure ApplyWidthHeightAttrs(E: TDOMElement; CS: TComputedStyle);
var
  S: string;
  N: Integer;
begin
  S := E.GetAttribute('width');
  if S <> '' then
  begin
    N := StrToIntDef(StringReplace(S, '%', '', []), -1);
    if N >= 0 then
      if Pos('%', S) > 0 then
        CS.WidthPct := N
      else
        CS.WidthPx := N;
  end;
  S := E.GetAttribute('height');
  N := StrToIntDef(S, -1);
  if N >= 0 then
    CS.HeightPx := N;
end;

procedure TStyleResolver.ApplyPresentationalAttrs(E: TDOMElement;
  CS: TComputedStyle);
var
  S: string;
  N: Integer;
  Col: TColor;
  Anc: TDOMNode;
begin
  if E.TagName = 'img' then
  begin
    S := E.GetAttribute('width');
    if S <> '' then
    begin
      N := StrToIntDef(StringReplace(S, '%', '', []), -1);
      if N >= 0 then
        if Pos('%', S) > 0 then
          CS.WidthPct := N
        else
          CS.WidthPx := N;
    end;
    S := E.GetAttribute('height');
    N := StrToIntDef(S, -1);
    if N >= 0 then
      CS.HeightPx := N;
    if E.GetAttribute('align') = 'left' then
      CS.Float_ := cfLeft
    else if E.GetAttribute('align') = 'right' then
      CS.Float_ := cfRight;
  end
  else if E.TagName = 'font' then
  begin
    S := E.GetAttribute('color');
    if (S <> '') and ParseCssColor(S, Col) then
      CS.Color := Col;
    S := E.GetAttribute('size');
    N := StrToIntDef(S, 0);
    case N of
      1: CS.FontSizePx := 10;
      2: CS.FontSizePx := 13;
      3: CS.FontSizePx := 16;
      4: CS.FontSizePx := 18;
      5: CS.FontSizePx := 24;
      6: CS.FontSizePx := 32;
      7: CS.FontSizePx := 48;
    end;
    S := E.GetAttribute('face');
    if S <> '' then
      CS.FontFamily := S;
  end
  else if E.TagName = 'table' then
  begin
    // border attribute draws a border around the table itself
    N := StrToIntDef(E.GetAttribute('border'), 0);
    if N > 0 then
    begin
      CS.BorderStyle := cbsSolid;
      CS.BordL := N;
      CS.BordT := N;
      CS.BordR := N;
      CS.BordB := N;
    end;
    ApplyWidthHeightAttrs(E, CS);
  end
  else if (E.TagName = 'td') or (E.TagName = 'th') then
  begin
    // cells inherit border/cellpadding from the enclosing table's attrs
    Anc := E.ParentNode;
    while (Anc <> nil) and
          not ((Anc is TDOMElement) and (TDOMElement(Anc).TagName = 'table')) do
      Anc := Anc.ParentNode;
    if Anc <> nil then
    begin
      if StrToIntDef(TDOMElement(Anc).GetAttribute('border'), 0) > 0 then
      begin
        CS.BorderStyle := cbsSolid;
        CS.BordL := 1;
        CS.BordT := 1;
        CS.BordR := 1;
        CS.BordB := 1;
      end;
      N := StrToIntDef(TDOMElement(Anc).GetAttribute('cellpadding'), -1);
      if N >= 0 then
      begin
        CS.PadL := N;
        CS.PadT := N;
        CS.PadR := N;
        CS.PadB := N;
      end;
    end;
    // valign attribute: own beats the one on the parent <tr>
    S := LowerCase(E.GetAttribute('valign'));
    if (S = '') and (E.ParentNode is TDOMElement) then
      S := LowerCase(TDOMElement(E.ParentNode).GetAttribute('valign'));
    if S = 'top' then
      CS.VertAlign := cvaTop
    else if S = 'middle' then
      CS.VertAlign := cvaMiddle
    else if (S = 'bottom') or (S = 'baseline') then
      CS.VertAlign := cvaBottom;
    ApplyWidthHeightAttrs(E, CS);
  end;

  S := LowerCase(E.GetAttribute('align'));
  if (S <> '') and (E.TagName <> 'img') then
  begin
    if S = 'center' then
      CS.TextAlign := ctaCenter
    else if S = 'right' then
      CS.TextAlign := ctaRight
    else if S = 'left' then
      CS.TextAlign := ctaLeft;
  end;

  S := E.GetAttribute('bgcolor');
  if (S <> '') and ParseCssColor(S, Col) then
  begin
    CS.BgColor := Col;
    CS.HasBgColor := True;
  end;
end;

// ---- TStyleResolver ----

type
  TDeclEntry = class
  public
    Prop, Value: string;
    Weight: Int64; // cascade band * 2^40 + specificity * 2^20 + order
  end;

constructor TStyleResolver.Create;
begin
  inherited Create;
  FUASheet := GetUASheet;
  FSheets := TList<TCssStyleSheet>.Create;
end;

destructor TStyleResolver.Destroy;
begin
  FSheets.Free;
  inherited Destroy;
end;

procedure TStyleResolver.ClearAuthorSheets;
begin
  FSheets.Clear;
end;

procedure TStyleResolver.AddAuthorSheet(Sheet: TCssStyleSheet);
begin
  FSheets.Add(Sheet);
end;

procedure TStyleResolver.CollectFromSheet(Sheet: TCssStyleSheet;
  E: TDOMElement; Band: Integer; var Seq: Integer; Entries: Classes.TList;
  AWantPseudo: TPseudoElem);
var
  I, J, K: Integer;
  Rule: TCssRule;
  BestSpec: Integer;
  Any: Boolean;
  Entry: TDeclEntry;
  ImpBand: Integer;
begin
  for I := 0 to Sheet.Rules.Count - 1 do
  begin
    Rule := Sheet.Rules[I];
    Any := False;
    BestSpec := 0;
    for J := 0 to Rule.Selectors.Count - 1 do
      if (Rule.Selectors[J].PseudoElement = AWantPseudo) and
         Rule.Selectors[J].Matches(E) then
      begin
        Any := True;
        if Rule.Selectors[J].Specificity > BestSpec then
          BestSpec := Rule.Selectors[J].Specificity;
      end;
    if not Any then
      Continue;
    for K := 0 to Rule.Decls.Count - 1 do
    begin
      Entry := TDeclEntry.Create;
      Entry.Prop := Rule.Decls[K].Prop;
      Entry.Value := Rule.Decls[K].Value;
      if Rule.Decls[K].Important then
      begin
        // !important: author=4, UA=5 (UA strongest per the specification)
        if Band = 0 then
          ImpBand := 5
        else
          ImpBand := 4;
        Entry.Weight := Int64(ImpBand) shl 40 + Int64(BestSpec) shl 20 + Seq;
      end
      else
        Entry.Weight := Int64(Band) shl 40 + Int64(BestSpec) shl 20 + Seq;
      Entries.Add(Entry);
      Inc(Seq);
    end;
  end;
end;

function CompareEntries(A, B: Pointer): Integer;
var
  WA, WB: Int64;
begin
  WA := TDeclEntry(A).Weight;
  WB := TDeclEntry(B).Weight;
  if WA < WB then
    Result := -1
  else if WA > WB then
    Result := 1
  else
    Result := 0;
end;

function TStyleResolver.Compute(E: TDOMElement;
  Parent: TComputedStyle): TComputedStyle;
var
  Entries: Classes.TList;
  I, Seq: Integer;
  CS: TComputedStyle;
  InlineDecls: TObjectList<TCssDecl>;
  Entry: TDeclEntry;
  ParentFS: Integer;
  StyleAttr: string;
  FontSzTmp, LhTmp, FamTmp: string;
begin
  CS := TComputedStyle.Create;
  CS.InheritFrom(Parent);
  if Parent <> nil then
    ParentFS := Parent.FontSizePx
  else
    ParentFS := 16;

  Entries := Classes.TList.Create;
  try
    Seq := 0;
    // bands: 0=UA, 2=author (1 reserved for presentational attributes,
    // applied directly below), 3=inline, 4/5=!important
    CollectFromSheet(FUASheet, E, 0, Seq, Entries);
    for I := 0 to FSheets.Count - 1 do
      if FSheets[I].Loaded then
        CollectFromSheet(FSheets[I], E, 2, Seq, Entries);

    // inline styles as band 3
    StyleAttr := E.GetAttribute('style');
    if StyleAttr <> '' then
    begin
      InlineDecls := TObjectList<TCssDecl>.Create(True);
      try
        ParseDeclarations(StyleAttr, InlineDecls);
        for I := 0 to InlineDecls.Count - 1 do
        begin
          Entry := TDeclEntry.Create;
          Entry.Prop := InlineDecls[I].Prop;
          Entry.Value := InlineDecls[I].Value;
          if InlineDecls[I].Important then
            Entry.Weight := Int64(4) shl 40 + Int64($FFFFF) shl 20 + Seq
          else
            Entry.Weight := Int64(3) shl 40 + Seq;
          Entries.Add(Entry);
          Inc(Seq);
        end;
      finally
        InlineDecls.Free;
      end;
    end;

    Entries.Sort(@CompareEntries);

    // font-size first (em units depend on it) — also the size from
    // the `font` shorthand, otherwise em dimensions would use the wrong size
    for I := 0 to Entries.Count - 1 do
      if TDeclEntry(Entries[I]).Prop = 'font-size' then
        ApplyDecl(CS, 'font-size', TDeclEntry(Entries[I]).Value, ParentFS, Parent)
      else if TDeclEntry(Entries[I]).Prop = 'font' then
        if ParseFontShorthand(TDeclEntry(Entries[I]).Value,
             FontSzTmp, LhTmp, FamTmp) and (FontSzTmp <> '') then
          ApplyDecl(CS, 'font-size', FontSzTmp, ParentFS, Parent);

    // presentational attributes — between UA and author styles.
    // We apply them before the rest; the author can override them
    ApplyPresentationalAttrs(E, CS);

    for I := 0 to Entries.Count - 1 do
      if TDeclEntry(Entries[I]).Prop <> 'font-size' then
        ApplyDecl(CS, TDeclEntry(Entries[I]).Prop,
          TDeclEntry(Entries[I]).Value, ParentFS, Parent);
  finally
    for I := 0 to Entries.Count - 1 do
      TDeclEntry(Entries[I]).Free;
    Entries.Free;
  end;

  // float forces block
  if (CS.Float_ <> cfNone) and (CS.Display in [cdInline, cdInlineBlock]) then
    CS.Display := cdBlock;

  // resolve the relative URL of the background image
  if (CS.BgImage <> '') and (E.OwnerDocument <> nil) then
    CS.BgImage := XelUrl.ResolveUrl(E.OwnerDocument.BaseUrl, CS.BgImage);

  // resolve the relative URL of the list marker (list-style-image)
  if (CS.ListImage <> '') and (E.OwnerDocument <> nil) then
    CS.ListImage := XelUrl.ResolveUrl(E.OwnerDocument.BaseUrl, CS.ListImage);

  Result := CS;
end;

function TStyleResolver.ComputePseudo(E: TDOMElement; Parent: TComputedStyle;
  Which: TPseudoElem): TComputedStyle;
var
  Entries: Classes.TList;
  I, Seq, ParentFS: Integer;
  CS: TComputedStyle;
  FontSzTmp, LhTmp, FamTmp: string;
begin
  Result := nil;
  CS := TComputedStyle.Create;
  CS.InheritFrom(Parent);   // the pseudo-element inherits from its originating element
  if Parent <> nil then ParentFS := Parent.FontSizePx else ParentFS := 16;
  Entries := Classes.TList.Create;
  try
    Seq := 0;
    for I := 0 to FSheets.Count - 1 do
      if FSheets[I].Loaded then
        CollectFromSheet(FSheets[I], E, 2, Seq, Entries, Which);
    if Entries.Count = 0 then
    begin
      CS.Free;
      Exit;
    end;
    Entries.Sort(@CompareEntries);
    for I := 0 to Entries.Count - 1 do
      if TDeclEntry(Entries[I]).Prop = 'font-size' then
        ApplyDecl(CS, 'font-size', TDeclEntry(Entries[I]).Value, ParentFS, Parent)
      else if TDeclEntry(Entries[I]).Prop = 'font' then
        if ParseFontShorthand(TDeclEntry(Entries[I]).Value,
             FontSzTmp, LhTmp, FamTmp) and (FontSzTmp <> '') then
          ApplyDecl(CS, 'font-size', FontSzTmp, ParentFS, Parent);
    for I := 0 to Entries.Count - 1 do
      if TDeclEntry(Entries[I]).Prop <> 'font-size' then
        ApplyDecl(CS, TDeclEntry(Entries[I]).Prop,
          TDeclEntry(Entries[I]).Value, ParentFS, Parent);
  finally
    for I := 0 to Entries.Count - 1 do
      TDeclEntry(Entries[I]).Free;
    Entries.Free;
  end;

  if (CS.Float_ <> cfNone) and (CS.Display in [cdInline, cdInlineBlock]) then
    CS.Display := cdBlock;
  if (CS.BgImage <> '') and (E.OwnerDocument <> nil) then
    CS.BgImage := XelUrl.ResolveUrl(E.OwnerDocument.BaseUrl, CS.BgImage);

  if CS.HasContent then
    Result := CS
  else
    CS.Free;
end;

initialization

finalization
  GUASheet.Free;
  GDefaultStyle.Free;

end.
