unit XelHtmlParser;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// HTML parser: TStream/string -> TDOMDocument.
// Forgiving, like browsers: tolerates unclosed tags,
// auto-closes <p>, <li>, <td>..., creates missing
// html/head/body, decodes entities (&amp; &#123; &#xAB;),
// treats <script>/<style> as raw text. Encoding: UTF-8.

interface

uses
  Classes, SysUtils, XelDom;

procedure ParseHtmlString(const Src: string; Doc: TDOMDocument);

// CharsetHint: charset taken from the HTTP Content-Type header; it wins
// over the <meta charset> declaration. Empty = autodetect from meta/BOM.
procedure ParseHtmlStream(S: TStream; Doc: TDOMDocument;
  const CharsetHint: string = '');

function DecodeEntities(const S: string): string;

implementation

uses
  Generics.Collections, LConvEncoding, XelTextUtil;

// ---- entities ----

function CodepointToUTF8(CP: Cardinal): string;
begin
  if CP < $80 then
    Result := Chr(CP)
  else if CP < $800 then
    Result := Chr($C0 or (CP shr 6)) + Chr($80 or (CP and $3F))
  else if CP < $10000 then
    Result := Chr($E0 or (CP shr 12)) + Chr($80 or ((CP shr 6) and $3F)) +
              Chr($80 or (CP and $3F))
  else
    Result := Chr($F0 or (CP shr 18)) + Chr($80 or ((CP shr 12) and $3F)) +
              Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F));
end;

type
  TEntityDef = record
    N: string;
    CP: Cardinal; // 0 = empty replacement (e.g. &shy;)
  end;

const
  // most common named entities
  ENTITIES: array[0..37] of TEntityDef = (
    (N: 'amp';    CP: 38),    (N: 'lt';     CP: 60),
    (N: 'gt';     CP: 62),    (N: 'quot';   CP: 34),
    (N: 'apos';   CP: 39),    (N: 'nbsp';   CP: $A0),
    (N: 'copy';   CP: $A9),   (N: 'reg';    CP: $AE),
    (N: 'trade';  CP: $2122), (N: 'hellip'; CP: $2026),
    (N: 'mdash';  CP: $2014), (N: 'ndash';  CP: $2013),
    (N: 'lsquo';  CP: $2018), (N: 'rsquo';  CP: $2019),
    (N: 'ldquo';  CP: $201C), (N: 'rdquo';  CP: $201D),
    (N: 'bdquo';  CP: $201E), (N: 'laquo';  CP: $AB),
    (N: 'raquo';  CP: $BB),   (N: 'bull';   CP: $2022),
    (N: 'middot'; CP: $B7),   (N: 'deg';    CP: $B0),
    (N: 'plusmn'; CP: $B1),   (N: 'times';  CP: $D7),
    (N: 'divide'; CP: $F7),   (N: 'frac12'; CP: $BD),
    (N: 'frac14'; CP: $BC),   (N: 'sect';   CP: $A7),
    (N: 'para';   CP: $B6),   (N: 'euro';   CP: $20AC),
    (N: 'pound';  CP: $A3),   (N: 'cent';   CP: $A2),
    (N: 'yen';    CP: $A5),   (N: 'larr';   CP: $2190),
    (N: 'rarr';   CP: $2192), (N: 'uarr';   CP: $2191),
    (N: 'darr';   CP: $2193), (N: 'shy';    CP: 0)
  );

