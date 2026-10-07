unit OTF;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// OTF.pas — font layer for the HTML browser.
//
// 1. Conversion: any web format (TTF, OTF, WOFF, WOFF2, SVG font)
//    -> SFNT/OpenType (.otf), using the font converter units (TTFParser, CFFBuilder, WOFF*...).
// 2. Temporary installation of an OTF font straight from memory (AddFontMemResourceEx)
//    without modifying the system and without temporary files.
// 3. Helper text renderer via GDI+ (anti-aliasing) that uses
//    a private font collection loaded from memory.
//
// The conversion is pure Pascal (font converter units) — no external
// programs or DLLs (except gdi32/gdiplus for installation and drawing).

interface

uses
  Classes, SysUtils, Math, Windows,
  FontTypes, TTFParser, CFFBuilder, WOFFCodec, WOFF2Codec, SVGFontReader;

type
  TFontFormat = (ffUnknown, ffTTF, ffOTF, ffTTC, ffWOFF, ffWOFF2, ffSVG);

  // Handle of a temporarily installed font. The Data field keeps a copy
  // of the OTF data — although GDI copies the font internally, we keep the buffer
  // for possible reuse (e.g. GDI+ rendering).
  TTempFont = record
    Handle: THandle;     // result of AddFontMemResourceEx (0 = not loaded)
    Data: TBytes;        // OTF/SFNT data
    Family: string;      // family name read from the 'name' table
  end;

// --- Format detection ---
function DetectFontFormat(Src: TStream): TFontFormat;
function DetectFontFormatBytes(const Data: TBytes): TFontFormat;
function FontFormatName(F: TFontFormat): string;

// --- Conversion to OTF/SFNT ---
// ForceCFF = True forces true OpenType CFF ('OTTO'): fonts based
// on 'glyf' outlines (TrueType) are re-encoded by CFFBuilder.
// ForceCFF = False (default) returns the closest valid SFNT with
// minimal transformation (highest fidelity, ideal for display).
function ConvertStreamToOTF(Src, Dst: TStream; ForceCFF: Boolean = False): Boolean;
function ConvertBytesToOTF(const Src: TBytes; out Dst: TBytes;
  ForceCFF: Boolean = False): Boolean;
function ConvertFileToOTF(const SrcFile, DstFile: string;
  ForceCFF: Boolean = False): Boolean;

// Reads the family name (nameID=1, prefers the Windows/Unicode record)
// from a ready SFNT. Returns '' if absent.
function ReadSfntFamilyName(const Sfnt: TBytes): string;

// --- Temporary installation of an OTF font from memory ---
function InstallTempFont(const OtfData: TBytes; out Font: TTempFont): Boolean;
// Convenience variant: any format -> OTF -> installation.
function InstallFontFromMemory(const Raw: TBytes; out Font: TTempFont): Boolean;
procedure UninstallTempFont(var Font: TTempFont);

// --- Rendering via GDI+ ---
// Draws text with an in-memory font (private GDI+ collection) on the given HDC.
// Does not require prior installation in GDI. EmSize in pixels,
// Color in 0x00RRGGBB format (alpha added automatically).
function GdiPlusReady: Boolean;
function DrawTextGdiPlusMem(DC: HDC; const FontData: TBytes;
  const FamilyName: WideString; const Text: WideString;
  X, Y, EmSize: Single; Color: LongWord;
  Bold: Boolean = False; Italic: Boolean = False): Boolean;

// --- Browser integration (persistent GDI+ collection) ---
//
// RegisterBrowserFont: registers an @font-face font for two purposes at once —
// in GDI (AddFontMemResourceEx, for text measurement) and in a persistent private
// GDI+ collection (for nice, anti-aliased drawing). CssFamily is
// the family name from the @font-face rule; InternalFamily returns the name from the
// 'name' table (associated with CssFamily for drawing).
function RegisterBrowserFont(const Raw: TBytes; const CssFamily: string;
  out InternalFamily: string): Boolean;

