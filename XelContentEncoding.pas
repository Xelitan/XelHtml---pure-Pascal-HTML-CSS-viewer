unit XelContentEncoding;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// HTTP Content-Encoding decoding for downloaded bodies.
// Supported: identity, gzip / x-gzip, deflate (zlib-wrapped or raw, as sent
// by some servers) and br (Brotli). gzip/deflate use XelInflate, br uses
// SimpleBrotli — all pure Pascal, no zlib DLL.

interface

uses
  Classes, SysUtils;

// The Accept-Encoding value matching what DecodeContentEncoding can handle.
const
  ACCEPT_ENCODING = 'gzip, deflate, br';

// Decodes Data in place according to the Content-Encoding header value
// (a comma-separated list, applied by the server in order, so undone in
// reverse). Raises an exception on an unknown encoding or corrupt data.
procedure DecodeContentEncoding(const Encoding: string; Data: TMemoryStream);

implementation

uses
  XelInflate, SimpleBrotli;

const
  GZ_FHCRC    = $02;
  GZ_FEXTRA   = $04;
  GZ_FNAME    = $08;
  GZ_FCOMMENT = $10;

// Offset of the raw DEFLATE data after the gzip member header (RFC 1952).
function GzipDataOffset(P: PByte; Len: NativeUInt): NativeUInt;
var
  Flags: Byte;
  XLen: NativeUInt;
begin
  if (Len < 18) or (P[0] <> $1F) or (P[1] <> $8B) or (P[2] <> 8) then
    raise Exception.Create('gzip: invalid header');
  Flags := P[3];
  Result := 10;
  if Flags and GZ_FEXTRA <> 0 then
  begin
    if Result + 2 > Len then
      raise Exception.Create('gzip: truncated header');
    XLen := P[Result] or (NativeUInt(P[Result + 1]) shl 8);
    Inc(Result, 2 + XLen);
  end;
  if Flags and GZ_FNAME <> 0 then
  begin
    while (Result < Len) and (P[Result] <> 0) do
      Inc(Result);
    Inc(Result);
  end;
  if Flags and GZ_FCOMMENT <> 0 then
  begin
    while (Result < Len) and (P[Result] <> 0) do
      Inc(Result);
    Inc(Result);
  end;
  if Flags and GZ_FHCRC <> 0 then
    Inc(Result, 2);
  if Result >= Len then
    raise Exception.Create('gzip: truncated header');
end;

// HTTP "deflate" should be zlib-wrapped, but some servers send raw DEFLATE.
function IsZlibHeader(P: PByte; Len: NativeUInt): Boolean;
begin
  Result := (Len >= 2) and (P[0] and $0F = 8) and (P[0] shr 4 <= 7) and
    (((Cardinal(P[0]) shl 8) or P[1]) mod 31 = 0);
end;

procedure ReplaceData(Data: TMemoryStream; const Bytes: TBytes);
begin
  Data.Clear;
  if Length(Bytes) > 0 then
    Data.WriteBuffer(Bytes[0], Length(Bytes));
  Data.Position := 0;
end;

procedure DecodeOne(const Enc: string; Data: TMemoryStream);
var
  P: PByte;
  Len, Ofs: NativeUInt;
  Output: TMemoryStream;
begin
  P := Data.Memory;
  Len := Data.Size;
  if (Enc = '') or (Enc = 'identity') then
    Exit;
  if Len = 0 then
    Exit;
  if (Enc = 'gzip') or (Enc = 'x-gzip') then
  begin
    Ofs := GzipDataOffset(P, Len);
    ReplaceData(Data, InflateRaw(P + Ofs, Len - Ofs));
  end
  else if Enc = 'deflate' then
  begin
    if IsZlibHeader(P, Len) then
      ReplaceData(Data, InflateZlib(P, Len))
    else
      ReplaceData(Data, InflateRaw(P, Len));
  end
  else if Enc = 'br' then
  begin
    Output := TMemoryStream.Create;
    try
      Data.Position := 0;
      if BrotliDecompressStreams(Data, Output) <> BROTLI_OK then
        raise Exception.Create('br: corrupt Brotli data');
      Data.Clear;
      Data.CopyFrom(Output, 0);
      Data.Position := 0;
    finally
      Output.Free;
    end;
  end
  else
    raise Exception.CreateFmt('Unsupported Content-Encoding: %s', [Enc]);
end;

procedure DecodeContentEncoding(const Encoding: string; Data: TMemoryStream);
var
  Parts: TStringList;
  I: Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := LowerCase(Encoding);
    for I := Parts.Count - 1 downto 0 do
      DecodeOne(Trim(Parts[I]), Data);
  finally
    Parts.Free;
  end;
  Data.Position := 0;
end;

end.
