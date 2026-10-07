unit WOFFCodec;

{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Math, ZStream, FontTypes;
{$WARN 5093 off}

// Author: www.xelitan.com
// License: MIT
//
// WOFF 1.0 codec: OTF -> WOFF and WOFF -> OTF.
//
// WOFF file structure:
//   TWOFFHeader            (44 bytes)
//   TWOFFEntry[numTables]  (20 bytes each)
//   Compressed table data  (zlib-deflate, padded to 4 bytes)
//   [optional metadata block]
//   [optional private data]
//
// Compression uses FPC's built-in ZStream unit:
//   TCompressionStream   (zlib deflate, WindowBits=15 -> includes zlib header)
//   TDecompressionStream (zlib inflate)
//
// Only the font table data is handled here; metadata and private data
// blocks are not generated on encoding (set to absent). On decoding they
// are silently skipped.


// Convert a CFF-based OTF (or any sfnt font) to WOFF 1.0
procedure OTFToWOFF(Src, Dst : TStream);

// Reconstruct an sfnt font from a WOFF 1.0 file
procedure WOFFToOTF(Src, Dst : TStream);

implementation

// ================================================================
// WOFF header and table entry (all fields big-endian)
// ================================================================

type
  TWOFFEntry = record
    Tag        : TTableTag;
    Offset     : LongWord;
    CompLength : LongWord;
    OrigLength : LongWord;
    OrigChecksum: LongWord;
  end;

// ================================================================
// Compression helpers using ZStream
// ================================================================

function CompressTable(const Raw : TBytes) : TBytes;
// Compress Raw with zlib deflate.  Returns Raw unchanged if the
// compressed result is not smaller (WOFF stores the original in that case).
var
  Src, Dst : TMemoryStream;
  Comp     : TCompressionStream;
begin
  if Length(Raw) = 0 then begin Result := Raw; Exit; end;

  Src := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    Src.WriteBuffer(Raw[0], Length(Raw));
    Src.Position := 0;

    Comp := TCompressionStream.Create(clDefault, Dst);
    try
      Comp.CopyFrom(Src, Src.Size);
    finally
      Comp.Free;  // must Free to flush the zlib trailer
    end;

    if Dst.Size < Int64(Length(Raw)) then
    begin
      SetLength(Result, Dst.Size);
      Dst.Position := 0;
      Dst.ReadBuffer(Result[0], Dst.Size);
    end
    else
      Result := Raw;  // not compressible: store original
  finally
    Src.Free; Dst.Free;
  end;
end;

function DecompressTable(const Comp : TBytes; OrigLen : LongWord) : TBytes;
// Inflate a zlib-compressed table back to its original size.
var
  Src    : TMemoryStream;
  Dst    : TMemoryStream;
  Decomp : TDecompressionStream;
begin
  if Length(Comp) = 0 then begin SetLength(Result, 0); Exit; end;

  if LongWord(Length(Comp)) = OrigLen then
  begin
    // Stored uncompressed
    Result := Comp;
    Exit;
  end;

  Src := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    Src.WriteBuffer(Comp[0], Length(Comp));
    Src.Position := 0;
    Decomp := TDecompressionStream.Create(Src);
    try
      Dst.CopyFrom(Decomp, 0);
    finally
      Decomp.Free;
    end;
    SetLength(Result, Dst.Size);
    Dst.Position := 0;
    if Dst.Size > 0 then Dst.ReadBuffer(Result[0], Dst.Size);
  finally
    Src.Free; Dst.Free;
  end;
  if LongWord(Length(Result)) <> OrigLen then
    raise Exception.CreateFmt(
      'WOFF decompress: expected %d bytes, got %d', [OrigLen, Length(Result)]);
end;

// ================================================================
// OTF -> WOFF
// ================================================================

procedure OTFToWOFF(Src, Dst : TStream);
var
  SfntSig    : LongWord;
  NumTables  : Word;
  I          : Integer;

  Tags       : array of TTableTag;
  ChkSums    : array of LongWord;
  SfntOffs   : array of LongWord;
  SfntLens   : array of LongWord;

  RawData    : array of TBytes;
  CompData   : array of TBytes;

  WEntry     : array of TWOFFEntry;

  DataOffset : LongWord;
  TotalSfntSize : LongWord;
  WOFFSize   : LongWord;

  Pad, N     : Integer;
  Z          : Byte;

  // WOFF header fields
  Flavor     : LongWord;

begin
  Src.Position := 0;
  SfntSig  := ReadU32(Src);
  if (SfntSig <> SFNT_CFF) and (SfntSig <> SFNT_TRUE) and
     (SfntSig <> SFNT_TRUE2) then
    raise Exception.Create('OTFToWOFF: source is not a valid sfnt font');
  Flavor := SfntSig;

  NumTables := ReadU16(Src);
  ReadU16(Src); ReadU16(Src); ReadU16(Src);  // searchRange, entrySelector, rangeShift

  SetLength(Tags,    NumTables);
  SetLength(ChkSums, NumTables);
  SetLength(SfntOffs,NumTables);
  SetLength(SfntLens,NumTables);

  for I := 0 to NumTables - 1 do
  begin
    Tags[I]     := ReadU32(Src);
    ChkSums[I]  := ReadU32(Src);
    SfntOffs[I] := ReadU32(Src);
    SfntLens[I] := ReadU32(Src);
  end;

  // Read raw table bytes and compress each one
  SetLength(RawData,  NumTables);
  SetLength(CompData, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    SetLength(RawData[I], SfntLens[I]);
    if SfntLens[I] > 0 then
    begin
      Src.Position := SfntOffs[I];
      Src.ReadBuffer(RawData[I][0], SfntLens[I]);
    end;
    CompData[I] := CompressTable(RawData[I]);
  end;

  // Compute total sfnt size (original, for WOFF header)
  // = offset table (12) + directory (16*N) + sum of padded table sizes
  TotalSfntSize := 12 + LongWord(NumTables) * 16;
  for I := 0 to NumTables - 1 do
  begin
    N := SfntLens[I] mod 4;
    Inc(TotalSfntSize, SfntLens[I] + LongWord(IfThen(N > 0, 4 - N, 0)));
  end;

  // Build WOFF table directory with data offsets
  SetLength(WEntry, NumTables);
  DataOffset := 44 + LongWord(NumTables) * 20;  // header + directory
  for I := 0 to NumTables - 1 do
  begin
    WEntry[I].Tag         := Tags[I];
    WEntry[I].Offset      := DataOffset;
    WEntry[I].CompLength  := Length(CompData[I]);
    WEntry[I].OrigLength  := SfntLens[I];
    WEntry[I].OrigChecksum := ChkSums[I];
    N   := Length(CompData[I]) mod 4;
    Pad := IfThen(N > 0, 4 - N, 0);
    Inc(DataOffset, LongWord(Length(CompData[I])) + LongWord(Pad));
  end;
  WOFFSize := DataOffset;  // no metadata or private data block

  // Write WOFF header
  WriteU32(Dst, WOFF_MAGIC);         // signature
  WriteU32(Dst, Flavor);             // sfnt flavor
  WriteU32(Dst, WOFFSize);           // total WOFF file length
  WriteU16(Dst, NumTables);          // numTables
  WriteU16(Dst, 0);                  // reserved
  WriteU32(Dst, TotalSfntSize);      // totalSfntSize
  WriteU16(Dst, 1); WriteU16(Dst, 0); // majorVersion, minorVersion
  WriteU32(Dst, 0); WriteU32(Dst, 0); WriteU32(Dst, 0);  // metaOffset/Len/OrigLen
  WriteU32(Dst, 0); WriteU32(Dst, 0);                     // privOffset/Len

  // Write WOFF table directory (20 bytes per entry)
  for I := 0 to NumTables - 1 do
  begin
    WriteU32(Dst, WEntry[I].Tag);
    WriteU32(Dst, WEntry[I].Offset);
    WriteU32(Dst, WEntry[I].CompLength);
    WriteU32(Dst, WEntry[I].OrigLength);
    WriteU32(Dst, WEntry[I].OrigChecksum);
  end;

  // Write compressed table data (4-byte padded)
  Z := 0;
  for I := 0 to NumTables - 1 do
  begin
    if Length(CompData[I]) > 0 then
      Dst.WriteBuffer(CompData[I][0], Length(CompData[I]));
    N := Length(CompData[I]) mod 4;
    if N > 0 then for Pad := 1 to 4 - N do Dst.WriteBuffer(Z, 1);
  end;
end;

// ================================================================
// WOFF -> OTF
// ================================================================

procedure WOFFToOTF(Src, Dst : TStream);
var
  Sig, Flavor  : LongWord;
  NumTables    : Word;
  I, N, Pad    : Integer;

  WEntry     : array of TWOFFEntry;
  Raw        : array of TBytes;
  Comp       : TBytes;

  DataStart  : LongWord;
  SfntOffset : LongWord;
  OutOffsets : array of LongWord;
  OutLens    : array of LongWord;

  SearchRange, EntrySelector, RangeShift : Word;
  Z : Byte;

begin
  Src.Position := 0;
  Sig  := ReadU32(Src);
  if Sig <> WOFF_MAGIC then
    raise Exception.Create('WOFFToOTF: not a WOFF file (bad signature)');

  Flavor    := ReadU32(Src);
  ReadU32(Src);                    // WOFF file length - not needed
  NumTables := ReadU16(Src);
  ReadU16(Src);                    // reserved
  ReadU32(Src);                    // totalSfntSize - not needed
  ReadU16(Src); ReadU16(Src);      // major/minor version
  ReadU32(Src); ReadU32(Src); ReadU32(Src); // meta offset/len/origLen
  ReadU32(Src); ReadU32(Src);              // priv offset/len

  SetLength(WEntry, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    WEntry[I].Tag          := ReadU32(Src);
    WEntry[I].Offset       := ReadU32(Src);
    WEntry[I].CompLength   := ReadU32(Src);
    WEntry[I].OrigLength   := ReadU32(Src);
    WEntry[I].OrigChecksum := ReadU32(Src);
  end;

  // Decompress each table
  SetLength(Raw, NumTables);
  for I := 0 to NumTables - 1 do
  begin
    SetLength(Comp, WEntry[I].CompLength);
    if WEntry[I].CompLength > 0 then
    begin
      Src.Position := WEntry[I].Offset;
      Src.ReadBuffer(Comp[0], WEntry[I].CompLength);
    end;
    Raw[I] := DecompressTable(Comp, WEntry[I].OrigLength);
  end;

  // Build sfnt output
  SearchRange   := 1; EntrySelector := 0;
  while SearchRange * 2 <= NumTables do
  begin SearchRange := SearchRange * 2; Inc(EntrySelector); end;
  SearchRange := SearchRange * 16;
  RangeShift  := NumTables * 16 - SearchRange;

  DataStart := 12 + LongWord(NumTables) * 16;

  // Compute table offsets in the reconstructed sfnt
  SetLength(OutOffsets, NumTables);
  SetLength(OutLens, NumTables);
  SfntOffset := DataStart;
  for I := 0 to NumTables - 1 do
  begin
    OutOffsets[I] := SfntOffset;
    OutLens[I]    := WEntry[I].OrigLength;
    N   := OutLens[I] mod 4;
    Pad := IfThen(N > 0, 4 - N, 0);
    Inc(SfntOffset, OutLens[I] + LongWord(Pad));
  end;

  // Write sfnt offset table
  WriteU32(Dst, Flavor);
  WriteU16(Dst, NumTables);
  WriteU16(Dst, SearchRange);
  WriteU16(Dst, EntrySelector);
  WriteU16(Dst, RangeShift);

  // Write sfnt table directory
  for I := 0 to NumTables - 1 do
  begin
    WriteU32(Dst, WEntry[I].Tag);
    WriteU32(Dst, WEntry[I].OrigChecksum);
    WriteU32(Dst, OutOffsets[I]);
    WriteU32(Dst, OutLens[I]);
  end;

  // Write decompressed table data (4-byte padded)
  Z := 0;
  for I := 0 to NumTables - 1 do
  begin
    if OutLens[I] > 0 then Dst.WriteBuffer(Raw[I][0], OutLens[I]);
    N := OutLens[I] mod 4;
    if N > 0 then for Pad := 1 to 4 - N do Dst.WriteBuffer(Z, 1);
  end;
end;

end.