// DrawTextGdiPlus: draws text on a DC at the baseline position (X, BaselineY).
// FamilyName may be an @font-face family or a system font — lookup order:
// private collection (by CssFamily and internal name) -> system.
// EmSizePx = font height in px, ColorRef in TColor format (0x00BBGGRR).
// GdiAdvances=True places every glyph at the advance of the GDI font currently
// selected into DC (GetTextExtentExPoint), so the drawn text has exactly the
// width the layout measured with GDI; otherwise GDI+ uses its own (unhinted)
// advances, which can be a few px wider and eat the following space.
// Returns False if drawing failed — the caller should fall back to GDI.
function DrawTextGdiPlus(DC: HDC; const FamilyName: string; EmSizePx: Integer;
  Bold, Italic: Boolean; ColorRef: LongWord; X, BaselineY: Single;
  const Text: string; GdiAdvances: Boolean = False): Boolean;

implementation

// =============================================================
// Format detection
// =============================================================

function DetectFontFormatBytes(const Data: TBytes): TFontFormat;
var
  Tag: LongWord;
  I: Integer;
begin
  Result := ffUnknown;
  if Length(Data) < 4 then Exit;
  Tag := (LongWord(Data[0]) shl 24) or (LongWord(Data[1]) shl 16) or
         (LongWord(Data[2]) shl 8)  or  LongWord(Data[3]);
  case Tag of
    $774F4646: Result := ffWOFF;          // 'wOFF'
    $774F4632: Result := ffWOFF2;         // 'wOF2'
    $4F54544F: Result := ffOTF;           // 'OTTO' (CFF OpenType)
    $74746366: Result := ffTTC;           // 'ttcf' (TrueType collection)
    $00010000,
    $74727565,                            // 'true'
    $74797031: Result := ffTTF;           // 'typ1'
  else
    // SVG font: starts with '<' (after an optional BOM/whitespace)
    for I := 0 to Min(Length(Data) - 1, 64) do
    begin
      if Data[I] in [9, 10, 13, 32, $EF, $BB, $BF] then Continue;
      if Data[I] = Ord('<') then Result := ffSVG;
      Break;
    end;
  end;
end;

function DetectFontFormat(Src: TStream): TFontFormat;
var
  Head: TBytes;
  N: Integer;
  Pos0: Int64;
begin
  Pos0 := Src.Position;
  SetLength(Head, 64);
  N := Src.Read(Head[0], 64);
  SetLength(Head, N);
  Src.Position := Pos0;
  Result := DetectFontFormatBytes(Head);
end;

function FontFormatName(F: TFontFormat): string;
begin
  case F of
    ffTTF:   Result := 'TTF';
    ffOTF:   Result := 'OTF';
    ffTTC:   Result := 'TTC';
    ffWOFF:  Result := 'WOFF';
    ffWOFF2: Result := 'WOFF2';
    ffSVG:   Result := 'SVG';
  else
    Result := 'unknown';
  end;
end;

// =============================================================
// Conversion to OTF/SFNT
// =============================================================

// TrueType (glyf) SFNT -> CFF OpenType ('OTTO') via CFFBuilder.
procedure TTFStreamToOTF(Src, Dst: TStream);
var
  Parser: TTTFParser;
  Builder: TCFFBuilder;
begin
  Src.Position := 0;
  Parser := TTTFParser.Create(Src, False);
  try
    Parser.Parse;
    Builder := TCFFBuilder.Create(Parser);
    try
      Builder.BuildOTF(Dst);
    finally
      Builder.Free;
    end;
  finally
    Parser.Free;
  end;
end;

// If the SFNT is based on 'glyf' (TrueType) and ForceCFF=True, re-encode
// to CFF; otherwise copy it unchanged.
procedure EmitSfnt(Sfnt: TStream; Dst: TStream; ForceCFF: Boolean);
var
  Fmt: TFontFormat;
  Tmp: TMemoryStream;
begin
  Sfnt.Position := 0;
  Fmt := DetectFontFormat(Sfnt);
  Sfnt.Position := 0;
  if ForceCFF and (Fmt in [ffTTF, ffTTC]) then
  begin
    Tmp := TMemoryStream.Create;
    try
      Tmp.CopyFrom(Sfnt, 0);
      Tmp.Position := 0;
      TTFStreamToOTF(Tmp, Dst);
    finally
      Tmp.Free;
    end;
  end
  else
  begin
    Sfnt.Position := 0;
    Dst.CopyFrom(Sfnt, 0);
  end;
