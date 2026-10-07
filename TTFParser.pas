unit TTFParser;

{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, FontTypes;

// Author: www.xelitan.com
// License: MIT
// Reads a TrueType font, parses all glyph outlines, and converts
// quadratic Bezier splines to cubic Bezier curves.

type
  TTTFParser = class
  private
    FStream      : TStream;
    FOwnsStream  : Boolean;
    FTables      : TRawTableArray;
    FNumGlyphs   : Word;
    FLocaFormat  : SmallInt;   // 0 = short (x2), 1 = long
    FNumHMetrics : Word;
    FUnitsPerEm  : Word;
    FAscender    : SmallInt;
    FDescender   : SmallInt;
    FLineGap     : SmallInt;
    FMacStyle    : Word;
    FHeadFlags   : Word;
    FXMin, FYMin, FXMax, FYMax : SmallInt;
    FGlyphs      : TGlyphDataArray;
    FHMetrics    : THMetricArray;

    function  FindTable(Tag : TTableTag) : Integer;
    function  TableStream(Tag : TTableTag) : TMemoryStream;  // caller frees
    procedure ReadTables;
    procedure ParseHead;
    procedure ParseHhea;
    procedure ParseMaxp;
    procedure ParseHmtx;
    procedure ParseGlyphs;

    function  LocaOffset(GID : Word; const LocaData : TBytes) : LongWord;
    procedure ParseSimpleGlyph(const GlyfData : TBytes; GlyfOfs : LongWord;
                                out GD : TGlyphData);
    procedure ParseCompositeGlyph(const GlyfData, LocaData : TBytes;
                                   GlyfOfs : LongWord; Depth : Integer;
                                   out GD : TGlyphData);
    procedure ParseOneGlyph(GID : Word; const LocaData, GlyfData : TBytes;
                             Depth : Integer; out GD : TGlyphData);
    procedure QuadToCubic(const QPts : TGlyphPointArray;
                           out CCont : TCubicContour);
  public
    constructor Create(AStream : TStream; AOwns : Boolean = False);
    destructor  Destroy; override;

    procedure Parse;

    // Raw table bytes (nil if not present)
    function RawTable(Tag : TTableTag) : TBytes;

    property NumGlyphs   : Word            read FNumGlyphs;
    property UnitsPerEm  : Word            read FUnitsPerEm;
    property Ascender    : SmallInt        read FAscender;
    property Descender   : SmallInt        read FDescender;
    property LineGap     : SmallInt        read FLineGap;
    property MacStyle    : Word            read FMacStyle;
    property HeadFlags   : Word            read FHeadFlags;
    property XMin        : SmallInt        read FXMin;
    property YMin        : SmallInt        read FYMin;
    property XMax        : SmallInt        read FXMax;
    property YMax        : SmallInt        read FYMax;
    property Glyphs      : TGlyphDataArray read FGlyphs;
    property HMetrics    : THMetricArray   read FHMetrics;
    property NumHMetrics : Word            read FNumHMetrics;
  end;

implementation

// ================================================================
// Constructor / destructor
// ================================================================

constructor TTTFParser.Create(AStream : TStream; AOwns : Boolean);
begin
  inherited Create;
  FStream     := AStream;
  FOwnsStream := AOwns;
end;

destructor TTTFParser.Destroy;
begin
  if FOwnsStream then FStream.Free;
  inherited;
end;

// ================================================================
// Table directory
// ================================================================

function TTTFParser.FindTable(Tag : TTableTag) : Integer;
var I : Integer;
begin
  for I := 0 to High(FTables) do
    if FTables[I].Tag = Tag then Exit(I);
  Result := -1;
end;

function TTTFParser.RawTable(Tag : TTableTag) : TBytes;
var I : Integer;
begin
  I := FindTable(Tag);
  if I >= 0 then Result := FTables[I].Data
  else Result := nil;
end;

function TTTFParser.TableStream(Tag : TTableTag) : TMemoryStream;
var I : Integer;
begin
  I := FindTable(Tag);
  if I < 0 then Exit(nil);
  Result := TMemoryStream.Create;
  if Length(FTables[I].Data) > 0 then
    Result.WriteBuffer(FTables[I].Data[0], Length(FTables[I].Data));
  Result.Position := 0;
end;

procedure TTTFParser.ReadTables;
var
  Sig, Chk, Off, Len : LongWord;
  Num, I              : Word;
  Saved               : Int64;
begin
  FStream.Position := 0;
  Sig := ReadU32(FStream);
  if (Sig <> SFNT_TRUE) and (Sig <> SFNT_TRUE2) then
    raise Exception.Create('Not a TrueType font (bad sfVersion)');
  Num := ReadU16(FStream);
  ReadU16(FStream);  // searchRange
  ReadU16(FStream);  // entrySelector
  ReadU16(FStream);  // rangeShift
  SetLength(FTables, Num);
  for I := 0 to Num - 1 do
  begin
    FTables[I].Tag      := ReadU32(FStream);
    FTables[I].Checksum := ReadU32(FStream);
    Off                 := ReadU32(FStream);
    Len                 := ReadU32(FStream);
    SetLength(FTables[I].Data, Len);
    Saved := FStream.Position;
    FStream.Position := Off;
    if Len > 0 then FStream.ReadBuffer(FTables[I].Data[0], Len);
    FStream.Position := Saved;
  end;
end;

// ================================================================
// Metric tables
// ================================================================

procedure TTTFParser.ParseHead;
var S : TMemoryStream;
begin
  S := TableStream(TAG_HEAD);
  if S = nil then raise Exception.Create('head table missing');
  try
    ReadU16(S); ReadU16(S);  // major/minor version
    ReadU32(S);              // fontRevision
    ReadU32(S);              // checkSumAdjustment
    ReadU32(S);              // magicNumber
    FHeadFlags  := ReadU16(S);
    FUnitsPerEm := ReadU16(S);
    S.Seek(16, soCurrent);   // created + modified (2 x Int64)
    FXMin := ReadS16(S);  FYMin := ReadS16(S);
    FXMax := ReadS16(S);  FYMax := ReadS16(S);
    FMacStyle := ReadU16(S);
    ReadU16(S);              // lowestRecPPEM
    ReadS16(S);              // fontDirectionHint
    FLocaFormat := ReadS16(S);
  finally S.Free; end;
end;

procedure TTTFParser.ParseHhea;
var S : TMemoryStream;
begin
  S := TableStream(TAG_HHEA);
  if S = nil then raise Exception.Create('hhea table missing');
  try
    ReadU16(S); ReadU16(S);
    FAscender    := ReadS16(S);
    FDescender   := ReadS16(S);
    FLineGap     := ReadS16(S);
    S.Seek(24, soCurrent);   // skip to numberOfHMetrics
    FNumHMetrics := ReadU16(S);
  finally S.Free; end;
end;

procedure TTTFParser.ParseMaxp;
var S : TMemoryStream;
begin
  S := TableStream(TAG_MAXP);
  if S = nil then raise Exception.Create('maxp table missing');
  try
    ReadU32(S);
    FNumGlyphs := ReadU16(S);
  finally S.Free; end;
end;

procedure TTTFParser.ParseHmtx;
var
  S      : TMemoryStream;
  I      : Word;
  LastAW : Word;
begin
  S := TableStream(TAG_HMTX);
  if S = nil then raise Exception.Create('hmtx table missing');
  try
    SetLength(FHMetrics, FNumGlyphs);
    LastAW := 0;
    for I := 0 to FNumGlyphs - 1 do
    begin
      if I < FNumHMetrics then
      begin
        FHMetrics[I].AdvanceWidth := ReadU16(S);
        FHMetrics[I].LSB          := ReadS16(S);
        LastAW := FHMetrics[I].AdvanceWidth;
      end
      else
      begin
        FHMetrics[I].AdvanceWidth := LastAW;
        FHMetrics[I].LSB          := ReadS16(S);
      end;
    end;
  finally S.Free; end;
end;

// ================================================================
// loca helper
// ================================================================

function TTTFParser.LocaOffset(GID : Word; const LocaData : TBytes) : LongWord;
var P : LongWord;
begin
  if FLocaFormat = 0 then
  begin
    P := LongWord(GID) * 2;
    if P + 1 >= LongWord(Length(LocaData)) then Exit(0);
    Result := LongWord((LongWord(LocaData[P]) shl 8) or LocaData[P + 1]) * 2;
  end
  else
  begin
    P := LongWord(GID) * 4;
    if P + 3 >= LongWord(Length(LocaData)) then Exit(0);
    Result := (LongWord(LocaData[P    ]) shl 24) or
              (LongWord(LocaData[P + 1]) shl 16) or
              (LongWord(LocaData[P + 2]) shl  8) or
               LongWord(LocaData[P + 3]);
  end;
end;

// ================================================================
// Quadratic-to-cubic spline conversion
// ================================================================
//
// Algorithm:
// 1. Expand implicit on-curve midpoints that TrueType inserts between
//    two consecutive off-curve points.
// 2. Count the on-curve points; that is the number of closed segments.
// 3. Walk the expanded contour, processing exactly that many segments.
//    - on-curve next point  -> line segment
//    - off-curve next point -> quadratic arc (one control point) ->
//        lifted to cubic via degree-elevation formula:
//          C1 = P0 + 2/3*(P1-P0)
//          C2 = P2 + 2/3*(P1-P2)
// The last segment closes back to the start; if it is a curve the last
// cubic endpoint coincides with the moveto point, making the CFF implicit
// close a no-op.  If it is a line the CFF implicit close draws it.

procedure TTTFParser.QuadToCubic(const QPts : TGlyphPointArray;
                                   out CCont : TCubicContour);
var
  N, I, K      : Integer;
  P0, P1, P2   : TGlyphPoint;
  Mid, C1, C2  : TGlyphPoint;
  Exp          : TGlyphPointArray;
  EC           : Integer;
  Out_         : TGlyphPointArray;
  OC           : Integer;
  StartIdx     : Integer;
  OnCurveCount : Integer;
  SegsDone     : Integer;

  procedure AddExp(const P : TGlyphPoint); inline;
  begin
    if EC >= Length(Exp) then SetLength(Exp, EC + 64);
    Exp[EC] := P; Inc(EC);
  end;

  procedure AddOut(const P : TGlyphPoint); inline;
  begin
    if OC >= Length(Out_) then SetLength(Out_, OC + 64);
    Out_[OC] := P; Inc(OC);
  end;

begin
  N := Length(QPts);
  if N = 0 then begin CCont := nil; Exit; end;

  // Step 1: insert implicit midpoints between consecutive off-curve points
  SetLength(Exp, N * 2 + 4);
  EC := 0;
  for I := 0 to N - 1 do
  begin
    P0 := QPts[I];
    P1 := QPts[(I + 1) mod N];
    AddExp(P0);
    if (not P0.OnCurve) and (not P1.OnCurve) then
    begin
      Mid.X := (P0.X + P1.X) * 0.5;
      Mid.Y := (P0.Y + P1.Y) * 0.5;
      Mid.OnCurve := True;
      AddExp(Mid);
    end;
  end;
  SetLength(Exp, EC);

  // Find first on-curve starting point
  StartIdx := -1;
  for I := 0 to EC - 1 do
    if Exp[I].OnCurve then begin StartIdx := I; Break; end;
  if StartIdx < 0 then begin CCont := nil; Exit; end;

  // Count on-curve points = total closed segments in this contour
  OnCurveCount := 0;
  for K := 0 to EC - 1 do
    if Exp[K].OnCurve then Inc(OnCurveCount);

  // Step 2: walk segments and lift quadratics to cubics
  SetLength(Out_, EC * 3 + 4);
  OC := 0;
  AddOut(Exp[StartIdx]);

  I        := (StartIdx + 1) mod EC;
  SegsDone := 0;

  while SegsDone < OnCurveCount do
  begin
    if Exp[I].OnCurve then
    begin
      // Line segment - or the closing line back to start
      AddOut(Exp[I]);
      I := (I + 1) mod EC;
      Inc(SegsDone);
    end
    else
    begin
      // Quadratic arc: Exp[I] is the single off-curve control point.
      // After expansion Exp[(I+1) mod EC] must be on-curve.
      P0 := Out_[OC - 1];              // previous on-curve endpoint
      P1 := Exp[I];                    // quadratic control point
      P2 := Exp[(I + 1) mod EC];       // next on-curve endpoint

      C1.X := P0.X + (2.0 / 3.0) * (P1.X - P0.X);
      C1.Y := P0.Y + (2.0 / 3.0) * (P1.Y - P0.Y);
      C1.OnCurve := False;
      C2.X := P2.X + (2.0 / 3.0) * (P1.X - P2.X);
      C2.Y := P2.Y + (2.0 / 3.0) * (P1.Y - P2.Y);
      C2.OnCurve := False;

      AddOut(C1); AddOut(C2); AddOut(P2);
      I := (I + 2) mod EC;
      Inc(SegsDone);
    end;
  end;

  SetLength(CCont, OC);
  if OC > 0 then Move(Out_[0], CCont[0], OC * SizeOf(TGlyphPoint));
end;

// ================================================================
// Simple glyph parser
// ================================================================

procedure TTTFParser.ParseSimpleGlyph(const GlyfData : TBytes;
                                       GlyfOfs : LongWord;
                                       out GD : TGlyphData);
const
  FLAG_ON_CURVE = $01;
  FLAG_X_SHORT  = $02;
  FLAG_Y_SHORT  = $04;
  FLAG_REPEAT   = $08;
  FLAG_X_POS    = $10;
  FLAG_Y_POS    = $20;
var
  MS         : TMemoryStream;
  NC, I, J   : Integer;
  InstrLen   : Word;
  EndPts     : array of Word;
  TotalPts   : Integer;
  Flags      : array of Byte;
  Flag, Rep  : Byte;
  XC, YC     : array of SmallInt;
  XVal, YVal : SmallInt;
  LX, LY     : SmallInt;
  P          : TGlyphPoint;
  QPts       : TGlyphPointArray;
  CC         : TCubicContour;
  CS, CE     : Integer;
begin
  GD.IsEmpty    := False;
  GD.IsComposite := False;
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(GlyfData[0], Length(GlyfData));
    MS.Position := GlyfOfs;

    NC := ReadS16(MS);
    GD.XMin := ReadS16(MS);  GD.YMin := ReadS16(MS);
    GD.XMax := ReadS16(MS);  GD.YMax := ReadS16(MS);

    if NC <= 0 then begin GD.IsEmpty := True; Exit; end;

    SetLength(EndPts, NC);
    for I := 0 to NC - 1 do EndPts[I] := ReadU16(MS);
    TotalPts := EndPts[NC - 1] + 1;

    InstrLen := ReadU16(MS);
    MS.Seek(InstrLen, soCurrent);

    // Flags with run-length encoding
    SetLength(Flags, TotalPts);
    I := 0;
    while I < TotalPts do
    begin
      Flag := ReadU8(MS);
      Flags[I] := Flag;
      Inc(I);
      if (Flag and FLAG_REPEAT) <> 0 then
      begin
        Rep := ReadU8(MS);
        while (Rep > 0) and (I < TotalPts) do
        begin
          Flags[I] := Flag; Inc(I); Dec(Rep);
        end;
      end;
    end;

    // X coordinates (delta-encoded)
    SetLength(XC, TotalPts);
    LX := 0;
    for I := 0 to TotalPts - 1 do
    begin
      Flag := Flags[I];
      if (Flag and FLAG_X_SHORT) <> 0 then
      begin
        XVal := ReadU8(MS);
        if (Flag and FLAG_X_POS) = 0 then XVal := -XVal;
      end
      else if (Flag and FLAG_X_POS) <> 0 then XVal := 0
      else XVal := ReadS16(MS);
      Inc(LX, XVal);
      XC[I] := LX;
    end;

    // Y coordinates (delta-encoded)
    SetLength(YC, TotalPts);
    LY := 0;
    for I := 0 to TotalPts - 1 do
    begin
      Flag := Flags[I];
      if (Flag and FLAG_Y_SHORT) <> 0 then
      begin
        YVal := ReadU8(MS);
        if (Flag and FLAG_Y_POS) = 0 then YVal := -YVal;
      end
      else if (Flag and FLAG_Y_POS) <> 0 then YVal := 0
      else YVal := ReadS16(MS);
      Inc(LY, YVal);
      YC[I] := LY;
    end;

    // Build cubic contours
    SetLength(GD.Contours, NC);
    CS := 0;
    for I := 0 to NC - 1 do
    begin
      CE := EndPts[I];
      SetLength(QPts, CE - CS + 1);
      for J := CS to CE do
      begin
        P.X       := XC[J];
        P.Y       := YC[J];
        P.OnCurve := (Flags[J] and FLAG_ON_CURVE) <> 0;
        QPts[J - CS] := P;
      end;
      QuadToCubic(QPts, CC);
      GD.Contours[I] := CC;
      CS := CE + 1;
    end;
  finally MS.Free; end;
end;

// ================================================================
// Composite glyph parser
// ================================================================

procedure TTTFParser.ParseCompositeGlyph(const GlyfData, LocaData : TBytes;
                                          GlyfOfs : LongWord; Depth : Integer;
                                          out GD : TGlyphData);
const
  ARG_WORDS     = $0001;
  ARGS_ARE_XY   = $0002;
  WE_HAVE_SCALE = $0008;
  MORE_COMPS    = $0020;
  WE_HAVE_XY_SC = $0040;
  WE_HAVE_2X2   = $0080;
var
  MS          : TMemoryStream;
  CFlags, CGID: Word;
  A1, A2      : SmallInt;
  DX, DY      : Single;
  SX, SY, S01, S10, Sc : Single;
  Has2x2      : Boolean;
  CompGD      : TGlyphData;
  CI, PI      : Integer;
  NewC        : TCubicContour;
  PT          : TGlyphPoint;
  AllC        : TCubicContourArray;
  TC          : Integer;
  CO, CO2     : LongWord;
begin
  GD.IsEmpty    := False;
  GD.IsComposite := True;
  TC := 0;
  SetLength(AllC, 0);

  if Depth > 8 then begin GD.IsEmpty := True; Exit; end;

  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(GlyfData[0], Length(GlyfData));
    MS.Position := GlyfOfs;

    ReadS16(MS);             // numberOfContours = -1
    GD.XMin := ReadS16(MS); GD.YMin := ReadS16(MS);
    GD.XMax := ReadS16(MS); GD.YMax := ReadS16(MS);

    repeat
      CFlags := ReadU16(MS);
      CGID   := ReadU16(MS);

      if (CFlags and ARG_WORDS) <> 0 then
      begin A1 := ReadS16(MS); A2 := ReadS16(MS); end
      else
      begin A1 := ShortInt(ReadU8(MS)); A2 := ShortInt(ReadU8(MS)); end;

      DX := 0; DY := 0;
      if (CFlags and ARGS_ARE_XY) <> 0 then begin DX := A1; DY := A2; end;

      SX := 1; SY := 1; S01 := 0; S10 := 0; Has2x2 := False;
      if (CFlags and WE_HAVE_2X2) <> 0 then
      begin
        SX  := ReadS16(MS) / 16384.0;  S01 := ReadS16(MS) / 16384.0;
        S10 := ReadS16(MS) / 16384.0;  SY  := ReadS16(MS) / 16384.0;
        Has2x2 := True;
      end
      else if (CFlags and WE_HAVE_XY_SC) <> 0 then
      begin SX := ReadS16(MS) / 16384.0; SY := ReadS16(MS) / 16384.0; end
      else if (CFlags and WE_HAVE_SCALE) <> 0 then
      begin Sc := ReadS16(MS) / 16384.0; SX := Sc; SY := Sc; end;

      if CGID < FNumGlyphs then
      begin
        CO  := LocaOffset(CGID,     LocaData);
        CO2 := LocaOffset(CGID + 1, LocaData);
        if CO2 > CO then
        begin
          ParseOneGlyph(CGID, LocaData, GlyfData, Depth + 1, CompGD);
          for CI := 0 to High(CompGD.Contours) do
          begin
            SetLength(NewC, Length(CompGD.Contours[CI]));
            for PI := 0 to High(CompGD.Contours[CI]) do
            begin
              PT := CompGD.Contours[CI][PI];
              if Has2x2 then
              begin
                NewC[PI].X := PT.X * SX + PT.Y * S10 + DX;
                NewC[PI].Y := PT.X * S01 + PT.Y * SY + DY;
              end
              else
              begin
                NewC[PI].X := PT.X * SX + DX;
                NewC[PI].Y := PT.Y * SY + DY;
              end;
              NewC[PI].OnCurve := PT.OnCurve;
            end;
            SetLength(AllC, TC + 1);
            AllC[TC] := NewC;
            Inc(TC);
          end;
        end;
      end;
    until (CFlags and MORE_COMPS) = 0;

    GD.Contours := AllC;
  finally MS.Free; end;
end;

// ================================================================
// Dispatch: simple vs composite
// ================================================================

procedure TTTFParser.ParseOneGlyph(GID : Word;
                                    const LocaData, GlyfData : TBytes;
                                    Depth : Integer; out GD : TGlyphData);
var
  Off, Off2 : LongWord;
  NC        : SmallInt;
begin
  GD.IsEmpty    := True;
  GD.IsComposite := False;
  SetLength(GD.Contours, 0);
  GD.XMin := 0; GD.YMin := 0; GD.XMax := 0; GD.YMax := 0;

  if (GID >= FNumGlyphs) or (Length(GlyfData) = 0) or (Length(LocaData) = 0) then
    Exit;
  Off  := LocaOffset(GID,     LocaData);
  Off2 := LocaOffset(GID + 1, LocaData);
  if Off2 <= Off then Exit;
  if Off + 2 > LongWord(Length(GlyfData)) then Exit;

  NC := SmallInt((LongWord(GlyfData[Off]) shl 8) or GlyfData[Off + 1]);
  if NC = -1 then
    ParseCompositeGlyph(GlyfData, LocaData, Off, Depth, GD)
  else if NC > 0 then
    ParseSimpleGlyph(GlyfData, Off, GD);
  // NC = 0: leave GD empty (space glyph etc.)
end;

procedure TTTFParser.ParseGlyphs;
var
  LocaData, GlyfData : TBytes;
  I : Word;
begin
  LocaData := RawTable(TAG_LOCA);
  GlyfData := RawTable(TAG_GLYF);
  SetLength(FGlyphs, FNumGlyphs);
  for I := 0 to FNumGlyphs - 1 do
    ParseOneGlyph(I, LocaData, GlyfData, 0, FGlyphs[I]);
end;

// ================================================================
// Public entry point
// ================================================================

procedure TTTFParser.Parse;
begin
  ReadTables;
  ParseHead;
  ParseHhea;
  ParseMaxp;
  ParseHmtx;
  ParseGlyphs;
end;

end.
