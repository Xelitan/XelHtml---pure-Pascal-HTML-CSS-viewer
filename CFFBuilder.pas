unit CFFBuilder;

{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Math, FontTypes, TTFParser;
{$WARN 5093 off}  // suppress "function result variable of managed type not initialized"

// Author: www.xelitan.com
// License: MIT
//
// Builds a CFF (Compact Font Format) table and assembles a complete
// CFF-based OpenType font from a parsed TTF.
//
// CFF layout:
//   Header | Name INDEX | Top DICT INDEX | String INDEX |
//   Global Subr INDEX (empty) | Charset | CharStrings INDEX | Private DICT
//
// All Top DICT offset fields use the 5-byte integer encoding (opcode $1D)
// so the Top DICT size is fixed before downstream offsets are known.

type
  TCFFBuilder = class
  private
    FParser     : TTTFParser;
    FFontName   : string;
    FGlyphs     : TGlyphDataArray;
    FHMetrics   : THMetricArray;
    FNumGlyphs  : Word;
    FUnitsPerEm : Word;
    FXMin, FYMin, FXMax, FYMax : SmallInt;
    FEmScale    : Double;   // 1000.0 / FUnitsPerEm; 1.0 when UPM already = 1000

    procedure ExtractFontName;

    // Type 2 number encoding (same encoding used for CFF DICT values)
    procedure EncNum (S : TStream; V : LongInt);
    procedure EncNum5(S : TStream; V : LongInt); // always 5 bytes for patchable fields

    // CFF DICT operator emit helpers
    procedure DictOp (S : TStream; Op : Byte);

    // CFF charstring generator
    procedure BuildCharString(GID : Word; S : TStream);

    // CFF structural builders
    procedure WriteINDEX(Dest : TStream; const Entries : array of TBytes);

    function BuildNameINDEX   : TBytes;
    function BuildStringINDEX(out SIDBase : Word) : TBytes;
    function BuildCharset     : TBytes;
    function BuildCharStrings : TBytes;
    function BuildPrivateDict : TBytes;
    function BuildTopDict(CharsetOfs, CharStrOfs,
                           PrivSize, PrivOfs : LongWord;
                           FullSID, FamSID, WtSID : Word) : TBytes;

    function  WrapINDEX(const Entry : TBytes) : TBytes;
  public
    constructor Create(AParser : TTTFParser);
    // Alternative constructor: build directly from glyph data, with no source
    // TTF parser (used by the SVG-font importer).  Only BuildCFF is valid on an
    // instance created this way; BuildOTF requires a parser and must not be used.
    constructor CreateFromData(const AGlyphs : TGlyphDataArray;
                               const AHMetrics : THMetricArray;
                               ANumGlyphs, AUnitsPerEm : Word;
                               AXMin, AYMin, AXMax, AYMax : SmallInt;
                               const AFontName : string);

    function  BuildCFF : TBytes;
    procedure BuildOTF(Dst : TStream);
  end;

implementation

// ================================================================
// Constructor
// ================================================================

constructor TCFFBuilder.Create(AParser : TTTFParser);
begin
  inherited Create;
  FParser     := AParser;
  FGlyphs     := AParser.Glyphs;
  FHMetrics   := AParser.HMetrics;
  FNumGlyphs  := AParser.NumGlyphs;
  FUnitsPerEm := AParser.UnitsPerEm;
  FXMin       := AParser.XMin;
  FYMin       := AParser.YMin;
  FXMax       := AParser.XMax;
  FYMax       := AParser.YMax;
  FEmScale    := 1000.0 / FUnitsPerEm;   // scale factor; 1.0 when UPM = 1000
  FFontName   := 'UnknownFont';
  ExtractFontName;
end;

constructor TCFFBuilder.CreateFromData(const AGlyphs : TGlyphDataArray;
                                       const AHMetrics : THMetricArray;
                                       ANumGlyphs, AUnitsPerEm : Word;
                                       AXMin, AYMin, AXMax, AYMax : SmallInt;
                                       const AFontName : string);
begin
  inherited Create;
  FParser     := nil;
  FGlyphs     := AGlyphs;
  FHMetrics   := AHMetrics;
  FNumGlyphs  := ANumGlyphs;
  if AUnitsPerEm = 0 then AUnitsPerEm := 1000;
  FUnitsPerEm := AUnitsPerEm;
  FXMin       := AXMin;
  FYMin       := AYMin;
  FXMax       := AXMax;
  FYMax       := AYMax;
  FEmScale    := 1000.0 / FUnitsPerEm;
  if AFontName <> '' then FFontName := AFontName else FFontName := 'ConvertedFont';
end;

procedure TCFFBuilder.ExtractFontName;
// Read PostScript name (nameID=6) from the name table if available.
// Platform 1 (Mac) entries are ASCII; Platform 3 (Windows) entries
// are UTF-16BE — we only use Platform 1 here for simplicity.
var
  Raw    : TBytes;
  MS     : TMemoryStream;
  Count  : Word;
  StrOfs : Word;
  J      : Integer;
  PlatID, LangID, NameID, SLen, SOfs : Word;
  S      : string;
begin
  Raw := FParser.RawTable(TAG_NAME);
  if Length(Raw) < 6 then Exit;
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(Raw[0], Length(Raw));
    MS.Position := 0;
    ReadU16(MS);            // format
    Count  := ReadU16(MS);
    StrOfs := ReadU16(MS);
    for J := 0 to Count - 1 do
    begin
      PlatID := ReadU16(MS); ReadU16(MS);  // EncID - not needed
      LangID := ReadU16(MS); NameID := ReadU16(MS);
      SLen   := ReadU16(MS); SOfs   := ReadU16(MS);
      if (NameID = 6) and (PlatID = 1) and (LangID = 0) and (SLen > 0) then
      begin
        if LongWord(StrOfs + SOfs + SLen) <= LongWord(Length(Raw)) then
        begin
          SetLength(S, SLen);
          Move(Raw[StrOfs + SOfs], S[1], SLen);
          S := StringReplace(S, ' ', '', [rfReplaceAll]);
          if S <> '' then FFontName := S;
        end;
        Break;
      end;
    end;
  finally
    MS.Free;
  end;
end;

// ================================================================
// Number encoding  (Type 2 / CFF DICT — identical encoding)
// ================================================================

procedure TCFFBuilder.EncNum(S : TStream; V : LongInt);
var B : array[0..4] of Byte;
    U : LongWord;
begin
  if (V >= -107) and (V <= 107) then
  begin
    B[0] := Byte(V + 139); S.WriteBuffer(B[0], 1);
  end
  else if (V >= 108) and (V <= 1131) then
  begin
    U    := LongWord(V - 108);
    B[0] := Byte(U shr 8) + 247; B[1] := Byte(U and $FF);
    S.WriteBuffer(B, 2);
  end
  else if (V >= -1131) and (V <= -108) then
  begin
    U    := LongWord(-V - 108);
    B[0] := Byte(U shr 8) + 251; B[1] := Byte(U and $FF);
    S.WriteBuffer(B, 2);
  end
  else if (V >= -32768) and (V <= 32767) then
  begin
    B[0] := 28; B[1] := (V shr 8) and $FF; B[2] := V and $FF;
    S.WriteBuffer(B, 3);
  end
  else
  begin
    B[0] := 29;
    B[1] := (V shr 24) and $FF; B[2] := (V shr 16) and $FF;
    B[3] := (V shr  8) and $FF; B[4] :=  V         and $FF;
    S.WriteBuffer(B, 5);
  end;
end;

procedure TCFFBuilder.EncNum5(S : TStream; V : LongInt);
var B : array[0..4] of Byte;
begin
  B[0] := 29;
  B[1] := (V shr 24) and $FF; B[2] := (V shr 16) and $FF;
  B[3] := (V shr  8) and $FF; B[4] :=  V         and $FF;
  S.WriteBuffer(B, 5);
end;

procedure TCFFBuilder.DictOp(S : TStream; Op : Byte);
begin
  S.WriteBuffer(Op, 1);
end;

// ================================================================
// Type 2 charstring generator
// ================================================================
//
// Per-glyph charstring layout:
//   [advanceWidth]  rmoveto
//   rmoveto, then rlineto/rrcurveto*
//   endchar
//
// Contour points from QuadToCubic alternate:
//   on, [off off on]*, ...
// where [off off on] is one cubic Bezier arc and [on] is a line end.
// The CFF contour closes implicitly.

procedure TCFFBuilder.BuildCharString(GID : Word; S : TStream);
var
  GD        : TGlyphData;
  HM        : THMetric;
  CurX, CurY : Single;
  CI, PI    : Integer;
  C         : TCubicContour;
  Op        : Byte;

  procedure N(V : Single); inline;
  begin EncNum(S, Round(V * FEmScale)); end;

begin
  GD := FGlyphs[GID];
  if GID < FNumGlyphs then HM := FHMetrics[GID]
  else begin HM.AdvanceWidth := 0; HM.LSB := 0; end;

  // Encode advance width (nominalWidthX = 0 so we emit the raw value)
  EncNum(S, Round(HM.AdvanceWidth * FEmScale));

  if GD.IsEmpty or (Length(GD.Contours) = 0) then
  begin
    Op := 14; S.WriteBuffer(Op, 1);  // endchar
    Exit;
  end;

  CurX := 0; CurY := 0;

  for CI := 0 to High(GD.Contours) do
  begin
    C := GD.Contours[CI];
    if Length(C) = 0 then Continue;

    // rmoveto: relative to current point
    N(C[0].X - CurX); N(C[0].Y - CurY);
    Op := 21; S.WriteBuffer(Op, 1);  // rmoveto
    CurX := C[0].X; CurY := C[0].Y;

    PI := 1;
    while PI < Length(C) do
    begin
      if C[PI].OnCurve then
      begin
        // rlineto
        N(C[PI].X - CurX); N(C[PI].Y - CurY);
        Op := 5; S.WriteBuffer(Op, 1);
        CurX := C[PI].X; CurY := C[PI].Y;
        Inc(PI);
      end
      else if (PI + 2 < Length(C)) and
              (not C[PI].OnCurve) and (not C[PI+1].OnCurve) and
              C[PI+2].OnCurve then
      begin
        // rrcurveto: dx1 dy1 dx2 dy2 dx3 dy3
        N(C[PI  ].X - CurX);        N(C[PI  ].Y - CurY);
        N(C[PI+1].X - C[PI  ].X);   N(C[PI+1].Y - C[PI  ].Y);
        N(C[PI+2].X - C[PI+1].X);   N(C[PI+2].Y - C[PI+1].Y);
        Op := 8; S.WriteBuffer(Op, 1);
        CurX := C[PI+2].X; CurY := C[PI+2].Y;
        Inc(PI, 3);
      end
      else
        Inc(PI);  // skip unexpected point (safety)
    end;
  end;

  Op := 14; S.WriteBuffer(Op, 1);  // endchar
end;

// ================================================================
// CFF INDEX writer
// ================================================================
//
// INDEX binary format:
//   count    : uint16          number of objects
//   offSize  : uint8           bytes per offset (1-4)
//   offsets  : offSize * (count+1) bytes   1-based, first = 1
//   data     : concatenated objects

procedure TCFFBuilder.WriteINDEX(Dest : TStream; const Entries : array of TBytes);
var
  Count    : Integer;
  TotalLen : LongWord;
  OffSize  : Byte;
  I        : Integer;
  CurOff   : LongWord;
  B        : array[0..3] of Byte;

  procedure WriteOff(V : LongWord);
  begin
    case OffSize of
      1: begin B[0] := V and $FF; Dest.WriteBuffer(B[0], 1); end;
      2: WriteU16(Dest, V);
      3: begin
           B[0] := (V shr 16) and $FF;
           B[1] := (V shr  8) and $FF;
           B[2] :=  V         and $FF;
           Dest.WriteBuffer(B, 3);
         end;
      4: WriteU32(Dest, V);
    end;
  end;

begin
  Count := Length(Entries);
  WriteU16(Dest, Count);
  if Count = 0 then Exit;

  // Maximum offset = 1 + sum of all entry lengths
  TotalLen := 1;
  for I := 0 to Count - 1 do Inc(TotalLen, Length(Entries[I]));

  if      TotalLen <= $FF     then OffSize := 1
  else if TotalLen <= $FFFF   then OffSize := 2
  else if TotalLen <= $FFFFFF then OffSize := 3
  else                             OffSize := 4;

  Dest.WriteBuffer(OffSize, 1);

  // Write count+1 offset entries
  CurOff := 1;
  for I := -1 to Count - 1 do
  begin
    WriteOff(CurOff);
    if I < Count - 1 then Inc(CurOff, Length(Entries[I + 1]));
  end;

  // Write object data
  for I := 0 to Count - 1 do
    if Length(Entries[I]) > 0 then
      Dest.WriteBuffer(Entries[I][0], Length(Entries[I]));
end;

// Convenience: build an INDEX containing a single entry and return as TBytes
function TCFFBuilder.WrapINDEX(const Entry : TBytes) : TBytes;
var
  MS  : TMemoryStream;
  Ent : array[0..0] of TBytes;
begin
  MS := TMemoryStream.Create;
  try
    Ent[0] := Entry;
    WriteINDEX(MS, Ent);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

// ================================================================
// CFF section builders
// ================================================================

function TCFFBuilder.BuildNameINDEX : TBytes;
var B : TBytes;
begin
  SetLength(B, Length(FFontName));
  if Length(FFontName) > 0 then Move(FFontName[1], B[0], Length(FFontName));
  Result := WrapINDEX(B);
end;

function TCFFBuilder.BuildStringINDEX(out SIDBase : Word) : TBytes;
// Adds four custom strings starting at SID 391 (first after predefined):
//   391 = FullName   392 = FamilyName   393 = Weight   394 = version
var
  MS   : TMemoryStream;
  Ent  : array[0..3] of TBytes;

  procedure SetStr(Idx : Integer; const S : string);
  begin
    SetLength(Ent[Idx], Length(S));
    if Length(S) > 0 then Move(S[1], Ent[Idx][0], Length(S));
  end;

begin
  SIDBase := 391;
  SetStr(0, FFontName);
  SetStr(1, FFontName);
  SetStr(2, 'Regular');
  SetStr(3, '1.000');
  MS := TMemoryStream.Create;
  try
    WriteINDEX(MS, Ent);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

function TCFFBuilder.BuildCharset : TBytes;
// Format 0: explicit SID per glyph.  GID 0 = .notdef (implicit).
// GID 1..N-1 mapped to SID 1..N-1 (standard glyph list ordering).
var
  MS : TMemoryStream;
  I  : Word;
begin
  MS := TMemoryStream.Create;
  try
    WriteU8(MS, 0);
    for I := 1 to FNumGlyphs - 1 do WriteU16(MS, I);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

function TCFFBuilder.BuildCharStrings : TBytes;
var
  MS      : TMemoryStream;
  Strs    : array of TBytes;
  CS      : TMemoryStream;
  I       : Integer;
begin
  SetLength(Strs, FNumGlyphs);
  for I := 0 to FNumGlyphs - 1 do
  begin
    CS := TMemoryStream.Create;
    try
      BuildCharString(I, CS);
      SetLength(Strs[I], CS.Size);
      CS.Position := 0;
      if CS.Size > 0 then CS.ReadBuffer(Strs[I][0], CS.Size);
    finally CS.Free; end;
  end;
  MS := TMemoryStream.Create;
  try
    WriteINDEX(MS, Strs);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

function TCFFBuilder.BuildPrivateDict : TBytes;
// Private DICT contains only defaultWidthX and nominalWidthX (both 0).
// No Subrs entry (op 19): Windows GDI rejects fonts where Subrs points to
// an empty count=0 Local Subrs INDEX.  Omitting op 19 is perfectly valid CFF
// and means "no local subroutines" — all outlines are encoded inline.
var MS : TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    EncNum(MS, 0); DictOp(MS, 20);  // defaultWidthX = 0
    EncNum(MS, 0); DictOp(MS, 21);  // nominalWidthX = 0
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

function TCFFBuilder.BuildTopDict(CharsetOfs, CharStrOfs,
                                   PrivSize, PrivOfs : LongWord;
                                   FullSID, FamSID, WtSID : Word) : TBytes;
// All offset/size fields use EncNum5 (5 bytes each) so the dict has
// a predictable size regardless of actual offset values.
var MS : TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    // FontMatrix is always the CFF default [0.001 0 0 0.001 0 0] because all
    // charstring coordinates are already scaled to 1000 UPM in BuildCharString.
    // Emitting an explicit FontMatrix with CFF Real numbers confuses Windows GDI.
    EncNum(MS, FullSID); DictOp(MS, 2);   // FullName
    EncNum(MS, FamSID);  DictOp(MS, 3);   // FamilyName
    EncNum(MS, WtSID);   DictOp(MS, 4);   // Weight
    // ItalicAngle = 0 (escape op 12 3).  Upright font; including this entry
    // explicitly makes the CFF Top DICT more complete and more compatible with
    // third-party tools, though GDI does not require it.
    EncNum(MS, 0); DictOp(MS, 12); DictOp(MS, 3);   // ItalicAngle = 0
    EncNum(MS, Round(FXMin * FEmScale)); EncNum(MS, Round(FYMin * FEmScale));
    EncNum(MS, Round(FXMax * FEmScale)); EncNum(MS, Round(FYMax * FEmScale));
    DictOp(MS, 5);  // FontBBox
    EncNum(MS, 0);       DictOp(MS, 16);  // Encoding=Standard
    EncNum5(MS, CharsetOfs); DictOp(MS, 15);            // charset
    EncNum5(MS, CharStrOfs); DictOp(MS, 17);            // CharStrings
    EncNum5(MS, PrivSize);
    EncNum5(MS, PrivOfs);   DictOp(MS, 18);            // Private
    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

// ================================================================
// Public: BuildCFF
// ================================================================

function TCFFBuilder.BuildCFF : TBytes;
var
  NameIdx    : TBytes;
  StrIdx     : TBytes;
  Charset    : TBytes;
  CharStrs   : TBytes;
  PrivDict   : TBytes;
  TopDict    : TBytes;
  TopDictIdx : TBytes;
  SIDBase    : Word;
  MS         : TMemoryStream;

  OfsName    : LongWord;  // 4 = header size
  OfsTopIdx  : LongWord;
  OfsStr     : LongWord;
  OfsGSubr   : LongWord;
  OfsCharset : LongWord;
  OfsCharStr : LongWord;
  OfsPriv    : LongWord;
begin
  NameIdx  := BuildNameINDEX;
  StrIdx   := BuildStringINDEX(SIDBase);
  Charset  := BuildCharset;
  CharStrs := BuildCharStrings;
  PrivDict := BuildPrivateDict;

  // Dummy Top DICT to measure its INDEX size (EncNum5 fields are fixed 5 bytes,
  // so the size is independent of the actual offset values).
  TopDict    := BuildTopDict(0, 0, 0, 0, SIDBase, SIDBase+1, SIDBase+2);
  TopDictIdx := WrapINDEX(TopDict);

  // Compute absolute offsets within the final CFF blob
  OfsName    := 4;                                   // after 4-byte header
  OfsTopIdx  := OfsName   + LongWord(Length(NameIdx));
  OfsStr     := OfsTopIdx + LongWord(Length(TopDictIdx));
  OfsGSubr   := OfsStr    + LongWord(Length(StrIdx));
  OfsCharset := OfsGSubr  + 2;                       // empty INDEX = 2 bytes
  OfsCharStr := OfsCharset + LongWord(Length(Charset));
  OfsPriv    := OfsCharStr + LongWord(Length(CharStrs));

  // Rebuild Top DICT with real offsets, rewrap in INDEX
  TopDict    := BuildTopDict(OfsCharset, OfsCharStr,
                              LongWord(Length(PrivDict)), OfsPriv,
                              SIDBase, SIDBase+1, SIDBase+2);
  TopDictIdx := WrapINDEX(TopDict);

  // Assemble final CFF
  MS := TMemoryStream.Create;
  try
    WriteU8(MS, 1); WriteU8(MS, 0);    // major, minor version
    WriteU8(MS, 4); WriteU8(MS, 4);    // hdrSize=4, offSize=4

    MS.WriteBuffer(NameIdx[0],    Length(NameIdx));
    MS.WriteBuffer(TopDictIdx[0], Length(TopDictIdx));
    MS.WriteBuffer(StrIdx[0],     Length(StrIdx));
    WriteU16(MS, 0);                   // Global Subr INDEX: empty
    MS.WriteBuffer(Charset[0],    Length(Charset));
    MS.WriteBuffer(CharStrs[0],   Length(CharStrs));
    MS.WriteBuffer(PrivDict[0],   Length(PrivDict));

    SetLength(Result, MS.Size);
    MS.Position := 0;
    if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
  finally MS.Free; end;
end;

// ================================================================
// Public: BuildOTF
// ================================================================

procedure TCFFBuilder.BuildOTF(Dst : TStream);
// Writes a complete OpenType/CFF font.
// Tables are sorted in ascending tag order (OpenType requirement).
// checkSumAdjustment is computed from the full file checksum.
const
  // Tags in ascending numerical order
  NUM_TABLES = 9;
  TAGS : array[0..NUM_TABLES-1] of TTableTag = (
    TAG_CFF,  TAG_OS2,  TAG_CMAP,
    TAG_HEAD, TAG_HHEA, TAG_HMTX,
    TAG_MAXP, TAG_NAME, TAG_POST
  );
  HEAD_IDX            = 3;   // index of head in TAGS array
  HEAD_CHKSUM_ADJ_OFS = 8;   // byte offset of checkSumAdjustment in head

var
  TableData : array[0..NUM_TABLES-1] of TBytes;
  I         : Integer;
  Buf       : TMemoryStream;  // complete font assembled here before copy to Dst
  Offsets   : array[0..NUM_TABLES-1] of LongWord;
  Lengths   : array[0..NUM_TABLES-1] of LongWord;
  Chksums   : array[0..NUM_TABLES-1] of LongWord;
  SearchRange, EntrySelector, RangeShift : Word;
  DataStart : LongWord;
  TotalSize : LongWord;
  Pad, N    : Integer;
  Z         : Byte;
  FullChk   : LongWord;
  AdjPos    : Int64;

  function CopyRaw(Tag : TTableTag) : TBytes;
  begin Result := FParser.RawTable(Tag); end;

  // ---- Metric scaling helpers ----
  // These patch a single big-endian int16/uint16 field in byte array B,
  // multiplying its value by FEmScale.  Used to normalise all design-unit
  // fields from the source UPM to the target 1000 UPM.

  procedure PatchS16(var B : TBytes; Ofs : Integer);
  var V : SmallInt;
  begin
    if Ofs + 1 < Length(B) then
    begin
      V := SmallInt((Word(B[Ofs]) shl 8) or B[Ofs+1]);
      V := SmallInt(Round(V * FEmScale));
      B[Ofs]   := (Word(V) shr 8) and $FF;
      B[Ofs+1] :=  Word(V)        and $FF;
    end;
  end;

  procedure PatchU16(var B : TBytes; Ofs : Integer);
  var V : Word;
  begin
    if Ofs + 1 < Length(B) then
    begin
      V := (Word(B[Ofs]) shl 8) or B[Ofs+1];
      V := Word(Round(V * FEmScale));
      B[Ofs]   := (V shr 8) and $FF;
      B[Ofs+1] :=  V        and $FF;
    end;
  end;

  // ---- Table builders / patchers ----

  // Clear OS/2.fsType (Restricted Licensing bits block AddFontResourceEx).
  // Clear Symbol bit in ulCodePageRange1: GDI rejects fonts where bit 31
  // (Symbol character set) is set but the cmap only has a Unicode subtable
  // (platform 3 encoding 1) rather than a Symbol subtable (encoding 0).
  // Also scale design-unit metric fields from source UPM to 1000 UPM.
  function PatchOS2(const Src : TBytes) : TBytes;
  begin
    Result := Copy(Src);
    // fsType = 0 → Installable Embedding
    if Length(Result) >= 10 then
    begin
      Result[8] := 0;   // fsType high byte
      Result[9] := 0;   // fsType low byte
    end;
    // Clear Symbol bit (bit 31 = 0x80000000) from ulCodePageRange1 at offset 78.
    // The field is big-endian: byte 78 is the high byte, bit 31 = its MSB.
    // We convert to a standard Unicode font, not a symbol-encoded one.
    if Length(Result) >= 82 then
      Result[78] := Result[78] and $7F;
    // Scale design-unit fields (only meaningful when UPM ≠ 1000)
    if FEmScale <> 1.0 then
    begin
      PatchS16(Result,  2);   // xAvgCharWidth
      PatchS16(Result, 68);   // sTypoAscender  (OS/2 v0)
      PatchS16(Result, 70);   // sTypoDescender
      PatchS16(Result, 72);   // sTypoLineGap
      PatchU16(Result, 74);   // usWinAscent
      PatchU16(Result, 76);   // usWinDescent
    end;
    // Upgrade OS/2 to version 4.  Windows GDI rejects CFF-based OpenType fonts
    // whose OS/2 table is version 1 or lower (FontForge warns about this too).
    // v2/v3/v4 extends the 86-byte v1 layout by 10 bytes:
    //   86  sxHeight      int16   x-height in design units (0 = unspecified)
    //   88  sCapHeight    int16   cap height in design units (0 = unspecified)
    //   90  usDefaultChar uint16  default char glyph index (0 = .notdef)
    //   92  usBreakChar   uint16  word-break code point (32 = space)
    //   94  usMaxContext  uint16  max context length for layout lookups (0)
    // SetLength zero-initialises the new bytes; only usBreakChar needs setting.
    if Length(Result) < 96 then
    begin
      SetLength(Result, 96);   // new bytes 86-95 are zero-initialised
      Result[92] := 0;
      Result[93] := 32;        // usBreakChar = 32 (space)
    end;
    // Set version field (bytes 0-1) to 4
    if Length(Result) >= 2 then
    begin
      Result[0] := 0;
      Result[1] := 4;          // version = 4
    end;
  end;

  // Build hmtx with advance widths and LSBs scaled to 1000 UPM
  function MakeHmtx : TBytes;
  var MS : TMemoryStream; J : Integer;
  begin
    MS := TMemoryStream.Create;
    try
      for J := 0 to FNumGlyphs - 1 do
      begin
        WriteU16(MS, Word(Round(FHMetrics[J].AdvanceWidth * FEmScale)));
        WriteS16(MS, SmallInt(Round(FHMetrics[J].LSB * FEmScale)));
      end;
      SetLength(Result, MS.Size); MS.Position := 0;
      if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
    finally MS.Free; end;
  end;

  function MakeMaxp05 : TBytes;
  var MS : TMemoryStream;
  begin
    MS := TMemoryStream.Create;
    try
      WriteU32(MS, $00005000);   // version 0.5
      WriteU16(MS, FNumGlyphs);
      SetLength(Result, MS.Size); MS.Position := 0;
      if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
    finally MS.Free; end;
  end;

  function MakePost3 : TBytes;
  var MS : TMemoryStream;
  begin
    MS := TMemoryStream.Create;
    try
      WriteU32(MS, $00030000);  // post version 3.0
      WriteU32(MS, 0);          // italicAngle (Fixed)
      WriteS16(MS, -100);       // underlinePosition
      WriteS16(MS, 50);         // underlineThickness
      WriteU32(MS, 0); WriteU32(MS, 0);
      WriteU32(MS, 0); WriteU32(MS, 0); WriteU32(MS, 0);
      SetLength(Result, MS.Size); MS.Position := 0;
      if MS.Size > 0 then MS.ReadBuffer(Result[0], MS.Size);
    finally MS.Free; end;
  end;

  // Copy hhea, scale design-unit metric fields, patch numberOfHMetrics
  function PatchHhea(const Src : TBytes) : TBytes;
  begin
    Result := Copy(Src);
    if FEmScale <> 1.0 then
    begin
      PatchS16(Result,  4);   // ascender
      PatchS16(Result,  6);   // descender
      PatchS16(Result,  8);   // lineGap
      PatchU16(Result, 10);   // advanceWidthMax
      PatchS16(Result, 12);   // minLeftSideBearing
      PatchS16(Result, 14);   // minRightSideBearing
      PatchS16(Result, 16);   // xMaxExtent
    end;
    if Length(Result) >= 36 then
    begin
      Result[34] := (FNumGlyphs shr 8) and $FF;
      Result[35] :=  FNumGlyphs        and $FF;
    end;
  end;

  // Copy head; clear checkSumAdjustment; normalise UPM to 1000 for CFF;
  // clear TrueType instruction bits (not valid for CFF); scale bbox;
  // set indexToLocFormat = 0.
  function PatchHead(const Src : TBytes) : TBytes;
  begin
    Result := Copy(Src);
    if Length(Result) >= 54 then
    begin
      Result[ 8] := 0; Result[ 9] := 0;
      Result[10] := 0; Result[11] := 0;  // checkSumAdjustment = 0
      // CFF fonts conventionally use 1000 UPM; charstrings already scaled
      Result[18] := (1000 shr 8) and $FF;
      Result[19] :=  1000        and $FF;  // unitsPerEm = 1000
      // Clear head.flags bits that are TrueType-specific and invalid for CFF:
      //   bit 2 (0x04) = instructions may depend on point size
      //   bit 4 (0x10) = instructions may alter advance width
      // flags is at bytes 16-17 (big-endian); these bits are in byte 17.
      Result[17] := Result[17] and not $14;   // clear bits 2 and 4
      if FEmScale <> 1.0 then
      begin
        PatchS16(Result, 36);   // xMin
        PatchS16(Result, 38);   // yMin
        PatchS16(Result, 40);   // xMax
        PatchS16(Result, 42);   // yMax
      end;
      Result[50] := 0; Result[51] := 0;  // indexToLocFormat = 0
    end;
  end;

begin
  // ---- Build table data ----
  TableData[0] := BuildCFF;
  TableData[1] := PatchOS2(CopyRaw(TAG_OS2));
  TableData[2] := CopyRaw(TAG_CMAP);
  TableData[3] := PatchHead(CopyRaw(TAG_HEAD));
  TableData[4] := PatchHhea(CopyRaw(TAG_HHEA));
  TableData[5] := MakeHmtx;
  TableData[6] := MakeMaxp05;
  TableData[7] := CopyRaw(TAG_NAME);
  TableData[8] := MakePost3;

  // Verify required raw tables are present
  for I := 1 to NUM_TABLES - 1 do
    if (I <> 5) and (I <> 6) and (I <> 8) then  // hmtx, maxp, post: built above
      if Length(TableData[I]) = 0 then
        raise Exception.CreateFmt(
          'Required table ''%s'' not found in source TTF', [TagStr(TAGS[I])]);

  // ---- OpenType header arithmetic ----
  SearchRange   := 1; EntrySelector := 0;
  while SearchRange * 2 <= NUM_TABLES do
  begin SearchRange := SearchRange * 2; Inc(EntrySelector); end;
  SearchRange := SearchRange * 16;
  RangeShift  := NUM_TABLES * 16 - SearchRange;

  // Offset table = 12 bytes, directory = 16 bytes * numTables
  DataStart := 12 + LongWord(NUM_TABLES) * 16;

  // Compute per-table offsets and checksums
  TotalSize := DataStart;
  for I := 0 to NUM_TABLES - 1 do
  begin
    Offsets[I] := TotalSize;
    Lengths[I] := Length(TableData[I]);
    if Lengths[I] > 0 then
      Chksums[I] := CalcChecksum(@TableData[I][0], Lengths[I])
    else
      Chksums[I] := 0;
    N   := Lengths[I] mod 4;
    Pad := IfThen(N > 0, 4 - N, 0);
    Inc(TotalSize, Lengths[I] + LongWord(Pad));
  end;

  // ---- Assemble into a memory buffer ----
  Buf := TMemoryStream.Create;
  try
    // Offset table
    WriteU32(Buf, SFNT_CFF);
    WriteU16(Buf, NUM_TABLES);
    WriteU16(Buf, SearchRange);
    WriteU16(Buf, EntrySelector);
    WriteU16(Buf, RangeShift);

    // Table directory
    for I := 0 to NUM_TABLES - 1 do
    begin
      WriteU32(Buf, TAGS[I]);
      WriteU32(Buf, Chksums[I]);
      WriteU32(Buf, Offsets[I]);
      WriteU32(Buf, Lengths[I]);
    end;

    // Table data (4-byte padded)
    Z := 0;
    for I := 0 to NUM_TABLES - 1 do
    begin
      if Lengths[I] > 0 then Buf.WriteBuffer(TableData[I][0], Lengths[I]);
      N := Lengths[I] mod 4;
      if N > 0 then for Pad := 1 to 4 - N do Buf.WriteBuffer(Z, 1);
    end;

    // ---- Compute and patch checkSumAdjustment ----
    // Sum the entire font file as 32-bit big-endian words
    Buf.Position := 0;
    FullChk := CalcChecksum(Buf.Memory, Buf.Size);
    // The head table checkSumAdjustment is at Offsets[HEAD_IDX]+8
    AdjPos := Offsets[HEAD_IDX] + HEAD_CHKSUM_ADJ_OFS;
    Buf.Position := AdjPos;
    WriteU32(Buf, LongWord($B1B0AFBA) - FullChk);

    // ---- Copy to output stream ----
    Buf.Position := 0;
    Dst.CopyFrom(Buf, Buf.Size);
  finally Buf.Free; end;
end;

end.
