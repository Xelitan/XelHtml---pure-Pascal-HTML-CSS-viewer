unit WOFF2Codec;

{$mode objfpc}{$H+}
{$WARN 5093 off}

interface
uses Classes, SysUtils, Math, FontTypes, WOFFCodec, SimpleBrotli;

// Author: www.xelitan.com
// License: MIT
//
// WOFF2 (Web Open Font Format 2.0) codec.
//
// WOFF2 file structure:
//   Header                (48 bytes)
//   Table directory       (variable length, UIntBase128 fields)
//   Brotli-compressed tables (all tables concatenated, no inter-table padding)
//
// Encoding uses a minimal Brotli "stored" stream (no actual compression),
// which is fully standards-compliant per RFC 7932.
// Decoding uses the SimpleBrotli decompressor.
//
// glyf/loca transform:
//   * Decoding  : both the null transform (version 3) and the standard
//                 glyf/loca transform (version 0) are supported. The latter
//                 reconstructs the glyf and loca tables from the transformed
//                 substreams (WOFF2 spec section 5.1).
//   * Encoding  : always emits the null transform (version 3) for all tables.

const
  WOFF2_MAGIC = $774F4632;  // 'wOF2'

procedure OTFToWOFF2(Src, Dst : TStream);
procedure WOFF2ToOTF(Src, Dst : TStream);
procedure WOFFToWOFF2(Src, Dst : TStream);
procedure WOFF2ToWOFF(Src, Dst : TStream);

implementation

// ================================================================
// Known WOFF2 table tag indices (spec table in section 5.2)
// ================================================================

const
  WOFF2_KNOWN_TAGS : array[0..62] of LongWord = (
    $636D6170,  //  0  cmap
    $68656164,  //  1  head
    $68686561,  //  2  hhea
    $686D7478,  //  3  hmtx
    $6D617870,  //  4  maxp
    $6E616D65,  //  5  name
    $4F532F32,  //  6  OS/2
    $706F7374,  //  7  post
    $63767420,  //  8  cvt
    $6670676D,  //  9  fpgm
    $676C7966,  // 10  glyf
    $6C6F6361,  // 11  loca
    $70726570,  // 12  prep
    $43464620,  // 13  CFF
    $564F5247,  // 14  VORG
    $45424454,  // 15  EBDT
    $45424C43,  // 16  EBLC
    $67617370,  // 17  gasp
    $68646D78,  // 18  hdmx
    $6B65726E,  // 19  kern
    $4C545348,  // 20  LTSH
    $50434C54,  // 21  PCLT
    $56444D58,  // 22  VDMX
    $76686561,  // 23  vhea
    $766D7478,  // 24  vmtx
    $42415345,  // 25  BASE
    $47444546,  // 26  GDEF
    $47504F53,  // 27  GPOS
    $47535542,  // 28  GSUB
    $45425343,  // 29  EBSC
    $4A535446,  // 30  JSTF
    $4D415448,  // 31  MATH
    $43424454,  // 32  CBDT
    $43424C43,  // 33  CBLC
    $434F4C52,  // 34  COLR
    $4350414C,  // 35  CPAL
    $53564720,  // 36  SVG
    $73626978,  // 37  sbix
    $61636E74,  // 38  acnt
    $61766172,  // 39  avar
    $62646174,  // 40  bdat
    $626C6F63,  // 41  bloc
    $62736C6E,  // 42  bsln
    $63766172,  // 43  cvar
    $66647363,  // 44  fdsc
    $66656174,  // 45  feat
    $666D7478,  // 46  fmtx
    $66766172,  // 47  fvar
    $67766172,  // 48  gvar
    $68737479,  // 49  hsty
    $6A757374,  // 50  just
    $6C636172,  // 51  lcar
    $6D6F7274,  // 52  mort
    $6D6F7278,  // 53  morx
    $6F706264,  // 54  opbd
    $70726F70,  // 55  prop
    $7472616B,  // 56  trak
    $5A617066,  // 57  Zapf
    $53696C66,  // 58  Silf
    $476C6174,  // 59  Glat
    $476C6F63,  // 60  Gloc
    $46656174,  // 61  Feat
    $53696C6C   // 62  Sill
  );

// Returns 0..62 for known tags, 63 for custom.
function WOFF2TagIndex(Tag : LongWord) : Integer;
var I : Integer;
begin
  for I := 0 to 62 do
    if WOFF2_KNOWN_TAGS[I] = Tag then begin Result := I; Exit; end;
  Result := 63;
end;

// ================================================================
// UIntBase128 — variable-length MSB-first unsigned integer encoding
// used by the WOFF2 table directory.
//
// Each byte: bit 7 = more bytes follow; bits 6..0 = 7 value bits (MSB first).
// ================================================================

procedure WriteUIntBase128(S : TStream; Value : LongWord);
var
  Buf   : array[0..4] of Byte;
  Count : Integer;
  I     : Integer;
begin
  Count := 0;
  repeat
    Buf[Count] := Value and $7F;
    Value := Value shr 7;
    Inc(Count);
  until Value = 0;
  for I := Count - 1 downto 1 do
    WriteU8(S, Buf[I] or $80);
  WriteU8(S, Buf[0]);
