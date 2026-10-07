unit FontTypes;

{$mode objfpc}{$H+}
interface
uses Classes, SysUtils;

// Author: www.xelitan.com
// License: MIT
// Shared types, constants, and big-endian I/O for the font converter.

const
  SFNT_CFF   = $4F54544F;  // 'OTTO' - CFF-based OTF
  SFNT_TRUE  = $00010000;
  SFNT_TRUE2 = $74727565;  // 'true' variant
  WOFF_MAGIC = $774F4646;  // 'wOFF'

  TAG_CFF  = $43464620;  TAG_CMAP = $636D6170;
  TAG_CVT  = $63767420;  TAG_FPGM = $6670676D;
  TAG_GASP = $67617370;  TAG_GLYF = $676C7966;
  TAG_GPOS = $47504F53;  TAG_GSUB = $47535542;
  TAG_HEAD = $68656164;  TAG_HHEA = $68686561;
  TAG_HMTX = $686D7478;  TAG_KERN = $6B65726E;
  TAG_LOCA = $6C6F6361;  TAG_MAXP = $6D617870;
  TAG_NAME = $6E616D65;  TAG_OS2  = $4F532F32;
  TAG_POST = $706F7374;  TAG_PREP = $70726570;

type
  TTableTag = LongWord;

  // A single outline point: on-curve = endpoint, off-curve = control point
  TGlyphPoint = record
    X, Y    : Single;
    OnCurve : Boolean;
  end;
  TGlyphPointArray  = array of TGlyphPoint;

  // Closed contour of cubic bezier points.
  // On-curve points alternate with pairs of off-curve control points,
  // or consecutive on-curve points represent line segments.
  TCubicContour      = array of TGlyphPoint;
  TCubicContourArray = array of TCubicContour;

  THMetric = record
    AdvanceWidth : Word;
    LSB          : SmallInt;
  end;
  THMetricArray = array of THMetric;

  TGlyphData = record
    Contours             : TCubicContourArray;
    XMin, YMin, XMax, YMax : SmallInt;
    IsEmpty              : Boolean;
    IsComposite          : Boolean;
  end;
  TGlyphDataArray = array of TGlyphData;

  // Raw table storage (tag + original checksum + raw bytes)
  TRawTable = record
    Tag      : TTableTag;
    Checksum : LongWord;
    Data     : TBytes;
  end;
  TRawTableArray = array of TRawTable;

// --- Big-endian stream I/O ---
function  ReadU8 (S : TStream) : Byte;
function  ReadU16(S : TStream) : Word;
function  ReadS16(S : TStream) : SmallInt;
function  ReadU32(S : TStream) : LongWord;
function  ReadS32(S : TStream) : LongInt;
procedure WriteU8 (S : TStream; V : Byte);
procedure WriteU16(S : TStream; V : Word);
procedure WriteS16(S : TStream; V : SmallInt);
procedure WriteU32(S : TStream; V : LongWord);
procedure WriteS32(S : TStream; V : LongInt);

function Swap16(V : Word)     : Word;     inline;
function Swap32(V : LongWord) : LongWord; inline;

function TagStr(T : TTableTag) : string;

// Compute OpenType checksum for a block of memory
function CalcChecksum(P : Pointer; Len : LongWord) : LongWord; overload;
function CalcChecksum(const D : TBytes)             : LongWord; overload;

// Pad stream to next 4-byte boundary with zero bytes
procedure PadStream(S : TStream);

implementation

function Swap16(V : Word) : Word;
begin
  Result := Word((V shl 8) or (V shr 8));
end;

function Swap32(V : LongWord) : LongWord;
begin
  Result := ((V and $000000FF) shl 24) or
            ((V and $0000FF00) shl  8) or
            ((V and $00FF0000) shr  8) or
             (V shr 24);
end;

function ReadU8(S : TStream) : Byte;
begin
  S.ReadBuffer(Result, 1);
end;

function ReadU16(S : TStream) : Word;
begin
  S.ReadBuffer(Result, 2);
  Result := Swap16(Result);
end;

function ReadS16(S : TStream) : SmallInt;
begin
  Result := SmallInt(ReadU16(S));
end;

function ReadU32(S : TStream) : LongWord;
begin
  S.ReadBuffer(Result, 4);
  Result := Swap32(Result);
end;

function ReadS32(S : TStream) : LongInt;
begin
  Result := LongInt(ReadU32(S));
end;

procedure WriteU8(S : TStream; V : Byte);
begin
  S.WriteBuffer(V, 1);
end;

procedure WriteU16(S : TStream; V : Word);
var W : Word;
begin
  W := Swap16(V);
  S.WriteBuffer(W, 2);
end;

procedure WriteS16(S : TStream; V : SmallInt);
begin
  WriteU16(S, Word(V));
end;

procedure WriteU32(S : TStream; V : LongWord);
var D : LongWord;
begin
  D := Swap32(V);
  S.WriteBuffer(D, 4);
end;

procedure WriteS32(S : TStream; V : LongInt);
begin
  WriteU32(S, LongWord(V));
end;

function TagStr(T : TTableTag) : string;
begin
  Result := Chr((T shr 24) and $FF) +
            Chr((T shr 16) and $FF) +
            Chr((T shr  8) and $FF) +
            Chr( T         and $FF);
end;

function CalcChecksum(P : Pointer; Len : LongWord) : LongWord;
var
  PB       : PByte;
  Sum, I, NL, Rem, V : LongWord;
begin
  Sum := 0;
  PB  := PByte(P);
  NL  := Len div 4;
  for I := 0 to NL - 1 do
  begin
    V := (LongWord(PB[0]) shl 24) or (LongWord(PB[1]) shl 16) or
         (LongWord(PB[2]) shl  8) or  LongWord(PB[3]);
    Inc(Sum, V);
    Inc(PB, 4);
  end;
  Rem := Len and 3;
  if Rem > 0 then
  begin
    V := 0;
    if Rem >= 1 then V := V or (LongWord(PB[0]) shl 24);
    if Rem >= 2 then V := V or (LongWord(PB[1]) shl 16);
    if Rem >= 3 then V := V or (LongWord(PB[2]) shl  8);
    Inc(Sum, V);
  end;
  Result := Sum;
end;

function CalcChecksum(const D : TBytes) : LongWord;
begin
  if Length(D) = 0 then
    Result := 0
  else
    Result := CalcChecksum(@D[0], Length(D));
end;

procedure PadStream(S : TStream);
const Z : Byte = 0;
var N : Integer;
begin
  N := S.Size mod 4;
  if N > 0 then
    while N < 4 do
    begin
      S.WriteBuffer(Z, 1);
      Inc(N);
    end;
end;

end.
