unit SVGFontReader;

{$mode objfpc}{$H+}
{$WARN 5093 off}
interface
uses Classes, SysUtils, FontTypes, CFFBuilder;

// Author: www.xelitan.com
// License: MIT
//
// SVG font -> CFF-based OpenType (.otf) converter.
//
// Parses an SVG 1.1 <font> (font-face / missing-glyph / glyph elements),
// converts each glyph's path data ('d') into cubic contours, then builds a
// complete CFF OpenType font: the CFF table is produced by CFFBuilder, and the
// remaining tables (cmap, head, hhea, hmtx, maxp, name, OS/2, post) are
// synthesised here.  The output is normalised to 1000 units per em.
//
// SVG glyph outlines use the font (Y up) coordinate system, so coordinates are
// taken as-is (no Y flip).  Only glyphs with a single-code-point 'unicode'
// attribute are emitted (ligatures / unencoded glyphs would require GSUB).

procedure SVGFontToOTF(Src, Dst : TStream);

implementation

uses DOM, XMLRead, Math;

// ================================================================
// Big-endian writers to a TMemoryStream + helpers
// ================================================================

procedure W8 (S : TStream; V : Byte);    inline; begin S.WriteBuffer(V, 1); end;
procedure W16(S : TStream; V : Word);     inline; begin WriteU16(S, V); end;
procedure WS16(S : TStream; V : SmallInt);inline; begin WriteU16(S, Word(V)); end;
procedure W32(S : TStream; V : LongWord); inline; begin WriteU32(S, V); end;

function MSBytes(MS : TMemoryStream) : TBytes;
begin
  SetLength(Result, MS.Size);
  if MS.Size > 0 then Move(MS.Memory^, Result[0], MS.Size);
end;

// ================================================================
// SVG path data parser  ->  cubic contours
// ================================================================
//
// Output contour format (matching CFFBuilder's expectation):
//   contour[0]                 on-curve start point
//   then, per segment, either  one on-curve point (a line) or
//                              [off, off, on] (a cubic Bezier).
// The contour closes implicitly (CFF does this), so no closing point is added.

type
  TPathParser = class
  private
    S        : string;
    P, Len   : Integer;
    FS       : TFormatSettings;
    Cmd      : Char;
    CurX, CurY, StartX, StartY : Double;
    LastCX, LastCY : Double;   // last control point (for S/T reflection)
    LastKind : Integer;        // 0 none, 1 cubic, 2 quad
    CurC     : TCubicContour;
    CurN     : Integer;
    HaveCur  : Boolean;
    Conts    : TCubicContourArray;
    procedure AddPt(X, Y : Double; OnC : Boolean);
    procedure BeginContour;
    procedure FlushContour;
    procedure EnsureOpen;
    procedure AddCubic(C1X, C1Y, C2X, C2Y, EX, EY : Double);
    procedure AddQuad(QX, QY, EX, EY : Double);
    procedure ArcTo(RX, RY, PhiDeg : Double; LargeArc, Sweep : Boolean; X2, Y2 : Double);
    procedure SkipSep;
    function  AtNumber : Boolean;
    function  ReadNum : Double;
    function  ReadFlag : Boolean;
  public
    function Parse(const APath : string) : TCubicContourArray;
  end;

procedure TPathParser.AddPt(X, Y : Double; OnC : Boolean);
begin
  if CurN >= Length(CurC) then SetLength(CurC, CurN + 32);
  CurC[CurN].X := X; CurC[CurN].Y := Y; CurC[CurN].OnCurve := OnC;
  Inc(CurN);
end;

procedure TPathParser.BeginContour;
begin
  SetLength(CurC, 0); CurN := 0; HaveCur := True;
  AddPt(CurX, CurY, True);
  StartX := CurX; StartY := CurY;
end;

procedure TPathParser.FlushContour;
begin
  if HaveCur and (CurN > 1) then
  begin
    SetLength(CurC, CurN);
    SetLength(Conts, Length(Conts) + 1);
    Conts[High(Conts)] := Copy(CurC, 0, CurN);
  end;
  HaveCur := False; CurN := 0;
end;

procedure TPathParser.EnsureOpen;
begin
  if not HaveCur then BeginContour;
end;

procedure TPathParser.AddCubic(C1X, C1Y, C2X, C2Y, EX, EY : Double);
begin
  EnsureOpen;
  AddPt(C1X, C1Y, False);
  AddPt(C2X, C2Y, False);
  AddPt(EX, EY, True);
  CurX := EX; CurY := EY;
end;

procedure TPathParser.AddQuad(QX, QY, EX, EY : Double);
var C1X, C1Y, C2X, C2Y : Double;
begin
  // Elevate quadratic to cubic
  C1X := CurX + (2.0/3.0) * (QX - CurX);
  C1Y := CurY + (2.0/3.0) * (QY - CurY);
  C2X := EX   + (2.0/3.0) * (QX - EX);
  C2Y := EY   + (2.0/3.0) * (QY - EY);
  AddCubic(C1X, C1Y, C2X, C2Y, EX, EY);
end;

procedure TPathParser.ArcTo(RX, RY, PhiDeg : Double; LargeArc, Sweep : Boolean; X2, Y2 : Double);
var
  Phi, CosP, SinP, DX, DY, X1P, Y1P, Lambda, SgnF, Num, Den, Co, CXP, CYP, CX, CY : Double;
  Theta1, DTheta, Delta, T, Ang, Ang2, EX, EY, C1X, C1Y, C2X, C2Y, D1X, D1Y, D2X, D2Y : Double;
  NSeg, I : Integer;
  X1, Y1 : Double;

  function VAngle(UX, UY, VX, VY : Double) : Double;
  var Dot, L, A : Double;
  begin
    Dot := UX*VX + UY*VY;
    L := Sqrt((UX*UX+UY*UY)*(VX*VX+VY*VY));
    if L = 0 then Exit(0);
    A := Dot / L;
    if A < -1 then A := -1; if A > 1 then A := 1;
    A := ArcCos(A);
    if (UX*VY - UY*VX) < 0 then A := -A;
    Result := A;
  end;