end;

function ReadUIntBase128(S : TStream) : LongWord;
var
  B : Byte;
  I : Integer;
begin
  Result := 0;
  for I := 0 to 4 do
  begin
    B := ReadU8(S);
    if (I = 0) and (B = $80) then
      raise Exception.Create('WOFF2: invalid UIntBase128 (leading zero byte)');
    Result := (Result shl 7) or (B and $7F);
    if (B and $80) = 0 then Exit;
  end;
  raise Exception.Create('WOFF2: UIntBase128 value overflows 32 bits');
end;

// Returns how many bytes WriteUIntBase128 will emit for a given value.
function UIntBase128Size(Value : LongWord) : Integer;
begin
  if Value < 128        then Result := 1
  else if Value < 16384      then Result := 2
  else if Value < 2097152    then Result := 3
  else if Value < 268435456  then Result := 4
  else                            Result := 5;
end;

// ================================================================
// Minimal Brotli "stored" encoder (RFC 7932-compliant)
//
// Emits a valid Brotli stream that contains the input data verbatim,
// as a single uncompressed meta-block followed by an empty last block:
//
//   [stream header + meta-block header, byte-aligned]
//   [DataLen bytes: raw data]
//   [empty last meta-block]
//
// Meta-block header bits (written LSB-first):
//   WBITS          : 4 bits "1111"  => window_bits = 24
//   ISLAST         : 1 bit  = 0
//   MNIBBLES       : 2 bits = nibbleCount - 4   (4, 5, or 6 nibbles)
//   MLEN-1         : nibbleCount*4 bits, LSB first
//   ISUNCOMPRESSED : 1 bit  = 1
//   <pad to byte boundary with zero bits>
//
// The Brotli decoder rejects non-minimal length encodings (the top nibble
// of a >4-nibble length must be nonzero) and requires the byte-alignment
// padding bits to be zero, so both are handled here.
//
// Handles data up to 16,777,215 bytes (just under 16 MB).
// ================================================================

type
  TBitWriter = record
    Data  : TBytes;
    Len   : Integer;    // bytes committed
    Acc   : LongWord;   // pending bits (LSB-first)
    NBits : Integer;    // number of pending bits
  end;

procedure BWInit(out B : TBitWriter);
begin
  SetLength(B.Data, 16);
  B.Len   := 0;
  B.Acc   := 0;
  B.NBits := 0;
end;

procedure BWPutBits(var B : TBitWriter; Value : LongWord; Count : Integer);
// Append Count low bits of Value (LSB first). Count must be 0..24.
begin
  if Count = 0 then Exit;
  B.Acc := B.Acc or ((Value and ((LongWord(1) shl Count) - 1)) shl B.NBits);
  Inc(B.NBits, Count);
  while B.NBits >= 8 do
  begin
    if B.Len >= Length(B.Data) then SetLength(B.Data, Length(B.Data) * 2);
    B.Data[B.Len] := Byte(B.Acc and $FF);
    Inc(B.Len);
    B.Acc := B.Acc shr 8;
    Dec(B.NBits, 8);
  end;
end;

procedure BWAlign(var B : TBitWriter);
// Flush any remaining bits, zero-padding to the next byte boundary.
begin
  if B.NBits > 0 then
  begin
    if B.Len >= Length(B.Data) then SetLength(B.Data, Length(B.Data) * 2);
    B.Data[B.Len] := Byte(B.Acc and $FF);
    Inc(B.Len);
    B.Acc   := 0;
    B.NBits := 0;
  end;
end;

procedure BWFlushTo(var B : TBitWriter; Dst : TStream);
begin
  BWAlign(B);
  if B.Len > 0 then Dst.WriteBuffer(B.Data[0], B.Len);
end;

procedure BrotliEncodeStored(Data : Pointer; DataLen : LongWord;
                              Dst  : TStream);
var
  BW      : TBitWriter;
  M       : LongWord;
  Nibbles : Integer;
begin
  if DataLen = 0 then
  begin
    // WBITS=24 (1111) + ISLAST=1 + ISLASTEMPTY=1
    BWInit(BW);
    BWPutBits(BW, $0F, 4);
    BWPutBits(BW, 1, 1);
    BWPutBits(BW, 1, 1);
    BWFlushTo(BW, Dst);
    Exit;
  end;

  if DataLen > 16777215 then
    raise Exception.CreateFmt(
      'BrotliEncodeStored: data exceeds 16 MB limit (%d bytes)', [DataLen]);

  M := DataLen - 1;

  // Choose the minimal nibble count for MLEN-1 (the decoder rejects
  // a non-minimal encoding where the top nibble would be zero).
  if      M < (LongWord(1) shl 16) then Nibbles := 4
  else if M < (LongWord(1) shl 20) then Nibbles := 5
  else                                  Nibbles := 6;

  BWInit(BW);
  BWPutBits(BW, $0F, 4);                  // WBITS = 24
  BWPutBits(BW, 0, 1);                    // ISLAST = 0
  BWPutBits(BW, LongWord(Nibbles - 4), 2);// MNIBBLES
  BWPutBits(BW, M, Nibbles * 4);          // MLEN - 1
  BWPutBits(BW, 1, 1);                    // ISUNCOMPRESSED = 1
  BWFlushTo(BW, Dst);                     // byte-align (zero padding)

  Dst.WriteBuffer(Data^, DataLen);        // raw data, byte-aligned

  // Empty last meta-block: ISLAST=1, ISLASTEMPTY=1
  BWInit(BW);
  BWPutBits(BW, 1, 1);
  BWPutBits(BW, 1, 1);
  BWFlushTo(BW, Dst);