const
  // Cyrillic entities (HTML5 *cy) — NOTE: they are case-sensitive
  // (Dcy = Д, dcy = д), so matching must be case-sensitive
  CYR_ENTITIES: array[0..63] of TEntityDef = (
    (N: 'Acy'; CP: $0410), (N: 'Bcy'; CP: $0411), (N: 'Vcy'; CP: $0412),
    (N: 'Gcy'; CP: $0413), (N: 'Dcy'; CP: $0414), (N: 'IEcy'; CP: $0415),
    (N: 'ZHcy'; CP: $0416), (N: 'Zcy'; CP: $0417), (N: 'Icy'; CP: $0418),
    (N: 'Jcy'; CP: $0419), (N: 'Kcy'; CP: $041A), (N: 'Lcy'; CP: $041B),
    (N: 'Mcy'; CP: $041C), (N: 'Ncy'; CP: $041D), (N: 'Ocy'; CP: $041E),
    (N: 'Pcy'; CP: $041F), (N: 'Rcy'; CP: $0420), (N: 'Scy'; CP: $0421),
    (N: 'Tcy'; CP: $0422), (N: 'Ucy'; CP: $0423), (N: 'Fcy'; CP: $0424),
    (N: 'KHcy'; CP: $0425), (N: 'TScy'; CP: $0426), (N: 'CHcy'; CP: $0427),
    (N: 'SHcy'; CP: $0428), (N: 'SHCHcy'; CP: $0429), (N: 'HARDcy'; CP: $042A),
    (N: 'Ycy'; CP: $042B), (N: 'SOFTcy'; CP: $042C), (N: 'Ecy'; CP: $042D),
    (N: 'YUcy'; CP: $042E), (N: 'YAcy'; CP: $042F),
    (N: 'acy'; CP: $0430), (N: 'bcy'; CP: $0431), (N: 'vcy'; CP: $0432),
    (N: 'gcy'; CP: $0433), (N: 'dcy'; CP: $0434), (N: 'iecy'; CP: $0435),
    (N: 'zhcy'; CP: $0436), (N: 'zcy'; CP: $0437), (N: 'icy'; CP: $0438),
    (N: 'jcy'; CP: $0439), (N: 'kcy'; CP: $043A), (N: 'lcy'; CP: $043B),
    (N: 'mcy'; CP: $043C), (N: 'ncy'; CP: $043D), (N: 'ocy'; CP: $043E),
    (N: 'pcy'; CP: $043F), (N: 'rcy'; CP: $0440), (N: 'scy'; CP: $0441),
    (N: 'tcy'; CP: $0442), (N: 'ucy'; CP: $0443), (N: 'fcy'; CP: $0444),
    (N: 'khcy'; CP: $0445), (N: 'tscy'; CP: $0446), (N: 'chcy'; CP: $0447),
    (N: 'shcy'; CP: $0448), (N: 'shchcy'; CP: $0449), (N: 'hardcy'; CP: $044A),
    (N: 'ycy'; CP: $044B), (N: 'softcy'; CP: $044C), (N: 'ecy'; CP: $044D),
    (N: 'yucy'; CP: $044E), (N: 'yacy'; CP: $044F)
  );

function NamedEntity(const Name: string; out Rep: string): Boolean;

  function Lookup(const Tab: array of TEntityDef; const Key: string): Boolean;
  var I: Integer;
  begin
    for I := 0 to High(Tab) do
      if Tab[I].N = Key then   // case-sensitive comparison
      begin
        if Tab[I].CP = 0 then Rep := ''
        else Rep := CodepointToUTF8(Tab[I].CP);
        Exit(True);
      end;
    Result := False;
  end;

begin
  Rep := '';
  // 1) exact match (case-sensitive) — required for Cyrillic
  if Lookup(CYR_ENTITIES, Name) then Exit(True);
  if Lookup(ENTITIES, Name) then Exit(True);
  // 2) fallback: basic entities, case-insensitive (e.g. &AMP;)
  if Lookup(ENTITIES, LowerCase(Name)) then Exit(True);
  Result := False;
end;

function DecodeEntities(const S: string): string;
var
  I, J, Len: Integer;
  Name, Rep: string;
  CP: Cardinal;
  Ok: Boolean;