begin
  X1 := CurX; Y1 := CurY;
  if (X1 = X2) and (Y1 = Y2) then Exit;
  if (RX = 0) or (RY = 0) then begin EnsureOpen; AddPt(X2, Y2, True); CurX:=X2; CurY:=Y2; Exit; end;
  RX := Abs(RX); RY := Abs(RY);
  Phi := PhiDeg * Pi / 180.0;
  CosP := Cos(Phi); SinP := Sin(Phi);
  DX := (X1 - X2) / 2; DY := (Y1 - Y2) / 2;
  X1P :=  CosP*DX + SinP*DY;
  Y1P := -SinP*DX + CosP*DY;
  Lambda := (X1P*X1P)/(RX*RX) + (Y1P*Y1P)/(RY*RY);
  if Lambda > 1 then begin T := Sqrt(Lambda); RX := RX*T; RY := RY*T; end;
  Num := RX*RX*RY*RY - RX*RX*Y1P*Y1P - RY*RY*X1P*X1P;
  Den := RX*RX*Y1P*Y1P + RY*RY*X1P*X1P;
  if Den = 0 then Den := 1e-12;
  Co := Sqrt(Max(0, Num/Den));
  if LargeArc = Sweep then Co := -Co;
  CXP :=  Co * (RX*Y1P/RY);
  CYP := -Co * (RY*X1P/RX);
  CX := CosP*CXP - SinP*CYP + (X1+X2)/2;
  CY := SinP*CXP + CosP*CYP + (Y1+Y2)/2;
  Theta1 := VAngle(1, 0, (X1P-CXP)/RX, (Y1P-CYP)/RY);
  DTheta := VAngle((X1P-CXP)/RX, (Y1P-CYP)/RY, (-X1P-CXP)/RX, (-Y1P-CYP)/RY);
  if (not Sweep) and (DTheta > 0) then DTheta := DTheta - 2*Pi;
  if (Sweep) and (DTheta < 0) then DTheta := DTheta + 2*Pi;

  NSeg := Ceil(Abs(DTheta) / (Pi/2));
  if NSeg < 1 then NSeg := 1;
  Delta := DTheta / NSeg;
  T := (4.0/3.0) * Tan(Delta/4.0);
  Ang := Theta1;
  for I := 1 to NSeg do
  begin
    Ang2 := Ang + Delta;
    EX := CX + CosP*RX*Cos(Ang2) - SinP*RY*Sin(Ang2);
    EY := CY + SinP*RX*Cos(Ang2) + CosP*RY*Sin(Ang2);
    D1X := -RX*Sin(Ang);  D1Y := RY*Cos(Ang);
    C1X := CurX + T*(CosP*D1X - SinP*D1Y);
    C1Y := CurY + T*(SinP*D1X + CosP*D1Y);
    D2X := -RX*Sin(Ang2); D2Y := RY*Cos(Ang2);
    C2X := EX - T*(CosP*D2X - SinP*D2Y);
    C2Y := EY - T*(SinP*D2X + CosP*D2Y);
    AddCubic(C1X, C1Y, C2X, C2Y, EX, EY);
    Ang := Ang2;
  end;
end;