end;

// ================================================================
// Per-table directory checksum.
//
// For the 'head' table the OpenType spec requires the checksum to be
// computed with the checkSumAdjustment field (bytes 8..11) set to zero,
// so a reconstructed font matches what a conforming builder writes.
// ================================================================

function TableChecksum(Tag : LongWord; const Data : TBytes) : LongWord;
var Tmp : TBytes;
begin
  if (Tag = TAG_HEAD) and (Length(Data) >= 12) then
  begin
    Tmp := Copy(Data, 0, Length(Data));
    Tmp[8] := 0; Tmp[9] := 0; Tmp[10] := 0; Tmp[11] := 0;
    Result := CalcChecksum(Tmp);
  end
  else
    Result := CalcChecksum(Data);
end;

// ================================================================
// OTF -> WOFF2
// ================================================================

procedure OTFToWOFF2(Src, Dst : TStream);
var
  SfntSig   : LongWord;
  NumTables : Word;
  I, N      : Integer;

  Tags      : array of LongWord;
  ChkSums   : array of LongWord;
  SfntOffs  : array of LongWord;
  SfntLens  : array of LongWord;
  RawData   : array of TBytes;

  Concat    : TMemoryStream;
  Comp      : TMemoryStream;

  TagIdx    : Integer;
  Flags     : Byte;
  DirSize   : LongWord;
  TotalSfntSize, TotalCompSize, WOFFSize : LongWord;