begin
  Result := '';
  Len := Length(S);
  I := 1;
  while I <= Len do
  begin
    if S[I] = '&' then
    begin
      // find ';' within a reasonable distance
      J := I + 1;
      while (J <= Len) and (J - I <= 32) and (S[J] <> ';') and (S[J] <> '&') and
            (S[J] <> ' ') do
        Inc(J);
      if (J <= Len) and (S[J] = ';') and (J > I + 1) then
      begin
        Name := Copy(S, I + 1, J - I - 1);
        Rep := '';
        Ok := False;
        if Name[1] = '#' then
        begin
          CP := 0;
          if (Length(Name) > 1) and (Name[2] in ['x', 'X']) then
            Ok := TryStrToDWord('$' + Copy(Name, 3, MaxInt), CP)
          else
            Ok := TryStrToDWord(Copy(Name, 2, MaxInt), CP);
          if Ok and (CP > 0) and (CP <= $10FFFF) then
            Rep := CodepointToUTF8(CP)
          else
            Ok := False;
        end
        else
          Ok := NamedEntity(Name, Rep);
        if Ok then
        begin
          Result := Result + Rep;
          I := J + 1;
          Continue;
        end;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

// ---- helper tag sets ----

function IsVoidElement(const Tag: string): Boolean;
begin
  Result := StrIn(Tag, ['area', 'base', 'br', 'col', 'embed', 'hr', 'img',
    'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
end;

function IsRawTextElement(const Tag: string): Boolean;
begin
  Result := (Tag = 'script') or (Tag = 'style') or (Tag = 'textarea') or
            (Tag = 'title');
end;

function IsHeadOnlyElement(const Tag: string): Boolean;
begin
  Result := StrIn(Tag, ['title', 'meta', 'link', 'base', 'style']);
end;

// block tags that automatically close an open <p>
function ClosesP(const Tag: string): Boolean;
begin
  Result := StrIn(Tag, ['address', 'article', 'aside', 'blockquote', 'div',
    'dl', 'fieldset', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'header', 'hr', 'main', 'nav', 'ol', 'p', 'pre', 'section', 'table',
    'ul', 'li', 'figure', 'figcaption', 'dt', 'dd']);
end;

// ---- parser ----

type
  THtmlParser = class
  private
    FSrc: string;
    FPos, FLen: Integer;
    FDoc: TDOMDocument;
    FStack: TList<TDOMElement>; // open elements; [0] = body
    FHtml, FHead, FBody: TDOMElement;
    FInBody: Boolean;
    function CurParent: TDOMElement;
    procedure PopTo(const Tag: string);
    procedure AutoClose(const NewTag: string);
    procedure ParseTag;
    procedure ParseComment;
    procedure ParseBang;
    procedure ParseText;
    procedure ReadRawText(Element: TDOMElement; const Tag: string);
    procedure MergeAttrs(Target: TDOMElement; Names, Values: TStringList);
    procedure ReadAttributes(Names, Values: TStringList; out SelfClose: Boolean);
  public
    procedure Run(const Src: string; Doc: TDOMDocument);
  end;

function THtmlParser.CurParent: TDOMElement;
begin
  if FStack.Count > 0 then
    Result := FStack[FStack.Count - 1]
  else
    Result := FBody;
end;

procedure THtmlParser.PopTo(const Tag: string);
var
  I: Integer;
begin
  // find the matching element from the top of the stack; [0]=body is never popped
  for I := FStack.Count - 1 downto 1 do
    if FStack[I].TagName = Tag then
    begin
      while FStack.Count > I do
        FStack.Delete(FStack.Count - 1);
      Exit;
    end;
end;

procedure THtmlParser.AutoClose(const NewTag: string);

  function TopTag: string;
  begin
    if FStack.Count > 1 then
      Result := FStack[FStack.Count - 1].TagName
    else
      Result := '';
  end;

begin
  if ClosesP(NewTag) then
    if TopTag = 'p' then
      FStack.Delete(FStack.Count - 1);

  if NewTag = 'li' then
    while TopTag = 'li' do
      FStack.Delete(FStack.Count - 1)
  else if (NewTag = 'dt') or (NewTag = 'dd') then
    while (TopTag = 'dt') or (TopTag = 'dd') do
      FStack.Delete(FStack.Count - 1)
  else if (NewTag = 'td') or (NewTag = 'th') then
    while (TopTag = 'td') or (TopTag = 'th') do
      FStack.Delete(FStack.Count - 1)
  else if NewTag = 'tr' then
    while (TopTag = 'td') or (TopTag = 'th') or (TopTag = 'tr') do
      FStack.Delete(FStack.Count - 1)
  else if NewTag = 'option' then
    while TopTag = 'option' do
      FStack.Delete(FStack.Count - 1);
end;

procedure THtmlParser.MergeAttrs(Target: TDOMElement; Names, Values: TStringList);
var
  I: Integer;
begin
  for I := 0 to Names.Count - 1 do
    if not Target.HasAttribute(Names[I]) then
      Target.SetAttribute(Names[I], Values[I]);
end;

procedure THtmlParser.ReadAttributes(Names, Values: TStringList; out SelfClose: Boolean);
var
  AName, AValue: string;
  Q: Char;
  Start: Integer;
begin
  SelfClose := False;
  while FPos <= FLen do
  begin
    // skip whitespace
    while (FPos <= FLen) and (FSrc[FPos] in [' ', #9, #10, #13]) do
      Inc(FPos);
    if FPos > FLen then
      Exit;
    if FSrc[FPos] = '>' then
    begin
      Inc(FPos);
      Exit;
    end;
    if (FSrc[FPos] = '/') then
    begin
      Inc(FPos);
      if (FPos <= FLen) and (FSrc[FPos] = '>') then
      begin
        Inc(FPos);
        SelfClose := True;
        Exit;
      end;
      Continue;
    end;
    // attribute name
    Start := FPos;
    while (FPos <= FLen) and not (FSrc[FPos] in [' ', #9, #10, #13, '=', '>', '/']) do
      Inc(FPos);
    AName := LowerCase(Copy(FSrc, Start, FPos - Start));
    if AName = '' then
    begin
      Inc(FPos);
      Continue;
    end;
    // value
    while (FPos <= FLen) and (FSrc[FPos] in [' ', #9, #10, #13]) do
      Inc(FPos);
    AValue := '';
    if (FPos <= FLen) and (FSrc[FPos] = '=') then
    begin
      Inc(FPos);
      while (FPos <= FLen) and (FSrc[FPos] in [' ', #9, #10, #13]) do
        Inc(FPos);
      if (FPos <= FLen) and (FSrc[FPos] in ['"', '''']) then
      begin
        Q := FSrc[FPos];
        Inc(FPos);
        Start := FPos;
        while (FPos <= FLen) and (FSrc[FPos] <> Q) do
          Inc(FPos);
        AValue := Copy(FSrc, Start, FPos - Start);
        if FPos <= FLen then
          Inc(FPos); // closing quote
      end
      else
      begin
        Start := FPos;
        while (FPos <= FLen) and not (FSrc[FPos] in [' ', #9, #10, #13, '>']) do
          Inc(FPos);
        AValue := Copy(FSrc, Start, FPos - Start);
      end;
      AValue := DecodeEntities(AValue);
    end;
    if Names.IndexOf(AName) < 0 then
    begin
      Names.Add(AName);
      Values.Add(AValue);
    end;
  end;
end;

procedure THtmlParser.ReadRawText(Element: TDOMElement; const Tag: string);
var
  CloseTag, Content: string;
  I, Start: Integer;
  Found: Boolean;
begin
  CloseTag := '</' + Tag;
  Start := FPos;
  Found := False;
  I := FPos;
  while I <= FLen - Length(CloseTag) + 1 do
  begin
    if (FSrc[I] = '<') and SameText(Copy(FSrc, I, Length(CloseTag)), CloseTag) then
    begin
      Found := True;
      Break;
    end;
    Inc(I);
  end;
  if not Found then
    I := FLen + 1;
  Content := Copy(FSrc, Start, I - Start);
  if (Tag = 'title') or (Tag = 'textarea') then
    Content := DecodeEntities(Content);
  if Content <> '' then
    Element.AppendChild(FDoc.CreateTextNode(Content));
  if Tag = 'title' then
    FDoc.Title := Trim(Content);
  // skip the closing tag
  FPos := I;
  if Found then
  begin
    while (FPos <= FLen) and (FSrc[FPos] <> '>') do
      Inc(FPos);
    if FPos <= FLen then
      Inc(FPos);
  end;
end;

procedure THtmlParser.ParseComment;
var
  I: Integer;
begin
  // FPos points at '<', followed by '!--'
  Inc(FPos, 4);
  I := FPos;
  while I <= FLen - 2 do
  begin
    if (FSrc[I] = '-') and (FSrc[I + 1] = '-') and (FSrc[I + 2] = '>') then
    begin
      CurParent.AppendChild(FDoc.CreateComment(Copy(FSrc, FPos, I - FPos)));
      FPos := I + 3;
      Exit;
    end;
    Inc(I);
  end;
  FPos := FLen + 1;
end;

// Document mode from a DOCTYPE (simplified rules of the HTML spec, 13.2.6.4.1).
function DoctypeMode(const D: string): TDocCompatMode;
const
  // public identifiers that select quirks mode (prefixes, lower case)
  QuirkPrefixes: array[0..15] of string = (
    '-//w3c//dtd html 4.0 transitional//', '-//w3c//dtd html 4.0 frameset//',
    '-//w3c//dtd html 3', '-//w3c//dtd html 2', '-//w3c//dtd w3 html',
    '-//w3o//', '-//ietf//', '-//netscape', '-//microsoft', '-//softquad',
    '-//sun microsystems', '-//o''reilly', '-//webtechs', '-//spyglass',
    '-//metrius', '-//w3c//dtd html experimental');
var
  L, Pub, Sys: string;
  P, Q, I: Integer;
  Quote: Char;

  function NextQuoted(var At: Integer): string;
  var
    E: Integer;
  begin
    Result := '';
    while (At <= Length(L)) and not (L[At] in ['"', '''']) do Inc(At);
    if At > Length(L) then Exit;
    Quote := L[At];
    E := At + 1;
    while (E <= Length(L)) and (L[E] <> Quote) do Inc(E);
    Result := Copy(L, At + 1, E - At - 1);
    At := E + 1;
  end;

begin
  L := LowerCase(Trim(D));                  // 'doctype html public "..." "..."'
  Result := dcmStandards;
  if Copy(L, 1, 7) <> 'doctype' then Exit(dcmQuirks);
  L := Trim(Copy(L, 8, MaxInt));
  if Copy(L, 1, 4) <> 'html' then Exit(dcmQuirks);
  P := Pos('public', L);
  if P = 0 then Exit;                       // <!DOCTYPE html> (or SYSTEM only)
  Q := P + 6;
  Pub := NextQuoted(Q);
  Sys := NextQuoted(Q);
  for I := 0 to High(QuirkPrefixes) do
    if Copy(Pub, 1, Length(QuirkPrefixes[I])) = QuirkPrefixes[I] then
      Exit(dcmQuirks);
  if (Copy(Pub, 1, 36) = '-//w3c//dtd html 4.01 transitional//') or
     (Copy(Pub, 1, 32) = '-//w3c//dtd html 4.01 frameset//') then
  begin
    if Sys = '' then Exit(dcmQuirks);
    Exit(dcmLimitedQuirks);
  end;
  if (Copy(Pub, 1, 36) = '-//w3c//dtd xhtml 1.0 transitional//') or
     (Copy(Pub, 1, 32) = '-//w3c//dtd xhtml 1.0 frameset//') then
    Exit(dcmLimitedQuirks);
end;

procedure THtmlParser.ParseBang;
var
  Start: Integer;
begin
  // <!DOCTYPE ...> or other <!...> — skip to '>'; a DOCTYPE sets the document mode
  Start := FPos + 2;
  while (FPos <= FLen) and (FSrc[FPos] <> '>') do
    Inc(FPos);
  if SameText(Copy(FSrc, Start, 7), 'doctype') then
    FDoc.CompatMode := DoctypeMode(Copy(FSrc, Start, FPos - Start));
  if FPos <= FLen then
    Inc(FPos);
end;

procedure THtmlParser.ParseTag;
var
  IsClose, SelfClose: Boolean;
  Start: Integer;
  Tag: string;
  Names, Values: TStringList;
  E: TDOMElement;
  Parent: TDOMNode;
begin
  // FPos points at '<'
  if (FPos + 3 <= FLen) and (FSrc[FPos + 1] = '!') and (FSrc[FPos + 2] = '-') and
     (FSrc[FPos + 3] = '-') then
  begin
    ParseComment;
    Exit;
  end;
  if (FPos + 1 <= FLen) and (FSrc[FPos + 1] = '!') then
  begin
    ParseBang;
    Exit;
  end;
  if (FPos + 1 <= FLen) and (FSrc[FPos + 1] = '?') then
  begin
    ParseBang;
    Exit;
  end;

  IsClose := (FPos + 1 <= FLen) and (FSrc[FPos + 1] = '/');
  if IsClose then
    Inc(FPos, 2)
  else
    Inc(FPos, 1);

  Start := FPos;
  while (FPos <= FLen) and not (FSrc[FPos] in [' ', #9, #10, #13, '>', '/']) do
    Inc(FPos);
  Tag := LowerCase(Copy(FSrc, Start, FPos - Start));

  if Tag = '' then
  begin
    // lone '<' — treat as text
    CurParent.AppendChild(FDoc.CreateTextNode('<'));
    Exit;
  end;

  Names := TStringList.Create;
  Values := TStringList.Create;
  try
    ReadAttributes(Names, Values, SelfClose);

    if IsClose then
    begin
      if (Tag = 'html') or (Tag = 'body') or (Tag = 'head') then
        Exit;
      PopTo(Tag);
      Exit;
    end;

    // special: html / head / body — merge attributes into the already created ones
    if Tag = 'html' then
    begin
      MergeAttrs(FHtml, Names, Values);
      Exit;
    end;
    if Tag = 'head' then
      Exit;
    if Tag = 'body' then
    begin
      MergeAttrs(FBody, Names, Values);
      FInBody := True;
      Exit;
    end;

    E := FDoc.CreateElement(Tag);
    MergeAttrs(E, Names, Values);

    // head elements before the content go into <head>
    if (not FInBody) and (IsHeadOnlyElement(Tag) or (Tag = 'script') or
       (Tag = 'noscript')) then
      Parent := FHead
    else
    begin
      FInBody := True;
      AutoClose(Tag);
      Parent := CurParent;
    end;
    Parent.AppendChild(E);

    if IsRawTextElement(Tag) then
      ReadRawText(E, Tag)
    else if (not IsVoidElement(Tag)) and (not SelfClose) then
      FStack.Add(E);
  finally
    Names.Free;
    Values.Free;
  end;
end;

procedure THtmlParser.ParseText;
var
  Start: Integer;
  Text: string;
begin
  Start := FPos;
  while (FPos <= FLen) and (FSrc[FPos] <> '<') do
    Inc(FPos);
  Text := Copy(FSrc, Start, FPos - Start);
  if Text = '' then
    Exit;
  if (not FInBody) and (Trim(Text) = '') then
    Exit; // whitespace before the content — ignore
  if not FInBody then
    FInBody := True;
  CurParent.AppendChild(FDoc.CreateTextNode(DecodeEntities(Text)));
end;

procedure THtmlParser.Run(const Src: string; Doc: TDOMDocument);
begin
  FSrc := Src;
  FLen := Length(Src);
  FPos := 1;
  FDoc := Doc;
  FInBody := False;

  // skip the UTF-8 BOM
  if (FLen >= 3) and (FSrc[1] = #$EF) and (FSrc[2] = #$BB) and (FSrc[3] = #$BF) then
    FPos := 4;

  // document skeleton — always present, as in browsers
  FHtml := Doc.CreateElement('html');
  Doc.AppendChild(FHtml);
  FHead := Doc.CreateElement('head');
  FHtml.AppendChild(FHead);
  FBody := Doc.CreateElement('body');
  FHtml.AppendChild(FBody);

  FStack := TList<TDOMElement>.Create;
  try
    FStack.Add(FBody);
    while FPos <= FLen do
    begin
      if FSrc[FPos] = '<' then
      begin
        // '<' without a tag name is plain text
        if (FPos + 1 <= FLen) and
           (FSrc[FPos + 1] in ['a'..'z', 'A'..'Z', '/', '!', '?']) then
          ParseTag
        else
        begin
          CurParent.AppendChild(FDoc.CreateTextNode('<'));
          Inc(FPos);
        end;
      end
      else
        ParseText;
    end;
  finally
    FStack.Free;
  end;
end;

procedure ParseHtmlString(const Src: string; Doc: TDOMDocument);
var
  P: THtmlParser;
begin
  P := THtmlParser.Create;
  try
    Doc.Lock;
    try
      P.Run(Src, Doc);
    finally
      Doc.Unlock;
    end;
  finally
    P.Free;
  end;
end;

// ---- charset handling ----

// Normalize a charset name to the identifiers used by LConvEncoding,
// e.g. 'ISO-8859-2' -> 'iso88592', 'Windows-1250' -> 'cp1250'.
function NormalizeCharset(const CS: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(CS) do
  begin
    C := CS[I];
    if C in ['a'..'z', '0'..'9'] then
      Result := Result + C
    else if C in ['A'..'Z'] then
      Result := Result + Chr(Ord(C) + 32);
    // dashes, underscores and spaces are dropped
  end;
  if Copy(Result, 1, 7) = 'windows' then
    Result := 'cp' + Copy(Result, 8, MaxInt)
  else if Result = 'latin1' then
    Result := 'iso88591'
  else if Result = 'latin2' then
    Result := 'iso88592';
end;

// Look for charset= inside the first 2 KB of the document: covers both
// <meta charset="..."> and <meta http-equiv content="...; charset=...">
function DetectMetaCharset(const Src: string): string;
var
  Head: string;
  P, E: Integer;
begin
  Result := '';
  Head := LowerCase(Copy(Src, 1, 2048));
  P := Pos('charset=', Head);
  if P = 0 then
    Exit;
  P := P + 8;
  while (P <= Length(Head)) and (Head[P] in ['"', '''', ' ']) do
    Inc(P);
  E := P;
  while (E <= Length(Head)) and
        not (Head[E] in ['"', '''', ' ', '>', ';', '/']) do
    Inc(E);
  Result := Copy(Head, P, E - P);
end;

// Convert raw page bytes to UTF-8 according to the charset hint
// (HTTP header), the <meta> declaration or the UTF-8 BOM.
function ConvertPageToUTF8(const Raw, CharsetHint: string): string;
var
  CS: string;
begin
  // UTF-8 BOM wins over everything
  if (Length(Raw) >= 3) and (Raw[1] = #$EF) and (Raw[2] = #$BB) and
     (Raw[3] = #$BF) then
    Exit(Raw);

  CS := NormalizeCharset(CharsetHint);
  if CS = '' then
    CS := NormalizeCharset(DetectMetaCharset(Raw));

  if (CS = '') or (CS = 'utf8') or (CS = 'usascii') then
    Result := Raw
  else
    // ConvertEncoding returns the input unchanged on unknown names
    Result := ConvertEncoding(Raw, CS, EncodingUTF8);
end;

procedure ParseHtmlStream(S: TStream; Doc: TDOMDocument;
  const CharsetHint: string);
var
  Src: string;
  N: Int64;
begin
  N := S.Size - S.Position;
  SetLength(Src, N);
  if N > 0 then
    S.ReadBuffer(Src[1], N);
  ParseHtmlString(ConvertPageToUTF8(Src, CharsetHint), Doc);
end;

end.