procedure TPathParser.SkipSep;
begin
  while (P <= Len) and (S[P] in [' ', #9, #10, #13, ',']) do Inc(P);
end;

function TPathParser.AtNumber : Boolean;
begin
  SkipSep;
  Result := (P <= Len) and (S[P] in ['0'..'9', '+', '-', '.']);
end;

function TPathParser.ReadNum : Double;
var St : Integer;
begin
  SkipSep;
  St := P;
  if (P <= Len) and (S[P] in ['+', '-']) then Inc(P);
  while (P <= Len) and (S[P] in ['0'..'9']) do Inc(P);
  if (P <= Len) and (S[P] = '.') then
  begin Inc(P); while (P <= Len) and (S[P] in ['0'..'9']) do Inc(P); end;
  if (P <= Len) and (S[P] in ['e', 'E']) then
  begin
    Inc(P);
    if (P <= Len) and (S[P] in ['+', '-']) then Inc(P);
    while (P <= Len) and (S[P] in ['0'..'9']) do Inc(P);
  end;
  if P > St then
  begin
    try Result := StrToFloat(Copy(S, St, P - St), FS); except Result := 0; end;
  end
  else begin Result := 0; Inc(P); end;
end;

function TPathParser.ReadFlag : Boolean;
// Arc flags are a single '0' or '1' (possibly not separated)
begin
  SkipSep;
  Result := False;
  if (P <= Len) and (S[P] = '1') then begin Result := True; Inc(P); end
  else if (P <= Len) and (S[P] = '0') then Inc(P)
  else Result := ReadNum <> 0;
end;

function TPathParser.Parse(const APath : string) : TCubicContourArray;
var
  C : Char;
  NX, NY, X1, Y1, X2, Y2, RX, RY, Rot : Double;
  Rel : Boolean;
  LA, SW : Boolean;
begin
  S := APath; Len := Length(S); P := 1;
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.'; FS.ThousandSeparator := #0;
  SetLength(Conts, 0);
  CurX := 0; CurY := 0; StartX := 0; StartY := 0;
  LastCX := 0; LastCY := 0; LastKind := 0;
  HaveCur := False; CurN := 0; Cmd := #0;

  while True do
  begin
    SkipSep;
    if P > Len then Break;
    C := S[P];
    if ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) then
    begin Cmd := C; Inc(P); end
    else if Cmd = #0 then Break;  // malformed: no command yet

    Rel := (Cmd >= 'a');
    case UpCase(Cmd) of
      'M':
        begin
          NX := ReadNum; NY := ReadNum;
          if Rel then begin NX := CurX + NX; NY := CurY + NY; end;
          FlushContour;
          CurX := NX; CurY := NY;
          BeginContour;
          LastKind := 0;
          if Rel then Cmd := 'l' else Cmd := 'L';  // subsequent pairs are lineto
        end;
      'L':
        begin
          NX := ReadNum; NY := ReadNum;
          if Rel then begin NX := CurX + NX; NY := CurY + NY; end;
          EnsureOpen; AddPt(NX, NY, True); CurX := NX; CurY := NY; LastKind := 0;
        end;
      'H':
        begin
          NX := ReadNum; if Rel then NX := CurX + NX;
          EnsureOpen; AddPt(NX, CurY, True); CurX := NX; LastKind := 0;
        end;
      'V':
        begin
          NY := ReadNum; if Rel then NY := CurY + NY;
          EnsureOpen; AddPt(CurX, NY, True); CurY := NY; LastKind := 0;
        end;
      'C':
        begin
          X1 := ReadNum; Y1 := ReadNum; X2 := ReadNum; Y2 := ReadNum;
          NX := ReadNum; NY := ReadNum;
          if Rel then
          begin
            X1:=CurX+X1; Y1:=CurY+Y1; X2:=CurX+X2; Y2:=CurY+Y2; NX:=CurX+NX; NY:=CurY+NY;
          end;
          AddCubic(X1, Y1, X2, Y2, NX, NY);
          LastCX := X2; LastCY := Y2; LastKind := 1;
        end;
      'S':
        begin
          X2 := ReadNum; Y2 := ReadNum; NX := ReadNum; NY := ReadNum;
          if Rel then begin X2:=CurX+X2; Y2:=CurY+Y2; NX:=CurX+NX; NY:=CurY+NY; end;
          if LastKind = 1 then begin X1 := 2*CurX - LastCX; Y1 := 2*CurY - LastCY; end
          else begin X1 := CurX; Y1 := CurY; end;
          AddCubic(X1, Y1, X2, Y2, NX, NY);
          LastCX := X2; LastCY := Y2; LastKind := 1;
        end;
      'Q':
        begin
          X1 := ReadNum; Y1 := ReadNum; NX := ReadNum; NY := ReadNum;
          if Rel then begin X1:=CurX+X1; Y1:=CurY+Y1; NX:=CurX+NX; NY:=CurY+NY; end;
          AddQuad(X1, Y1, NX, NY);
          LastCX := X1; LastCY := Y1; LastKind := 2;
        end;
      'T':
        begin
          NX := ReadNum; NY := ReadNum;
          if Rel then begin NX:=CurX+NX; NY:=CurY+NY; end;
          if LastKind = 2 then begin X1 := 2*CurX - LastCX; Y1 := 2*CurY - LastCY; end
          else begin X1 := CurX; Y1 := CurY; end;
          AddQuad(X1, Y1, NX, NY);
          LastCX := X1; LastCY := Y1; LastKind := 2;
        end;
      'A':
        begin
          RX := ReadNum; RY := ReadNum; Rot := ReadNum;
          LA := ReadFlag; SW := ReadFlag;
          NX := ReadNum; NY := ReadNum;
          if Rel then begin NX:=CurX+NX; NY:=CurY+NY; end;
          ArcTo(RX, RY, Rot, LA, SW, NX, NY);
          LastKind := 0;
        end;
      'Z':
        begin
          FlushContour;
          CurX := StartX; CurY := StartY;
          LastKind := 0; Cmd := #0;  // a fresh command must follow
        end;
    else
      Break;  // unknown command
    end;
  end;

  FlushContour;
  Result := Conts;
end;

// ================================================================
// Glyph collection
// ================================================================

type
  TGlyphRec = record
    CP   : LongWord;        // single code point (0 = .notdef / unencoded)
    Adv  : Integer;         // advance width, SVG units
    XMin : Integer;         // glyph xMin, SVG units (for LSB)
    Data : TGlyphData;      // cubic contours
  end;

// ================================================================
// XML attribute helpers
// ================================================================

function AttrA(E : TDOMElement; const Name : string) : string;
begin
  Result := string(E.GetAttribute(WideString(Name)));
end;

function HasA(E : TDOMElement; const Name : string) : Boolean;
begin
  Result := E.hasAttribute(WideString(Name));
end;

function AttrInt(E : TDOMElement; const Name : string; Default : Integer) : Integer;
begin
  if HasA(E, Name) then Result := StrToIntDef(Trim(AttrA(E, Name)), Default)
  else Result := Default;
end;

// First code point of a 'unicode' attribute (handles surrogate pairs).
// Returns the number of UTF-16 units the value occupies, so ligatures
// (more than one code point) can be detected and skipped.
function UnicodeCP(E : TDOMElement; out CP : LongWord) : Integer;
var W : WideString; Hi, Lo : Word;
begin
  CP := 0;
  W := E.GetAttribute('unicode');
  Result := Length(W);
  if Result = 0 then Exit;
  Hi := Ord(W[1]);
  if (Hi >= $D800) and (Hi <= $DBFF) and (Length(W) >= 2) then
  begin
    Lo := Ord(W[2]);
    CP := $10000 + ((LongWord(Hi - $D800) shl 10) or (Lo - $DC00));
    // surrogate pair = one code point spanning two units
    if Length(W) = 2 then Result := 1 else Result := 2;
  end
  else
    CP := Hi;
end;

// ================================================================
// cmap subtable builders
// ================================================================

function BuildCmap4(const CPs, GIDs : array of Word; Count : Integer) : TBytes;
// Inputs sorted ascending by CP (all <= 0xFFFF), unique.
var
  MS : TMemoryStream;
  SegStart, SegEnd, SegGidIdx : array of Integer;
  NSeg, I, J, RunStart, SegCount : Integer;
  GlyphIds : array of Word;
  SearchRange, EntrySel, RangeShift, Seg2 : Integer;
begin
  // Build runs of consecutive code points
  SetLength(SegStart, Count + 1);
  SetLength(SegEnd,   Count + 1);
  SetLength(SegGidIdx,Count + 1);
  SetLength(GlyphIds, Count);
  NSeg := 0; I := 0;
  while I < Count do
  begin
    RunStart := I;
    while (I + 1 < Count) and (CPs[I+1] = CPs[I] + 1) do Inc(I);
    SegStart[NSeg]  := CPs[RunStart];
    SegEnd[NSeg]    := CPs[I];
    SegGidIdx[NSeg] := RunStart;     // index into GlyphIds for this run start
    Inc(NSeg); Inc(I);
  end;
  for I := 0 to Count - 1 do GlyphIds[I] := GIDs[I];

  // Final mandatory segment 0xFFFF
  SegStart[NSeg] := $FFFF; SegEnd[NSeg] := $FFFF; SegGidIdx[NSeg] := -1;
  Inc(NSeg);
  SegCount := NSeg;

  // search params
  Seg2 := 1; EntrySel := 0;
  while Seg2 * 2 <= SegCount do begin Seg2 := Seg2 * 2; Inc(EntrySel); end;
  SearchRange := Seg2 * 2;
  RangeShift  := SegCount * 2 - SearchRange;

  MS := TMemoryStream.Create;
  try
    W16(MS, 4);                       // format
    W16(MS, 0);                       // length (patched below)
    W16(MS, 0);                       // language
    W16(MS, SegCount * 2);            // segCountX2
    W16(MS, SearchRange);
    W16(MS, EntrySel);
    W16(MS, RangeShift);
    for I := 0 to SegCount - 1 do W16(MS, SegEnd[I]);     // endCode
    W16(MS, 0);                                            // reservedPad
    for I := 0 to SegCount - 1 do W16(MS, SegStart[I]);   // startCode
    // idDelta: 0 for real segments (we use glyphIdArray), 1 for the 0xFFFF segment
    for I := 0 to SegCount - 1 do
      if SegStart[I] = $FFFF then WS16(MS, 1) else WS16(MS, 0);
    // idRangeOffset
    for I := 0 to SegCount - 1 do
    begin
      if SegStart[I] = $FFFF then
        W16(MS, 0)
      else
        // bytes from this entry to glyphId: 2*((segCount - I) + runStartIdx)
        W16(MS, Word(2 * ((SegCount - I) + SegGidIdx[I])));
    end;
    for J := 0 to Count - 1 do W16(MS, GlyphIds[J]);       // glyphIdArray

    // patch length
    MS.Position := 2; W16(MS, Word(MS.Size));
    Result := MSBytes(MS);
  finally
    MS.Free;
  end;
end;

function BuildCmap12(const CPs : array of LongWord; const GIDs : array of Word;
                     Count : Integer) : TBytes;
var
  MS : TMemoryStream;
  Groups : array of record SC, EC, SG : LongWord; end;
  NG, I : Integer;
begin
  SetLength(Groups, Count);
  NG := 0; I := 0;
  while I < Count do
  begin
    Groups[NG].SC := CPs[I];
    Groups[NG].SG := GIDs[I];
    while (I + 1 < Count) and (CPs[I+1] = CPs[I] + 1) and
          (GIDs[I+1] = GIDs[I] + 1) do Inc(I);
    Groups[NG].EC := CPs[I];
    Inc(NG); Inc(I);
  end;

  MS := TMemoryStream.Create;
  try
    W16(MS, 12);          // format
    W16(MS, 0);           // reserved
    W32(MS, 0);           // length (patched)
    W32(MS, 0);           // language
    W32(MS, LongWord(NG));
    for I := 0 to NG - 1 do
    begin
      W32(MS, Groups[I].SC);
      W32(MS, Groups[I].EC);
      W32(MS, Groups[I].SG);
    end;
    MS.Position := 4; W32(MS, LongWord(MS.Size));
    Result := MSBytes(MS);
  finally
    MS.Free;
  end;
end;

// ================================================================
// name table builder
// ================================================================

function BuildName(const FamilyName : string) : TBytes;
var
  MS, Recs, Strs : TMemoryStream;
  Ids  : array[0..4] of Integer;
  Vals : array[0..4] of string;
  PostName : string;
  K, I : Integer;
  Ofs : Integer;

  procedure AddRec(Plat, Enc, Lang, NameID : Word; const Val : string; Utf16 : Boolean);
  var LenBytes : Integer; J : Integer; Start : Integer;
  begin
    Start := Strs.Size;
    if Utf16 then
    begin
      for J := 1 to Length(Val) do begin W8(Strs, 0); W8(Strs, Byte(Val[J])); end;
      LenBytes := Length(Val) * 2;
    end
    else
    begin
      for J := 1 to Length(Val) do W8(Strs, Byte(Val[J]));
      LenBytes := Length(Val);
    end;
    W16(Recs, Plat); W16(Recs, Enc); W16(Recs, Lang); W16(Recs, NameID);
    W16(Recs, Word(LenBytes)); W16(Recs, Word(Start));
  end;

begin
  PostName := '';
  for I := 1 to Length(FamilyName) do
    if FamilyName[I] <> ' ' then PostName := PostName + FamilyName[I];
  if PostName = '' then PostName := 'ConvertedFont';

  Ids[0] := 1; Vals[0] := FamilyName;             // Family
  Ids[1] := 2; Vals[1] := 'Regular';              // Subfamily
  Ids[2] := 3; Vals[2] := PostName + '-Regular';  // Unique ID
  Ids[3] := 4; Vals[3] := FamilyName;             // Full name
  Ids[4] := 6; Vals[4] := PostName;               // PostScript name

  Recs := TMemoryStream.Create;
  Strs := TMemoryStream.Create;
  MS   := TMemoryStream.Create;
  try
    // Platform 1 (Mac, ASCII), then platform 3 (Windows, UTF-16BE)
    for K := 0 to 4 do AddRec(1, 0, 0, Ids[K], Vals[K], False);
    for K := 0 to 4 do AddRec(3, 1, $409, Ids[K], Vals[K], True);

    Ofs := 6 + (Recs.Size);                 // string storage offset
    W16(MS, 0);                             // format 0
    W16(MS, Word(10));                      // count = 10 records
    W16(MS, Word(Ofs));                     // stringOffset
    Recs.Position := 0; MS.CopyFrom(Recs, Recs.Size);
    Strs.Position := 0; MS.CopyFrom(Strs, Strs.Size);
    Result := MSBytes(MS);
  finally
    Recs.Free; Strs.Free; MS.Free;
  end;
end;

// ================================================================
// Main converter
// ================================================================

procedure SVGFontToOTF(Src, Dst : TStream);
const
  NUM_TABLES = 9;
  TAGS : array[0..NUM_TABLES-1] of TTableTag = (
    TAG_CFF, TAG_OS2, TAG_CMAP, TAG_HEAD, TAG_HHEA, TAG_HMTX,
    TAG_MAXP, TAG_NAME, TAG_POST);
  HEAD_IDX = 3;
var
  Raw      : string;
  Doc      : TXMLDocument;
  MemIn    : TMemoryStream;
  PP       : TPathParser;
  Builder  : TCFFBuilder;

  FontName : string;
  UnitsPerEm, Ascent, Descent, DefaultAdv : Integer;
  EmScale  : Double;

  Glyphs   : array of TGlyphRec;
  NumGlyphs: Integer;
  CmapCP   : array of LongWord;
  CmapGID  : array of Word;
  CmapN    : Integer;

  GlyphsArr : TGlyphDataArray;
  HM        : THMetricArray;

  // bbox (SVG units)
  GXMin, GYMin, GXMax, GYMax : Double;
  HaveBBox  : Boolean;

  TableData : array[0..NUM_TABLES-1] of TBytes;
  Offsets, Lengths, Chksums : array[0..NUM_TABLES-1] of LongWord;
  SearchRange, EntrySelector, RangeShift : Word;
  DataStart, TotalSize, FullChk : LongWord;
  Buf : TMemoryStream;
  I, J, N, Pad : Integer;
  Z : Byte;
  AdjPos : Int64;

  ListFF, ListGl, ListFont, ListMiss : TDOMNodeList;
  FF : TDOMElement;
  K  : Integer;
  Tmp : LongWord; TmpG : Word;
  HasSupp : Boolean;
  Cmap4, Cmap12 : TBytes;
  CmapMS : TMemoryStream;
  NumSubtables, CmapHdr : Integer;
  Off4, Off12 : LongWord;
  CMS, HMS : TMemoryStream;
  AvgW, MinLSB, XMaxExt, FirstCP, LastCP : Integer;
  MaxAdv : Integer;
  BmpCP, BmpG : array of Word;
  BmpN : Integer;

  procedure ScanBBox(const GD : TGlyphData);
  var CI, PIdx : Integer; X, Y : Double;
  begin
    for CI := 0 to High(GD.Contours) do
      for PIdx := 0 to High(GD.Contours[CI]) do
      begin
        X := GD.Contours[CI][PIdx].X; Y := GD.Contours[CI][PIdx].Y;
        if (not HaveBBox) then
        begin GXMin:=X; GXMax:=X; GYMin:=Y; GYMax:=Y; HaveBBox:=True; end
        else
        begin
          if X<GXMin then GXMin:=X; if X>GXMax then GXMax:=X;
          if Y<GYMin then GYMin:=Y; if Y>GYMax then GYMax:=Y;
        end;
      end;
  end;

  function GlyphXMin(const GD : TGlyphData) : Integer;
  var CI, PIdx : Integer; X, MinX : Double; Got : Boolean;
  begin
    Got := False; MinX := 0;
    for CI := 0 to High(GD.Contours) do
      for PIdx := 0 to High(GD.Contours[CI]) do
      begin
        X := GD.Contours[CI][PIdx].X;
        if (not Got) or (X < MinX) then begin MinX := X; Got := True; end;
      end;
    if Got then Result := Round(MinX) else Result := 0;
  end;

  function Sc(V : Double) : Integer; inline;
  begin Result := Round(V * EmScale); end;

  procedure CollectGlyph(E : TDOMElement; IsMissing : Boolean);
  var GR : TGlyphRec; CP : LongWord; ULen : Integer; D : string;
  begin
    if IsMissing then begin CP := 0; ULen := 1; end
    else
    begin
      ULen := UnicodeCP(E, CP);
      if ULen <> 1 then Exit;             // skip ligatures / unencoded
      if (CP = 0) then Exit;
    end;

    D := Trim(AttrA(E, 'd'));
    FillChar(GR, SizeOf(GR), 0);
    GR.CP := CP;
    GR.Data.IsEmpty := True;
    GR.Data.IsComposite := False;
    if D <> '' then
    begin
      GR.Data.Contours := PP.Parse(D);
      GR.Data.IsEmpty := Length(GR.Data.Contours) = 0;
    end;
    if HasA(E, 'horiz-adv-x') then GR.Adv := AttrInt(E, 'horiz-adv-x', DefaultAdv)
    else GR.Adv := DefaultAdv;
    GR.XMin := GlyphXMin(GR.Data);

    SetLength(Glyphs, Length(Glyphs) + 1);
    Glyphs[High(Glyphs)] := GR;
  end;

begin
  // ---- Read input, strip DOCTYPE (avoids external-DTD handling) ----
  Src.Position := 0;
  SetLength(Raw, Src.Size);
  if Src.Size > 0 then Src.ReadBuffer(Raw[1], Src.Size);
  I := Pos('<!DOCTYPE', Raw);
  if I > 0 then
  begin
    J := I;
    while (J <= Length(Raw)) and (Raw[J] <> '>') do Inc(J);
    if J <= Length(Raw) then Delete(Raw, I, J - I + 1);
  end;

  MemIn := TMemoryStream.Create;
  Doc := nil;
  PP := TPathParser.Create;
  try
    if Length(Raw) > 0 then MemIn.WriteBuffer(Raw[1], Length(Raw));
    MemIn.Position := 0;
    ReadXMLFile(Doc, MemIn);
    if Doc = nil then raise Exception.Create('SVGFontToOTF: failed to parse SVG XML');

    // ---- font / font-face metadata ----
    UnitsPerEm := 1000; Ascent := 800; Descent := -200; DefaultAdv := 0;
    FontName := 'ConvertedFont';

    ListFont := Doc.GetElementsByTagName('font');
    try
      if ListFont.Count > 0 then
      begin
        FF := TDOMElement(ListFont[0]);
        DefaultAdv := AttrInt(FF, 'horiz-adv-x', 0);
        if HasA(FF, 'id') then FontName := AttrA(FF, 'id');
      end;
    finally ListFont.Free; end;

    ListFF := Doc.GetElementsByTagName('font-face');
    try
      if ListFF.Count > 0 then
      begin
        FF := TDOMElement(ListFF[0]);
        UnitsPerEm := AttrInt(FF, 'units-per-em', 1000);
        if UnitsPerEm <= 0 then UnitsPerEm := 1000;
        Ascent  := AttrInt(FF, 'ascent', Round(0.8 * UnitsPerEm));
        Descent := AttrInt(FF, 'descent', -Round(0.2 * UnitsPerEm));
        if HasA(FF, 'font-family') then FontName := AttrA(FF, 'font-family');
      end;
    finally ListFF.Free; end;

    if DefaultAdv = 0 then DefaultAdv := UnitsPerEm;
    FontName := Trim(FontName);
    if FontName = '' then FontName := 'ConvertedFont';

    EmScale := 1000.0 / UnitsPerEm;

    // ---- Collect glyphs: GID 0 = .notdef (missing-glyph if present) ----
    SetLength(Glyphs, 0);
    ListMiss := Doc.GetElementsByTagName('missing-glyph');
    try
      if ListMiss.Count > 0 then
        CollectGlyph(TDOMElement(ListMiss[0]), True)
      else
      begin
        // synthesize an empty .notdef
        SetLength(Glyphs, 1);
        FillChar(Glyphs[0], SizeOf(Glyphs[0]), 0);
        Glyphs[0].CP := 0; Glyphs[0].Adv := DefaultAdv;
        Glyphs[0].Data.IsEmpty := True;
      end;
    finally ListMiss.Free; end;

    ListGl := Doc.GetElementsByTagName('glyph');
    try
      for K := 0 to ListGl.Count - 1 do
        CollectGlyph(TDOMElement(ListGl[K]), False);
    finally ListGl.Free; end;

    NumGlyphs := Length(Glyphs);
    if NumGlyphs < 1 then raise Exception.Create('SVGFontToOTF: no glyphs found');

    // ---- bbox over all glyphs ----
    HaveBBox := False; GXMin:=0; GYMin:=0; GXMax:=0; GYMax:=0;
    for I := 0 to NumGlyphs - 1 do ScanBBox(Glyphs[I].Data);
    if not HaveBBox then begin GXMin:=0; GYMin:=0; GXMax:=Double(UnitsPerEm); GYMax:=Double(UnitsPerEm); end;

    // ---- glyph arrays for CFFBuilder ----
    SetLength(GlyphsArr, NumGlyphs);
    SetLength(HM, NumGlyphs);
    for I := 0 to NumGlyphs - 1 do
    begin
      GlyphsArr[I] := Glyphs[I].Data;
      GlyphsArr[I].XMin := SmallInt(Glyphs[I].XMin);   // informational
      if Glyphs[I].Adv < 0 then Glyphs[I].Adv := 0;
      HM[I].AdvanceWidth := Word(Glyphs[I].Adv);        // SVG units (builder scales)
      HM[I].LSB := SmallInt(Glyphs[I].XMin);
    end;

    // ---- cmap pairs (sorted ascending by CP, unique) ----
    SetLength(CmapCP, NumGlyphs); SetLength(CmapGID, NumGlyphs); CmapN := 0;
    for I := 1 to NumGlyphs - 1 do          // skip GID 0 (.notdef, CP=0)
      if Glyphs[I].CP <> 0 then
      begin
        CmapCP[CmapN] := Glyphs[I].CP; CmapGID[CmapN] := Word(I); Inc(CmapN);
      end;
    // insertion sort by CP, dropping duplicates
    for I := 1 to CmapN - 1 do
    begin
      Tmp := CmapCP[I]; TmpG := CmapGID[I]; J := I - 1;
      while (J >= 0) and (CmapCP[J] > Tmp) do
      begin CmapCP[J+1]:=CmapCP[J]; CmapGID[J+1]:=CmapGID[J]; Dec(J); end;
      CmapCP[J+1] := Tmp; CmapGID[J+1] := TmpG;
    end;
    // dedup
    J := 0;
    for I := 0 to CmapN - 1 do
      if (I = 0) or (CmapCP[I] <> CmapCP[I-1]) then
      begin CmapCP[J] := CmapCP[I]; CmapGID[J] := CmapGID[I]; Inc(J); end;
    CmapN := J;

    // ---- Build CFF table ----
    Builder := TCFFBuilder.CreateFromData(GlyphsArr, HM, Word(NumGlyphs),
                 Word(UnitsPerEm), SmallInt(Round(GXMin)), SmallInt(Round(GYMin)),
                 SmallInt(Round(GXMax)), SmallInt(Round(GYMax)), FontName);
    try
      TableData[0] := Builder.BuildCFF;
    finally
      Builder.Free;
    end;

    // ---- cmap table ----
    HasSupp := (CmapN > 0) and (CmapCP[CmapN-1] > $FFFF);
    // BMP-only arrays for format 4
    SetLength(BmpCP, CmapN); SetLength(BmpG, CmapN); BmpN := 0;
    for I := 0 to CmapN - 1 do
      if CmapCP[I] <= $FFFF then
      begin BmpCP[BmpN] := Word(CmapCP[I]); BmpG[BmpN] := CmapGID[I]; Inc(BmpN); end;
    Cmap4 := BuildCmap4(BmpCP, BmpG, BmpN);
    if HasSupp then Cmap12 := BuildCmap12(CmapCP, CmapGID, CmapN);

    CmapMS := TMemoryStream.Create;
    try
      if HasSupp then NumSubtables := 4 else NumSubtables := 2;
      CmapHdr := 4 + NumSubtables * 8;
      Off4  := LongWord(CmapHdr);
      Off12 := Off4 + LongWord(Length(Cmap4));
      W16(CmapMS, 0);                       // version
      W16(CmapMS, Word(NumSubtables));
      // (0,3) and (3,1) -> format 4
      W16(CmapMS, 0); W16(CmapMS, 3); W32(CmapMS, Off4);
      W16(CmapMS, 3); W16(CmapMS, 1); W32(CmapMS, Off4);
      if HasSupp then
      begin
        W16(CmapMS, 0); W16(CmapMS, 4);  W32(CmapMS, Off12);
        W16(CmapMS, 3); W16(CmapMS, 10); W32(CmapMS, Off12);
      end;
      CmapMS.WriteBuffer(Cmap4[0], Length(Cmap4));
      if HasSupp then CmapMS.WriteBuffer(Cmap12[0], Length(Cmap12));
      TableData[2] := MSBytes(CmapMS);
    finally
      CmapMS.Free;
    end;

    // ---- head ----
    CMS := TMemoryStream.Create;
    try
      W16(CMS, 1); W16(CMS, 0);            // version 1.0
      W32(CMS, $00010000);                 // fontRevision 1.0
      W32(CMS, 0);                         // checkSumAdjustment (patched)
      W32(CMS, $5F0F3CF5);                 // magicNumber
      W16(CMS, $0003);                     // flags
      W16(CMS, 1000);                      // unitsPerEm (normalised)
      W32(CMS, 0); W32(CMS, 0);            // created (LONGDATETIME)
      W32(CMS, 0); W32(CMS, 0);            // modified
      WS16(CMS, SmallInt(Sc(GXMin)));
      WS16(CMS, SmallInt(Sc(GYMin)));
      WS16(CMS, SmallInt(Sc(GXMax)));
      WS16(CMS, SmallInt(Sc(GYMax)));
      W16(CMS, 0);                         // macStyle
      W16(CMS, 8);                         // lowestRecPPEM
      WS16(CMS, 2);                        // fontDirectionHint
      WS16(CMS, 0);                        // indexToLocFormat
      WS16(CMS, 0);                        // glyphDataFormat
      TableData[3] := MSBytes(CMS);
    finally CMS.Free; end;

    // ---- metrics for hhea / OS2 ----
    MaxAdv := 0; AvgW := 0;
    for I := 0 to NumGlyphs - 1 do
    begin
      if Glyphs[I].Adv > MaxAdv then MaxAdv := Glyphs[I].Adv;
      AvgW := AvgW + Glyphs[I].Adv;
    end;
    if NumGlyphs > 0 then AvgW := AvgW div NumGlyphs;
    MinLSB  := Sc(GXMin);
    XMaxExt := Sc(GXMax);

    // ---- hhea ----
    CMS := TMemoryStream.Create;
    try
      W16(CMS, 1); W16(CMS, 0);            // version 1.0
      WS16(CMS, SmallInt(Sc(Ascent)));
      WS16(CMS, SmallInt(Sc(Descent)));
      WS16(CMS, 0);                        // lineGap
      W16(CMS, Word(Sc(MaxAdv)));          // advanceWidthMax
      WS16(CMS, SmallInt(MinLSB));         // minLeftSideBearing
      WS16(CMS, 0);                        // minRightSideBearing
      WS16(CMS, SmallInt(XMaxExt));        // xMaxExtent
      WS16(CMS, 1); WS16(CMS, 0); WS16(CMS, 0);  // caret slope/offset
      WS16(CMS, 0); WS16(CMS, 0); WS16(CMS, 0); WS16(CMS, 0);  // reserved
      WS16(CMS, 0);                        // metricDataFormat
      W16(CMS, Word(NumGlyphs));           // numberOfHMetrics
      TableData[4] := MSBytes(CMS);
    finally CMS.Free; end;

    // ---- hmtx (advances + LSB, scaled) ----
    HMS := TMemoryStream.Create;
    try
      for I := 0 to NumGlyphs - 1 do
      begin
        W16(HMS, Word(Sc(Glyphs[I].Adv)));
        WS16(HMS, SmallInt(Sc(Glyphs[I].XMin)));
      end;
      TableData[5] := MSBytes(HMS);
    finally HMS.Free; end;

    // ---- maxp 0.5 ----
    CMS := TMemoryStream.Create;
    try
      W32(CMS, $00005000);
      W16(CMS, Word(NumGlyphs));
      TableData[6] := MSBytes(CMS);
    finally CMS.Free; end;

    // ---- name ----
    TableData[7] := BuildName(FontName);

    // ---- post 3.0 ----
    CMS := TMemoryStream.Create;
    try
      W32(CMS, $00030000);
      W32(CMS, 0);                         // italicAngle
      WS16(CMS, -100);                     // underlinePosition
      WS16(CMS, 50);                       // underlineThickness
      W32(CMS, 0);                         // isFixedPitch
      W32(CMS, 0); W32(CMS, 0); W32(CMS, 0); W32(CMS, 0);
      TableData[8] := MSBytes(CMS);
    finally CMS.Free; end;

    // ---- OS/2 v4 ----
    if CmapN > 0 then
    begin
      FirstCP := Integer(CmapCP[0]); if FirstCP > $FFFF then FirstCP := $FFFF;
      LastCP  := Integer(CmapCP[CmapN-1]); if LastCP > $FFFF then LastCP := $FFFF;
    end
    else begin FirstCP := 0; LastCP := 0; end;
    CMS := TMemoryStream.Create;
    try
      W16(CMS, 4);                         // version
      WS16(CMS, SmallInt(Sc(AvgW)));       // xAvgCharWidth
      W16(CMS, 400);                       // usWeightClass
      W16(CMS, 5);                         // usWidthClass
      W16(CMS, 0);                         // fsType
      WS16(CMS, 650); WS16(CMS, 600); WS16(CMS, 0);   WS16(CMS, 75);   // subscript
      WS16(CMS, 650); WS16(CMS, 600); WS16(CMS, 0);   WS16(CMS, 350);  // superscript
      WS16(CMS, 50);  WS16(CMS, 258);                                  // strikeout
      WS16(CMS, 0);                        // sFamilyClass
      for I := 0 to 9 do W8(CMS, 0);       // panose
      W32(CMS, 1); W32(CMS, 0); W32(CMS, 0); W32(CMS, 0);  // ulUnicodeRange (Basic Latin)
      W8(CMS, Ord('x')); W8(CMS, Ord('e')); W8(CMS, Ord('l')); W8(CMS, Ord('i')); // achVendID
      W16(CMS, $0040);                     // fsSelection = REGULAR
      W16(CMS, Word(FirstCP));
      W16(CMS, Word(LastCP));
      WS16(CMS, SmallInt(Sc(Ascent)));     // sTypoAscender
      WS16(CMS, SmallInt(Sc(Descent)));    // sTypoDescender
      WS16(CMS, 0);                        // sTypoLineGap
      W16(CMS, Word(Sc(Ascent)));          // usWinAscent
      W16(CMS, Word(Sc(-Descent)));        // usWinDescent
      W32(CMS, 1); W32(CMS, 0);            // ulCodePageRange (Latin 1)
      WS16(CMS, 0);                        // sxHeight
      WS16(CMS, 0);                        // sCapHeight
      W16(CMS, 0);                         // usDefaultChar
      W16(CMS, 32);                        // usBreakChar
      W16(CMS, 0);                         // usMaxContext
      TableData[1] := MSBytes(CMS);
    finally CMS.Free; end;

    // ================================================================
    // Assemble the OpenType font
    // ================================================================
    SearchRange := 1; EntrySelector := 0;
    while SearchRange * 2 <= NUM_TABLES do
    begin SearchRange := SearchRange * 2; Inc(EntrySelector); end;
    SearchRange := SearchRange * 16;
    RangeShift  := NUM_TABLES * 16 - SearchRange;

    DataStart := 12 + LongWord(NUM_TABLES) * 16;
    TotalSize := DataStart;
    for I := 0 to NUM_TABLES - 1 do
    begin
      Offsets[I] := TotalSize;
      Lengths[I] := Length(TableData[I]);
      if Lengths[I] > 0 then Chksums[I] := CalcChecksum(@TableData[I][0], Lengths[I])
      else Chksums[I] := 0;
      N := Lengths[I] mod 4;
      Pad := 0; if N > 0 then Pad := 4 - N;
      Inc(TotalSize, Lengths[I] + LongWord(Pad));
    end;

    Buf := TMemoryStream.Create;
    try
      W32(Buf, SFNT_CFF);
      W16(Buf, NUM_TABLES);
      W16(Buf, SearchRange);
      W16(Buf, EntrySelector);
      W16(Buf, RangeShift);
      for I := 0 to NUM_TABLES - 1 do
      begin
        W32(Buf, TAGS[I]);
        W32(Buf, Chksums[I]);
        W32(Buf, Offsets[I]);
        W32(Buf, Lengths[I]);
      end;
      Z := 0;
      for I := 0 to NUM_TABLES - 1 do
      begin
        if Lengths[I] > 0 then Buf.WriteBuffer(TableData[I][0], Lengths[I]);
        N := Lengths[I] mod 4;
        if N > 0 then for Pad := 1 to 4 - N do Buf.WriteBuffer(Z, 1);
      end;

      // checkSumAdjustment
      Buf.Position := 0;
      FullChk := CalcChecksum(Buf.Memory, Buf.Size);
      AdjPos := Offsets[HEAD_IDX] + 8;
      Buf.Position := AdjPos;
      W32(Buf, LongWord($B1B0AFBA) - FullChk);

      Buf.Position := 0;
      Dst.CopyFrom(Buf, Buf.Size);
    finally
      Buf.Free;
    end;

  finally
    if Doc <> nil then Doc.Free;
    PP.Free;
    MemIn.Free;
  end;
end;

end.
