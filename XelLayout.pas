unit XelLayout;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Layout engine.
// Builds the box tree from the DOM + computed styles,
// then computes the geometry: CSS box model (margin/padding/border),
// blocks and inline content with line breaking, floats
// (text flows around them), auto margins (centering), widths in px and %,
// replaced elements (img) and form controls.

interface

uses
  Classes, SysUtils, Math, Graphics, Generics.Collections,
  LCLType, LCLIntf, LazUTF8, Forms,
  XelDom, XelStyle, XelCssParser;

type
  TGetImageSizeFunc = function(const Url: string;
    out W, H: Integer): Boolean of object;

  TLayoutBox = class;

  TFragKind = (fkText, fkImage, fkControl, fkBox);

  // line fragment: a word, image, control or inline-block box
  TLineFrag = class
  public
    Kind: TFragKind;
    Text: string;
    Style: TComputedStyle;  // owned by the engine
    R: TRect;               // absolute page coordinates
    Url: string;            // for images
    Href: string;           // raw href of the enclosing <a>, '' = no link
    Target: string;         // target attribute of the enclosing <a>
    Element: TDOMElement;
    Box: TLayoutBox;        // for fkBox — owned by the fragment
    Ascent: Integer;
    destructor Destroy; override;
  end;

  TLineBox = class
  public
    Frags: TObjectList<TLineFrag>;
    Y, H: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  // layout box — border-box in page coordinates
  TLayoutBox = class
  public
    Element: TDOMElement;       // nil for anonymous boxes
    Style: TComputedStyle;      // owned by the engine
    X, Y, W, H: Integer;
    Children: TObjectList<TLayoutBox>;
    Lines: TObjectList<TLineBox>;
    InlineNodes: TList<TDOMNode>; // inline content to be broken into lines
    IsAnonymous: Boolean;
    BulletText: string;         // list marker for display:list-item
    ColSpan: Integer;           // colspan of a table cell (default 1)
    RowSpan: Integer;           // rowspan of a table cell (default 1)
    constructor Create;
    destructor Destroy; override;
  end;

  TFloatInfo = record
    R: TRect;
    Side: TCssFloat;
  end;

  // result of a hit test at a page point — for the context menu, link targets etc.
  THitInfo = record
    Element: TDOMElement;  // deepest element under the point (or nil)
    LinkHref: string;      // raw href of the enclosing <a> ('' = none)
    LinkTarget: string;    // target attribute of the enclosing <a>
    ImageUrl: string;      // src of the image under the point ('' = none)
    IsControl: Boolean;    // whether there is a form control under the point
  end;

  // TLayoutEngine

  TLayoutEngine = class
  private
    FStyles: TObjectList<TComputedStyle>;     // all styles of this pass
    FStyleMap: TDictionary<Pointer, TComputedStyle>;
    FFloats: array of TFloatInfo;
    FFloatCount: Integer;
    FFontCache: TDictionary<string, string>;
    FAnchors: TDictionary<string, Integer>;   // inline anchor name -> page Y
    FGenNodes: TObjectList<TDOMNode>; // generated content text nodes (owned)
    function StyleOf(E: TDOMElement; Parent: TComputedStyle): TComputedStyle;
    function NewInheritedStyle(Parent: TComputedStyle): TComputedStyle;
    procedure AddFloat(const R: TRect; Side: TCssFloat);
    procedure GetLineBounds(Y, H, CX, CW: Integer; out LX, RX: Integer);
    function NextFloatBottom(Y: Integer): Integer;
    function ClearY(Y: Integer; Clear: TCssClear): Integer;
    function MaxFloatBottom: Integer;
    function BuildBlockBox(E: TDOMElement; ParentStyle: TComputedStyle): TLayoutBox;
    procedure BuildTableChildren(E: TDOMElement; St: TComputedStyle;
      Box: TLayoutBox);
    function BuildRowBox(E: TDOMElement; St: TComputedStyle): TLayoutBox;
    function MakeAnonBox(Parent: TComputedStyle; Disp: TCssDisplay;
      OwnerE: TDOMElement): TLayoutBox;
    function BuildCellBox(C: TDOMElement; CSt, RowSt: TComputedStyle): TLayoutBox;
    procedure LayoutBlockBox(Box: TLayoutBox; CX, CW: Integer; var Y: Integer);
    procedure LayoutTable(Box: TLayoutBox; CX, CW: Integer; var Y: Integer);
    procedure LayoutFlex(Box: TLayoutBox; CX, CW: Integer; var Y: Integer);
    procedure LayoutGrid(Box: TLayoutBox; CX, CW: Integer; var Y: Integer);
    procedure LayoutMultiCol(Box: TLayoutBox; ContentX, ContentW: Integer;
      var Y: Integer);
    procedure PlaceAbsChildren(Box: TLayoutBox;
      ContentX, ContentW, ContentTop, BottomInner: Integer);
    function MeasureCellPref(Cell: TLayoutBox): Integer;
    procedure ClearBoxLayout(Box: TLayoutBox);
    procedure PlaceFloat(Box: TLayoutBox; CX, CW, Y: Integer);
    procedure LayoutInlineContent(Box: TLayoutBox; CX, CW: Integer; var Y: Integer);
    procedure ComputeImageSize(E: TDOMElement; St: TComputedStyle; CW: Integer;
      out W, H: Integer);
    function MeasureMaxRight(Box: TLayoutBox): Integer;
    function MeasureDocWidth(Box: TLayoutBox): Integer;
    procedure OffsetBox(Box: TLayoutBox; DX, DY: Integer);
    procedure OffsetBoxContent(Box: TLayoutBox; DY: Integer);
    function ListItemMarker(E: TDOMElement; St: TComputedStyle): string;
    procedure PlaceFixedBoxes(Box: TLayoutBox);
  public
    Canvas: TCanvas;            // for measuring text
    ViewportWidth: Integer;
    ViewportHeight: Integer;    // for position:fixed (and bottom/right)
    Resolver: TStyleResolver;
    OnGetImageSize: TGetImageSizeFunc;
    Root: TLayoutBox;
    DocHeight: Integer;
    DocWidth: Integer;          // widest content - drives the H scrollbar
    ExtraFonts: TStringList;    // families loaded from @font-face (owned)

    constructor Create;
    destructor Destroy; override;

    procedure Run(Doc: TDOMDocument);
    function MapFontName(const FamilyList: string): string;
    procedure SetCanvasFont(C: TCanvas; St: TComputedStyle);

    // Returns the href of the link at page coordinates (X, Y), or ''.
    // Y is in page space (caller adds the scroll offset).
    function HitTestLink(PageX, PageY: Integer): string;

    // Full hit test at a point: element, link, image, control.
    function HitTest(PageX, PageY: Integer): THitInfo;

    // Returns the CSS cursor for the deepest box/fragment at (X, Y);
    // ccrAuto when nothing specifies one. Y is in page space.
    function CursorAt(PageX, PageY: Integer): TCssCursor;

    // Finds the layout box of the element with the given id
    // (in-page #anchor navigation). Returns nil when not found.
    function FindBoxById(const AnId: string): TLayoutBox;

    // Resolves an in-page anchor: element id (block boxes) or
    // inline <a name>/<a id> markers recorded during layout.
    function FindAnchorY(const AnId: string; out AY: Integer): Boolean;
  end;

implementation

uses
  XelUrl, XelForms;

