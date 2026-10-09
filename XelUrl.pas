unit XelUrl;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Resolution of URLs (http://) and local paths.
// Relative resource addresses (img src, link href...) are resolved
// against the document's base address.

interface

function ResolveUrl(const Base, Rel: string): string;
function IsHttpUrl(const S: string): Boolean;
function IsHttpsUrl(const S: string): Boolean;
function StripFragment(const S: string): string;
// file:// URL -> local path: 'file:///C:/a/b' -> 'C:\a\b' on Windows,
// 'file:///a/b' -> '/a/b' elsewhere. Other strings are returned unchanged.
function FileUrlToPath(const Url: string): string;
// data: URL -> its bytes (percent-decoded, then base64-decoded when marked
// ';base64'). MimeType is lower case, e.g. 'image/png'. False if not a data: URL.
function DecodeDataUrl(const Url: string; out Data: RawByteString;
  out MimeType: string): Boolean;

implementation

uses
  SysUtils, base64;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := SameText(Copy(S, 1, 7), 'http://');
end;

function IsHttpsUrl(const S: string): Boolean;
begin
  Result := SameText(Copy(S, 1, 8), 'https://');
end;

function StripFragment(const S: string): string;
var
  I: Integer;
begin
  I := Pos('#', S);
  if I > 0 then
    Result := Copy(S, 1, I - 1)
  else
    Result := S;
end;

function FileUrlToPath(const Url: string): string;
begin
  Result := Url;
  if not SameText(Copy(Result, 1, 7), 'file://') then
    Exit;
  Result := Copy(Result, 8, MaxInt);  // '/C:/a' or '/a/b' (file:///), 'C:/a' (file://C:/a)
  {$IFDEF MSWINDOWS}
  if (Result <> '') and (Result[1] = '/') then
    Delete(Result, 1, 1);
  {$ENDIF}
  Result := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
end;

function DecodeDataUrl(const Url: string; out Data: RawByteString;
  out MimeType: string): Boolean;
var
  P, I: Integer;
  Meta, Payload: string;
begin
  Data := '';
  MimeType := '';
  Result := SameText(Copy(Url, 1, 5), 'data:');
  if not Result then Exit;
  P := Pos(',', Url);
  if P = 0 then Exit(False);
  Meta := LowerCase(Copy(Url, 6, P - 6));
  Payload := Copy(Url, P + 1, MaxInt);
  MimeType := Trim(Copy(Meta, 1, Pos(';', Meta + ';') - 1));
  // percent-decode first (Acid2 encodes '/', '+', '=' even inside base64)
  SetLength(Data, Length(Payload));
  P := 0;
  I := 1;
  while I <= Length(Payload) do
  begin
    Inc(P);
    if (Payload[I] = '%') and (I + 2 <= Length(Payload)) then
    begin
      Data[P] := AnsiChar(StrToIntDef('$' + Copy(Payload, I + 1, 2), 32));
      Inc(I, 3);
    end
    else
    begin
      Data[P] := AnsiChar(Payload[I]);
      Inc(I);
    end;
  end;
  SetLength(Data, P);
  if Pos(';base64', Meta) > 0 then
    Data := DecodeStringBase64(Data);
end;

// Whether the string starts with a scheme, e.g. "http:", "data:", "mailto:"
function HasScheme(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (S = '') or not (S[1] in ['a'..'z', 'A'..'Z']) then
    Exit;
  I := 2;
  while (I <= Length(S)) and (S[I] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.']) do
    Inc(I);
  Result := (I <= Length(S)) and (S[I] = ':');
end;

// Normalizes a URL path: removes "." and ".." segments. The path starts with '/'.
function NormalizeUrlPath(const Path: string): string;
var
  Segs: array of string;
  Count, I, P, Start: Integer;
  Seg, QueryPart, PathOnly: string;
begin
  P := Pos('?', Path);
  if P > 0 then
  begin
    PathOnly := Copy(Path, 1, P - 1);
    QueryPart := Copy(Path, P, MaxInt);
  end
  else
  begin
    PathOnly := Path;
    QueryPart := '';
  end;

  SetLength(Segs, 0);
  Count := 0;
  Start := 1;
  for I := 1 to Length(PathOnly) + 1 do
    if (I > Length(PathOnly)) or (PathOnly[I] = '/') then
    begin
      Seg := Copy(PathOnly, Start, I - Start);
      Start := I + 1;
      if (Seg = '') or (Seg = '.') then
        Continue
      else if Seg = '..' then
      begin
        if Count > 0 then
          Dec(Count);
      end
      else
      begin
        if Count >= Length(Segs) then
          SetLength(Segs, Count + 8);
        Segs[Count] := Seg;
        Inc(Count);
      end;
    end;

  Result := '';
  for I := 0 to Count - 1 do
    Result := Result + '/' + Segs[I];
  if Result = '' then
    Result := '/';
  // keep the trailing '/' if there was one (matters for directories)
  if (PathOnly <> '') and (PathOnly[Length(PathOnly)] = '/') and (Result <> '/') then
    Result := Result + '/';
  Result := Result + QueryPart;
end;

// Splits an http URL into the root ("http://host:port") and the path ("/a/b?q")
procedure SplitHttp(const Url: string; out Root, Path: string);
var
  P: Integer;
  Rest: string;
begin
  Rest := Copy(Url, 8, MaxInt); // after "http://"
  P := Pos('/', Rest);
  if P = 0 then
  begin
    Root := Url;
    Path := '/';
  end
  else
  begin
    Root := Copy(Url, 1, 7 + P - 1);
    Path := Copy(Rest, P, MaxInt);
  end;
end;

// Directory of a URL path: "/a/b/c.html" -> "/a/b/"
function UrlPathDir(const Path: string): string;
var
  I: Integer;
begin
  Result := '/';
  for I := Length(Path) downto 1 do
    if Path[I] = '/' then
    begin
      Result := Copy(Path, 1, I);
      Exit;
    end;
end;

function ResolveUrl(const Base, Rel: string): string;
var
  R, Root, Path: string;
begin
  R := Trim(StripFragment(Rel));
  if R = '' then
    Exit(StripFragment(Base));

  // Absolute URL with any scheme
  if HasScheme(R) then
    Exit(R);

  // Protocol-relative: //host/path
  if (Length(R) >= 2) and (R[1] = '/') and (R[2] = '/') then
  begin
    if IsHttpsUrl(Base) then
      Exit('https:' + R)
    else
      Exit('http:' + R);
  end;

  if IsHttpUrl(Base) or IsHttpsUrl(Base) then
  begin
    if IsHttpUrl(Base) then
      SplitHttp(Base, Root, Path)
    else
    begin
      // https — resolved correctly, even though fetching may report it as unsupported
      Path := Copy(Base, 9, MaxInt);
      if Pos('/', Path) > 0 then
      begin
        Root := Copy(Base, 1, 8 + Pos('/', Path) - 1);
        Path := Copy(Path, Pos('/', Path), MaxInt);
      end
      else
      begin
        Root := Base;
        Path := '/';
      end;
    end;
    if R[1] = '/' then
      Result := Root + NormalizeUrlPath(R)
    else
      Result := Root + NormalizeUrlPath(UrlPathDir(Path) + R);
  end
  else
  begin
    // Local base — a file on disk
    R := StringReplace(R, '/', PathDelim, [rfReplaceAll]);
    if (R <> '') and (R[1] = PathDelim) then
      Result := ExtractFileDrive(Base) + R
    else
      Result := ExpandFileName(ExtractFilePath(Base) + R);
  end;
end;

end.