begin
  Src.Position := 0;
  SfntSig := ReadU32(Src);
  if (SfntSig <> SFNT_CFF) and (SfntSig <> SFNT_TRUE) and
     (SfntSig <> SFNT_TRUE2) then
    raise Exception.Create('OTFToWOFF2: not a valid sfnt font');

  NumTables := ReadU16(Src);
  ReadU16(Src); ReadU16(Src); ReadU16(Src);  // searchRange, entrySelector, rangeShift

  SetLength(Tags,     NumTables);
  SetLength(ChkSums,  NumTables);
  SetLength(SfntOffs, NumTables);
  SetLength(SfntLens, NumTables);

  for I := 0 to NumTables - 1 do
  begin
    Tags[I]     := ReadU32(Src);
    ChkSums[I]  := ReadU32(Src);
    SfntOffs[I] := ReadU32(Src);
    SfntLens[I] := ReadU32(Src);
  end;

  SetLength(RawData, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    SetLength(RawData[I], SfntLens[I]);
    if SfntLens[I] > 0 then
    begin
      Src.Position := SfntOffs[I];
      Src.ReadBuffer(RawData[I][0], SfntLens[I]);
    end;
  end;

  // Concatenate all table data (WOFF2: no padding between tables)
  Concat := TMemoryStream.Create;
  try
    for I := 0 to NumTables - 1 do
      if SfntLens[I] > 0 then
        Concat.WriteBuffer(RawData[I][0], SfntLens[I]);

    Comp := TMemoryStream.Create;
    try
      BrotliEncodeStored(Concat.Memory, LongWord(Concat.Size), Comp);
      TotalCompSize := LongWord(Comp.Size);

      // totalSfntSize = offset table + directory + padded table data
      TotalSfntSize := 12 + LongWord(NumTables) * 16;
      for I := 0 to NumTables - 1 do
      begin
        N := SfntLens[I] mod 4;
        Inc(TotalSfntSize, SfntLens[I] + LongWord(IfThen(N > 0, 4 - N, 0)));
      end;

      // Compute table directory byte size (needed for WOFFSize)
      DirSize := 0;
      for I := 0 to NumTables - 1 do
      begin
        TagIdx := WOFF2TagIndex(Tags[I]);
        Inc(DirSize, 1);                        // flags byte
        if TagIdx = 63 then Inc(DirSize, 4);    // explicit tag
        Inc(DirSize, UIntBase128Size(SfntLens[I])); // origLength
        // No transformLength for version-0 non-glyf and version-3 glyf/loca
      end;

      WOFFSize := 48 + DirSize + TotalCompSize;

      // --- WOFF2 header (48 bytes) ---
      WriteU32(Dst, WOFF2_MAGIC);
      WriteU32(Dst, SfntSig);               // flavor
      WriteU32(Dst, WOFFSize);
      WriteU16(Dst, NumTables);
      WriteU16(Dst, 0);                     // reserved
      WriteU32(Dst, TotalSfntSize);
      WriteU32(Dst, TotalCompSize);
      WriteU16(Dst, 1); WriteU16(Dst, 0);   // majorVersion, minorVersion
      WriteU32(Dst, 0); WriteU32(Dst, 0); WriteU32(Dst, 0); // meta absent
      WriteU32(Dst, 0); WriteU32(Dst, 0);                    // priv absent

      // --- Table directory ---
      for I := 0 to NumTables - 1 do
      begin
        TagIdx := WOFF2TagIndex(Tags[I]);
        // glyf (10) and loca (11): transform version 3 = no transform, bits 6-7 = 11
        // all others             : transform version 0 = no-op,          bits 6-7 = 00
        if (TagIdx = 10) or (TagIdx = 11) then
          Flags := Byte(TagIdx) or $C0
        else
          Flags := Byte(TagIdx) and $3F;
        WriteU8(Dst, Flags);
        if TagIdx = 63 then WriteU32(Dst, Tags[I]);
        WriteUIntBase128(Dst, SfntLens[I]);
        // transformLength omitted (no transform applied)
      end;

      // --- Compressed data ---
      Comp.Position := 0;
      Dst.CopyFrom(Comp, Comp.Size);

    finally
      Comp.Free;
    end;
  finally
    Concat.Free;
  end;
end;

// ================================================================
// Inverse glyf/loca transform (WOFF2 spec section 5.1)
//
// A substream cursor reads big-endian values from a slice of the
// decompressed transformed-glyf table.
// ================================================================

type
  TSub = record
    Pos : LongWord;   // current read offset within TG
    Lim : LongWord;   // end offset within TG (exclusive)
  end;

function SubU8(const TG : TBytes; var S : TSub) : Byte;
begin
  if S.Pos >= S.Lim then raise Exception.Create('WOFF2 glyf: substream overrun');
  Result := TG[S.Pos]; Inc(S.Pos);
end;

function SubU16(const TG : TBytes; var S : TSub) : Word;
begin
  Result := (Word(SubU8(TG, S)) shl 8) or SubU8(TG, S);
end;

// 255UInt16 variable-length unsigned integer (WOFF2 spec section 6.1.1)
function Sub255UShort(const TG : TBytes; var S : TSub) : Word;
var Code : Byte;
begin
  Code := SubU8(TG, S);
  if      Code = 253 then Result := SubU16(TG, S)
  else if Code = 255 then Result := Word(SubU8(TG, S)) + 253
  else if Code = 254 then Result := Word(SubU8(TG, S)) + 506
  else                    Result := Code;
end;

procedure SubCopy(const TG : TBytes; var S : TSub; Dst : TStream; N : LongWord);
begin
  if N = 0 then Exit;
  if S.Pos + N > S.Lim then raise Exception.Create('WOFF2 glyf: substream copy overrun');
  Dst.WriteBuffer(TG[S.Pos], N);
  Inc(S.Pos, N);
end;

function WithSign(Flag, BaseVal : Integer) : Integer; inline;
begin
  if (Flag and 1) <> 0 then Result := BaseVal else Result := -BaseVal;
end;

// Reconstruct the original glyf and loca tables from a transformed glyf table.
procedure ReconstructGlyfLoca(const TG : TBytes; out GlyfOut, LocaOut : TBytes);
const
  FLAG_WE_HAVE_INSTRUCTIONS = $0100;
  FLAG_ARG_1_AND_2_ARE_WORDS = $0001;
  FLAG_WE_HAVE_A_SCALE       = $0008;
  FLAG_MORE_COMPONENTS       = $0020;
  FLAG_WE_HAVE_X_AND_Y_SCALE = $0040;
  FLAG_WE_HAVE_TWO_BY_TWO    = $0080;
var
  HdrLen : LongWord;
  OptionFlags, NumGlyphs, IndexFormat : Word;
  nContourSize, nPointsSize, FlagSize, GlyphSize,
  CompositeSize, BboxSize, InstrSize : LongWord;
  cNCont, cNPts, cFlag, cGlyph, cComp, cBbox, cInstr : TSub;
  BboxBitmapBase, Off : LongWord;
  BboxBitmapBytes : LongWord;

  Glyf  : TMemoryStream;
  Comp  : TMemoryStream;
  FlagsB, XsB, YsB : TMemoryStream;
  LocaStream : TMemoryStream;
  Offsets : array of LongWord;

  GI, C, P : Integer;
  nContours : SmallInt;
  TotalPts  : Integer;
  EndPts    : array of Word;
  PX, PY    : array of LongInt;
  OnCurve   : array of Boolean;
  Flag, F   : Byte;
  NData     : Integer;
  D0, D1, D2, D3, B0 : Integer;
  DX, DY    : Integer;
  CurX, CurY: LongInt;
  PrevX, PrevY : LongInt;
  XMin, YMin, XMax, YMax : LongInt;
  InstrLen  : Word;
  CFlags, GlyphIdx : Word;
  ArgBytes, ScaleBytes : Integer;
  HasInstr  : Boolean;
  FB        : Byte;
  GlyphStart : LongWord;

  function BBoxBitSet(Gi : Integer) : Boolean;
  begin
    Result := (TG[BboxBitmapBase + LongWord(Gi shr 3)]
               and (Byte($80) shr (Gi and 7))) <> 0;
  end;

begin
  if Length(TG) < 36 then
    raise Exception.Create('WOFF2 glyf: transformed table too small');

  // --- Transformed glyf header (36 bytes) ---
  // [0..1] reserved, [2..3] optionFlags, [4..5] numGlyphs, [6..7] indexFormat
  OptionFlags := (Word(TG[2]) shl 8) or TG[3];
  NumGlyphs   := (Word(TG[4]) shl 8) or TG[5];
  IndexFormat := (Word(TG[6]) shl 8) or TG[7];

  nContourSize  := (LongWord(TG[ 8]) shl 24) or (LongWord(TG[ 9]) shl 16) or (LongWord(TG[10]) shl 8) or TG[11];
  nPointsSize   := (LongWord(TG[12]) shl 24) or (LongWord(TG[13]) shl 16) or (LongWord(TG[14]) shl 8) or TG[15];
  FlagSize      := (LongWord(TG[16]) shl 24) or (LongWord(TG[17]) shl 16) or (LongWord(TG[18]) shl 8) or TG[19];
  GlyphSize     := (LongWord(TG[20]) shl 24) or (LongWord(TG[21]) shl 16) or (LongWord(TG[22]) shl 8) or TG[23];
  CompositeSize := (LongWord(TG[24]) shl 24) or (LongWord(TG[25]) shl 16) or (LongWord(TG[26]) shl 8) or TG[27];
  BboxSize      := (LongWord(TG[28]) shl 24) or (LongWord(TG[29]) shl 16) or (LongWord(TG[30]) shl 8) or TG[31];
  InstrSize     := (LongWord(TG[32]) shl 24) or (LongWord(TG[33]) shl 16) or (LongWord(TG[34]) shl 8) or TG[35];

  // --- Lay out substreams consecutively after the header ---
  HdrLen := 36;
  Off := HdrLen;
  cNCont.Pos := Off; cNCont.Lim := Off + nContourSize;  Inc(Off, nContourSize);
  cNPts.Pos  := Off; cNPts.Lim  := Off + nPointsSize;   Inc(Off, nPointsSize);
  cFlag.Pos  := Off; cFlag.Lim  := Off + FlagSize;      Inc(Off, FlagSize);
  cGlyph.Pos := Off; cGlyph.Lim := Off + GlyphSize;     Inc(Off, GlyphSize);
  cComp.Pos  := Off; cComp.Lim  := Off + CompositeSize; Inc(Off, CompositeSize);

  // bbox stream begins with a one-bit-per-glyph bitmap
  BboxBitmapBytes := (LongWord(NumGlyphs) + 7) shr 3;
  BboxBitmapBase  := Off;
  cBbox.Pos := Off + BboxBitmapBytes;
  cBbox.Lim := Off + BboxSize;
  Inc(Off, BboxSize);

  cInstr.Pos := Off; cInstr.Lim := Off + InstrSize;     Inc(Off, InstrSize);

  if Off > LongWord(Length(TG)) then
    raise Exception.Create('WOFF2 glyf: substream sizes exceed table length');

  Glyf   := TMemoryStream.Create;
  Comp   := TMemoryStream.Create;
  FlagsB := TMemoryStream.Create;
  XsB    := TMemoryStream.Create;
  YsB    := TMemoryStream.Create;
  try
    SetLength(Offsets, LongInt(NumGlyphs) + 1);

    for GI := 0 to NumGlyphs - 1 do
    begin
      Offsets[GI] := LongWord(Glyf.Size);
      nContours := SmallInt(SubU16(TG, cNCont));

      if nContours = 0 then
        // Empty glyph: contributes no data; loca offset unchanged.
        Continue

      else if nContours > 0 then
      begin
        // ---- Simple glyph ----
        SetLength(EndPts, nContours);
        TotalPts := 0;
        for C := 0 to nContours - 1 do
        begin
          Inc(TotalPts, Sub255UShort(TG, cNPts));
          EndPts[C] := Word(TotalPts - 1);
        end;

        SetLength(PX, TotalPts);
        SetLength(PY, TotalPts);
        SetLength(OnCurve, TotalPts);

        CurX := 0; CurY := 0;
        for P := 0 to TotalPts - 1 do
        begin
          Flag := SubU8(TG, cFlag);
          OnCurve[P] := (Flag and $80) = 0;
          F := Flag and $7F;

          if      F < 84  then NData := 1
          else if F < 120 then NData := 2
          else if F < 124 then NData := 3
          else                 NData := 4;

          D0 := 0; D1 := 0; D2 := 0; D3 := 0;
          if NData >= 1 then D0 := SubU8(TG, cGlyph);
          if NData >= 2 then D1 := SubU8(TG, cGlyph);
          if NData >= 3 then D2 := SubU8(TG, cGlyph);
          if NData >= 4 then D3 := SubU8(TG, cGlyph);

          if F < 10 then
          begin
            DX := 0;
            DY := WithSign(F, ((F and 14) shl 7) + D0);
          end
          else if F < 20 then
          begin
            DX := WithSign(F, (((F - 10) and 14) shl 7) + D0);
            DY := 0;
          end
          else if F < 84 then
          begin
            B0 := F - 20;
            DX := WithSign(F,        1 + (B0 and $30) + (D0 shr 4));
            DY := WithSign(F shr 1,  1 + ((B0 and $0C) shl 2) + (D0 and $0F));
          end
          else if F < 120 then
          begin
            B0 := F - 84;
            DX := WithSign(F,       1 + ((B0 div 12) shl 8) + D0);
            DY := WithSign(F shr 1, 1 + (((B0 mod 12) shr 2) shl 8) + D1);
          end
          else if F < 124 then
          begin
            DX := WithSign(F,       (D0 shl 4) + (D1 shr 4));
            DY := WithSign(F shr 1, ((D1 and $0F) shl 8) + D2);
          end
          else
          begin
            DX := WithSign(F,       (D0 shl 8) + D1);
            DY := WithSign(F shr 1, (D2 shl 8) + D3);
          end;

          CurX := CurX + DX;
          CurY := CurY + DY;
          PX[P] := CurX;
          PY[P] := CurY;
        end;

        // Instruction length and bytes
        InstrLen := Sub255UShort(TG, cGlyph);

        // Bounding box: explicit if its bitmap bit is set, else computed.
        if BBoxBitSet(GI) then
        begin
          XMin := SmallInt(SubU16(TG, cBbox));
          YMin := SmallInt(SubU16(TG, cBbox));
          XMax := SmallInt(SubU16(TG, cBbox));
          YMax := SmallInt(SubU16(TG, cBbox));
        end
        else if TotalPts > 0 then
        begin
          XMin := PX[0]; XMax := PX[0]; YMin := PY[0]; YMax := PY[0];
          for P := 1 to TotalPts - 1 do
          begin
            if PX[P] < XMin then XMin := PX[P];
            if PX[P] > XMax then XMax := PX[P];
            if PY[P] < YMin then YMin := PY[P];
            if PY[P] > YMax then YMax := PY[P];
          end;
        end
        else begin XMin := 0; YMin := 0; XMax := 0; YMax := 0; end;

        // Encode coordinates as standard glyf flags + delta bytes
        FlagsB.Clear; XsB.Clear; YsB.Clear;
        PrevX := 0; PrevY := 0;
        for P := 0 to TotalPts - 1 do
        begin
          FB := 0;
          if OnCurve[P] then FB := FB or $01;

          DX := PX[P] - PrevX;
          if DX = 0 then FB := FB or $10                      // X_IS_SAME (no byte)
          else if (DX >= -255) and (DX <= 255) then
          begin
            FB := FB or $02;                                  // X_SHORT
            if DX > 0 then FB := FB or $10;                   // positive
            WriteU8(XsB, Byte(Abs(DX)));
          end
          else
            WriteS16(XsB, SmallInt(DX));

          DY := PY[P] - PrevY;
          if DY = 0 then FB := FB or $20                      // Y_IS_SAME (no byte)
          else if (DY >= -255) and (DY <= 255) then
          begin
            FB := FB or $04;                                  // Y_SHORT
            if DY > 0 then FB := FB or $20;                   // positive
            WriteU8(YsB, Byte(Abs(DY)));
          end
          else
            WriteS16(YsB, SmallInt(DY));

          WriteU8(FlagsB, FB);
          PrevX := PX[P]; PrevY := PY[P];
        end;

        // Emit the reconstructed simple glyph
        WriteS16(Glyf, nContours);
        WriteS16(Glyf, SmallInt(XMin)); WriteS16(Glyf, SmallInt(YMin));
        WriteS16(Glyf, SmallInt(XMax)); WriteS16(Glyf, SmallInt(YMax));
        for C := 0 to nContours - 1 do WriteU16(Glyf, EndPts[C]);
        WriteU16(Glyf, InstrLen);
        SubCopy(TG, cInstr, Glyf, InstrLen);
        if FlagsB.Size > 0 then Glyf.WriteBuffer(FlagsB.Memory^, FlagsB.Size);
        if XsB.Size    > 0 then Glyf.WriteBuffer(XsB.Memory^,    XsB.Size);
        if YsB.Size    > 0 then Glyf.WriteBuffer(YsB.Memory^,    YsB.Size);
      end

      else
      begin
        // ---- Composite glyph (nContours = -1) ----
        Comp.Clear;
        HasInstr := False;
        repeat
          CFlags   := SubU16(TG, cComp);
          GlyphIdx := SubU16(TG, cComp);
          WriteU16(Comp, CFlags);
          WriteU16(Comp, GlyphIdx);

          if (CFlags and FLAG_WE_HAVE_INSTRUCTIONS) <> 0 then HasInstr := True;

          if (CFlags and FLAG_ARG_1_AND_2_ARE_WORDS) <> 0 then ArgBytes := 4
          else ArgBytes := 2;
          SubCopy(TG, cComp, Comp, ArgBytes);

          if      (CFlags and FLAG_WE_HAVE_A_SCALE)       <> 0 then ScaleBytes := 2
          else if (CFlags and FLAG_WE_HAVE_X_AND_Y_SCALE) <> 0 then ScaleBytes := 4
          else if (CFlags and FLAG_WE_HAVE_TWO_BY_TWO)    <> 0 then ScaleBytes := 8
          else                                                     ScaleBytes := 0;
          SubCopy(TG, cComp, Comp, ScaleBytes);
        until (CFlags and FLAG_MORE_COMPONENTS) = 0;

        // Composite glyphs always carry an explicit bbox.
        XMin := SmallInt(SubU16(TG, cBbox));
        YMin := SmallInt(SubU16(TG, cBbox));
        XMax := SmallInt(SubU16(TG, cBbox));
        YMax := SmallInt(SubU16(TG, cBbox));

        WriteS16(Glyf, -1);
        WriteS16(Glyf, SmallInt(XMin)); WriteS16(Glyf, SmallInt(YMin));
        WriteS16(Glyf, SmallInt(XMax)); WriteS16(Glyf, SmallInt(YMax));
        Glyf.WriteBuffer(Comp.Memory^, Comp.Size);

        if HasInstr then
        begin
          InstrLen := Sub255UShort(TG, cGlyph);
          WriteU16(Glyf, InstrLen);
          SubCopy(TG, cInstr, Glyf, InstrLen);
        end;
      end;

      // Pad each glyph to an even length so short-format loca offsets are valid.
      if (Glyf.Size and 1) <> 0 then WriteU8(Glyf, 0);
    end;

    Offsets[NumGlyphs] := LongWord(Glyf.Size);

    // Materialize glyf
    SetLength(GlyfOut, Glyf.Size);
    if Glyf.Size > 0 then Move(Glyf.Memory^, GlyfOut[0], Glyf.Size);

    // Build loca from the collected offsets
    LocaStream := TMemoryStream.Create;
    try
      if IndexFormat = 0 then
        for GI := 0 to NumGlyphs do WriteU16(LocaStream, Word(Offsets[GI] shr 1))
      else
        for GI := 0 to NumGlyphs do WriteU32(LocaStream, Offsets[GI]);
      SetLength(LocaOut, LocaStream.Size);
      if LocaStream.Size > 0 then Move(LocaStream.Memory^, LocaOut[0], LocaStream.Size);
    finally
      LocaStream.Free;
    end;

  finally
    Glyf.Free; Comp.Free; FlagsB.Free; XsB.Free; YsB.Free;
  end;

  // Touch optionFlags to silence "unused" notes; the optional overlap-simple
  // bitmap (optionFlags bit 0) is a rasterizer hint and is safely ignored.
  if (OptionFlags and 0) <> 0 then ;
end;

// ================================================================
// WOFF2 -> OTF
// ================================================================

procedure WOFF2ToOTF(Src, Dst : TStream);
var
  Sig       : LongWord;
  Flavor    : LongWord;
  NumTables : Word;
  TotalCompSize : LongWord;
  I, N, Pad : Integer;

  Tags      : array of LongWord;
  TagIdxs   : array of Integer;
  OrigLens  : array of LongWord;   // declared original length (informational)
  TransLens : array of LongWord;   // on-the-wire length within the Brotli stream
  TransVers : array of Byte;
  ChkSums   : array of LongWord;
  RawData   : array of TBytes;     // final reconstructed table bytes
  OutOffsets: array of LongWord;
  OutLens   : array of LongWord;

  CompData  : TMemoryStream;
  DecompData: TMemoryStream;

  Flags     : Byte;
  TagIdx    : Integer;
  SfntOff   : LongWord;
  SearchRange, EntrySelector, RangeShift : Word;
  Z : Byte;

  GlyfIdx, LocaIdx : Integer;
  TransGlyf : TBytes;
  GlyfOut, LocaOut : TBytes;

begin
  Src.Position := 0;
  Sig := ReadU32(Src);
  if Sig <> WOFF2_MAGIC then
    raise Exception.Create('WOFF2ToOTF: not a WOFF2 file (bad signature)');

  Flavor        := ReadU32(Src);
  ReadU32(Src);                         // total file length
  NumTables     := ReadU16(Src);
  ReadU16(Src);                         // reserved
  ReadU32(Src);                         // totalSfntSize
  TotalCompSize := ReadU32(Src);
  ReadU16(Src); ReadU16(Src);           // majorVersion, minorVersion
  ReadU32(Src); ReadU32(Src); ReadU32(Src); // meta offset/len/origLen
  ReadU32(Src); ReadU32(Src);               // priv offset/len
  // 48 bytes consumed

  SetLength(Tags,      NumTables);
  SetLength(TagIdxs,   NumTables);
  SetLength(OrigLens,  NumTables);
  SetLength(TransLens, NumTables);
  SetLength(TransVers, NumTables);
  SetLength(ChkSums,   NumTables);

  GlyfIdx := -1; LocaIdx := -1;

  for I := 0 to NumTables - 1 do
  begin
    Flags        := ReadU8(Src);
    TagIdx       := Flags and $3F;
    TransVers[I] := (Flags shr 6) and $03;

    if TagIdx = 63 then
      Tags[I] := ReadU32(Src)
    else
      Tags[I] := WOFF2_KNOWN_TAGS[TagIdx];
    TagIdxs[I] := TagIdx;

    OrigLens[I] := ReadUIntBase128(Src);

    if (TagIdx = 10) and (TransVers[I] = 0) then GlyfIdx := I;
    if (TagIdx = 11) and (TransVers[I] = 0) then LocaIdx := I;

    // A "transformed" table carries an explicit transformLength.
    // For glyf/loca that is transform version 0 (the standard transform).
    if ((TagIdx = 10) or (TagIdx = 11)) and (TransVers[I] = 0) then
      TransLens[I] := ReadUIntBase128(Src)   // bytes present in the stream
    else
    begin
      TransLens[I] := OrigLens[I];

      // glyf/loca may only be untransformed (v3) or transformed (v0).
      if ((TagIdx = 10) or (TagIdx = 11)) and (TransVers[I] <> 3) then
        raise Exception.CreateFmt(
          'WOFF2ToOTF: unsupported glyf/loca transform version %d', [TransVers[I]]);

      // Other tables only support the null transform (version 0).
      if (TagIdx <> 10) and (TagIdx <> 11) and (TransVers[I] <> 0) then
        raise Exception.CreateFmt(
          'WOFF2ToOTF: unsupported transform version %d for table %s',
          [TransVers[I], TagStr(Tags[I])]);
    end;
  end;

  if (GlyfIdx >= 0) and (LocaIdx < 0) then
    raise Exception.Create('WOFF2ToOTF: transformed glyf without a matching loca');

  // Decompress Brotli block
  CompData   := TMemoryStream.Create;
  DecompData := TMemoryStream.Create;
  try
    CompData.CopyFrom(Src, TotalCompSize);
    CompData.Position := 0;

    if BrotliDecompressStreams(CompData, DecompData) <> BROTLI_OK then
      raise Exception.Create('WOFF2ToOTF: Brotli decompression failed');

    // Slice the on-the-wire bytes for each table (no inter-table padding).
    // Transformed loca occupies zero bytes; its content is rebuilt from glyf.
    SetLength(RawData, NumTables);
    DecompData.Position := 0;
    for I := 0 to NumTables - 1 do
    begin
      SetLength(RawData[I], TransLens[I]);
      if TransLens[I] > 0 then
        DecompData.ReadBuffer(RawData[I][0], TransLens[I]);
    end;
  finally
    CompData.Free;
    DecompData.Free;
  end;

  // Apply the inverse glyf/loca transform if present.
  if GlyfIdx >= 0 then
  begin
    TransGlyf := RawData[GlyfIdx];
    ReconstructGlyfLoca(TransGlyf, GlyfOut, LocaOut);
    RawData[GlyfIdx] := GlyfOut;
    RawData[LocaIdx] := LocaOut;
  end;

  // Final per-table lengths and checksums (computed on reconstructed data).
  SetLength(OutLens, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    OutLens[I] := LongWord(Length(RawData[I]));
    ChkSums[I] := TableChecksum(Tags[I], RawData[I]);
  end;

  // Build sfnt
  SearchRange := 1; EntrySelector := 0;
  while SearchRange * 2 <= NumTables do
  begin
    SearchRange := SearchRange * 2;
    Inc(EntrySelector);
  end;
  SearchRange := SearchRange * 16;
  RangeShift  := NumTables * 16 - SearchRange;

  SetLength(OutOffsets, NumTables);
  SfntOff := 12 + LongWord(NumTables) * 16;
  for I := 0 to NumTables - 1 do
  begin
    OutOffsets[I] := SfntOff;
    N := OutLens[I] mod 4;
    Pad := IfThen(N > 0, 4 - N, 0);
    Inc(SfntOff, OutLens[I] + LongWord(Pad));
  end;

  // sfnt offset table
  WriteU32(Dst, Flavor);
  WriteU16(Dst, NumTables);
  WriteU16(Dst, SearchRange);
  WriteU16(Dst, EntrySelector);
  WriteU16(Dst, RangeShift);

  // sfnt table directory
  for I := 0 to NumTables - 1 do
  begin
    WriteU32(Dst, Tags[I]);
    WriteU32(Dst, ChkSums[I]);
    WriteU32(Dst, OutOffsets[I]);
    WriteU32(Dst, OutLens[I]);
  end;

  // Table data (4-byte padded)
  Z := 0;
  for I := 0 to NumTables - 1 do
  begin
    if OutLens[I] > 0 then Dst.WriteBuffer(RawData[I][0], OutLens[I]);
    N := OutLens[I] mod 4;
    if N > 0 then for Pad := 1 to 4 - N do Dst.WriteBuffer(Z, 1);
  end;
end;

// ================================================================
// Convenience wrappers: WOFF <-> WOFF2
// ================================================================

procedure WOFFToWOFF2(Src, Dst : TStream);
var Mid : TMemoryStream;
begin
  Mid := TMemoryStream.Create;
  try
    WOFFToOTF(Src, Mid);
    Mid.Position := 0;
    OTFToWOFF2(Mid, Dst);
  finally
    Mid.Free;
  end;
end;

procedure WOFF2ToWOFF(Src, Dst : TStream);
var Mid : TMemoryStream;
begin
  Mid := TMemoryStream.Create;
  try
    WOFF2ToOTF(Src, Mid);
    Mid.Position := 0;
    OTFToWOFF(Mid, Dst);
  finally
    Mid.Free;
  end;
end;

end.