// number of characters (UTF-8 code points) — for letter-spacing
function CountGlyphs(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if (Ord(S[I]) and $C0) <> $80 then
      Inc(Result);
end;

// text-transform on a single word (words are already split on spaces)
function ApplyTextTransform(const S: string; T: TCssTextTransform): string;
begin
  case T of
    cttUpper: Result := UTF8UpperCase(S);
    cttLower: Result := UTF8LowerCase(S);
    cttCapitalize:
      begin
        Result := S;
        if (Result <> '') and (Result[1] in ['a'..'z']) then
          Result[1] := UpCase(Result[1]);
      end;
  else
    Result := S;
  end;
end;

// Resolves percentage margins/paddings against the width of the containing
// block (CW). Idempotent — always computed from the original percentage.
procedure ResolvePctMetrics(St: TComputedStyle; CW: Integer);
begin
  if St.MarginLPct >= 0 then St.MarginL := Round(CW * St.MarginLPct / 100);
  if St.MarginTPct >= 0 then St.MarginT := Round(CW * St.MarginTPct / 100);
  if St.MarginRPct >= 0 then St.MarginR := Round(CW * St.MarginRPct / 100);
  if St.MarginBPct >= 0 then St.MarginB := Round(CW * St.MarginBPct / 100);
  if St.PadLPct >= 0 then St.PadL := Round(CW * St.PadLPct / 100);
  if St.PadTPct >= 0 then St.PadT := Round(CW * St.PadTPct / 100);
  if St.PadRPct >= 0 then St.PadR := Round(CW * St.PadRPct / 100);
  if St.PadBPct >= 0 then St.PadB := Round(CW * St.PadBPct / 100);
end;

// ---- helper classes ----

destructor TLineFrag.Destroy;
begin
  Box.Free;
  inherited Destroy;
end;

constructor TLineBox.Create;
begin
  inherited Create;
  Frags := TObjectList<TLineFrag>.Create(True);
end;

destructor TLineBox.Destroy;
begin
  Frags.Free;
  inherited Destroy;
end;

constructor TLayoutBox.Create;
begin
  inherited Create;
  Children := TObjectList<TLayoutBox>.Create(True);
  Lines := TObjectList<TLineBox>.Create(True);
  ColSpan := 1;
  RowSpan := 1;
end;

destructor TLayoutBox.Destroy;
begin
  Children.Free;
  Lines.Free;
  InlineNodes.Free;
  inherited Destroy;
end;

// ---- TLayoutEngine ----

constructor TLayoutEngine.Create;
begin
  inherited Create;
  FStyles := TObjectList<TComputedStyle>.Create(True);
  FStyleMap := TDictionary<Pointer, TComputedStyle>.Create;
  FFontCache := TDictionary<string, string>.Create;
  FAnchors := TDictionary<string, Integer>.Create;
  FGenNodes := TObjectList<TDOMNode>.Create(True);
  ExtraFonts := TStringList.Create;
  ExtraFonts.CaseSensitive := False;
end;

destructor TLayoutEngine.Destroy;
begin
  Root.Free;
  FStyleMap.Free;
  FStyles.Free;
  FFontCache.Free;
  FAnchors.Free;
  FGenNodes.Free;
  ExtraFonts.Free;
  inherited Destroy;
end;

// ---- fonts ----

function TLayoutEngine.MapFontName(const FamilyList: string): string;
var
  Parts: TStringList;
  I: Integer;
  Fam: string;

  function MapGeneric(const F: string): string;
  var
    L: string;
  begin
    L := LowerCase(F);
    if L = 'serif' then
      Result := 'Times New Roman'
    else if L = 'sans-serif' then
      Result := 'Arial'
    else if L = 'monospace' then
      Result := 'Courier New'
    else if L = 'cursive' then
      Result := 'Comic Sans MS'
    else if L = 'fantasy' then
      Result := 'Impact'
    else if L = 'system-ui' then
      Result := 'Segoe UI'
    else
      Result := '';
  end;

var
  Mapped: string;
begin
  if FFontCache.TryGetValue(FamilyList, Result) then
    Exit;

  Result := 'Times New Roman';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := FamilyList;
    for I := 0 to Parts.Count - 1 do
    begin
      Fam := Trim(Parts[I]);
      if (Fam <> '') and (Fam[1] in ['"', '''']) then
        Fam := Copy(Fam, 2, Length(Fam) - 2);
      Fam := Trim(Fam);
      if Fam = '' then
        Continue;
      Mapped := MapGeneric(Fam);
      if Mapped <> '' then
      begin
        Result := Mapped;
        Break;
      end;
      // @font-face font: use the internal name (GDI knows it under that name)
      if ExtraFonts.IndexOfName(Fam) >= 0 then
      begin
        Result := ExtraFonts.Values[Fam];
        if Result = '' then
          Result := Fam;
        Break;
      end;
      // font installed in the system
      if Screen.Fonts.IndexOf(Fam) >= 0 then
      begin
        Result := Fam;
        Break;
      end;
      // first family as a candidate in case none exists
      if I = 0 then
        Result := Fam;
    end;
  finally
    Parts.Free;
  end;
  FFontCache.Add(FamilyList, Result);
end;

procedure TLayoutEngine.SetCanvasFont(C: TCanvas; St: TComputedStyle);
var
  FS: TFontStyles;
begin
  C.Font.Name := MapFontName(St.FontFamily);
  C.Font.Height := -St.FontSizePx;
  FS := [];
  if St.Bold then
    Include(FS, fsBold);
  if St.Italic then
    Include(FS, fsItalic);
  if St.Underline then
    Include(FS, fsUnderline);
  if St.Strike then
    Include(FS, fsStrikeOut);
  C.Font.Style := FS;
end;

// ---- styles ----

function TLayoutEngine.StyleOf(E: TDOMElement;
  Parent: TComputedStyle): TComputedStyle;
begin
  if FStyleMap.TryGetValue(E, Result) then
    Exit;
  Result := Resolver.Compute(E, Parent);
  FStyles.Add(Result);
  FStyleMap.Add(E, Result);
end;

function TLayoutEngine.NewInheritedStyle(Parent: TComputedStyle): TComputedStyle;
begin
  Result := TComputedStyle.Create;
  Result.InheritFrom(Parent);
  Result.Display := cdBlock;
  FStyles.Add(Result);
end;

// ---- floats ----

procedure TLayoutEngine.AddFloat(const R: TRect; Side: TCssFloat);
begin
  if FFloatCount >= Length(FFloats) then
    SetLength(FFloats, FFloatCount + 16);
  FFloats[FFloatCount].R := R;
  FFloats[FFloatCount].Side := Side;
  Inc(FFloatCount);
end;

procedure TLayoutEngine.GetLineBounds(Y, H, CX, CW: Integer; out LX, RX: Integer);
var
  I: Integer;
begin
  LX := CX;
  RX := CX + CW;
  for I := 0 to FFloatCount - 1 do
    if (FFloats[I].R.Top < Y + H) and (FFloats[I].R.Bottom > Y) then
    begin
      if FFloats[I].Side = cfLeft then
        LX := Max(LX, FFloats[I].R.Right)
      else
        RX := Min(RX, FFloats[I].R.Left);
    end;
end;

function TLayoutEngine.NextFloatBottom(Y: Integer): Integer;
var
  I, B: Integer;
begin
  Result := Y;
  B := MaxInt;
  for I := 0 to FFloatCount - 1 do
    if FFloats[I].R.Bottom > Y then
      B := Min(B, FFloats[I].R.Bottom);
  if B <> MaxInt then
    Result := B;
end;

function TLayoutEngine.ClearY(Y: Integer; Clear: TCssClear): Integer;
var
  I: Integer;
begin
  Result := Y;
  for I := 0 to FFloatCount - 1 do
    case Clear of
      ccLeft:
        if FFloats[I].Side = cfLeft then
          Result := Max(Result, FFloats[I].R.Bottom);
      ccRight:
        if FFloats[I].Side = cfRight then
          Result := Max(Result, FFloats[I].R.Bottom);
      ccBoth:
        Result := Max(Result, FFloats[I].R.Bottom);
    end;
end;

function TLayoutEngine.MaxFloatBottom: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FFloatCount - 1 do
    Result := Max(Result, FFloats[I].R.Bottom);
end;

// ---- building the box tree ----

function IsWhitespaceText(Node: TDOMNode): Boolean;
begin
  Result := (Node.NodeType = ntText) and (Trim(Node.NodeValue) = '');
end;

function TLayoutEngine.ListItemMarker(E: TDOMElement;
  St: TComputedStyle): string;
var
  N: Integer;
  Sib: TDOMNode;
begin
  case St.ListType of
    cltNone: Result := '';
    cltDecimal:
      begin
        N := 1;
        Sib := E.PreviousSibling;
        while Sib <> nil do
        begin
          if (Sib is TDOMElement) and (TDOMElement(Sib).TagName = 'li') then
            Inc(N);
          Sib := Sib.PreviousSibling;
        end;
        Result := IntToStr(N) + '.';
      end;
    cltCircle: Result := #$E2#$97#$A6;  // ◦
    cltSquare: Result := #$E2#$96#$AA;  // ▪
  else
    Result := #$E2#$80#$A2;             // •
  end;
end;

function TLayoutEngine.BuildBlockBox(E: TDOMElement;
  ParentStyle: TComputedStyle): TLayoutBox;
var
  St, ChildSt, BeforeSt, AfterSt: TComputedStyle;
  Box, Anon, ChildBox: TLayoutBox;
  I: Integer;
  Node: TDOMNode;
  HasBlockChild, HasGenBlock: Boolean;
  Run: TList<TDOMNode>;

  function IsBlockDisp(D: TCssDisplay): Boolean;
  begin
    Result := D in [cdBlock, cdListItem, cdTable, cdFlex, cdGrid];
  end;

  // creates a generated content box from the given pseudo-element style
  function MakeGenBox(PSt: TComputedStyle): TLayoutBox;
  var Txt: TDOMText;
  begin
    Result := TLayoutBox.Create;
    // NOT anonymous — the pseudo-element must paint its background/borders
    Result.Element := E;
    Result.Style := PSt;
    if PSt.Content <> '' then
    begin
      Txt := TDOMText.Create(E.OwnerDocument, PSt.Content);
      FGenNodes.Add(Txt);
      Result.InlineNodes := TList<TDOMNode>.Create;
      Result.InlineNodes.Add(Txt);
    end;
  end;

  procedure FlushRun;
  var
    J: Integer;
    OnlyWs: Boolean;
  begin
    if Run.Count = 0 then
      Exit;
    OnlyWs := True;
    for J := 0 to Run.Count - 1 do
      if not IsWhitespaceText(Run[J]) then
      begin
        OnlyWs := False;
        Break;
      end;
    if not OnlyWs then
    begin
      Anon := TLayoutBox.Create;
      Anon.IsAnonymous := True;
      Anon.Element := E;
      Anon.Style := NewInheritedStyle(St);
      Anon.InlineNodes := TList<TDOMNode>.Create;
      for J := 0 to Run.Count - 1 do
        Anon.InlineNodes.Add(Run[J]);
      Box.Children.Add(Anon);
    end;
    Run.Clear;
  end;

begin
  St := StyleOf(E, ParentStyle);
  Box := TLayoutBox.Create;
  Box.Element := E;
  Box.Style := St;
  if St.Display = cdListItem then
    Box.BulletText := ListItemMarker(E, St);
  Result := Box;

  // tables get a dedicated structure: rows -> cells
  if St.Display = cdTable then
  begin
    BuildTableChildren(E, St, Box);
    Exit;
  end;

  // generated content ::before / ::after
  BeforeSt := nil; AfterSt := nil;
  if Resolver <> nil then
  begin
    BeforeSt := Resolver.ComputePseudo(E, St, peBefore);
    if BeforeSt <> nil then FStyles.Add(BeforeSt);
    AfterSt := Resolver.ComputePseudo(E, St, peAfter);
    if AfterSt <> nil then FStyles.Add(AfterSt);
  end;
  HasGenBlock := ((BeforeSt <> nil) and IsBlockDisp(BeforeSt.Display)) or
                 ((AfterSt <> nil) and IsBlockDisp(AfterSt.Display));

  // are there block children?
  HasBlockChild := HasGenBlock;
  if not HasBlockChild then
    for I := 0 to E.ChildCount - 1 do
      if E.Children[I] is TDOMElement then
      begin
        ChildSt := StyleOf(TDOMElement(E.Children[I]), St);
        if ChildSt.Display in [cdBlock, cdListItem, cdTable, cdFlex, cdGrid] then
        begin
          HasBlockChild := True;
          Break;
        end;
      end;

  if not HasBlockChild then
  begin
    Box.InlineNodes := TList<TDOMNode>.Create;
    // inline ::before with text
    if (BeforeSt <> nil) and (BeforeSt.Content <> '') then
    begin
      Node := TDOMText.Create(E.OwnerDocument, BeforeSt.Content);
      FGenNodes.Add(Node);
      Box.InlineNodes.Add(Node);
    end;
    for I := 0 to E.ChildCount - 1 do
    begin
      Node := E.Children[I];
      if Node.NodeType = ntComment then
        Continue;
      if (Node is TDOMElement) and
         (StyleOf(TDOMElement(Node), St).Display = cdNone) then
        Continue;
      Box.InlineNodes.Add(Node);
    end;
    // inline ::after with text
    if (AfterSt <> nil) and (AfterSt.Content <> '') then
    begin
      Node := TDOMText.Create(E.OwnerDocument, AfterSt.Content);
      FGenNodes.Add(Node);
      Box.InlineNodes.Add(Node);
    end;
    Exit;
  end;

  // block context: runs of inline content -> anonymous boxes
  Run := TList<TDOMNode>.Create;
  try
    if BeforeSt <> nil then
      Box.Children.Add(MakeGenBox(BeforeSt));
    for I := 0 to E.ChildCount - 1 do
    begin
      Node := E.Children[I];
      if Node.NodeType = ntComment then
        Continue;
      if Node is TDOMElement then
      begin
        ChildSt := StyleOf(TDOMElement(Node), St);
        if ChildSt.Display = cdNone then
          Continue;
        if ChildSt.Display in [cdBlock, cdListItem, cdTable, cdFlex, cdGrid] then
        begin
          FlushRun;
          ChildBox := BuildBlockBox(TDOMElement(Node), St);
          Box.Children.Add(ChildBox);
          Continue;
        end;
      end
      else if IsWhitespaceText(Node) then
        Continue; // whitespace between blocks — skipped
      Run.Add(Node);
    end;
    FlushRun;
    if AfterSt <> nil then
      Box.Children.Add(MakeGenBox(AfterSt));
  finally
    Run.Free;
  end;
end;

// ---- table structure ----

// Collects rows (directly or inside thead/tbody/tfoot) and other
// block children (caption) of a table element.
// Whether the element is a table cell (display:table-cell or td/th)?
function IsCellElem(C: TDOMElement; CSt: TComputedStyle): Boolean;
begin
  Result := (CSt.Display = cdTableCell) or (C.TagName = 'td') or (C.TagName = 'th');
end;

// Creates an anonymous box with the given display, inheriting the style.
function TLayoutEngine.MakeAnonBox(Parent: TComputedStyle;
  Disp: TCssDisplay; OwnerE: TDOMElement): TLayoutBox;
begin
  Result := TLayoutBox.Create;
  Result.IsAnonymous := True;
  Result.Element := OwnerE;
  Result.Style := NewInheritedStyle(Parent);
  Result.Style.Display := Disp;
end;

// Builds a cell box: a real cell -> directly; another element ->
// wrapped in an anonymous cell (CSS anonymous table cell).
function TLayoutEngine.BuildCellBox(C: TDOMElement; CSt, RowSt: TComputedStyle): TLayoutBox;
begin
  if IsCellElem(C, CSt) then
  begin
    Result := BuildBlockBox(C, RowSt);
    Result.ColSpan := Max(1, StrToIntDef(C.GetAttribute('colspan'), 1));
    Result.RowSpan := Max(1, StrToIntDef(C.GetAttribute('rowspan'), 1));
  end
  else
  begin
    Result := MakeAnonBox(RowSt, cdTableCell, C);
    Result.Children.Add(BuildBlockBox(C, Result.Style));
  end;
end;

procedure TLayoutEngine.BuildTableChildren(E: TDOMElement;
  St: TComputedStyle; Box: TLayoutBox);
var
  I: Integer;
  Node: TDOMNode;
  C: TDOMElement;
  CSt: TComputedStyle;
  AnonRow: TLayoutBox;

  procedure FlushAnonRow;
  begin
    if (AnonRow <> nil) and (AnonRow.Children.Count > 0) then
    begin
      Box.Children.Add(AnonRow);
      AnonRow := nil;
    end
    else
      FreeAndNil(AnonRow);
  end;

  procedure AddCellToAnonRow(C: TDOMElement; CSt: TComputedStyle);
  begin
    if AnonRow = nil then
      AnonRow := MakeAnonBox(St, cdTableRow, E);
    AnonRow.Children.Add(BuildCellBox(C, CSt, AnonRow.Style));
  end;

  procedure AddRowsFrom(Parent: TDOMElement; ParentSt: TComputedStyle);
  var
    J: Integer;
    R: TDOMElement;
    RSt: TComputedStyle;
  begin
    for J := 0 to Parent.ChildCount - 1 do
      if Parent.Children[J] is TDOMElement then
      begin
        R := TDOMElement(Parent.Children[J]);
        RSt := StyleOf(R, ParentSt);
        if RSt.Display = cdNone then Continue;
        if RSt.Display = cdTableRow then
          Box.Children.Add(BuildRowBox(R, RSt))
        else
          // cell/content without a row -> anonymous row
          AddCellToAnonRow(R, RSt);
      end;
  end;

begin
  AnonRow := nil;
  for I := 0 to E.ChildCount - 1 do
  begin
    Node := E.Children[I];
    if not (Node is TDOMElement) then
      Continue;
    C := TDOMElement(Node);
    CSt := StyleOf(C, St);
    if CSt.Display = cdNone then
      Continue;
    if CSt.Display = cdTableRow then
    begin
      FlushAnonRow;
      Box.Children.Add(BuildRowBox(C, CSt));
    end
    else if (C.TagName = 'thead') or (C.TagName = 'tbody') or
            (C.TagName = 'tfoot') then
    begin
      FlushAnonRow;
      AddRowsFrom(C, St);
    end
    else if IsCellElem(C, CSt) or (E.TagName <> 'table') then
      // a cell or any element in display:table -> anonymous row/cell
      AddCellToAnonRow(C, CSt)
    else
    begin
      // <table>: caption/content — a plain block above the rows
      FlushAnonRow;
      Box.Children.Add(BuildBlockBox(C, St));
    end;
  end;
  FlushAnonRow;
end;

function TLayoutEngine.BuildRowBox(E: TDOMElement;
  St: TComputedStyle): TLayoutBox;
var
  I: Integer;
  C: TDOMElement;
  CSt: TComputedStyle;
begin
  Result := TLayoutBox.Create;
  Result.Element := E;
  Result.Style := St;
  for I := 0 to E.ChildCount - 1 do
    if E.Children[I] is TDOMElement then
    begin
      C := TDOMElement(E.Children[I]);
      CSt := StyleOf(C, St);
      if CSt.Display = cdNone then
        Continue;
      // cells directly; other elements wrapped in anonymous cells
      Result.Children.Add(BuildCellBox(C, CSt, St));
    end;
end;

// ---- images ----

procedure TLayoutEngine.ComputeImageSize(E: TDOMElement; St: TComputedStyle;
  CW: Integer; out W, H: Integer);
var
  NW, NH, MaxW: Integer;
  HasNatural, HeightExplicit: Boolean;
  Url: string;
begin
  NW := 0;
  NH := 0;
  HasNatural := False;
  HeightExplicit := St.HeightPx >= 0;
  if (E <> nil) and Assigned(OnGetImageSize) then
  begin
    Url := ResolveUrl(E.OwnerDocument.BaseUrl, E.GetAttribute('src'));
    HasNatural := OnGetImageSize(Url, NW, NH) and (NW > 0) and (NH > 0);
  end;

  W := -1;
  H := -1;
  if St.WidthPx >= 0 then
    W := St.WidthPx
  else if St.WidthPct >= 0 then
    W := Round(CW * St.WidthPct / 100);
  if St.HeightPx >= 0 then
    H := St.HeightPx;

  if (W < 0) and (H < 0) then
  begin
    if HasNatural then
    begin
      W := NW;
      H := NH;
    end
    else
    begin
      W := 24;
      H := 24;
    end;
  end
  else if W < 0 then
  begin
    if HasNatural then
      W := MulDiv(H, NW, NH)
    else
      W := H;
  end
  else if H < 0 then
  begin
    if HasNatural then
      H := MulDiv(W, NH, NW)
    else
      H := W;
  end;

  MaxW := -1;
  if St.MaxWidthPx >= 0 then
    MaxW := St.MaxWidthPx
  else if St.MaxWidthPct >= 0 then
    MaxW := Round(CW * St.MaxWidthPct / 100);
  if (MaxW >= 0) and (W > MaxW) then
  begin
    if not HeightExplicit then
      H := MulDiv(H, MaxW, W);
    W := MaxW;
  end;
  if (St.MinWidthPx >= 0) and (W < St.MinWidthPx) then
  begin
    if not HeightExplicit and (W > 0) then
      H := MulDiv(H, St.MinWidthPx, W);
    W := St.MinWidthPx;
  end;
  if (St.MinHeightPx >= 0) and (H < St.MinHeightPx) then
  begin
    if (St.WidthPx < 0) and (St.WidthPct < 0) then
      W := MulDiv(W, St.MinHeightPx, H);
    H := St.MinHeightPx;
  end;
  if (St.MaxHeightPx >= 0) and (H > St.MaxHeightPx) then
  begin
    if (St.WidthPx < 0) and (St.WidthPct < 0) then
      W := MulDiv(W, St.MaxHeightPx, H);
    H := St.MaxHeightPx;
  end;
  W := Max(1, W);
  H := Max(1, H);
end;

// ---- geometry ----

procedure TLayoutEngine.OffsetBox(Box: TLayoutBox; DX, DY: Integer);
var
  I, J: Integer;
  Line: TLineBox;
  Frag: TLineFrag;
begin
  Inc(Box.X, DX);
  Inc(Box.Y, DY);
  for I := 0 to Box.Children.Count - 1 do
    OffsetBox(Box.Children[I], DX, DY);
  for I := 0 to Box.Lines.Count - 1 do
  begin
    Line := Box.Lines[I];
    Inc(Line.Y, DY);
    for J := 0 to Line.Frags.Count - 1 do
    begin
      Frag := Line.Frags[J];
      OffsetRect(Frag.R, DX, DY);
      if Frag.Box <> nil then
        OffsetBox(Frag.Box, DX, DY);
    end;
  end;
end;

function TLayoutEngine.MeasureMaxRight(Box: TLayoutBox): Integer;
var
  I, J: Integer;
begin
  Result := Box.X;
  for I := 0 to Box.Children.Count - 1 do
    Result := Max(Result, MeasureMaxRight(Box.Children[I]));
  for I := 0 to Box.Lines.Count - 1 do
    for J := 0 to Box.Lines[I].Frags.Count - 1 do
      Result := Max(Result, Box.Lines[I].Frags[J].R.Right);
end;

// unlike MeasureMaxRight this includes the border boxes themselves -
// used to size the horizontal scrollbar
function TLayoutEngine.MeasureDocWidth(Box: TLayoutBox): Integer;
var
  I, J: Integer;
  Frag: TLineFrag;
begin
  Result := Box.X + Box.W;
  for I := 0 to Box.Children.Count - 1 do
    Result := Max(Result, MeasureDocWidth(Box.Children[I]));
  for I := 0 to Box.Lines.Count - 1 do
    for J := 0 to Box.Lines[I].Frags.Count - 1 do
    begin
      Frag := Box.Lines[I].Frags[J];
      Result := Max(Result, Frag.R.Right);
      if Frag.Box <> nil then
        Result := Max(Result, MeasureDocWidth(Frag.Box));
    end;
end;

// shifts the content of a box down without moving the box itself -
// used for vertical alignment inside stretched table cells
procedure TLayoutEngine.OffsetBoxContent(Box: TLayoutBox; DY: Integer);
var
  I, J: Integer;
  Line: TLineBox;
  Frag: TLineFrag;
begin
  for I := 0 to Box.Children.Count - 1 do
    OffsetBox(Box.Children[I], 0, DY);
  for I := 0 to Box.Lines.Count - 1 do
  begin
    Line := Box.Lines[I];
    Inc(Line.Y, DY);
    for J := 0 to Line.Frags.Count - 1 do
    begin
      Frag := Line.Frags[J];
      OffsetRect(Frag.R, 0, DY);
      if Frag.Box <> nil then
        OffsetBox(Frag.Box, 0, DY);
    end;
  end;
end;

// ---- block layout ----

procedure TLayoutEngine.LayoutBlockBox(Box: TLayoutBox; CX, CW: Integer;
  var Y: Integer);
var
  St: TComputedStyle;
  ML, MR, MT, MB: Integer;
  ContentW, BBW, ContentX, InnerY, StartInnerY, ContentH, MaxW, MinW: Integer;
  I, PrevMB, TmpY, AbsX, AbsY, FlowBottom, SavedFloats: Integer;
  BfcLX, BfcRX: Integer;
  Child: TLayoutBox;
  ImgW, ImgH: Integer;
  IsImg, HasSpecifiedWidth, MaxWidthApplied: Boolean;
begin
  St := Box.Style;

  // tables / flex / grid have their own layout algorithms
  if St.Display = cdTable then
  begin
    LayoutTable(Box, CX, CW, Y);
    Exit;
  end;
  if St.Display = cdFlex then
  begin
    LayoutFlex(Box, CX, CW, Y);
    Exit;
  end;
  if St.Display = cdGrid then
  begin
    LayoutGrid(Box, CX, CW, Y);
    Exit;
  end;

  ResolvePctMetrics(St, CW);
  ML := St.MarginL;
  MR := St.MarginR;
  MT := St.MarginT;
  MB := St.MarginB;

  // clear — move below the floats (before determining the BFC band)
  if St.Clear_ <> ccNone then
    Y := ClearY(Y, St.Clear_);

  // A block that establishes a formatting context (overflow<>visible) does NOT overlap
  // floats — it narrows to the band next to the float. This way e.g. the border-bottom
  // of the .mw-heading2 heading ends at the infobox (float:right) instead of running
  // across the full width. Only when the width is auto and the float actually intrudes.
  if ((St.OverflowX <> coVisible) or (St.OverflowY <> coVisible)) and
     (St.Float_ = cfNone) and (St.Position <> cpAbsolute) and
     (St.WidthPx < 0) and (St.WidthPct < 0) and
     (not ((Box.Element <> nil) and (Box.Element.TagName = 'img'))) then
  begin
    GetLineBounds(Y + MT, 1, CX, CW, BfcLX, BfcRX);
    if BfcRX - BfcLX < CW then
    begin
      CX := BfcLX;
      CW := Max(0, BfcRX - BfcLX);
    end;
  end;

  IsImg := (Box.Element <> nil) and (Box.Element.TagName = 'img');
  HasSpecifiedWidth := (St.WidthPx >= 0) or (St.WidthPct >= 0);
  MaxWidthApplied := False;

  // content width
  if IsImg then
  begin
    ComputeImageSize(Box.Element, St, CW, ImgW, ImgH);
    ContentW := ImgW;
  end
  else if St.WidthPx >= 0 then
  begin
    ContentW := St.WidthPx;
    if St.BoxSizing = cbsBorderBox then
      Dec(ContentW, St.PadL + St.PadR + St.BordL + St.BordR);
    ContentW := Max(0, ContentW);
  end
  else if St.WidthPct >= 0 then
  begin
    ContentW := Max(0, Round(CW * St.WidthPct / 100));
    if St.BoxSizing = cbsBorderBox then
      Dec(ContentW, St.PadL + St.PadR + St.BordL + St.BordR);
    ContentW := Max(0, ContentW);
  end
  else
    ContentW := Max(0, CW - ML - MR - St.PadL - St.PadR - St.BordL - St.BordR);

  if not IsImg then
  begin
    MaxW := -1;
    if St.MaxWidthPx >= 0 then
      MaxW := St.MaxWidthPx
    else if St.MaxWidthPct >= 0 then
      MaxW := Round(CW * St.MaxWidthPct / 100);
    if MaxW >= 0 then
    begin
      if St.BoxSizing = cbsBorderBox then
        Dec(MaxW, St.PadL + St.PadR + St.BordL + St.BordR);
      MaxW := Max(0, MaxW);
      if ContentW > MaxW then
      begin
        ContentW := MaxW;
        MaxWidthApplied := True;
      end;
    end;

    // min-width — takes precedence over max-width
    MinW := -1;
    if St.MinWidthPx >= 0 then
      MinW := St.MinWidthPx
    else if St.MinWidthPct >= 0 then
      MinW := Round(CW * St.MinWidthPct / 100);
    if MinW >= 0 then
    begin
      if St.BoxSizing = cbsBorderBox then
        Dec(MinW, St.PadL + St.PadR + St.BordL + St.BordR);
      MinW := Max(0, MinW);
      if ContentW < MinW then
      begin
        ContentW := MinW;
        MaxWidthApplied := True; // treat as an explicit width when centering
      end;
    end;
  end;

  BBW := ContentW + St.PadL + St.PadR + St.BordL + St.BordR;

  // margin:auto — centering
  if (HasSpecifiedWidth or MaxWidthApplied or IsImg) and
     St.MarginLAuto and St.MarginRAuto then
  begin
    ML := Max(0, (CW - BBW) div 2);
    MR := ML;
  end;

  Box.X := CX + ML;
  Box.Y := Y + MT;
  Box.W := BBW;

  ContentX := Box.X + St.BordL + St.PadL;
  InnerY := Box.Y + St.BordT + St.PadT;
  StartInnerY := InnerY;

  if IsImg then
    ContentH := ImgH
  else if Box.InlineNodes <> nil then
  begin
    LayoutInlineContent(Box, ContentX, ContentW, InnerY);
    ContentH := InnerY - StartInnerY;
  end
  else if ((St.ColumnCount > 0) or (St.ColumnWidthPx > 0)) and
          (Box.Children.Count >= 1) then
  begin
    LayoutMultiCol(Box, ContentX, ContentW, InnerY);
    ContentH := InnerY - StartInnerY;
  end
  else
  begin
    PrevMB := -1;
    for I := 0 to Box.Children.Count - 1 do
    begin
      Child := Box.Children[I];
      if Child.Style.Position in [cpAbsolute, cpFixed] then
        Continue;
      if Child.Style.Float_ <> cfNone then
        PlaceFloat(Child, ContentX, ContentW, InnerY)
      else
      begin
        // collapse adjacent vertical margins: use max instead of sum
        if PrevMB >= 0 then
          Dec(InnerY, Min(PrevMB, Child.Style.MarginT));
        LayoutBlockBox(Child, ContentX, ContentW, InnerY);
        PrevMB := Child.Style.MarginB;
      end;
    end;
    ContentH := InnerY - StartInnerY;
  end;

  if St.HeightPx >= 0 then
    ContentH := St.HeightPx;
  if St.MinHeightPx >= 0 then
    ContentH := Max(ContentH, St.MinHeightPx);
  if St.MaxHeightPx >= 0 then
    ContentH := Min(ContentH, St.MaxHeightPx);

  Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
  FlowBottom := Box.Y + Box.H + MB;

  PlaceAbsChildren(Box, ContentX, ContentW, StartInnerY,
    Box.Y + Box.H - St.BordB - St.PadB);

  if St.Position = cpRelative then
  begin
    AbsX := 0;
    AbsY := 0;
    if St.PosLeft <> Low(Integer) then
      AbsX := St.PosLeft
    else if St.PosRight <> Low(Integer) then
      AbsX := -St.PosRight;
    if St.PosTop <> Low(Integer) then
      AbsY := St.PosTop
    else if St.PosBottom <> Low(Integer) then
      AbsY := -St.PosBottom;
    if (AbsX <> 0) or (AbsY <> 0) then
      OffsetBox(Box, AbsX, AbsY);
  end;

  Y := FlowBottom;
end;

// ---- table layout ----
//
// Simplified automatic algorithm:
// 1. measure each cell's preferred width (content laid out unconstrained),
// 2. column width = max preferred width of its cells (colspan cells
//    distribute any deficit equally over the spanned columns),
// 3. columns are scaled down when they exceed the available width and
//    stretched proportionally when the table has an explicit width,
// 4. each row's height = the tallest cell; cells are stretched to it.

procedure TLayoutEngine.ClearBoxLayout(Box: TLayoutBox);
var
  I: Integer;
begin
  Box.Lines.Clear; // frees fragments and their inline-block boxes
  for I := 0 to Box.Children.Count - 1 do
    ClearBoxLayout(Box.Children[I]);
end;

function TLayoutEngine.MeasureCellPref(Cell: TLayoutBox): Integer;
var
  SavedFloats, TmpY: Integer;
  St: TComputedStyle;
  SavedTA: TCssTextAlign;
begin
  St := Cell.Style;
  if St.WidthPx >= 0 then
    Exit(St.WidthPx + St.PadL + St.PadR + St.BordL + St.BordR);

  // lay the cell out with effectively unlimited width, measure the
  // widest content, then discard that throwaway layout. Left alignment
  // during the measurement — otherwise text-align:center (e.g. navbox-group) inflates
  // max-content to half of the measurement width.
  SavedFloats := FFloatCount;
  SavedTA := Cell.Style.TextAlign;
  Cell.Style.TextAlign := ctaLeft;
  TmpY := 0;
  LayoutBlockBox(Cell, 0, 8000, TmpY);
  Result := MeasureMaxRight(Cell) - Cell.X + St.PadR + St.BordR;
  Cell.Style.TextAlign := SavedTA;
  FFloatCount := SavedFloats;
  ClearBoxLayout(Cell);
  if Result < 16 then
    Result := 16;
end;

procedure TLayoutEngine.LayoutTable(Box: TLayoutBox; CX, CW: Integer;
  var Y: Integer);
type
  TGridCell = record
    Cell: TLayoutBox;
    Row, Col, CSpan, RSpan: Integer;
    NaturalH: Integer;
  end;
var
  St: TComputedStyle;
  Rows: TList<TLayoutBox>;
  Others: TList<TLayoutBox>;
  Child, Cell, Row: TLayoutBox;
  Grid: array of TGridCell;
  NGrid: Integer;
  Blocked: array of Integer; // per column: last row index taken by a rowspan
  I, J, C, R, K, NCols, Span: Integer;
  ColPref, ColW, RowHs, RowYPos, ColX: array of Integer;
  Spacing, SpacingV, SumPref, AvailInner, UsedInner, Extra, Deficit, SpanSum: Integer;
  SpecW, ContentW, ContentH: Integer;
  ML, MR, MT, MB: Integer;
  ContentX, InnerY, RowY, W, DX, DY, FinalH, SavedFloats, TmpY: Integer;
begin
  St := Box.Style;
  ResolvePctMetrics(St, CW);
  ML := St.MarginL;
  MR := St.MarginR;
  MT := St.MarginT;
  MB := St.MarginB;

  if St.Clear_ <> ccNone then
    Y := ClearY(Y, St.Clear_);

  // cell spacing: border-collapse -> 0, otherwise border-spacing (H/V);
  // the cellspacing attribute (HTML) overrides both axes if given
  if St.BorderCollapse then
  begin
    Spacing := 0;
    SpacingV := 0;
  end
  else
  begin
    Spacing := St.BorderSpacingH;
    SpacingV := St.BorderSpacingV;
  end;
  if (Box.Element <> nil) and (Box.Element.GetAttribute('cellspacing') <> '') then
  begin
    Spacing := Max(0, StrToIntDef(Box.Element.GetAttribute('cellspacing'), Spacing));
    SpacingV := Spacing;
  end;

  Rows := TList<TLayoutBox>.Create;
  Others := TList<TLayoutBox>.Create;
  try
    for I := 0 to Box.Children.Count - 1 do
    begin
      Child := Box.Children[I];
      if Child.Style.Display = cdTableRow then
        Rows.Add(Child)
      else
        Others.Add(Child);
    end;

    // build the occupancy grid: assigns every cell its (row, col) slot,
    // honouring colspan and rowspan from previous rows
    NGrid := 0;
    for I := 0 to Rows.Count - 1 do
      Inc(NGrid, Rows[I].Children.Count);
    SetLength(Grid, NGrid);
    NGrid := 0;
    SetLength(Blocked, 8);
    for K := 0 to High(Blocked) do
      Blocked[K] := -1;
    NCols := 0;
    for R := 0 to Rows.Count - 1 do
    begin
      C := 0;
      for J := 0 to Rows[R].Children.Count - 1 do
      begin
        Cell := Rows[R].Children[J];
        // skip slots still occupied by rowspans from rows above
        while True do
        begin
          if C >= Length(Blocked) then
          begin
            K := Length(Blocked);
            SetLength(Blocked, C + 8);
            while K < Length(Blocked) do
            begin
              Blocked[K] := -1;
              Inc(K);
            end;
          end;
          if Blocked[C] >= R then
            Inc(C)
          else
            Break;
        end;
        Span := Max(1, Cell.ColSpan);
        Grid[NGrid].Cell := Cell;
        Grid[NGrid].Row := R;
        Grid[NGrid].Col := C;
        Grid[NGrid].CSpan := Span;
        Grid[NGrid].RSpan := Max(1, Min(Cell.RowSpan, Rows.Count - R));
        if C + Span > Length(Blocked) then
        begin
          K := Length(Blocked);
          SetLength(Blocked, C + Span + 8);
          while K < Length(Blocked) do
          begin
            Blocked[K] := -1;
            Inc(K);
          end;
        end;
        for K := C to C + Span - 1 do
          Blocked[K] := R + Grid[NGrid].RSpan - 1;
        Inc(NGrid);
        Inc(C, Span);
        NCols := Max(NCols, C);
      end;
    end;

    // explicit width?
    SpecW := -1;
    if St.WidthPx >= 0 then
      SpecW := St.WidthPx
    else if St.WidthPct >= 0 then
      SpecW := Round((CW - ML - MR) * St.WidthPct / 100) -
        St.PadL - St.PadR - St.BordL - St.BordR;

    if NCols = 0 then
    begin
      // no rows - behaves like a plain block with the caption content
      ContentW := Max(0, CW - ML - MR - St.PadL - St.PadR -
        St.BordL - St.BordR);
      if SpecW >= 0 then
        ContentW := SpecW;
      Box.X := CX + ML;
      Box.Y := Y + MT;
      Box.W := ContentW + St.PadL + St.PadR + St.BordL + St.BordR;
      ContentX := Box.X + St.BordL + St.PadL;
      InnerY := Box.Y + St.BordT + St.PadT;
      RowY := InnerY;
      for I := 0 to Others.Count - 1 do
        LayoutBlockBox(Others[I], ContentX, ContentW, RowY);
      ContentH := RowY - InnerY;
      if St.HeightPx >= 0 then
        ContentH := Max(ContentH, St.HeightPx);
      Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
      Y := Box.Y + Box.H + MB;
      Exit;
    end;

    // preferred column widths
    SetLength(ColPref, NCols);
    for I := 0 to NCols - 1 do
      ColPref[I] := 16;
    for I := 0 to NGrid - 1 do
      if Grid[I].CSpan = 1 then
        ColPref[Grid[I].Col] :=
          Max(ColPref[Grid[I].Col], MeasureCellPref(Grid[I].Cell));
    // second pass: colspan cells enlarge spanned columns if needed
    for I := 0 to NGrid - 1 do
      if Grid[I].CSpan > 1 then
      begin
        Deficit := MeasureCellPref(Grid[I].Cell) -
          (Grid[I].CSpan - 1) * Spacing;
        SpanSum := 0;
        for K := Grid[I].Col to Grid[I].Col + Grid[I].CSpan - 1 do
        begin
          Dec(Deficit, ColPref[K]);
          Inc(SpanSum, ColPref[K]);
        end;
        if Deficit > 0 then
        begin
          // distribute the surplus proportionally to the existing widths,
          // so that a wide column (e.g. a navbox list) absorbs most of it,
          // and a narrow one (group label) does not swell to half the width
          if SpanSum > 0 then
            for K := Grid[I].Col to Grid[I].Col + Grid[I].CSpan - 1 do
              Inc(ColPref[K], MulDiv(Deficit, ColPref[K], SpanSum))
          else
            for K := Grid[I].Col to Grid[I].Col + Grid[I].CSpan - 1 do
              Inc(ColPref[K], Deficit div Grid[I].CSpan);
        end;
      end;

    SumPref := 0;
    for I := 0 to NCols - 1 do
      Inc(SumPref, ColPref[I]);

    if SpecW >= 0 then
      AvailInner := SpecW - Spacing * (NCols + 1)
    else
      AvailInner := CW - ML - MR - St.PadL - St.PadR - St.BordL -
        St.BordR - Spacing * (NCols + 1);

    SetLength(ColW, NCols);
    if SumPref > AvailInner then
    begin
      // too wide - scale columns down proportionally
      for I := 0 to NCols - 1 do
        ColW[I] := Max(16, MulDiv(ColPref[I], AvailInner, Max(1, SumPref)));
    end
    else if SpecW >= 0 then
    begin
      // explicit width - stretch columns proportionally
      Extra := AvailInner - SumPref;
      for I := 0 to NCols - 1 do
        ColW[I] := ColPref[I] + MulDiv(Extra, ColPref[I], Max(1, SumPref));
    end
    else
      // auto width - shrink to fit the content
      for I := 0 to NCols - 1 do
        ColW[I] := ColPref[I];

    UsedInner := Spacing * (NCols + 1);
    for I := 0 to NCols - 1 do
      Inc(UsedInner, ColW[I]);

    ContentW := UsedInner;
    Box.W := ContentW + St.PadL + St.PadR + St.BordL + St.BordR;

    // margin:auto centers the table
    if St.MarginLAuto and St.MarginRAuto then
    begin
      ML := Max(0, (CW - Box.W) div 2);
      MR := ML;
    end;

    Box.X := CX + ML;
    Box.Y := Y + MT;
    ContentX := Box.X + St.BordL + St.PadL;
    InnerY := Box.Y + St.BordT + St.PadT;
    RowY := InnerY;

    // captions and other non-row content go above the grid
    for I := 0 to Others.Count - 1 do
      LayoutBlockBox(Others[I], ContentX, ContentW, RowY);

    // column x positions
    SetLength(ColX, NCols);
    W := ContentX + Spacing;
    for I := 0 to NCols - 1 do
    begin
      ColX[I] := W;
      Inc(W, ColW[I] + Spacing);
    end;

    // lay out every cell at a temporary origin to learn its natural
    // height; floats inside a cell stay internal to that cell
    for I := 0 to NGrid - 1 do
    begin
      W := (Grid[I].CSpan - 1) * Spacing;
      for K := Grid[I].Col to Grid[I].Col + Grid[I].CSpan - 1 do
        Inc(W, ColW[K]);
      SavedFloats := FFloatCount;
      TmpY := 0;
      LayoutBlockBox(Grid[I].Cell, 0, W, TmpY);
      FFloatCount := SavedFloats;
      Grid[I].NaturalH := Grid[I].Cell.H;
    end;

    // row heights from single-row cells...
    SetLength(RowHs, Rows.Count);
    for R := 0 to Rows.Count - 1 do
      RowHs[R] := 0;
    for I := 0 to NGrid - 1 do
      if Grid[I].RSpan = 1 then
        RowHs[Grid[I].Row] := Max(RowHs[Grid[I].Row], Grid[I].NaturalH);
    // ...then make sure rowspan cells fit (expand their last row)
    for I := 0 to NGrid - 1 do
      if Grid[I].RSpan > 1 then
      begin
        Extra := Grid[I].NaturalH - (Grid[I].RSpan - 1) * SpacingV;
        for K := Grid[I].Row to Grid[I].Row + Grid[I].RSpan - 1 do
          Dec(Extra, RowHs[K]);
        if Extra > 0 then
          Inc(RowHs[Grid[I].Row + Grid[I].RSpan - 1], Extra);
      end;

    // row y positions
    SetLength(RowYPos, Rows.Count);
    Inc(RowY, SpacingV);
    for R := 0 to Rows.Count - 1 do
    begin
      RowYPos[R] := RowY;
      Inc(RowY, RowHs[R] + SpacingV);
    end;

    // move the cells into place, stretch them over their rows and apply
    // vertical alignment of the content
    for I := 0 to NGrid - 1 do
    begin
      Cell := Grid[I].Cell;
      DX := ColX[Grid[I].Col] - Cell.X;
      DY := RowYPos[Grid[I].Row] - Cell.Y;
      OffsetBox(Cell, DX, DY);
      FinalH := (Grid[I].RSpan - 1) * SpacingV;
      for K := Grid[I].Row to Grid[I].Row + Grid[I].RSpan - 1 do
        Inc(FinalH, RowHs[K]);
      Cell.H := FinalH;
      DY := 0;
      case Cell.Style.VertAlign of
        cvaMiddle: DY := (FinalH - Grid[I].NaturalH) div 2;
        cvaBottom: DY := FinalH - Grid[I].NaturalH;
      end;
      if DY > 0 then
        OffsetBoxContent(Cell, DY);
    end;

    // row box geometry (row backgrounds)
    for R := 0 to Rows.Count - 1 do
    begin
      Row := Rows[R];
      Row.X := ContentX;
      Row.Y := RowYPos[R];
      Row.W := ContentW;
      Row.H := RowHs[R];
    end;

    ContentH := RowY - InnerY;
    if St.HeightPx >= 0 then
      ContentH := Max(ContentH, St.HeightPx);
    Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
    Y := Box.Y + Box.H + MB;
  finally
    Rows.Free;
    Others.Free;
  end;
end;

// Lays out and positions position:absolute children (out of flow). Shared
// by blocks, flex and grid — without it abs children of flex/grid are not positioned.
procedure TLayoutEngine.PlaceAbsChildren(Box: TLayoutBox;
  ContentX, ContentW, ContentTop, BottomInner: Integer);
var
  I, AbsX, AbsY, TmpY, SavedFloats: Integer;
  Child: TLayoutBox;
begin
  for I := 0 to Box.Children.Count - 1 do
  begin
    Child := Box.Children[I];
    if Child.Style.Position <> cpAbsolute then
      Continue;
    SavedFloats := FFloatCount;   // an absolute box is out of flow
    TmpY := 0;
    if (Child.Style.WidthPx < 0) and (Child.Style.WidthPct < 0) and
       not ((Child.Element <> nil) and (Child.Element.TagName = 'img')) then
    begin
      // auto width: shrink to the content (shrink-to-fit)
      LayoutBlockBox(Child, 0, 10000, TmpY);
      AbsX := MeasureMaxRight(Child) - Child.X + Child.Style.PadR + Child.Style.BordR;
      FFloatCount := SavedFloats;
      if AbsX < 1 then AbsX := 1;
      if AbsX > ContentW then AbsX := ContentW;
      TmpY := 0;
      LayoutBlockBox(Child, 0, AbsX, TmpY);
    end
    else
      LayoutBlockBox(Child, 0, ContentW, TmpY);
    FFloatCount := SavedFloats;
    if Child.Style.PosLeft <> Low(Integer) then
      AbsX := ContentX + Child.Style.PosLeft
    else if Child.Style.PosRight <> Low(Integer) then
      AbsX := ContentX + ContentW - Child.Style.PosRight - Child.W
    else
      AbsX := ContentX;
    if Child.Style.PosTop <> Low(Integer) then
      AbsY := ContentTop + Child.Style.PosTop
    else if Child.Style.PosBottom <> Low(Integer) then
      AbsY := BottomInner - Child.Style.PosBottom - Child.H
    else
      AbsY := ContentTop;
    OffsetBox(Child, AbsX - Child.X, AbsY - Child.Y);
  end;
end;

// Positions all position:fixed boxes relative to the viewport (0,0 ..
// ViewportWidth x ViewportHeight). The renderer draws them without the scroll
// offset. Called once after the main layout.
procedure TLayoutEngine.PlaceFixedBoxes(Box: TLayoutBox);
var
  I, AbsX, AbsY, TmpY, SavedFloats, VW, VH: Integer;
  Child: TLayoutBox;
begin
  if Box = nil then Exit;
  VW := Max(1, ViewportWidth);
  VH := Max(1, ViewportHeight);
  for I := 0 to Box.Children.Count - 1 do
  begin
    Child := Box.Children[I];
    if Child.Style.Position = cpFixed then
    begin
      SavedFloats := FFloatCount;
      TmpY := 0;
      if (Child.Style.WidthPx < 0) and (Child.Style.WidthPct < 0) and
         not ((Child.Element <> nil) and (Child.Element.TagName = 'img')) then
      begin
        LayoutBlockBox(Child, 0, VW, TmpY);
        AbsX := MeasureMaxRight(Child) - Child.X + Child.Style.PadR + Child.Style.BordR;
        FFloatCount := SavedFloats;
        if AbsX < 1 then AbsX := 1;
        if AbsX > VW then AbsX := VW;
        TmpY := 0;
        LayoutBlockBox(Child, 0, AbsX, TmpY);
      end
      else
        LayoutBlockBox(Child, 0, VW, TmpY);
      FFloatCount := SavedFloats;

      if Child.Style.PosLeft <> Low(Integer) then
        AbsX := Child.Style.PosLeft
      else if Child.Style.PosRight <> Low(Integer) then
        AbsX := VW - Child.Style.PosRight - Child.W
      else
        AbsX := 0;
      if Child.Style.PosTop <> Low(Integer) then
        AbsY := Child.Style.PosTop
      else if Child.Style.PosBottom <> Low(Integer) then
        AbsY := VH - Child.Style.PosBottom - Child.H
      else
        AbsY := 0;
      OffsetBox(Child, AbsX - Child.X, AbsY - Child.Y);
    end
    else
      PlaceFixedBoxes(Child); // look for nested fixed boxes
  end;
end;

// ---- flexbox ----

procedure TLayoutEngine.LayoutFlex(Box: TLayoutBox; CX, CW: Integer;
  var Y: Integer);
var
  St: TComputedStyle;
  ML, MR, MT, MB, ContentW, ContentX, InnerY, AvailW: Integer;
  Items: TList<TLayoutBox>;
  I, ContentH, X, LineStart, LineH, NItems: Integer;
  Basis, OuterW: array of Integer;
  Grow: array of Double;
  Ch: TLayoutBox;

  function NaturalW(B: TLayoutBox): Integer;
  var Sf, Ty: Integer; SavedTA: TCssTextAlign;
  begin
    // we lay out at a very large width -> the content does not wrap,
    // MeasureMaxRight returns the max-content (intrinsic) width.
    // Left alignment during the measurement, so that center/right does not inflate it.
    Sf := FFloatCount; Ty := 0;
    SavedTA := B.Style.TextAlign;
    B.Style.TextAlign := ctaLeft;
    LayoutBlockBox(B, 0, 10000, Ty);
    Result := MeasureMaxRight(B) - B.X + B.Style.PadR + B.Style.BordR;
    B.Style.TextAlign := SavedTA;
    FFloatCount := Sf;
    if Result < 1 then Result := 1;
    if Result > AvailW then Result := AvailW;
  end;

  // lays out one line [A..Z] at height LineTop; returns the line height
  procedure EmitLine(A, Z, LineTop: Integer);
  var
    J, SumOuter, SumBasis, FreeSp, CurX, MainW, Gap, ExtraGap, LeadGap, NL: Integer;
    SumGrow: Double;
    MT2, MB2: Integer;
    Tmp: Integer;
  begin
    Gap := St.ColGap;
    NL := Z - A + 1;
    SumOuter := 0;
    SumBasis := 0;
    SumGrow := 0;
    for J := A to Z do
    begin
      Inc(SumOuter, OuterW[J]);
      Inc(SumBasis, OuterW[J]);
      SumGrow := SumGrow + Grow[J];
    end;
    Inc(SumOuter, Gap * (NL - 1));
    FreeSp := AvailW - SumOuter;

    LeadGap := 0;
    ExtraGap := 0;
    if (FreeSp > 0) and (SumGrow = 0) then
      case St.JustifyContent of
        cjCenter: LeadGap := FreeSp div 2;
        cjEnd: LeadGap := FreeSp;
        cjSpaceBetween: if NL > 1 then ExtraGap := FreeSp div (NL - 1);
        cjSpaceAround:
          begin LeadGap := FreeSp div (NL * 2); ExtraGap := FreeSp div NL; end;
      end;

    CurX := ContentX + LeadGap;
    LineH := 0;
    // line height: first lay out the items at their main size
    for J := A to Z do
    begin
      Ch := Items[J];
      MainW := OuterW[J];
      if (FreeSp > 0) and (SumGrow > 0) then
        MainW := OuterW[J] + Round(FreeSp * Grow[J] / SumGrow)
      else if (FreeSp < 0) and (SumBasis > 0) then
        // flex-shrink (default 1): shrink proportionally to the basis
        MainW := Max(1, OuterW[J] + Round(FreeSp * OuterW[J] / SumBasis));
      Tmp := LineTop;
      ResolvePctMetrics(Ch.Style, AvailW);
      LayoutBlockBox(Ch, CurX, MainW, Tmp);
      MT2 := Ch.Style.MarginT; MB2 := Ch.Style.MarginB;
      if Ch.H + MT2 + MB2 > LineH then LineH := Ch.H + MT2 + MB2;
      Inc(CurX, MainW + Gap + ExtraGap);
    end;
    // cross-axis alignment + stretch
    for J := A to Z do
    begin
      Ch := Items[J];
      MT2 := Ch.Style.MarginT; MB2 := Ch.Style.MarginB;
      if Ch.Style.AlignItems = caStretch then // simplification: taken from the container
        ;
      case St.AlignItems of
        caStretch: Ch.H := LineH - MT2 - MB2;
        caCenter: OffsetBox(Ch, 0, (LineH - (Ch.H + MT2 + MB2)) div 2);
        caEnd: OffsetBox(Ch, 0, LineH - (Ch.H + MT2 + MB2));
      end;
    end;
  end;

begin
  St := Box.Style;
  ResolvePctMetrics(St, CW);
  ML := St.MarginL; MR := St.MarginR; MT := St.MarginT; MB := St.MarginB;
  if St.Clear_ <> ccNone then
    Y := ClearY(Y, St.Clear_);

  if St.WidthPx >= 0 then
  begin
    ContentW := St.WidthPx;
    if St.BoxSizing = cbsBorderBox then
      Dec(ContentW, St.PadL + St.PadR + St.BordL + St.BordR);
  end
  else if St.WidthPct >= 0 then
    ContentW := Max(0, Round(CW * St.WidthPct / 100) -
      St.PadL - St.PadR - St.BordL - St.BordR)
  else
    ContentW := Max(0, CW - ML - MR - St.PadL - St.PadR - St.BordL - St.BordR);
  ContentW := Max(0, ContentW);

  if St.MarginLAuto and St.MarginRAuto and (St.WidthPx >= 0) then
  begin
    ML := Max(0, (CW - (ContentW + St.PadL + St.PadR + St.BordL + St.BordR)) div 2);
    MR := ML;
  end;

  Box.X := CX + ML;
  Box.Y := Y + MT;
  Box.W := ContentW + St.PadL + St.PadR + St.BordL + St.BordR;
  ContentX := Box.X + St.BordL + St.PadL;
  InnerY := Box.Y + St.BordT + St.PadT;
  AvailW := ContentW;

  Items := TList<TLayoutBox>.Create;
  try
    for I := 0 to Box.Children.Count - 1 do
      if (Box.Children[I].Style.Display <> cdNone) and
         (Box.Children[I].Style.Position <> cpAbsolute) then
        Items.Add(Box.Children[I]);
    NItems := Items.Count;

    ContentH := 0;
    if St.FlexDirCol then
    begin
      // column direction: a simple stack with a RowGap gap
      X := InnerY;
      for I := 0 to NItems - 1 do
      begin
        if I > 0 then Inc(X, St.RowGap);
        ResolvePctMetrics(Items[I].Style, AvailW);
        LayoutBlockBox(Items[I], ContentX, AvailW, X);
      end;
      ContentH := X - InnerY;
    end
    else
    begin
      SetLength(Basis, NItems);
      SetLength(OuterW, NItems);
      SetLength(Grow, NItems);
      for I := 0 to NItems - 1 do
      begin
        Ch := Items[I];
        ResolvePctMetrics(Ch.Style, AvailW);
        Grow[I] := Ch.Style.FlexGrow;
        if Ch.Style.FlexBasis >= 0 then
          Basis[I] := Ch.Style.FlexBasis
        else if Ch.Style.WidthPx >= 0 then
          Basis[I] := Ch.Style.WidthPx + Ch.Style.PadL + Ch.Style.PadR +
            Ch.Style.BordL + Ch.Style.BordR
        else
          Basis[I] := NaturalW(Ch);
        OuterW[I] := Basis[I] + Ch.Style.MarginL + Ch.Style.MarginR;
      end;

      // splitting into lines (wrap)
      I := 0;
      LineStart := 0;
      ContentH := 0;
      while I < NItems do
      begin
        // how many items fit in this line
        if St.FlexWrapOn then
        begin
          LineStart := I;
          X := 0;
          while I < NItems do
          begin
            if (I > LineStart) then Inc(X, St.ColGap);
            if (I > LineStart) and (X + OuterW[I] > AvailW) then Break;
            Inc(X, OuterW[I]);
            Inc(I);
          end;
        end
        else
        begin
          LineStart := 0;
          I := NItems;
        end;
        if ContentH > 0 then Inc(ContentH, St.RowGap);
        EmitLine(LineStart, I - 1, InnerY + ContentH);
        Inc(ContentH, LineH);
        if not St.FlexWrapOn then Break;
      end;
    end;

    if St.HeightPx >= 0 then ContentH := Max(ContentH, St.HeightPx);
    if St.MinHeightPx >= 0 then ContentH := Max(ContentH, St.MinHeightPx);
    Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
    PlaceAbsChildren(Box, ContentX, AvailW, InnerY,
      Box.Y + Box.H - St.BordB - St.PadB);
    Y := Box.Y + Box.H + MB;
  finally
    Items.Free;
  end;
end;

// ---- CSS grid ----

type
  TGTrack = record
    IsFr, IsAuto: Boolean;
    Fr: Double;
    Px: Integer;
  end;
  TGTrackArr = array of TGTrack;
  TIntArrLocal = array of Integer;

// parses "1fr 1fr 200px auto" -> tracks (standalone, without XelStyle)
function ParseGridTracks(const S: string): TGTrackArr;
var
  Words: TStringList;
  I, P, Depth, Start: Integer;
  L, Num: string;
  FSx: TFormatSettings;
begin
  SetLength(Result, 0);
  FSx := DefaultFormatSettings;
  FSx.DecimalSeparator := '.';
  Words := TStringList.Create;
  try
    // split on spaces, respecting parentheses
    Depth := 0; Start := 1;
    for P := 1 to Length(S) + 1 do
      if (P > Length(S)) or ((S[P] = ' ') and (Depth = 0)) then
      begin
        if P > Start then Words.Add(Copy(S, Start, P - Start));
        Start := P + 1;
      end
      else if S[P] = '(' then Inc(Depth)
      else if S[P] = ')' then Dec(Depth);

    for I := 0 to Words.Count - 1 do
    begin
      L := LowerCase(Trim(Words[I]));
      if L = '' then Continue;
      // minmax(min,max) -> we use the max argument (e.g. minmax(0,1fr) -> 1fr)
      if Pos('minmax(', L) = 1 then
      begin
        Num := Copy(L, 8, Length(L) - 8);  // inside of the parentheses
        P := Pos(',', Num);
        if P > 0 then L := Trim(Copy(Num, P + 1, MaxInt)) else L := Trim(Num);
      end
      else if Pos('(', L) > 0 then
        Continue; // repeat() and others — skipped
      SetLength(Result, Length(Result) + 1);
      with Result[High(Result)] do
      begin
        IsFr := False; IsAuto := False; Fr := 0; Px := 0;
        if (Length(L) > 2) and (Copy(L, Length(L) - 1, 2) = 'fr') then
        begin
          IsFr := True;
          Fr := StrToFloatDef(Copy(L, 1, Length(L) - 2), 1, FSx);
        end
        else if (L = 'auto') or (L = 'min-content') or (L = 'max-content') then
          IsAuto := True
        else
        begin
          Num := L;
          if (Length(Num) > 3) and (Copy(Num, Length(Num) - 2, 3) = 'rem') then
            Px := Round(StrToFloatDef(Copy(Num, 1, Length(Num) - 3), 0, FSx) * 16)
          else if (Length(Num) > 2) and (Copy(Num, Length(Num) - 1, 2) = 'em') then
            Px := Round(StrToFloatDef(Copy(Num, 1, Length(Num) - 2), 0, FSx) * 16)
          else
          begin
            if (Length(Num) > 2) and (Copy(Num, Length(Num) - 1, 2) = 'px') then
              Num := Copy(Num, 1, Length(Num) - 2);
            Px := Round(StrToFloatDef(Num, 0, FSx));
          end;
          if Px <= 0 then IsAuto := True;
        end;
      end;
    end;
  finally
    Words.Free;
  end;
end;

// computes the column/track pixels: fixed px directly, fr share the rest,
// auto treated as 1fr (for columns)
function ResolveGridTracks(const Tr: TGTrackArr; Avail, Gap: Integer): TIntArrLocal;
var
  I, FixedSum, FreeSp: Integer;
  SumFr, FrUnit: Double;
begin
  SetLength(Result, Length(Tr));
  if Length(Tr) = 0 then Exit;
  FixedSum := Gap * (Length(Tr) - 1);
  SumFr := 0;
  for I := 0 to High(Tr) do
    if Tr[I].IsFr then SumFr := SumFr + Tr[I].Fr
    else if Tr[I].IsAuto then SumFr := SumFr + 1
    else Inc(FixedSum, Tr[I].Px);
  FreeSp := Avail - FixedSum;
  if FreeSp < 0 then FreeSp := 0;
  if SumFr > 0 then FrUnit := FreeSp / SumFr else FrUnit := 0;
  for I := 0 to High(Tr) do
    if Tr[I].IsFr then Result[I] := Round(Tr[I].Fr * FrUnit)
    else if Tr[I].IsAuto then Result[I] := Round(FrUnit)
    else Result[I] := Tr[I].Px;
end;

procedure TLayoutEngine.LayoutGrid(Box: TLayoutBox; CX, CW: Integer;
  var Y: Integer);
var
  St: TComputedStyle;
  ML, MR, MT, MB, ContentW, ContentX, InnerY, AvailW: Integer;
  ColTr, RowTr: TGTrackArr;
  ColW: TIntArrLocal;
  ColX: array of Integer;
  RowH, RowY: array of Integer;
  Items: TList<TLayoutBox>;
  ItCol, ItColSpan, ItRow, ItRowSpan, ItNatH: array of Integer;
  Occ: array of array of Boolean;
  NC, NR, I, J, R, C, CurR, CurC, CW2, CellW, CellX, CellY, CellH: Integer;
  ContentH, Sf, TmpY, JustH, AlignV, TmpRS: Integer;
  Ch: TLayoutBox;

  procedure EnsureRows(N: Integer);
  var RR, CC, Old: Integer;
  begin
    Old := Length(Occ);
    if N <= Old then Exit;
    SetLength(Occ, N);
    for RR := Old to N - 1 do
    begin
      SetLength(Occ[RR], NC);
      for CC := 0 to NC - 1 do Occ[RR][CC] := False;
    end;
  end;

  function CellFree(R, C, Span: Integer): Boolean;
  var K: Integer;
  begin
    Result := False;
    if C + Span > NC then Exit;
    EnsureRows(R + 1);
    for K := C to C + Span - 1 do
      if Occ[R][K] then Exit;
    Result := True;
  end;

  procedure Mark(R, C, CSpan, RSpan: Integer);
  var KR, KC: Integer;
  begin
    EnsureRows(R + RSpan);
    for KR := R to R + RSpan - 1 do
      for KC := C to C + CSpan - 1 do
        if KC < NC then Occ[KR][KC] := True;
  end;

  // Returns the rectangle of a named area from grid-template-areas (rows
  // separated by '|', cells by spaces).
  function AreaRect(const Name: string; out AC, AR, ACS, ARS: Integer): Boolean;
  var
    RowsS: TStringList;
    Cells: TStringList;
    RowIx, ColIx: Integer;
    MinR, MaxR, MinC, MaxC: Integer;
  begin
    Result := False;
    AC := 0; AR := 0; ACS := 1; ARS := 1;
    if (St.GridTemplateAreas = '') or (Name = '') then Exit;
    MinR := MaxInt; MaxR := -1; MinC := MaxInt; MaxC := -1;
    RowsS := TStringList.Create;
    Cells := TStringList.Create;
    try
      RowsS.Delimiter := '|'; RowsS.StrictDelimiter := True;
      RowsS.DelimitedText := St.GridTemplateAreas;
      for RowIx := 0 to RowsS.Count - 1 do
      begin
        Cells.Delimiter := ' '; Cells.StrictDelimiter := False;
        Cells.DelimitedText := Trim(RowsS[RowIx]);
        for ColIx := 0 to Cells.Count - 1 do
          if SameText(Trim(Cells[ColIx]), Name) then
          begin
            if RowIx < MinR then MinR := RowIx;
            if RowIx > MaxR then MaxR := RowIx;
            if ColIx < MinC then MinC := ColIx;
            if ColIx > MaxC then MaxC := ColIx;
          end;
      end;
    finally
      Cells.Free; RowsS.Free;
    end;
    if MaxR < 0 then Exit;
    AC := MinC; AR := MinR;
    ACS := MaxC - MinC + 1; ARS := MaxR - MinR + 1;
    Result := True;
  end;

begin
  St := Box.Style;
  ResolvePctMetrics(St, CW);
  ML := St.MarginL; MR := St.MarginR; MT := St.MarginT; MB := St.MarginB;
  if St.Clear_ <> ccNone then
    Y := ClearY(Y, St.Clear_);

  if St.WidthPx >= 0 then
  begin
    ContentW := St.WidthPx;
    if St.BoxSizing = cbsBorderBox then
      Dec(ContentW, St.PadL + St.PadR + St.BordL + St.BordR);
  end
  else if St.WidthPct >= 0 then
    ContentW := Round(CW * St.WidthPct / 100) - St.PadL - St.PadR - St.BordL - St.BordR
  else
    ContentW := CW - ML - MR - St.PadL - St.PadR - St.BordL - St.BordR;
  ContentW := Max(0, ContentW);

  Box.X := CX + ML;
  Box.Y := Y + MT;
  Box.W := ContentW + St.PadL + St.PadR + St.BordL + St.BordR;
  ContentX := Box.X + St.BordL + St.PadL;
  InnerY := Box.Y + St.BordT + St.PadT;
  AvailW := ContentW;

  ColTr := ParseGridTracks(St.GridTemplate);
  NC := Length(ColTr);
  Items := TList<TLayoutBox>.Create;
  try
    for I := 0 to Box.Children.Count - 1 do
      if (Box.Children[I].Style.Display <> cdNone) and
         (Box.Children[I].Style.Position <> cpAbsolute) then
        Items.Add(Box.Children[I]);

    if NC = 0 then
    begin
      // no template — a block stack
      TmpY := InnerY;
      for I := 0 to Items.Count - 1 do
        LayoutBlockBox(Items[I], ContentX, AvailW, TmpY);
      ContentH := TmpY - InnerY;
      Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
      PlaceAbsChildren(Box, ContentX, AvailW, InnerY,
        Box.Y + Box.H - St.BordB - St.PadB);
      Y := Box.Y + Box.H + MB;
      Exit;
    end;

    ColW := ResolveGridTracks(ColTr, AvailW, St.ColGap);
    SetLength(ColX, NC);
    CW2 := ContentX;
    for I := 0 to NC - 1 do
    begin
      ColX[I] := CW2;
      Inc(CW2, ColW[I] + St.ColGap);
    end;

    RowTr := ParseGridTracks(St.GridTemplateRows);

    // item placement (row auto-flow)
    SetLength(ItCol, Items.Count); SetLength(ItColSpan, Items.Count);
    SetLength(ItRow, Items.Count); SetLength(ItRowSpan, Items.Count);
    SetLength(ItNatH, Items.Count);
    SetLength(Occ, 0);
    CurR := 0; CurC := 0;
    for I := 0 to Items.Count - 1 do
    begin
      Ch := Items[I];
      // placement by named area (grid-template-areas / grid-area)
      if (St.GridTemplateAreas <> '') and (Ch.Style.GridAreaName <> '') and
         AreaRect(Ch.Style.GridAreaName, C, R, J, TmpRS) then
      begin
        ItColSpan[I] := Max(1, Min(J, NC));
        ItRowSpan[I] := Max(1, TmpRS);
        if C + ItColSpan[I] > NC then C := Max(0, NC - ItColSpan[I]);
        ItCol[I] := C; ItRow[I] := R;
        Mark(R, C, ItColSpan[I], ItRowSpan[I]);
        Continue;
      end;
      // column
      if Ch.Style.GridColSpan > 0 then ItColSpan[I] := Ch.Style.GridColSpan
      else if (Ch.Style.GridColStart > 0) and (Ch.Style.GridColEnd > 0) then
        ItColSpan[I] := Max(1, Ch.Style.GridColEnd - Ch.Style.GridColStart)
      else ItColSpan[I] := 1;
      if ItColSpan[I] > NC then ItColSpan[I] := NC;
      // row
      if Ch.Style.GridRowSpan > 0 then ItRowSpan[I] := Ch.Style.GridRowSpan
      else if (Ch.Style.GridRowStart > 0) and (Ch.Style.GridRowEnd > 0) then
        ItRowSpan[I] := Max(1, Ch.Style.GridRowEnd - Ch.Style.GridRowStart)
      else ItRowSpan[I] := 1;

      if (Ch.Style.GridColStart > 0) and (Ch.Style.GridRowStart > 0) then
      begin
        C := Ch.Style.GridColStart - 1;
        R := Ch.Style.GridRowStart - 1;
      end
      else if Ch.Style.GridColStart > 0 then
      begin
        C := Ch.Style.GridColStart - 1;
        R := 0;
        while not CellFree(R, C, ItColSpan[I]) do Inc(R);
      end
      else if Ch.Style.GridRowStart > 0 then
      begin
        R := Ch.Style.GridRowStart - 1;
        C := 0;
        while not CellFree(R, C, ItColSpan[I]) do Inc(C);
      end
      else
      begin
        R := CurR; C := CurC;
        while True do
        begin
          if C + ItColSpan[I] > NC then begin C := 0; Inc(R); end;
          if CellFree(R, C, ItColSpan[I]) then Break;
          Inc(C);
        end;
        CurR := R; CurC := C + ItColSpan[I];
      end;
      if C < 0 then C := 0;
      if C + ItColSpan[I] > NC then C := NC - ItColSpan[I];
      if R < 0 then R := 0;
      ItCol[I] := C; ItRow[I] := R;
      Mark(R, C, ItColSpan[I], ItRowSpan[I]);
    end;

    NR := Length(Occ);
    if NR = 0 then NR := 1;

    // natural height of each item at its cell width
    for I := 0 to Items.Count - 1 do
    begin
      Ch := Items[I];
      CellW := 0;
      for J := ItCol[I] to ItCol[I] + ItColSpan[I] - 1 do
        Inc(CellW, ColW[J]);
      Inc(CellW, St.ColGap * (ItColSpan[I] - 1));
      Sf := FFloatCount; TmpY := 0;
      ResolvePctMetrics(Ch.Style, CellW);
      LayoutBlockBox(Ch, 0, CellW, TmpY);
      ItNatH[I] := Ch.H;
      FFloatCount := Sf;
    end;

    // row heights: explicit px or from the content (single-row items)
    SetLength(RowH, NR);
    for R := 0 to NR - 1 do
    begin
      if (R <= High(RowTr)) and (not RowTr[R].IsFr) and (not RowTr[R].IsAuto) then
        RowH[R] := RowTr[R].Px
      else
        RowH[R] := 0;
    end;
    for I := 0 to Items.Count - 1 do
      if ItRowSpan[I] = 1 then
        RowH[ItRow[I]] := Max(RowH[ItRow[I]], ItNatH[I]);
    for I := 0 to Items.Count - 1 do
      if ItRowSpan[I] > 1 then
      begin
        J := ItNatH[I] - St.RowGap * (ItRowSpan[I] - 1);
        for R := ItRow[I] to ItRow[I] + ItRowSpan[I] - 1 do
          if R <= High(RowH) then Dec(J, RowH[R]);
        if (J > 0) and (ItRow[I] + ItRowSpan[I] - 1 <= High(RowH)) then
          Inc(RowH[ItRow[I] + ItRowSpan[I] - 1], J);
      end;

    SetLength(RowY, NR + 1);
    TmpY := InnerY;
    for R := 0 to NR - 1 do
    begin
      RowY[R] := TmpY;
      Inc(TmpY, RowH[R] + St.RowGap);
    end;
    RowY[NR] := TmpY;
    ContentH := TmpY - InnerY;
    if NR > 0 then Dec(ContentH, St.RowGap);

    // distribute any min-height surplus to the fr rows
    if St.MinHeightPx > ContentH then
    begin
      J := St.MinHeightPx - ContentH;
      for R := 0 to NR - 1 do
        if (R <= High(RowTr)) and RowTr[R].IsFr then
        begin
          Inc(RowH[R], J);
          Break;
        end;
      // recompute RowY
      TmpY := InnerY;
      for R := 0 to NR - 1 do
      begin
        RowY[R] := TmpY;
        Inc(TmpY, RowH[R] + St.RowGap);
      end;
      RowY[NR] := TmpY;
      ContentH := TmpY - InnerY - St.RowGap;
    end;

    // final placement + alignment
    for I := 0 to Items.Count - 1 do
    begin
      Ch := Items[I];
      CellX := ColX[ItCol[I]];
      CellW := 0;
      for J := ItCol[I] to ItCol[I] + ItColSpan[I] - 1 do
        Inc(CellW, ColW[J]);
      Inc(CellW, St.ColGap * (ItColSpan[I] - 1));
      CellY := RowY[ItRow[I]];
      CellH := 0;
      for J := ItRow[I] to ItRow[I] + ItRowSpan[I] - 1 do
        if J <= High(RowH) then Inc(CellH, RowH[J]);
      Inc(CellH, St.RowGap * (ItRowSpan[I] - 1));

      // the item is already laid out (measurement) at (0,0) with width CellW —
      // we move it into the target cell without laying it out again
      OffsetBox(Ch, CellX, CellY);

      // justify-self / justify-items (horizontal) — when the item is narrower than the cell
      if Ch.Style.JustifySelfAuto then JustH := Ord(St.JustifyItems)
      else JustH := Ord(Ch.Style.JustifySelf);
      if Ch.W < CellW then
        case TCssAlign(JustH) of
          caCenter: OffsetBox(Ch, (CellW - Ch.W) div 2, 0);
          caEnd: OffsetBox(Ch, CellW - Ch.W, 0);
        end;
      // align-self / align-items (vertical)
      if Ch.Style.AlignSelfAuto then AlignV := Ord(St.AlignItems)
      else AlignV := Ord(Ch.Style.AlignSelf);
      case TCssAlign(AlignV) of
        caStretch: if Ch.Style.HeightPx < 0 then Ch.H := CellH;
        caCenter: if Ch.H < CellH then OffsetBox(Ch, 0, (CellH - Ch.H) div 2);
        caEnd: if Ch.H < CellH then OffsetBox(Ch, 0, CellH - Ch.H);
      end;
    end;

    if St.HeightPx >= 0 then ContentH := Max(ContentH, St.HeightPx);
    if St.MinHeightPx >= 0 then ContentH := Max(ContentH, St.MinHeightPx);
    Box.H := St.BordT + St.PadT + ContentH + St.PadB + St.BordB;
    PlaceAbsChildren(Box, ContentX, AvailW, InnerY,
      Box.Y + Box.H - St.BordB - St.PadB);
    Y := Box.Y + Box.H + MB;
  finally
    Items.Free;
  end;
end;

// Multi-column layout (CSS column-count / column-width). Block children are
// distributed into N columns with height balancing. When the container has a single
// list child (e.g. <ol> in .mw-references-columns), its items are put in columns.
procedure TLayoutEngine.LayoutMultiCol(Box: TLayoutBox; ContentX, ContentW: Integer;
  var Y: Integer);
var
  St: TComputedStyle;
  Kids: TList<TLayoutBox>;
  I: Integer;
  Cont: TLayoutBox;
  CIX, CIW, CIY: Integer;

  // distributes the items from Items into N columns in the area [AX, AX+AW], from AY down;
  // returns the bottom edge
  function Distribute(Items: TList<TLayoutBox>; AX, AW, AY: Integer): Integer;
  var
    N, Gap, ColW, J, Col, StartY, TmpY, Sf, Total, Target: Integer;
    ColX, ColY: array of Integer;
    Ch: TLayoutBox;
  begin
    Gap := St.ColGap;
    if Gap <= 0 then Gap := 16;
    if St.ColumnCount > 0 then
      N := St.ColumnCount
    else
      N := Max(1, (AW + Gap) div (Max(1, St.ColumnWidthPx) + Gap));
    if N > Items.Count then N := Items.Count;
    if N < 1 then N := 1;
    ColW := (AW - (N - 1) * Gap) div N;
    if ColW < 1 then ColW := 1;

    // measures item heights at the column width
    Total := 0;
    for J := 0 to Items.Count - 1 do
    begin
      Ch := Items[J];
      Sf := FFloatCount; TmpY := 0;
      ResolvePctMetrics(Ch.Style, ColW);
      LayoutBlockBox(Ch, 0, ColW, TmpY);
      FFloatCount := Sf;
      Inc(Total, Max(TmpY, Ch.H));
    end;
    Target := (Total + N - 1) div N;

    SetLength(ColX, N); SetLength(ColY, N);
    StartY := AY;
    for J := 0 to N - 1 do
    begin ColX[J] := AX + J * (ColW + Gap); ColY[J] := StartY; end;

    Col := 0;
    for J := 0 to Items.Count - 1 do
    begin
      Ch := Items[J];
      if (Col < N - 1) and (ColY[Col] - StartY >= Target) and
         (Items.Count - J > N - 1 - Col) then
        Inc(Col);
      TmpY := ColY[Col];
      LayoutBlockBox(Ch, ColX[Col], ColW, TmpY);
      ColY[Col] := TmpY;
    end;

    Result := StartY;
    for J := 0 to N - 1 do
      if ColY[J] > Result then Result := ColY[J];
  end;

begin
  St := Box.Style;
  Kids := TList<TLayoutBox>.Create;
  try
    for I := 0 to Box.Children.Count - 1 do
      if Box.Children[I].Style.Position <> cpAbsolute then
        Kids.Add(Box.Children[I]);
    if Kids.Count = 0 then Exit;

    // a single list child -> put its items in columns inside its box
    if (Kids.Count = 1) and (Kids[0].InlineNodes = nil) and
       (Kids[0].Children <> nil) and (Kids[0].Children.Count > 1) then
    begin
      Cont := Kids[0];
      ResolvePctMetrics(Cont.Style, ContentW);
      Cont.X := ContentX + Cont.Style.MarginL;
      Cont.Y := Y + Cont.Style.MarginT;
      Cont.W := Max(0, ContentW - Cont.Style.MarginL - Cont.Style.MarginR);
      CIX := Cont.X + Cont.Style.BordL + Cont.Style.PadL;
      CIW := Max(0, Cont.W - Cont.Style.BordL - Cont.Style.PadL
                  - Cont.Style.BordR - Cont.Style.PadR);
      CIY := Cont.Y + Cont.Style.BordT + Cont.Style.PadT;
      Kids.Clear;
      for I := 0 to Cont.Children.Count - 1 do
        if Cont.Children[I].Style.Position <> cpAbsolute then
          Kids.Add(Cont.Children[I]);
      CIY := Distribute(Kids, CIX, CIW, CIY);
      Cont.H := (CIY - Cont.Y) + Cont.Style.PadB + Cont.Style.BordB;
      Y := Cont.Y + Cont.H + Cont.Style.MarginB;
    end
    else
      Y := Distribute(Kids, ContentX, ContentW, Y);
  finally
    Kids.Free;
  end;
end;

procedure TLayoutEngine.PlaceFloat(Box: TLayoutBox; CX, CW, Y: Integer);
var
  St: TComputedStyle;
  TempY, FY, LX, RX, TotalW, TotalH, TX: Integer;
  UsedW: Integer;
  FR: TRect;
  Guard, SavedCount, K: Integer;
  SavedFloats: array of TFloatInfo;
begin
  St := Box.Style;

  // A float establishes its own block formatting context (BFC): its inner
  // floats do NOT see the parent's floats and must NOT leak into them. Save and
  // clear the float context while laying out the float's content, then restore it
  // (dropping the inner floats) — otherwise e.g. floats in <dd> would break the position
  // of the <dd> itself next to <dt>.
  SavedCount := FFloatCount;
  SetLength(SavedFloats, SavedCount);
  for K := 0 to SavedCount - 1 do
    SavedFloats[K] := FFloats[K];
  FFloatCount := 0;

  // lay out the float in temporary coordinates (0,0)
  TempY := 0;
  LayoutBlockBox(Box, 0, CW, TempY);

  // auto width — shrink to the content (shrink-to-fit)
  if (St.WidthPx < 0) and (St.WidthPct < 0) and
     not ((Box.Element <> nil) and (Box.Element.TagName = 'img')) then
  begin
    UsedW := MeasureMaxRight(Box) - Box.X + St.PadR + St.BordR;
    if (UsedW > 0) and (UsedW < Box.W) then
      Box.W := UsedW;
  end;

  // restore the parent's float context
  FFloatCount := SavedCount;
  for K := 0 to SavedCount - 1 do
    FFloats[K] := SavedFloats[K];

  TotalW := Box.W + St.MarginL + St.MarginR;
  TotalH := Box.H + St.MarginT + St.MarginB;

  // find a place next to the existing floats
  FY := Y;
  Guard := 0;
  repeat
    GetLineBounds(FY, Max(1, TotalH), CX, CW, LX, RX);
    if (RX - LX >= TotalW) or (Guard > 50) then
      Break;
    FY := Max(FY + 1, NextFloatBottom(FY));
    Inc(Guard);
  until False;

  if St.Float_ = cfLeft then
    TX := LX + St.MarginL
  else
    TX := RX - St.MarginR - Box.W;

  OffsetBox(Box, TX - Box.X, FY + St.MarginT - Box.Y);

  FR := Rect(Box.X - St.MarginL, FY, Box.X + Box.W + St.MarginR, FY + TotalH);
  AddFloat(FR, St.Float_);
end;

// ---- inline content ----

type
  TItemKind = (iiWord, iiSpace, iiBreak, iiImage, iiControl, iiBox,
    iiAnchor); // zero-width marker recording an in-page anchor position

  TInlineItem = class
  public
    Kind: TItemKind;
    Text: string;
    Style: TComputedStyle;
    Element: TDOMElement;
    Box: TLayoutBox;     // ownership passed to the fragment
    Href: string;        // link target inherited from the enclosing <a>
    Target: string;      // target attribute of the enclosing <a>
    W, H, Ascent: Integer;
    LineAdvance: Integer; // line height resulting from line-height
    destructor Destroy; override;
  end;

destructor TInlineItem.Destroy;
begin
  Box.Free;
  inherited Destroy;
end;

procedure TLayoutEngine.LayoutInlineContent(Box: TLayoutBox; CX, CW: Integer;
  var Y: Integer);
var
  Items: TObjectList<TInlineItem>;
  CurrentHref: string; // href of the <a> being walked, '' outside links
  CurrentTarget: string; // target attribute of the current <a>

  procedure MeasureTextItem(It: TInlineItem);
  var
    TM: TTextMetric;
    TH: Integer;
  begin
    SetCanvasFont(Canvas, It.Style);
    It.W := Canvas.TextWidth(It.Text);
    // letter-spacing: extra after every character (consistent with GDI rendering
    // using SetTextCharacterExtra); word-spacing: extra per space
    if It.Style.LetterSpacing <> 0 then
      Inc(It.W, It.Style.LetterSpacing * CountGlyphs(It.Text));
    if (It.Style.WordSpacing <> 0) and (It.Kind = iiSpace) then
      Inc(It.W, It.Style.WordSpacing);
    TH := Canvas.TextHeight('Hg');
    if GetTextMetrics(Canvas.Handle, TM) then
      It.Ascent := TM.tmAscent
    else
      It.Ascent := Round(TH * 0.8);
    It.H := TH;
    It.LineAdvance := Max(TH, Round(It.Style.FontSizePx * It.Style.LineHeight));
  end;

  procedure AddWord(const Word: string; St: TComputedStyle);
  var
    It: TInlineItem;
  begin
    It := TInlineItem.Create;
    It.Kind := iiWord;
    if St.TextTransform <> cttNone then
      It.Text := ApplyTextTransform(Word, St.TextTransform)
    else
      It.Text := Word;
    It.Style := St;
    It.Href := CurrentHref;
    It.Target := CurrentTarget;
    MeasureTextItem(It);
    Items.Add(It);
  end;

  procedure AddSpace(St: TComputedStyle);
  var
    It: TInlineItem;
  begin
    It := TInlineItem.Create;
    It.Kind := iiSpace;
    It.Text := ' ';
    It.Style := St;
    It.Href := CurrentHref;
    It.Target := CurrentTarget;
    MeasureTextItem(It);
    Items.Add(It);
  end;

  procedure AddBreak(St: TComputedStyle);
  var
    It: TInlineItem;
  begin
    It := TInlineItem.Create;
    It.Kind := iiBreak;
    It.Style := St;
    It.LineAdvance := Max(1, Round(St.FontSizePx * St.LineHeight));
    Items.Add(It);
  end;

  procedure AddAnchor(const AName: string; St: TComputedStyle);
  var
    It: TInlineItem;
  begin
    if AName = '' then
      Exit;
    It := TInlineItem.Create;
    It.Kind := iiAnchor;
    It.Text := AName;
    It.Style := St;
    Items.Add(It);
  end;

  // horizontal gap (margin-left/right of an inline element) — zero height
  procedure AddGap(W: Integer; St: TComputedStyle);
  var
    It: TInlineItem;
  begin
    if W <= 0 then
      Exit;
    It := TInlineItem.Create;
    It.Kind := iiSpace;
    It.Text := '';
    It.Style := St;
    It.W := W;
    It.H := 0;
    It.Ascent := 0;
    It.LineAdvance := 1;
    Items.Add(It);
  end;

  procedure AddTextTokens(const S: string; St: TComputedStyle);
  var
    I, Start, Len: Integer;
    InWs: Boolean;
    T: string;
  begin
    Len := Length(S);
    if St.PreWhiteSpace then
    begin
      // white-space:pre — keep spaces and line breaks
      I := 1;
      Start := 1;
      while I <= Len + 1 do
      begin
        if (I > Len) or (S[I] = #10) then
        begin
          T := Copy(S, Start, I - Start);
          T := StringReplace(T, #13, '', [rfReplaceAll]);
          T := StringReplace(T, #9, '    ', [rfReplaceAll]);
          if T <> '' then
            AddWord(T, St);
          if I <= Len then
            AddBreak(St);
          Start := I + 1;
        end;
        Inc(I);
      end;
      Exit;
    end;
    // plain text — collapse whitespace
    I := 1;
    while I <= Len do
    begin
      InWs := S[I] in [' ', #9, #10, #13];
      Start := I;
      while (I <= Len) and ((S[I] in [' ', #9, #10, #13]) = InWs) do
        Inc(I);
      if InWs then
        AddSpace(St)
      else
        AddWord(Copy(S, Start, I - Start), St);
    end;
  end;

  procedure AddImageItem(E: TDOMElement; St: TComputedStyle);
  var
    It: TInlineItem;
    W, H: Integer;
  begin
    ComputeImageSize(E, St, CW, W, H);
    It := TInlineItem.Create;
    It.Kind := iiImage;
    It.Element := E;
    It.Style := St;
    It.Href := CurrentHref;
    It.Target := CurrentTarget;
    It.W := W;
    It.H := H;
    // vertical-align: middle centres the image relative to the text line;
    // top/bottom — accordingly; default baseline (bottom on the baseline)
    case St.VertAlign of
      cvaMiddle: It.Ascent := H div 2 + Round(St.FontSizePx * 0.3);
      cvaTop: It.Ascent := H;     // correction when laying out the line below
      cvaBottom: It.Ascent := Round(St.FontSizePx * 0.8);
    else
      It.Ascent := H;
    end;
    It.LineAdvance := H;
    Items.Add(It);
  end;

  procedure AddControlItem(E: TDOMElement; St: TComputedStyle);
  var
    It: TInlineItem;
    Lbl, Typ: string;
    N: Integer;
    Opt: TDOMElement;
  begin
    It := TInlineItem.Create;
    It.Kind := iiControl;
    It.Element := E;
    It.Style := St;
    It.Href := CurrentHref;
    It.Target := CurrentTarget;
    SetCanvasFont(Canvas, St);
    Lbl := '';
    if E.TagName = 'input' then
    begin
      Typ := LowerCase(E.GetAttribute('type'));
      if (Typ = 'checkbox') or (Typ = 'radio') then
      begin
        It.W := 14;
        It.H := 14;
      end
      else if (Typ = 'submit') or (Typ = 'button') or (Typ = 'reset') then
      begin
        Lbl := E.GetAttribute('value');
        if (Lbl = '') and not E.HasAttribute('value') then
          if Typ = 'submit' then
            Lbl := 'Submit'
          else if Typ = 'reset' then
            Lbl := 'Reset';
        It.W := Canvas.TextWidth(Lbl) + 24;
        It.H := Canvas.TextHeight('Hg') + 10;
      end
      else if Typ = 'hidden' then
      begin
        It.Free;
        Exit;
      end
      else
      begin
        Lbl := E.GetAttribute('value');
        N := StrToIntDef(E.GetAttribute('size'), 0);
        if N > 0 then
          It.W := N * 8 + 12
        else
          It.W := 160;
        It.H := Canvas.TextHeight('Hg') + 8;
      end;
    end
    else if E.TagName = 'button' then
    begin
      Lbl := Trim(E.TextContent);
      if Lbl = '' then
        Lbl := E.GetAttribute('value');
      It.W := Canvas.TextWidth(Lbl) + 24;
      It.H := Canvas.TextHeight('Hg') + 10;
    end
    else if E.TagName = 'select' then
    begin
      Opt := SelectedOption(E);
      if Opt <> nil then
        Lbl := OptionLabel(Opt);
      It.W := Canvas.TextWidth(Lbl) + 32;
      It.H := Canvas.TextHeight('Hg') + 8;
    end
    else if E.TagName = 'textarea' then
    begin
      Lbl := E.TextContent;
      N := StrToIntDef(E.GetAttribute('cols'), 0);
      if N > 0 then
        It.W := N * 8 + 12
      else
        It.W := 240;
      N := StrToIntDef(E.GetAttribute('rows'), 0);
      if N > 0 then
        It.H := N * (Canvas.TextHeight('Hg') + 2) + 8
      else
        It.H := 64;
    end;
    if St.WidthPx >= 0 then
      It.W := St.WidthPx;
    if St.HeightPx >= 0 then
      It.H := St.HeightPx;
    It.Text := Lbl;
    It.Ascent := It.H;
    It.LineAdvance := It.H;
    Items.Add(It);
  end;

  procedure AddInlineBlockItem(E: TDOMElement; St: TComputedStyle);
  var
    It: TInlineItem;
    Sub: TLayoutBox;
    TempY, UsedW, SavedFloats: Integer;
    SavedTA: TCssTextAlign;
  begin
    Sub := BuildBlockBox(E, Box.Style);
    // inline-block establishes its own formatting context — its floats are
    // local; save the float counter and restore it so they do not leak
    // (especially from the measurement at 1000000 px -> huge LX).
    SavedFloats := FFloatCount;
    // auto width — shrink to the content (max-content).
    // Measure at a large width and with left alignment, so that center/right
    // does not inflate the width; then lay out again at the shrunk width.
    if (St.WidthPx < 0) and (St.WidthPct < 0) and
       not (E.TagName = 'img') then
    begin
      SavedTA := Sub.Style.TextAlign;
      Sub.Style.TextAlign := ctaLeft;
      TempY := 0;
      LayoutBlockBox(Sub, 0, 10000, TempY);
      UsedW := MeasureMaxRight(Sub) - Sub.X + St.PadR + St.BordR;
      Sub.Style.TextAlign := SavedTA;
      FFloatCount := SavedFloats;
      if UsedW < 1 then UsedW := 1;
      if UsedW > CW then UsedW := CW;
      TempY := 0;
      LayoutBlockBox(Sub, 0, UsedW, TempY);
    end
    else
    begin
      TempY := 0;
      LayoutBlockBox(Sub, 0, CW, TempY);
    end;
    FFloatCount := SavedFloats;
    It := TInlineItem.Create;
    It.Kind := iiBox;
    It.Element := E;
    It.Style := St;
    It.Box := Sub;
    // inline-block <a href> — keep it clickable (and the cursor)
    if (E.TagName = 'a') and (E.GetAttribute('href') <> '') then
    begin
      It.Href := E.GetAttribute('href');
      It.Target := E.GetAttribute('target');
    end
    else
    begin
      It.Href := CurrentHref;
      It.Target := CurrentTarget;
    end;
    It.W := Sub.W + St.MarginL + St.MarginR;
    It.H := Sub.H + St.MarginT + St.MarginB;
    It.Ascent := It.H;
    It.LineAdvance := It.H;
    Items.Add(It);
  end;

  procedure CollectItems(Nodes: TList<TDOMNode>; BaseStyle: TComputedStyle);
  var
    I, J: Integer;
    Node: TDOMNode;
    E: TDOMElement;
    St: TComputedStyle;
    Sub: TList<TDOMNode>;
    SavedHref, SavedTarget: string;
  begin
    for I := 0 to Nodes.Count - 1 do
    begin
      Node := Nodes[I];
      if Node.NodeType = ntText then
        AddTextTokens(Node.NodeValue, BaseStyle)
      else if Node is TDOMElement then
      begin
        E := TDOMElement(Node);
        St := StyleOf(E, BaseStyle);
        if St.Display = cdNone then
          Continue;
        // record in-page anchor targets (id or legacy <a name>)
        if E.GetId <> '' then
          AddAnchor(E.GetId, BaseStyle);
        if (E.TagName = 'a') and (E.GetAttribute('name') <> '') then
          AddAnchor(E.GetAttribute('name'), BaseStyle);
        if E.TagName = 'br' then
          AddBreak(BaseStyle)
        else if E.TagName = 'img' then
        begin
          if St.Float_ <> cfNone then
          begin
            // float in inline content — a floating box
            AddInlineBlockItem(E, St);
            Items[Items.Count - 1].Kind := iiBox;
          end
          else
            AddImageItem(E, St);
        end
        else if (E.TagName = 'input') or (E.TagName = 'button') or
                (E.TagName = 'select') or (E.TagName = 'textarea') then
          AddControlItem(E, St)
        else if St.Display in [cdInlineBlock, cdBlock, cdListItem,
          cdTable] then
          AddInlineBlockItem(E, St)
        else
        begin
          // inline element - descend into children with its style;
          // an <a href> marks all nested items as link targets
          SavedHref := CurrentHref;
          SavedTarget := CurrentTarget;
          if (E.TagName = 'a') and (E.GetAttribute('href') <> '') then
          begin
            CurrentHref := E.GetAttribute('href');
            CurrentTarget := E.GetAttribute('target');
          end;
          // horizontal margins of an inline element give spacing before/after the content
          AddGap(St.MarginL, St);
          Sub := TList<TDOMNode>.Create;
          try
            for J := 0 to E.ChildCount - 1 do
              Sub.Add(E.Children[J]);
            CollectItems(Sub, St);
          finally
            Sub.Free;
          end;
          AddGap(St.MarginR, St);
          CurrentHref := SavedHref;
          CurrentTarget := SavedTarget;
        end;
      end;
    end;
  end;

var
  CurY: Integer;
  LineStart: Integer; // index of the first item of the current line

  procedure EmitLine(FromIdx, ToIdx: Integer; ForcedAdvance: Integer);
  var
    Line: TLineBox;
    I, PenX, LX, RX, FragTop: Integer;
    MaxAscent, MaxDescent, LineH, MaxAdvance: Integer;
    It: TInlineItem;
    Frag: TLineFrag;
    Extra, TotalW: Integer;
    EstH: Integer;
  begin
    // skip spaces at the beginning and end
    while (FromIdx <= ToIdx) and (Items[FromIdx].Kind = iiSpace) do
      Inc(FromIdx);
    while (ToIdx >= FromIdx) and (Items[ToIdx].Kind = iiSpace) do
      Dec(ToIdx);

    if FromIdx > ToIdx then
    begin
      // empty line (e.g. <br><br>)
      Inc(CurY, ForcedAdvance);
      Exit;
    end;

    // estimate the height for computing the bounds (floats)
    EstH := 0;
    for I := FromIdx to ToIdx do
      EstH := Max(EstH, Items[I].LineAdvance);
    GetLineBounds(CurY, Max(1, EstH), CX, CW, LX, RX);

    MaxAscent := 0;
    MaxDescent := 0;
    MaxAdvance := 0;
    for I := FromIdx to ToIdx do
    begin
      It := Items[I];
      MaxAscent := Max(MaxAscent, It.Ascent);
      MaxDescent := Max(MaxDescent, It.H - It.Ascent);
      MaxAdvance := Max(MaxAdvance, It.LineAdvance);
    end;
    LineH := Max(MaxAscent + MaxDescent, MaxAdvance);

    Line := TLineBox.Create;
    Line.Y := CurY;
    Line.H := LineH;

    PenX := LX;
    for I := FromIdx to ToIdx do
    begin
      It := Items[I];
      if It.Kind = iiBreak then
        Continue;
      if It.Kind = iiAnchor then
      begin
        FAnchors.AddOrSetValue(It.Text, CurY);
        Continue;
      end;
      Frag := TLineFrag.Create;
      Frag.Style := It.Style;
      Frag.Element := It.Element;
      Frag.Href := It.Href;
      Frag.Target := It.Target;
      Frag.Ascent := It.Ascent;
      case It.Kind of
        iiWord, iiSpace:
          begin
            Frag.Kind := fkText;
            Frag.Text := It.Text;
          end;
        iiImage:
          begin
            Frag.Kind := fkImage;
            Frag.Url := ResolveUrl(It.Element.OwnerDocument.BaseUrl,
              It.Element.GetAttribute('src'));
          end;
        iiControl:
          begin
            Frag.Kind := fkControl;
            Frag.Text := It.Text;
          end;
        iiBox:
          begin
            Frag.Kind := fkBox;
            Frag.Box := It.Box;
            It.Box := nil; // ownership transfer
          end;
      end;
      // baseline alignment
      case It.Style.VertAlign of
        cvaTop:
          FragTop := CurY;
        cvaMiddle:
          FragTop := CurY + (LineH - It.H) div 2;
        cvaBottom:
          FragTop := CurY + LineH - It.H;
      else
        FragTop := CurY + (MaxAscent - It.Ascent);
      end;
      Frag.R := Rect(PenX, FragTop, PenX + It.W, FragTop + It.H);
      if (Frag.Kind = fkBox) and (Frag.Box <> nil) then
        OffsetBox(Frag.Box,
          Frag.R.Left + It.Style.MarginL - Frag.Box.X,
          Frag.R.Top + It.Style.MarginT - Frag.Box.Y);
      Inc(PenX, It.W);
      Line.Frags.Add(Frag);
    end;

    // horizontal alignment
    TotalW := PenX - LX;
    Extra := (RX - LX) - TotalW;
    if Extra > 0 then
    begin
      case Box.Style.TextAlign of
        ctaCenter: Extra := Extra div 2;
        ctaRight: ;
      else
        Extra := 0;
      end;
      if Extra > 0 then
        for I := 0 to Line.Frags.Count - 1 do
        begin
          Frag := Line.Frags[I];
          OffsetRect(Frag.R, Extra, 0);
          if Frag.Box <> nil then
            OffsetBox(Frag.Box, Extra, 0);
        end;
    end;

    Box.Lines.Add(Line);
    Inc(CurY, LineH);
  end;

var
  I, PenX, LX, RX, EstH: Integer;
  It: TInlineItem;
  LastAdvance: Integer;
  Guard: Integer;
begin
  Box.Lines.Clear; // clear the previous layout (flex/grid re-measurement)
  Items := TObjectList<TInlineItem>.Create(True);
  try
    CurrentHref := '';
    CurrentTarget := '';
    CollectItems(Box.InlineNodes, Box.Style);

    CurY := Y;
    LineStart := 0;
    LastAdvance := Max(1, Round(Box.Style.FontSizePx * Box.Style.LineHeight));

    I := 0;
    PenX := -1;
    LX := CX;
    RX := CX + CW;
    while I < Items.Count do
    begin
      It := Items[I];

      if PenX < 0 then
      begin
        // start of a line — compute the bounds taking floats into account
        EstH := It.LineAdvance;
        Guard := 0;
        repeat
          GetLineBounds(CurY, Max(1, EstH), CX, CW, LX, RX);
          if (RX - LX >= Min(CW, Max(It.W, 30))) or (Guard > 50) or
             (NextFloatBottom(CurY) <= CurY) then
            Break;
          CurY := NextFloatBottom(CurY);
          Inc(Guard);
        until False;
        PenX := LX;
        // skip spaces at the beginning of a line
        if It.Kind = iiSpace then
        begin
          Inc(I);
          Continue;
        end;
      end;

      if It.Kind = iiBreak then
      begin
        EmitLine(LineStart, I, LastAdvance);
        LastAdvance := It.LineAdvance;
        LineStart := I + 1;
        PenX := -1;
        Inc(I);
        Continue;
      end;

      LastAdvance := Max(LastAdvance, It.LineAdvance);

      // does not fit — break the line (unless the line is empty)
      if (PenX + It.W > RX) and (It.Kind <> iiSpace) and (PenX > LX) and
         not It.Style.NoWrap then
      begin
        EmitLine(LineStart, I - 1, LastAdvance);
        LineStart := I;
        PenX := -1;
        Continue; // retry this item on a new line
      end;

      Inc(PenX, It.W);
      Inc(I);
    end;

    if LineStart < Items.Count then
      EmitLine(LineStart, Items.Count - 1, LastAdvance);

    Y := CurY;
  finally
    Items.Free;
  end;
end;

// ---- link hit-testing ----

function TLayoutEngine.HitTestLink(PageX, PageY: Integer): string;

  function ScanBox(Box: TLayoutBox): string;
  var
    I, J: Integer;
    Frag: TLineFrag;
  begin
    Result := '';
    // quick reject: outside the box and its possible float overflow
    if (PageY < Box.Y - 4) or (PageY > Box.Y + Box.H + 200) then
      Exit;
    for I := 0 to Box.Lines.Count - 1 do
      for J := 0 to Box.Lines[I].Frags.Count - 1 do
      begin
        Frag := Box.Lines[I].Frags[J];
        if (PageX >= Frag.R.Left) and (PageX < Frag.R.Right) and
           (PageY >= Frag.R.Top) and (PageY < Frag.R.Bottom) then
        begin
          if Frag.Href <> '' then
            Exit(Frag.Href);
          if Frag.Box <> nil then
          begin
            Result := ScanBox(Frag.Box);
            if Result <> '' then
              Exit;
          end;
        end;
      end;
    for I := 0 to Box.Children.Count - 1 do
    begin
      Result := ScanBox(Box.Children[I]);
      if Result <> '' then
        Exit;
    end;
  end;

begin
  Result := '';
  if Root <> nil then
    Result := ScanBox(Root);
end;

function TLayoutEngine.HitTest(PageX, PageY: Integer): THitInfo;
var
  HI: THitInfo;

  function Inside(const R: TRect): Boolean;
  begin
    Result := (PageX >= R.Left) and (PageX < R.Right) and
              (PageY >= R.Top) and (PageY < R.Bottom);
  end;

  procedure ScanBox(Box: TLayoutBox);
  var
    I, J: Integer;
    Frag: TLineFrag;
  begin
    if (PageY < Box.Y - 4) or (PageY > Box.Y + Box.H + 200) then
      Exit;
    // the block under the point (its background/padding count for :hover)
    if (Box.Element <> nil) and
       Inside(Rect(Box.X, Box.Y, Box.X + Box.W, Box.Y + Box.H)) then
    begin
      HI.Element := Box.Element;
      // block <img>
      if Box.Element.TagName = 'img' then
        HI.ImageUrl := Box.Element.GetAttribute('src');
    end;
    // children — deeper ones override the element
    for I := 0 to Box.Children.Count - 1 do
      ScanBox(Box.Children[I]);
    for I := 0 to Box.Lines.Count - 1 do
      for J := 0 to Box.Lines[I].Frags.Count - 1 do
      begin
        Frag := Box.Lines[I].Frags[J];
        if not Inside(Frag.R) then Continue;
        if Frag.Href <> '' then
        begin HI.LinkHref := Frag.Href; HI.LinkTarget := Frag.Target; end;
        case Frag.Kind of
          fkImage:
            begin HI.ImageUrl := Frag.Url; HI.Element := Frag.Element; end;
          fkControl:
            begin HI.IsControl := True; HI.Element := Frag.Element; end;
          fkText:
            if Frag.Element <> nil then HI.Element := Frag.Element;
        end;
        if Frag.Box <> nil then ScanBox(Frag.Box);
      end;
  end;

begin
  HI.Element := nil;
  HI.LinkHref := '';
  HI.LinkTarget := '';
  HI.ImageUrl := '';
  HI.IsControl := False;
  if Root <> nil then
    ScanBox(Root);
  Result := HI;
end;

function TLayoutEngine.CursorAt(PageX, PageY: Integer): TCssCursor;

  function ScanBox(Box: TLayoutBox): TCssCursor;
  var
    I, J: Integer;
    Frag: TLineFrag;
  begin
    Result := ccrAuto;
    if (PageY < Box.Y - 4) or (PageY > Box.Y + Box.H + 200) then
      Exit;
    // children first — the most specific cursor wins
    for I := 0 to Box.Children.Count - 1 do
    begin
      Result := ScanBox(Box.Children[I]);
      if Result <> ccrAuto then
        Exit;
    end;
    for I := 0 to Box.Lines.Count - 1 do
      for J := 0 to Box.Lines[I].Frags.Count - 1 do
      begin
        Frag := Box.Lines[I].Frags[J];
        if (PageX >= Frag.R.Left) and (PageX < Frag.R.Right) and
           (PageY >= Frag.R.Top) and (PageY < Frag.R.Bottom) then
        begin
          if Frag.Box <> nil then
          begin
            Result := ScanBox(Frag.Box);
            if Result <> ccrAuto then
              Exit;
          end;
          if (Frag.Style <> nil) and (Frag.Style.Cursor <> ccrAuto) then
            Exit(Frag.Style.Cursor);
        end;
      end;
    if (PageX >= Box.X) and (PageX < Box.X + Box.W) and
       (PageY >= Box.Y) and (PageY < Box.Y + Box.H) and
       (Box.Style <> nil) and (Box.Style.Cursor <> ccrAuto) then
      Result := Box.Style.Cursor;
  end;

begin
  Result := ccrAuto;
  if Root <> nil then
    Result := ScanBox(Root);
end;

function TLayoutEngine.FindAnchorY(const AnId: string; out AY: Integer): Boolean;
var
  Box: TLayoutBox;
begin
  AY := 0;
  Box := FindBoxById(AnId);
  if Box <> nil then
  begin
    AY := Box.Y;
    Exit(True);
  end;
  Result := FAnchors.TryGetValue(AnId, AY);
end;

function TLayoutEngine.FindBoxById(const AnId: string): TLayoutBox;

  function Scan(Box: TLayoutBox): TLayoutBox;
  var
    I, J: Integer;
    Frag: TLineFrag;
  begin
    Result := nil;
    if (Box.Element <> nil) and (Box.Element.GetId = AnId) then
      Exit(Box);
    for I := 0 to Box.Children.Count - 1 do
    begin
      Result := Scan(Box.Children[I]);
      if Result <> nil then
        Exit;
    end;
    for I := 0 to Box.Lines.Count - 1 do
      for J := 0 to Box.Lines[I].Frags.Count - 1 do
      begin
        Frag := Box.Lines[I].Frags[J];
        if Frag.Box <> nil then
        begin
          Result := Scan(Frag.Box);
          if Result <> nil then
            Exit;
        end;
      end;
  end;

begin
  Result := nil;
  if (Root <> nil) and (AnId <> '') then
    Result := Scan(Root);
end;

// ---- main pass ----

procedure TLayoutEngine.Run(Doc: TDOMDocument);
var
  Html: TDOMElement;
  BaseStyle: TComputedStyle;
  Y: Integer;
begin
  FreeAndNil(Root);
  FStyleMap.Clear;
  FStyles.Clear;
  FFloatCount := 0;
  FFontCache.Clear;
  FAnchors.Clear;
  FGenNodes.Clear;
  DocHeight := 0;
  DocWidth := 0;

  if Doc = nil then
    Exit;
  Html := Doc.DocumentElement;
  if Html = nil then
    Exit;

  BaseStyle := TComputedStyle.Create;
  FStyles.Add(BaseStyle);

  Root := BuildBlockBox(Html, BaseStyle);
  Y := 0;
  LayoutBlockBox(Root, 0, ViewportWidth, Y);
  PlaceFixedBoxes(Root);   // position:fixed relative to the viewport
  DocHeight := Max(Y, MaxFloatBottom);
  DocWidth := MeasureDocWidth(Root);
  // Note: overflow:hidden on <html> in a browser only HIDES the scrollbar —
  // the document keeps its full height, and anchor navigation (#top) still scrolls.
  // Acid2 assembles the face only after scrolling to #top (fixed skull + abs eyes/mouth
  // relative to .picture, which then lands at the top of the viewport). That is why we do NOT clamp
  // the height here — a clamp would make it impossible to reach #top.
end;

end.