end;

function ConvertStreamToOTF(Src, Dst: TStream; ForceCFF: Boolean): Boolean;
var
  Fmt: TFontFormat;
  Sfnt: TMemoryStream;
begin
  Result := False;
  Fmt := DetectFontFormat(Src);
  Src.Position := 0;
  try
    case Fmt of
      ffOTF:
        begin
          Dst.CopyFrom(Src, 0);             // already CFF OpenType
          Result := True;
        end;

      ffTTF, ffTTC:
        begin
          if ForceCFF then
            TTFStreamToOTF(Src, Dst)
          else
            Dst.CopyFrom(Src, 0);           // glyf SFNT — installable
          Result := True;
        end;

      ffWOFF:
        begin
          Sfnt := TMemoryStream.Create;
          try
            WOFFToOTF(Src, Sfnt);           // table decompression
            EmitSfnt(Sfnt, Dst, ForceCFF);
          finally
            Sfnt.Free;
          end;
          Result := True;
        end;

      ffWOFF2:
        begin
          Sfnt := TMemoryStream.Create;
          try
            WOFF2ToOTF(Src, Sfnt);          // Brotli decoder
            EmitSfnt(Sfnt, Dst, ForceCFF);
          finally
            Sfnt.Free;
          end;
          Result := True;
        end;

      ffSVG:
        begin
          SVGFontToOTF(Src, Dst);           // builds CFF OpenType
          Result := True;
        end;
    end;
  except
    Result := False;
  end;
end;

function ConvertBytesToOTF(const Src: TBytes; out Dst: TBytes;
  ForceCFF: Boolean): Boolean;
var
  SrcS, DstS: TMemoryStream;
begin
  Dst := nil;
  SrcS := TMemoryStream.Create;
  DstS := TMemoryStream.Create;
  try
    if Length(Src) > 0 then
      SrcS.WriteBuffer(Src[0], Length(Src));
    SrcS.Position := 0;
    Result := ConvertStreamToOTF(SrcS, DstS, ForceCFF);
    if Result and (DstS.Size > 0) then
    begin
      SetLength(Dst, DstS.Size);
      DstS.Position := 0;
      DstS.ReadBuffer(Dst[0], DstS.Size);
    end
    else
      Result := False;
  finally
    SrcS.Free;
    DstS.Free;
  end;
end;

function ConvertFileToOTF(const SrcFile, DstFile: string;
  ForceCFF: Boolean): Boolean;
var
  SrcS, DstS: TFileStream;
begin
  SrcS := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  try
    DstS := TFileStream.Create(DstFile, fmCreate);
    try
      Result := ConvertStreamToOTF(SrcS, DstS, ForceCFF);
    finally
      DstS.Free;
    end;
  finally
    SrcS.Free;
  end;
  if not Result then
    SysUtils.DeleteFile(DstFile);
end;

// =============================================================
// Reading the family name from the 'name' table
// =============================================================

function BU16(const D: TBytes; O: Integer): Word; inline;
begin
  if O + 1 < Length(D) then
    Result := (Word(D[O]) shl 8) or D[O + 1]
  else
    Result := 0;
end;

function BU32(const D: TBytes; O: Integer): LongWord; inline;
begin
  if O + 3 < Length(D) then
    Result := (LongWord(D[O]) shl 24) or (LongWord(D[O + 1]) shl 16) or
              (LongWord(D[O + 2]) shl 8) or D[O + 3]
  else
    Result := 0;
end;

function ReadSfntFamilyName(const Sfnt: TBytes): string;
var
  NumTables, I: Integer;
  Tag, Ofs, Len: LongWord;
  NameOfs, NameLen: LongWord;
  Count, StrOfs, Rec: Integer;
  PlatID, EncID, NameID, RLen, ROfs: Word;
  BestScore, Score, J: Integer;
  Best: string;
  W: WideString;
begin
  Result := '';
  if Length(Sfnt) < 12 then Exit;
  NumTables := BU16(Sfnt, 4);
  NameOfs := 0; NameLen := 0;
  for I := 0 to NumTables - 1 do
  begin
    Tag := BU32(Sfnt, 12 + I * 16);
    Ofs := BU32(Sfnt, 12 + I * 16 + 8);
    Len := BU32(Sfnt, 12 + I * 16 + 12);
    if Tag = $6E616D65 then   // 'name'
    begin
      NameOfs := Ofs; NameLen := Len; Break;
    end;
  end;
  if (NameOfs = 0) or (NameOfs + 6 > LongWord(Length(Sfnt))) then Exit;

  Count := BU16(Sfnt, NameOfs + 2);
  StrOfs := BU16(Sfnt, NameOfs + 4);
  BestScore := -1;
  Best := '';
  for Rec := 0 to Count - 1 do
  begin
    J := NameOfs + 6 + Rec * 12;
    if J + 12 > Length(Sfnt) then Break;
    PlatID := BU16(Sfnt, J);
    EncID  := BU16(Sfnt, J + 2);
    NameID := BU16(Sfnt, J + 6);
    RLen   := BU16(Sfnt, J + 8);
    ROfs   := BU16(Sfnt, J + 10);
    if NameID <> 1 then Continue;          // 1 = Font Family
    // preference: Windows/Unicode > Mac/Roman
    if (PlatID = 3) then Score := 3
    else if (PlatID = 0) then Score := 2
    else if (PlatID = 1) then Score := 1
    else Score := 0;
    if Score <= BestScore then Continue;

    if NameOfs + StrOfs + ROfs + RLen > LongWord(Length(Sfnt)) then Continue;
    if (PlatID = 3) or (PlatID = 0) then
    begin
      // UTF-16 BE
      SetLength(W, RLen div 2);
      for I := 0 to (RLen div 2) - 1 do
        W[I + 1] := WideChar((Word(Sfnt[NameOfs + StrOfs + ROfs + I * 2]) shl 8) or
                              Sfnt[NameOfs + StrOfs + ROfs + I * 2 + 1]);
      Best := UTF8Encode(W);
    end
    else
    begin
      // ASCII / Mac Roman
      SetLength(Best, RLen);
      for I := 0 to RLen - 1 do
        Best[I + 1] := Chr(Sfnt[NameOfs + StrOfs + ROfs + I]);
    end;
    BestScore := Score;
  end;
  Result := Best;
end;

// =============================================================
// Temporary font installation from memory
// =============================================================

function GdiAddFontMemResourceEx(pbFont: Pointer; cbFont: DWORD;
  pdv: Pointer; pcFonts: PDWORD): THandle; stdcall;
  external 'gdi32.dll' name 'AddFontMemResourceEx';
function GdiRemoveFontMemResourceEx(fh: THandle): LongBool; stdcall;
  external 'gdi32.dll' name 'RemoveFontMemResourceEx';

function InstallTempFont(const OtfData: TBytes; out Font: TTempFont): Boolean;
var
  Cnt: DWORD;
begin
  Font.Handle := 0;
  Font.Data := nil;
  Font.Family := '';
  Result := False;
  if Length(OtfData) = 0 then Exit;

  Font.Data := Copy(OtfData, 0, Length(OtfData));
  Cnt := 0;
  Font.Handle := GdiAddFontMemResourceEx(@Font.Data[0], Length(Font.Data),
    nil, @Cnt);
  if (Font.Handle <> 0) and (Cnt > 0) then
  begin
    Font.Family := ReadSfntFamilyName(Font.Data);
    Result := True;
  end
  else
  begin
    Font.Handle := 0;
    Font.Data := nil;
  end;
end;

function InstallFontFromMemory(const Raw: TBytes; out Font: TTempFont): Boolean;
var
  Otf: TBytes;
begin
  if not ConvertBytesToOTF(Raw, Otf) then
    Otf := Raw;                            // attempt: maybe it is already an SFNT
  Result := InstallTempFont(Otf, Font);
end;

procedure UninstallTempFont(var Font: TTempFont);
begin
  if Font.Handle <> 0 then
    GdiRemoveFontMemResourceEx(Font.Handle);
  Font.Handle := 0;
  Font.Data := nil;
  Font.Family := '';
end;

// =============================================================
// Rendering via GDI+ (gdiplus.dll, flat API)
// =============================================================

type
  GpStatus           = Integer;
  GpGraphics         = Pointer;
  GpBrush            = Pointer;
  GpFontCollection   = Pointer;
  GpFontFamily       = Pointer;
  GpFont             = Pointer;
  GpStringFormat     = Pointer;
  ARGB               = LongWord;
  ULONG_PTR          = PtrUInt;

  TGdiplusStartupInput = record
    GdiplusVersion: LongWord;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: LongBool;
    SuppressExternalCodecs: LongBool;
  end;

  TGpRectF = record
    X, Y, Width, Height: Single;
  end;

  TGpPointF = record
    X, Y: Single;
  end;

const
  UnitPixel                  = 2;
  FontStyleRegular           = 0;
  FontStyleBold              = 1;
  FontStyleItalic            = 2;
  TextRenderingHintAntiAlias = 4;

function GdiplusStartup(out token: ULONG_PTR;
  const input: TGdiplusStartupInput; output: Pointer): GpStatus; stdcall;
  external 'gdiplus.dll';
procedure GdiplusShutdown(token: ULONG_PTR); stdcall;
  external 'gdiplus.dll';
function GdipCreateFromHDC(hdc: HDC; out graphics: GpGraphics): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDeleteGraphics(graphics: GpGraphics): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipSetTextRenderingHint(graphics: GpGraphics; mode: Integer): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipCreateSolidFill(color: ARGB; out brush: GpBrush): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDeleteBrush(brush: GpBrush): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipNewPrivateFontCollection(out fc: GpFontCollection): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDeletePrivateFontCollection(var fc: GpFontCollection): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipPrivateAddMemoryFont(fc: GpFontCollection; memory: Pointer;
  length: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipGetFontCollectionFamilyCount(fc: GpFontCollection;
  out numFound: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipGetFontCollectionFamilyList(fc: GpFontCollection; numSought: Integer;
  gpfamilies: Pointer; out numFound: Integer): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipCreateFontFamilyFromName(name: PWideChar; fc: GpFontCollection;
  out fontFamily: GpFontFamily): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDeleteFontFamily(family: GpFontFamily): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipCreateFont(family: GpFontFamily; emSize: Single; style: Integer;
  unit_: Integer; out font: GpFont): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDeleteFont(font: GpFont): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDrawString(graphics: GpGraphics; text: PWideChar; length: Integer;
  font: GpFont; const layoutRect: TGpRectF; stringFormat: GpStringFormat;
  brush: GpBrush): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDrawDriverString(graphics: GpGraphics; const text: PWideChar;
  length: Integer; font: GpFont; brush: GpBrush; const positions: TGpPointF;
  flags: Integer; matrix: Pointer): GpStatus; stdcall; external 'gdiplus.dll';
const
  // DrawDriverString: the text is Unicode characters (CmapLookup), and GDI+ itself
  // computes the glyph advances (RealizedAdvance) relative to the base point
  DriverStringOptionsCmapLookup     = 1;
  DriverStringOptionsRealizedAdvance = 4;
  TextRenderingHintAntiAliasGridFit = 3;

var
  GToken: ULONG_PTR = 0;
  GReady: Boolean = False;
  GTriedInit: Boolean = False;

function GdiPlusReady: Boolean;
var
  Inp: TGdiplusStartupInput;
begin
  if not GTriedInit then
  begin
    GTriedInit := True;
    FillChar(Inp, SizeOf(Inp), 0);
    Inp.GdiplusVersion := 1;
    GReady := GdiplusStartup(GToken, Inp, nil) = 0;
  end;
  Result := GReady;
end;

function DrawTextGdiPlusMem(DC: HDC; const FontData: TBytes;
  const FamilyName: WideString; const Text: WideString;
  X, Y, EmSize: Single; Color: LongWord; Bold, Italic: Boolean): Boolean;
var
  G: GpGraphics;
  Brush: GpBrush;
  FC: GpFontCollection;
  Family: GpFontFamily;
  Fnt: GpFont;
  R: TGpRectF;
  Style, FamCount, GotCount: Integer;
  Fams: array of GpFontFamily;
begin
  Result := False;
  if (Length(FontData) = 0) or (Text = '') then Exit;
  if not GdiPlusReady then Exit;

  G := nil; Brush := nil; FC := nil; Family := nil; Fnt := nil;
  Fams := nil;
  try
    if GdipCreateFromHDC(DC, G) <> 0 then Exit;
    GdipSetTextRenderingHint(G, TextRenderingHintAntiAlias);

    if GdipNewPrivateFontCollection(FC) <> 0 then Exit;
    if GdipPrivateAddMemoryFont(FC, @FontData[0], Length(FontData)) <> 0 then Exit;

    // try by name; if missing — the first family in the collection
    if (FamilyName = '') or
       (GdipCreateFontFamilyFromName(PWideChar(FamilyName), FC, Family) <> 0) then
    begin
      Family := nil;
      FamCount := 0;
      if (GdipGetFontCollectionFamilyCount(FC, FamCount) = 0) and (FamCount > 0) then
      begin
        SetLength(Fams, FamCount);
        if GdipGetFontCollectionFamilyList(FC, FamCount, @Fams[0], GotCount) = 0 then
          if GotCount > 0 then
            Family := Fams[0];
      end;
    end;
    if Family = nil then Exit;

    Style := FontStyleRegular;
    if Bold then Style := Style or FontStyleBold;
    if Italic then Style := Style or FontStyleItalic;

    if GdipCreateFont(Family, EmSize, Style, UnitPixel, Fnt) <> 0 then Exit;

    if GdipCreateSolidFill(ARGB($FF000000 or (Color and $00FFFFFF)), Brush) <> 0 then Exit;

    R.X := X; R.Y := Y; R.Width := 0; R.Height := 0;  // 0 = no wrapping
    Result := GdipDrawString(G, PWideChar(Text), Length(Text), Fnt, R, nil, Brush) = 0;
  finally
    if Fnt <> nil then GdipDeleteFont(Fnt);
    // families from the list are owned by the collection — not freed individually;
    // a family from CreateFontFamilyFromName must be freed
    if (Family <> nil) and (Length(Fams) = 0) then GdipDeleteFontFamily(Family);
    if Brush <> nil then GdipDeleteBrush(Brush);
    if FC <> nil then GdipDeletePrivateFontCollection(FC);
    if G <> nil then GdipDeleteGraphics(G);
  end;
end;

// =============================================================
// Persistent @font-face font collection + cache of GDI+ families/fonts
// =============================================================

var
  GCollection: GpFontCollection = nil;   // private @font-face collection
  GFontData: array of TBytes;            // buffers must live as long as the collection
  GCssMap: TStringList = nil;            // CssFamily=InternalFamily
  GFamilyCache: TStringList = nil;       // name -> GpFontFamily (Object)
  GFontCache: TStringList = nil;         // 'name|px|style' -> GpFont (Object)

function WS(const S: string): WideString; inline;
begin
  Result := UTF8Decode(S);
end;

procedure EnsureCaches;
begin
  if GCssMap = nil then
  begin
    GCssMap := TStringList.Create;
    GCssMap.CaseSensitive := False;
    GFamilyCache := TStringList.Create;
    GFamilyCache.CaseSensitive := False;
    GFontCache := TStringList.Create;
    GFontCache.CaseSensitive := False;
  end;
end;

// Invalidates the cache of resolved GDI+ families/fonts. Required after adding
// a new font: the first render (before @font-face was downloaded) stores
// "not found" (nil) in the cache, which would otherwise make the missing font permanent.
procedure ClearResolveCaches;
var
  I: Integer;
begin
  if GFontCache <> nil then
  begin
    for I := 0 to GFontCache.Count - 1 do
      if GFontCache.Objects[I] <> nil then
        GdipDeleteFont(GpFont(Pointer(GFontCache.Objects[I])));
    GFontCache.Clear;
  end;
  if GFamilyCache <> nil then
  begin
    for I := 0 to GFamilyCache.Count - 1 do
      if GFamilyCache.Objects[I] <> nil then
        GdipDeleteFontFamily(GpFontFamily(Pointer(GFamilyCache.Objects[I])));
    GFamilyCache.Clear;
  end;
end;

function RegisterBrowserFont(const Raw: TBytes; const CssFamily: string;
  out InternalFamily: string): Boolean;
var
  Otf: TBytes;
  Cnt: DWORD;
  N: Integer;
begin
  Result := False;
  InternalFamily := '';
  if Length(Raw) = 0 then Exit;

  // any format -> OTF/SFNT
  if not ConvertBytesToOTF(Raw, Otf) then
    Otf := Raw;
  if Length(Otf) = 0 then Exit;

  // 1) GDI — for text measurement in the layout engine
  Cnt := 0;
  if GdiAddFontMemResourceEx(@Otf[0], Length(Otf), nil, @Cnt) = 0 then Exit;
  Result := True;
  InternalFamily := ReadSfntFamilyName(Otf);

  // 2) GDI+ — persistent private collection for drawing.
  //    GdipPrivateAddMemoryFont does NOT copy the data, so we keep the buffer.
  if GdiPlusReady then
  begin
    EnsureCaches;
    if GCollection = nil then
      if GdipNewPrivateFontCollection(GCollection) <> 0 then
        GCollection := nil;
    if GCollection <> nil then
    begin
      N := Length(GFontData);
      SetLength(GFontData, N + 1);
      GFontData[N] := Otf;   // keep the reference
      GdipPrivateAddMemoryFont(GCollection, @GFontData[N][0], Length(GFontData[N]));
      // associate the CSS name with the font's internal name
      if (CssFamily <> '') and (GCssMap.IndexOfName(CssFamily) < 0) then
        GCssMap.Add(CssFamily + '=' + InternalFamily);
      // new font — drop any "not found" entries from the cache
      ClearResolveCaches;
    end;
  end;
end;

// Returns the GDI+ family for the given name (cached). nil = not found.
function ResolveFamily(const Name: string): GpFontFamily;
var
  Idx: Integer;
  Fam: GpFontFamily;
  Internal: string;
begin
  EnsureCaches;
  Idx := GFamilyCache.IndexOf(Name);
  if Idx >= 0 then
    Exit(GpFontFamily(Pointer(GFamilyCache.Objects[Idx])));

  Fam := nil;
  // a) private collection by the internal name associated with CssFamily
  if GCollection <> nil then
  begin
    Internal := GCssMap.Values[Name];
    if (Internal <> '') and
       (GdipCreateFontFamilyFromName(PWideChar(WS(Internal)), GCollection, Fam) <> 0) then
      Fam := nil;
    // b) private collection by the name itself
    if (Fam = nil) and
       (GdipCreateFontFamilyFromName(PWideChar(WS(Name)), GCollection, Fam) <> 0) then
      Fam := nil;
  end;
  // c) system font
  if Fam = nil then
    if GdipCreateFontFamilyFromName(PWideChar(WS(Name)), nil, Fam) <> 0 then
      Fam := nil;

  GFamilyCache.AddObject(Name, TObject(Pointer(Fam)));
  Result := Fam;
end;

function ResolveFont(const Name: string; EmSizePx: Integer;
  Bold, Italic: Boolean): GpFont;
var
  Style, Idx: Integer;
  Key: string;
  Fam: GpFontFamily;
  Fnt: GpFont;
begin
  EnsureCaches;
  Style := FontStyleRegular;
  if Bold then Style := Style or FontStyleBold;
  if Italic then Style := Style or FontStyleItalic;
  Key := Name + '|' + IntToStr(EmSizePx) + '|' + IntToStr(Style);

  Idx := GFontCache.IndexOf(Key);
  if Idx >= 0 then
    Exit(GpFont(Pointer(GFontCache.Objects[Idx])));

  Fnt := nil;
  Fam := ResolveFamily(Name);
  if Fam <> nil then
    if GdipCreateFont(Fam, EmSizePx, Style, UnitPixel, Fnt) <> 0 then
      Fnt := nil;

  GFontCache.AddObject(Key, TObject(Pointer(Fnt)));
  Result := Fnt;
end;

function DrawTextGdiPlus(DC: HDC; const FamilyName: string; EmSizePx: Integer;
  Bold, Italic: Boolean; ColorRef: LongWord; X, BaselineY: Single;
  const Text: string; GdiAdvances: Boolean): Boolean;
var
  G: GpGraphics;
  Brush: GpBrush;
  Fnt: GpFont;
  Origin: TGpPointF;
  W: WideString;
  ColArgb: ARGB;
  Ext: array of Integer;
  Pts: array of TGpPointF;
  Sz: TSize;
  I: Integer;
begin
  Result := False;
  if (Text = '') or (EmSizePx <= 0) then Exit;
  if not GdiPlusReady then Exit;

  Fnt := ResolveFont(FamilyName, EmSizePx, Bold, Italic);
  if Fnt = nil then Exit;

  W := UTF8Decode(Text);
  if W = '' then Exit;

  // TColor (0x00BBGGRR) -> ARGB (0xAARRGGBB)
  ColArgb := $FF000000 or
          ((ColorRef and $000000FF) shl 16) or
          (ColorRef and $0000FF00) or
          ((ColorRef and $00FF0000) shr 16);

  G := nil; Brush := nil;
  try
    if GdipCreateFromHDC(DC, G) <> 0 then Exit;
    GdipSetTextRenderingHint(G, TextRenderingHintAntiAlias);
    if GdipCreateSolidFill(ColArgb, Brush) <> 0 then Exit;

    Pts := nil;
    if GdiAdvances then
    begin
      // Ext[I] = GDI extent of the first I+1 characters -> origin of character I+1
      SetLength(Ext, Length(W));
      if GetTextExtentExPointW(DC, PWideChar(W), Length(W), 0, nil,
           @Ext[0], @Sz) then
      begin
        SetLength(Pts, Length(W));
        for I := 0 to High(Pts) do
        begin
          if I = 0 then
            Pts[I].X := X
          else
            Pts[I].X := X + Ext[I - 1];
          Pts[I].Y := BaselineY;
        end;
      end;
    end;
    if Pts <> nil then
      Result := GdipDrawDriverString(G, PWideChar(W), Length(W), Fnt, Brush,
        Pts[0], DriverStringOptionsCmapLookup, nil) = 0
    else
    begin
      Origin.X := X;
      Origin.Y := BaselineY;   // DrawDriverString draws from the baseline
      Result := GdipDrawDriverString(G, PWideChar(W), Length(W), Fnt, Brush,
        Origin, DriverStringOptionsCmapLookup or DriverStringOptionsRealizedAdvance,
        nil) = 0;
    end;
  finally
    if Brush <> nil then GdipDeleteBrush(Brush);
    if G <> nil then GdipDeleteGraphics(G);
  end;
end;

procedure FreeGdiPlusCaches;
var
  I: Integer;
begin
  if GFontCache <> nil then
  begin
    for I := 0 to GFontCache.Count - 1 do
      if GFontCache.Objects[I] <> nil then
        GdipDeleteFont(GpFont(Pointer(GFontCache.Objects[I])));
    FreeAndNil(GFontCache);
  end;
  if GFamilyCache <> nil then
  begin
    for I := 0 to GFamilyCache.Count - 1 do
      if GFamilyCache.Objects[I] <> nil then
        GdipDeleteFontFamily(GpFontFamily(Pointer(GFamilyCache.Objects[I])));
    FreeAndNil(GFamilyCache);
  end;
  FreeAndNil(GCssMap);
  if GCollection <> nil then
    GdipDeletePrivateFontCollection(GCollection);
  GCollection := nil;
  GFontData := nil;
end;

initialization

finalization
  FreeGdiPlusCaches;
  if GReady and (GToken <> 0) then
    GdiplusShutdown(GToken);

end.
