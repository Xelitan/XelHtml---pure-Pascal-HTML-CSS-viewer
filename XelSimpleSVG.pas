unit XelSimpleSVG;

//Renders SVG images on a TBitmap
//No dependencies
//Author: www.xelitan.com
//License: MIT

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DOM, XMLRead, Windows, Types, Graphics;

function RenderSimpleSVGToBitmap(const ASVGText: string; ABitmap: TBitmap;
  ABgColor: TColor = clWhite): Boolean;

implementation

var
  CSSClassStyles: TStringList = nil;

type
  TMatrix2D = record
    A, B, C, D, E, F: Double; // SVG matrix(a,b,c,d,e,f): x'=A*x+C*y+E  y'=B*x+D*y+F
  end;

  TRenderState = record
    ViewX, ViewY, ViewW, ViewH: Double;
    BitmapW, BitmapH: Integer;
    CTM: TMatrix2D;
  end;

function IdentityMatrix: TMatrix2D;
begin
  Result.A := 1; Result.B := 0;
  Result.C := 0; Result.D := 1;
  Result.E := 0; Result.F := 0;
end;

// Compose: result = M1 * M2  (M2 applied first, then M1)
function MatMul(const M1, M2: TMatrix2D): TMatrix2D;
begin
  Result.A := M1.A * M2.A + M1.C * M2.B;
  Result.B := M1.B * M2.A + M1.D * M2.B;
  Result.C := M1.A * M2.C + M1.C * M2.D;
  Result.D := M1.B * M2.C + M1.D * M2.D;
  Result.E := M1.A * M2.E + M1.C * M2.F + M1.E;
  Result.F := M1.B * M2.E + M1.D * M2.F + M1.F;
end;

// Windows.POINT shadows Types.Point() — use this helper everywhere instead.
function MakePt(AX, AY: Integer): TPoint;
begin
  Result.X := AX;
  Result.Y := AY;
end;

function GetAttr(ANode: TDOMNode; const AName: string; const ADefault: string = ''): string;
var
  Attr: TDOMNode;
begin
  Result := ADefault;
  if (ANode = nil) or (ANode.Attributes = nil) then
    Exit;
  Attr := ANode.Attributes.GetNamedItem(AName);
  if Attr <> nil then
    Result := Attr.NodeValue;
end;

function TrimUnit(const S: string): string;
var
  I: Integer;
begin
  Result := Trim(S);
  I := Length(Result);
  while (I > 0) and (Result[I] in ['a'..'z', 'A'..'Z', '%']) do
  begin
    Delete(Result, I, 1);
    Dec(I);
  end;
end;

function StrToFloatSafe(const S: string; const ADefault: Double = 0.0): Double;
var
  FS: TFormatSettings;
  T: string;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  T := TrimUnit(Trim(S));
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  Result := ADefault;
  if T = '' then Exit;
  try
    Result := StrToFloat(T, FS);
  except
    Result := ADefault;
  end;
end;

function ParseIntSafe(const S: string; const ADefault: Integer = 0): Integer;
begin
  Result := Round(StrToFloatSafe(S, ADefault));
end;

function ClampByte(Value: Integer): Byte;
begin
  if Value < 0 then Exit(0);
  if Value > 255 then Exit(255);
  Result := Value;
end;

function SplitNumbers(const S: string): TStringList;
var
  T: string;
begin
  Result := TStringList.Create;
  T := Trim(S);
  T := StringReplace(T, #13, ' ', [rfReplaceAll]);
  T := StringReplace(T, #10, ' ', [rfReplaceAll]);
  T := StringReplace(T, #9,  ' ', [rfReplaceAll]);
  T := StringReplace(T, ',', ' ', [rfReplaceAll]);
  while Pos('  ', T) > 0 do
    T := StringReplace(T, '  ', ' ', [rfReplaceAll]);

  Result.Delimiter := ' ';
  Result.StrictDelimiter := False;
  Result.DelimitedText := T;
end;

function ParseSVGColor(const S: string; const ADefault: TColor): TColor;
var
  T: string;
  R, G, B: Integer;
  Parts: TStringList;
begin
  T := LowerCase(Trim(S));

  if (T = '') or (T = 'none') then
    Exit(clNone);

  if T[1] = '#' then
  begin
    if Length(T) = 7 then
    begin
      R := StrToIntDef('$' + Copy(T, 2, 2), 0);
      G := StrToIntDef('$' + Copy(T, 4, 2), 0);
      B := StrToIntDef('$' + Copy(T, 6, 2), 0);
      Exit(RGBToColor(R, G, B));
    end
    else if Length(T) = 4 then
    begin
      R := StrToIntDef('$' + Copy(T, 2, 1) + Copy(T, 2, 1), 0);
      G := StrToIntDef('$' + Copy(T, 3, 1) + Copy(T, 3, 1), 0);
      B := StrToIntDef('$' + Copy(T, 4, 1) + Copy(T, 4, 1), 0);
      Exit(RGBToColor(R, G, B));
    end;
  end;

  if Pos('rgb(', T) = 1 then
  begin
    T := Copy(T, 5, Length(T) - 4);
    if (Length(T) > 0) and (T[Length(T)] = ')') then
      Delete(T, Length(T), 1);

    Parts := TStringList.Create;
    try
      Parts.Delimiter := ',';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := T;
      if Parts.Count >= 3 then
      begin
        R := ClampByte(ParseIntSafe(Trim(Parts[0]), 0));
        G := ClampByte(ParseIntSafe(Trim(Parts[1]), 0));
        B := ClampByte(ParseIntSafe(Trim(Parts[2]), 0));
        Exit(RGBToColor(R, G, B));
      end;
    finally
      Parts.Free;
    end;
  end;

  if T = 'black'   then Exit(clBlack);
  if T = 'white'   then Exit(clWhite);
  if T = 'red'     then Exit(clRed);
  if T = 'green'   then Exit(clGreen);
  if T = 'blue'    then Exit(clBlue);
  if T = 'yellow'  then Exit(clYellow);
  if T = 'gray'    then Exit(clGray);
  if T = 'grey'    then Exit(clGray);
  if T = 'silver'  then Exit(clSilver);
  if T = 'maroon'  then Exit(clMaroon);
  if T = 'navy'    then Exit(clNavy);
  if T = 'lime'    then Exit(clLime);
  if T = 'fuchsia' then Exit(clFuchsia);
  if T = 'aqua'    then Exit(clAqua);
  if T = 'teal'    then Exit(clTeal);
  if T = 'purple'  then Exit(clPurple);
  if T = 'olive'   then Exit(clOlive);
  if T = 'orange'  then Exit(RGBToColor(255, 165, 0));

  Result := ADefault;
end;

function GetStyleProp(const StyleText, PropName: string): string;
var
  Parts: TStringList;
  I, P: Integer;
  S, K, V: string;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := False;
    Parts.DelimitedText := StyleText;

    for I := 0 to Parts.Count - 1 do
    begin
      S := Trim(Parts[I]);
      P := Pos(':', S);
      if P > 0 then
      begin
        K := LowerCase(Trim(Copy(S, 1, P - 1)));
        V := Trim(Copy(S, P + 1, MaxInt));
        if K = LowerCase(PropName) then
          Exit(V);
      end;
    end;
  finally
    Parts.Free;
  end;
end;


function CollapseCSSWhitespace(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in [#9, #10, #13] then
      Result[I] := ' ';
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  Result := Trim(Result);
end;

procedure ParseCSSStyleText(const CSS: string);
var
  T, Selector, Body, ClassName: string;
  P, OpenBrace, CloseBrace, DotPos, I, J: Integer;
  Selectors: TStringList;
begin
  if CSSClassStyles = nil then
  begin
    CSSClassStyles := TStringList.Create;
    CSSClassStyles.CaseSensitive := False;
    CSSClassStyles.NameValueSeparator := '=';
  end;

  T := CollapseCSSWhitespace(CSS);
  P := 1;
  while P <= Length(T) do
  begin
    OpenBrace := Pos('{', Copy(T, P, MaxInt));
    if OpenBrace = 0 then Break;
    OpenBrace := P + OpenBrace - 1;

    CloseBrace := Pos('}', Copy(T, OpenBrace + 1, MaxInt));
    if CloseBrace = 0 then Break;
    CloseBrace := OpenBrace + CloseBrace;

    Selector := Trim(Copy(T, P, OpenBrace - P));
    Body := Trim(Copy(T, OpenBrace + 1, CloseBrace - OpenBrace - 1));

    Selectors := TStringList.Create;
    try
      Selectors.Delimiter := ',';
      Selectors.StrictDelimiter := True;
      Selectors.DelimitedText := Selector;
      for I := 0 to Selectors.Count - 1 do
      begin
        Selector := Trim(Selectors[I]);
        DotPos := Pos('.', Selector);
        if DotPos > 0 then
        begin
          ClassName := Copy(Selector, DotPos + 1, MaxInt);
          J := 1;
          while (J <= Length(ClassName)) and (ClassName[J] in
            ['a'..'z','A'..'Z','0'..'9','_','-']) do
            Inc(J);
          ClassName := Copy(ClassName, 1, J - 1);

          if ClassName <> '' then
            CSSClassStyles.Values[LowerCase(ClassName)] := Body;
        end;
      end;
    finally
      Selectors.Free;
    end;

    P := CloseBrace + 1;
  end;
end;

procedure CollectCSSStyles(ANode: TDOMNode);
var
  Child: TDOMNode;
  CSS: string;
begin
  if ANode = nil then Exit;

  if (ANode is TDOMElement) and (LowerCase(ANode.NodeName) = 'style') then
  begin
    CSS := '';
    Child := ANode.FirstChild;
    while Child <> nil do
    begin
      CSS := CSS + Child.NodeValue;
      Child := Child.NextSibling;
    end;
    ParseCSSStyleText(CSS);
    Exit;
  end;

  Child := ANode.FirstChild;
  while Child <> nil do
  begin
    CollectCSSStyles(Child);
    Child := Child.NextSibling;
  end;
end;

function GetClassStyleProp(ANode: TDOMNode; const PropName: string): string;
var
  Classes, ClassName, StyleText, V: string;
  I: Integer;
  Parts: TStringList;
begin
  Result := '';
  if CSSClassStyles = nil then Exit;

  Classes := Trim(GetAttr(ANode, 'class', ''));
  if Classes = '' then Exit;

  Parts := TStringList.Create;
  try
    Classes := StringReplace(Classes, #9, ' ', [rfReplaceAll]);
    Classes := StringReplace(Classes, #10, ' ', [rfReplaceAll]);
    Classes := StringReplace(Classes, #13, ' ', [rfReplaceAll]);
    while Pos('  ', Classes) > 0 do
      Classes := StringReplace(Classes, '  ', ' ', [rfReplaceAll]);

    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Classes;

    for I := 0 to Parts.Count - 1 do
    begin
      ClassName := LowerCase(Trim(Parts[I]));
      if ClassName = '' then Continue;

      StyleText := CSSClassStyles.Values[ClassName];
      if StyleText <> '' then
      begin
        V := GetStyleProp(StyleText, PropName);
        if V <> '' then
          Exit(V);
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function GetAttrOrStyle(ANode: TDOMNode; const AName, ADefault: string): string;
var
  V, StyleText: string;
begin
  // CSS cascade order used here:
  // 1) inline style="..."  2) CSS class from <style>  3) presentation attribute  4) default.
  StyleText := GetAttr(ANode, 'style', '');
  if StyleText <> '' then
  begin
    V := GetStyleProp(StyleText, AName);
    if V <> '' then
      Exit(V);
  end;

  V := GetClassStyleProp(ANode, AName);
  if V <> '' then
    Exit(V);

  V := GetAttr(ANode, AName, '');
  if V <> '' then
    Exit(V);

  Result := ADefault;
end;

procedure ApplyStyle(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState);
var
  FillColor, StrokeColor: TColor;
  StrokeWidth, CTMScale, ViewScale, PixelWidth: Double;
begin
  FillColor := ParseSVGColor(GetAttrOrStyle(ANode, 'fill', 'black'), clBlack);
  StrokeColor := ParseSVGColor(GetAttrOrStyle(ANode, 'stroke', 'none'), clNone);
  StrokeWidth := StrToFloatSafe(GetAttrOrStyle(ANode, 'stroke-width', '1'), 1.0);

  if FillColor = clNone then
    ACanvas.Brush.Style := bsClear
  else
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := FillColor;
  end;

  if StrokeColor = clNone then
    ACanvas.Pen.Style := psClear
  else
  begin
    // Scale stroke-width from SVG user units to bitmap pixels.
    // CTMScale = sqrt(|det(CTM)|) gives the linear scale factor of the transform.
    // ViewScale maps SVG viewport units to bitmap pixels.
    CTMScale  := Sqrt(Abs(State.CTM.A * State.CTM.D - State.CTM.B * State.CTM.C));
    ViewScale := Sqrt((State.BitmapW / Math.Max(State.ViewW, 1e-12)) *
                      (State.BitmapH / Math.Max(State.ViewH, 1e-12)));
    PixelWidth := StrokeWidth * CTMScale * ViewScale;
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := StrokeColor;
    ACanvas.Pen.Width := Max(1, Round(PixelWidth));
  end;
end;

procedure MapPoint(SX, SY: Double; const S: TRenderState; out PX, PY: Integer);
var
  TX, TY: Double;
begin
  TX := S.CTM.A * SX + S.CTM.C * SY + S.CTM.E;
  TY := S.CTM.B * SX + S.CTM.D * SY + S.CTM.F;

  if Abs(S.ViewW) < 1e-12 then
    PX := Round(TX)
  else
    PX := Round((TX - S.ViewX) * S.BitmapW / S.ViewW);

  if Abs(S.ViewH) < 1e-12 then
    PY := Round(TY)
  else
    PY := Round((TY - S.ViewY) * S.BitmapH / S.ViewH);
end;

procedure ParseViewBox(const S: string; out VX, VY, VW, VH: Double);
var
  Parts: TStringList;
begin
  VX := 0; VY := 0; VW := 0; VH := 0;
  Parts := SplitNumbers(S);
  try
    if Parts.Count >= 4 then
    begin
      VX := StrToFloatSafe(Parts[0], 0);
      VY := StrToFloatSafe(Parts[1], 0);
      VW := StrToFloatSafe(Parts[2], 0);
      VH := StrToFloatSafe(Parts[3], 0);
    end;
  finally
    Parts.Free;
  end;
end;

// Extract content inside first matching parentheses starting at Pos P in S (1-based).
// Returns the inner string and advances P past the closing ')'.
function ExtractParens(const S: string; var P: Integer): string;
var
  Start, Depth: Integer;
begin
  Result := '';
  while (P <= Length(S)) and (S[P] <> '(') do Inc(P);
  if P > Length(S) then Exit;
  Inc(P); // skip '('
  Start := P;
  Depth := 1;
  while (P <= Length(S)) and (Depth > 0) do
  begin
    if S[P] = '(' then Inc(Depth)
    else if S[P] = ')' then Dec(Depth);
    Inc(P);
  end;
  Result := Copy(S, Start, P - Start - 1);
end;

function ParseTransform(const TransformText: string): TMatrix2D;
var
  T: string;
  P, FuncEnd: Integer;
  FuncName, Inside: string;
  Parts: TStringList;
  M: TMatrix2D;
  Angle, CX, CY, Rad, Cos_A, Sin_A: Double;
begin
  Result := IdentityMatrix;
  T := LowerCase(Trim(TransformText));
  P := 1;

  while P <= Length(T) do
  begin
    // Skip whitespace
    while (P <= Length(T)) and (T[P] <= ' ') do Inc(P);
    if P > Length(T) then Break;

    // Read function name (until '(' or end)
    FuncEnd := P;
    while (FuncEnd <= Length(T)) and (T[FuncEnd] <> '(') do Inc(FuncEnd);
    FuncName := Trim(Copy(T, P, FuncEnd - P));
    P := FuncEnd;

    // Extract parenthesised arguments
    Inside := ExtractParens(T, P);
    Parts := SplitNumbers(Inside);
    try
      M := IdentityMatrix;

      if FuncName = 'matrix' then
      begin
        if Parts.Count >= 6 then
        begin
          M.A := StrToFloatSafe(Parts[0], 1);
          M.B := StrToFloatSafe(Parts[1], 0);
          M.C := StrToFloatSafe(Parts[2], 0);
          M.D := StrToFloatSafe(Parts[3], 1);
          M.E := StrToFloatSafe(Parts[4], 0);
          M.F := StrToFloatSafe(Parts[5], 0);
        end;
      end
      else if FuncName = 'translate' then
      begin
        M.E := StrToFloatSafe(Parts[0], 0);
        if Parts.Count >= 2 then
          M.F := StrToFloatSafe(Parts[1], 0)
        else
          M.F := 0;
      end
      else if FuncName = 'scale' then
      begin
        M.A := StrToFloatSafe(Parts[0], 1);
        if Parts.Count >= 2 then
          M.D := StrToFloatSafe(Parts[1], 1)
        else
          M.D := M.A;
      end
      else if FuncName = 'rotate' then
      begin
        Angle := StrToFloatSafe(Parts[0], 0);
        Rad   := DegToRad(Angle);
        Cos_A := Cos(Rad);
        Sin_A := Sin(Rad);
        if Parts.Count >= 3 then
        begin
          CX := StrToFloatSafe(Parts[1], 0);
          CY := StrToFloatSafe(Parts[2], 0);
          // rotate around (CX,CY): translate(-CX,-CY), rotate, translate(CX,CY)
          M.A :=  Cos_A; M.B := Sin_A;
          M.C := -Sin_A; M.D := Cos_A;
          M.E := CX - Cos_A * CX + Sin_A * CY;
          M.F := CY - Sin_A * CX - Cos_A * CY;
        end
        else
        begin
          M.A :=  Cos_A; M.B := Sin_A;
          M.C := -Sin_A; M.D := Cos_A;
        end;
      end
      else if FuncName = 'skewx' then
      begin
        M.C := Tan(DegToRad(StrToFloatSafe(Parts[0], 0)));
      end
      else if FuncName = 'skewy' then
      begin
        M.B := Tan(DegToRad(StrToFloatSafe(Parts[0], 0)));
      end;

      // Compose: result = result * M  (M applied after current result)
      Result := MatMul(Result, M);
    finally
      Parts.Free;
    end;

    // Skip optional comma between transforms
    while (P <= Length(T)) and ((T[P] <= ' ') or (T[P] = ',')) do Inc(P);
  end;
end;

function TokenizePathData(const S: string): TStringList;
var
  I, L: Integer;
  C: Char;
  Tok: string;
  HasDot: Boolean;

  function IsCmd(Ch: Char): Boolean;
  begin
    Result := Ch in ['M','m','L','l','H','h','V','v',
                     'C','c','S','s',
                     'Q','q','T','t',
                     'A','a','Z','z'];
  end;

begin
  Result := TStringList.Create;
  I := 1;
  L := Length(S);

  while I <= L do
  begin
    C := S[I];

    if (C <= ' ') or (C = ',') then
    begin
      Inc(I);
      Continue;
    end;

    if IsCmd(C) then
    begin
      Result.Add(C);
      Inc(I);
      Continue;
    end;

    if C in ['+','-','0'..'9','.'] then
    begin
      Tok := '';

      if C in ['+','-'] then
      begin
        Tok := Tok + C;
        Inc(I);
      end;

      // a second '.' starts the next number (SVG: ".92.92" = ".92" ".92")
      HasDot := False;
      while (I <= L) and (S[I] in ['0'..'9','.']) do
      begin
        if S[I] = '.' then
        begin
          if HasDot then Break;
          HasDot := True;
        end;
        Tok := Tok + S[I];
        Inc(I);
      end;

      if (I <= L) and (S[I] in ['e','E']) then
      begin
        Tok := Tok + S[I];
        Inc(I);

        if (I <= L) and (S[I] in ['+','-']) then
        begin
          Tok := Tok + S[I];
          Inc(I);
        end;

        while (I <= L) and (S[I] in ['0'..'9']) do
        begin
          Tok := Tok + S[I];
          Inc(I);
        end;
      end;

      if Tok <> '' then
        Result.Add(Tok);

      Continue;
    end;

    Inc(I);
  end;
end;

function IsPathCommand(const S: string): Boolean;
begin
  Result :=
    (Length(S) = 1) and
    (S[1] in ['M','m','L','l','H','h','V','v',
              'C','c','S','s',
              'Q','q','T','t',
              'A','a','Z','z']);
end;

procedure CubicBezierPoint(
  T, X0, Y0, X1, Y1, X2, Y2, X3, Y3: Double;
  out X, Y: Double);
var
  MT, MT2, T2: Double;
begin
  MT := 1.0 - T;
  MT2 := MT * MT;
  T2 := T * T;

  X :=
    MT2 * MT * X0 +
    3.0 * MT2 * T * X1 +
    3.0 * MT * T2 * X2 +
    T2 * T * X3;

  Y :=
    MT2 * MT * Y0 +
    3.0 * MT2 * T * Y1 +
    3.0 * MT * T2 * Y2 +
    T2 * T * Y3;
end;

procedure QuadraticBezierPoint(
  T, X0, Y0, X1, Y1, X2, Y2: Double;
  out X, Y: Double);
var
  MT: Double;
begin
  MT := 1.0 - T;

  X :=
    MT * MT * X0 +
    2.0 * MT * T * X1 +
    T * T * X2;

  Y :=
    MT * MT * Y0 +
    2.0 * MT * T * Y1 +
    T * T * Y2;
end;

function VectorAngle(const UX, UY, VX, VY: Double): Double;
var
  DotV, LenP, A: Double;
begin
  LenP := Hypot(UX, UY) * Hypot(VX, VY);
  if LenP < 1e-20 then
    Exit(0);

  DotV := UX * VX + UY * VY;
  A := DotV / LenP;
  if A < -1 then A := -1;
  if A > 1 then A := 1;

  Result := ArcCos(A);
  if (UX * VY - UY * VX) < 0 then
    Result := -Result;
end;

procedure DrawPolylineOrPolygon(ANode: TDOMNode; ACanvas: TCanvas;
  const State: TRenderState; Closed: Boolean);
var
  Parts: TStringList;
  Pts: array of TPoint;
  I, Cnt, PX, PY: Integer;
  X, Y: Double;
begin
  Parts := SplitNumbers(GetAttr(ANode, 'points', ''));
  try
    Cnt := Parts.Count div 2;
    if Cnt <= 0 then Exit;

    SetLength(Pts, Cnt);
    for I := 0 to Cnt - 1 do
    begin
      X := StrToFloatSafe(Parts[I * 2], 0);
      Y := StrToFloatSafe(Parts[I * 2 + 1], 0);
      MapPoint(X, Y, State, PX, PY);
      Pts[I] := MakePt(PX, PY);
    end;

    ApplyStyle(ANode, ACanvas, State);

    if Closed then
      ACanvas.Polygon(Pts)
    else
      ACanvas.Polyline(Pts);
  finally
    Parts.Free;
  end;
end;

procedure DrawPath(ANode: TDOMNode; ACanvas: TCanvas; const State: TRenderState);
const
  MAX_BEZIER_STEPS = 10;
  MAX_ARC_SEGMENTS_PER_PI = 10;
  CURVE_PIXELS_PER_SEGMENT = 8.0;
type
  TSubPath = record
    Pts: array of TPoint;
    Closed: Boolean;
  end;
var
  D, Cmd: string;
  Tokens: TStringList;
  I: Integer;
  CurX, CurY: Double;
  StartX, StartY: Double;
  X, Y: Double;
  HasFill, HasStroke: Boolean;
  SavedFillColor: TColor;
  SavedPenStyle: TPenStyle;
  SavedPenColor: TColor;
  SavedPenWidth: Integer;

  LastC2X, LastC2Y: Double;
  LastQ1X, LastQ1Y: Double;
  PrevCmd: Char;

  // Current sub-path being built
  // PtsCount/PtsCapacity avoid SetLength for every single point.
  Pts: array of TPoint;
  PtsCount, PtsCapacity: Integer;

  // All completed sub-paths for this path element
  SubPaths: array of TSubPath;
  SubPathCount, SubPathCapacity: Integer;

  // Scratch variables for the fill/stroke render passes
  AllPts: array of TPoint;
  Counts: array of LongInt;
  TotalPts, FJ, FK, SJ: Integer;

  procedure EnsurePtsCapacity(Needed: Integer);
  begin
    if Needed <= PtsCapacity then Exit;
    if PtsCapacity < 64 then
      PtsCapacity := 64;
    while PtsCapacity < Needed do
      PtsCapacity := PtsCapacity * 2;
    SetLength(Pts, PtsCapacity);
  end;

  procedure EnsureSubPathCapacity(Needed: Integer);
  begin
    if Needed <= SubPathCapacity then Exit;
    if SubPathCapacity < 8 then
      SubPathCapacity := 8;
    while SubPathCapacity < Needed do
      SubPathCapacity := SubPathCapacity * 2;
    SetLength(SubPaths, SubPathCapacity);
  end;

  procedure AddPoint(AX, AY: Double);
  var
    PX, PY: Integer;
  begin
    MapPoint(AX, AY, State, PX, PY);

    // After the transform many curve samples land on the same pixel.
    // Skipping them greatly speeds up large SVGs from potrace/Inkscape.
    if (PtsCount > 0) and (Pts[PtsCount - 1].X = PX) and (Pts[PtsCount - 1].Y = PY) then
      Exit;

    EnsurePtsCapacity(PtsCount + 1);
    Pts[PtsCount] := MakePt(PX, PY);
    Inc(PtsCount);
  end;

  function ScreenDist(AX, AY, BX, BY: Double): Double;
  var
    PX1, PY1, PX2, PY2: Integer;
  begin
    MapPoint(AX, AY, State, PX1, PY1);
    MapPoint(BX, BY, State, PX2, PY2);
    Result := Hypot(PX2 - PX1, PY2 - PY1);
  end;

  function CurveStepCount(ApproxPixelLen: Double): Integer;
  begin
    Result := Ceil(ApproxPixelLen / CURVE_PIXELS_PER_SEGMENT);
    if Result < 2 then Result := 2;
    if Result > MAX_BEZIER_STEPS then Result := MAX_BEZIER_STEPS;
  end;

  // Commit the current sub-path to the SubPaths list.
  procedure CommitSubPath(Closed: Boolean);
  begin
    if PtsCount >= 2 then
    begin
      EnsureSubPathCapacity(SubPathCount + 1);
      SetLength(SubPaths[SubPathCount].Pts, PtsCount);
      Move(Pts[0], SubPaths[SubPathCount].Pts[0], PtsCount * SizeOf(TPoint));
      SubPaths[SubPathCount].Closed := Closed;
      Inc(SubPathCount);
    end;
    PtsCount := 0;
  end;

  procedure BeginSubPath(AX, AY: Double);
  begin
    CommitSubPath(False);
    AddPoint(AX, AY);
    StartX := AX;
    StartY := AY;
    CurX := AX;
    CurY := AY;
  end;

  procedure AddCubicBezier(X1, Y1, X2, Y2, X3, Y3: Double);
  var
    Step, Steps: Integer;
    T, BX, BY, Len: Double;
  begin
    // Adaptive: the number of segments depends on the length in pixels,
    // instead of a fixed 24 samples for every curve, even a microscopic one.
    Len := ScreenDist(CurX, CurY, X1, Y1) + ScreenDist(X1, Y1, X2, Y2) + ScreenDist(X2, Y2, X3, Y3);
    Steps := CurveStepCount(Len);

    for Step := 1 to Steps do
    begin
      T := Step / Steps;
      CubicBezierPoint(T, CurX, CurY, X1, Y1, X2, Y2, X3, Y3, BX, BY);
      AddPoint(BX, BY);
    end;

    CurX := X3;
    CurY := Y3;
    LastC2X := X2;
    LastC2Y := Y2;
  end;

  procedure AddQuadraticBezier(X1, Y1, X2, Y2: Double);
  var
    Step, Steps: Integer;
    T, BX, BY, Len: Double;
  begin
    Len := ScreenDist(CurX, CurY, X1, Y1) + ScreenDist(X1, Y1, X2, Y2);
    Steps := CurveStepCount(Len);

    for Step := 1 to Steps do
    begin
      T := Step / Steps;
      QuadraticBezierPoint(T, CurX, CurY, X1, Y1, X2, Y2, BX, BY);
      AddPoint(BX, BY);
    end;

    CurX := X2;
    CurY := Y2;
    LastQ1X := X1;
    LastQ1Y := Y1;
  end;

  procedure AddArc(RX, RY, XAxisRotation: Double; LargeArcFlag, SweepFlag: Integer; X2, Y2: Double);
  var
    X1, Y1: Double;
    Phi, CosPhi, SinPhi: Double;
    DX2, DY2: Double;
    X1p, Y1p: Double;
    RXa, RYa: Double;
    Lambda: Double;
    Num, Den, Factor: Double;
    CXp, CYp: Double;
    CX, CY: Double;
    Theta1, DeltaTheta: Double;
    Ux, Uy, Vx, Vy: Double;
    Segments, Step: Integer;
    TAng, PX, PY: Double;
  begin
    X1 := CurX;
    Y1 := CurY;

    if (Abs(X1 - X2) < 1e-12) and (Abs(Y1 - Y2) < 1e-12) then
      Exit;

    RXa := Abs(RX);
    RYa := Abs(RY);

    if (RXa < 1e-12) or (RYa < 1e-12) then
    begin
      CurX := X2;
      CurY := Y2;
      AddPoint(CurX, CurY);
      Exit;
    end;

    Phi := DegToRad(XAxisRotation);
    CosPhi := Cos(Phi);
    SinPhi := Sin(Phi);

    DX2 := (X1 - X2) / 2.0;
    DY2 := (Y1 - Y2) / 2.0;

    X1p := CosPhi * DX2 + SinPhi * DY2;
    Y1p := -SinPhi * DX2 + CosPhi * DY2;

    Lambda := Sqr(X1p) / Sqr(RXa) + Sqr(Y1p) / Sqr(RYa);
    if Lambda > 1.0 then
    begin
      Lambda := Sqrt(Lambda);
      RXa := RXa * Lambda;
      RYa := RYa * Lambda;
    end;

    Num := Sqr(RXa) * Sqr(RYa) - Sqr(RXa) * Sqr(Y1p) - Sqr(RYa) * Sqr(X1p);
    Den := Sqr(RXa) * Sqr(Y1p) + Sqr(RYa) * Sqr(X1p);

    if Abs(Den) < 1e-20 then
      Factor := 0
    else
    begin
      Factor := Num / Den;
      if Factor < 0 then
        Factor := 0;
      Factor := Sqrt(Factor);
    end;

    if LargeArcFlag = SweepFlag then
      Factor := -Factor;

    CXp := Factor * (RXa * Y1p / RYa);
    CYp := Factor * (-RYa * X1p / RXa);

    CX := CosPhi * CXp - SinPhi * CYp + (X1 + X2) / 2.0;
    CY := SinPhi * CXp + CosPhi * CYp + (Y1 + Y2) / 2.0;

    Ux := (X1p - CXp) / RXa;
    Uy := (Y1p - CYp) / RYa;
    Vx := (-X1p - CXp) / RXa;
    Vy := (-Y1p - CYp) / RYa;

    Theta1 := VectorAngle(1, 0, Ux, Uy);
    DeltaTheta := VectorAngle(Ux, Uy, Vx, Vy);

    if (SweepFlag = 0) and (DeltaTheta > 0) then
      DeltaTheta := DeltaTheta - 2 * Pi
    else if (SweepFlag <> 0) and (DeltaTheta < 0) then
      DeltaTheta := DeltaTheta + 2 * Pi;

    Segments := Ceil(Abs(DeltaTheta) / Pi * MAX_ARC_SEGMENTS_PER_PI);
    if Segments < 1 then
      Segments := 1;

    for Step := 1 to Segments do
    begin
      TAng := Theta1 + DeltaTheta * (Step / Segments);

      PX := CX + CosPhi * RXa * Cos(TAng) - SinPhi * RYa * Sin(TAng);
      PY := CY + SinPhi * RXa * Cos(TAng) + CosPhi * RYa * Sin(TAng);

      AddPoint(PX, PY);
    end;

    CurX := X2;
    CurY := Y2;
  end;

  function NextIsNumber: Boolean;
  begin
    Result := (I < Tokens.Count) and (not IsPathCommand(Tokens[I]));
  end;

var
  X1, Y1, X2, Y2, X3, Y3: Double;
  RX1, RY1: Double;
  ARX, ARY, AXRot: Double;
  ALarge, ASweep: Integer;
  SavedI: Integer;
begin
  ApplyStyle(ANode, ACanvas, State);
  HasFill   := ACanvas.Brush.Style <> bsClear;
  HasStroke := ACanvas.Pen.Style   <> psClear;
  SavedFillColor := ACanvas.Brush.Color;
  SavedPenStyle  := ACanvas.Pen.Style;
  SavedPenColor  := ACanvas.Pen.Color;
  SavedPenWidth  := ACanvas.Pen.Width;

  D := GetAttr(ANode, 'd', '');
  if D = '' then Exit;

  SubPathCount := 0;
  SubPathCapacity := 0;

  Tokens := TokenizePathData(D);
  try
    I := 0;
    Cmd := '';
    CurX := 0;
    CurY := 0;
    StartX := 0;
    StartY := 0;

    LastC2X := 0;
    LastC2Y := 0;
    LastQ1X := 0;
    LastQ1Y := 0;

    PrevCmd := #0;
    PtsCount := 0;
    PtsCapacity := 0;
    SetLength(Pts, 0);

    while I < Tokens.Count do
    begin
      if IsPathCommand(Tokens[I]) then
      begin
        Cmd := Tokens[I];
        Inc(I);

        if (Cmd = 'Z') or (Cmd = 'z') then
        begin
          AddPoint(StartX, StartY);
          CommitSubPath(True);
          CurX := StartX;
          CurY := StartY;
          PrevCmd := Cmd[1];
        end;

        Continue;
      end;

      if Cmd = '' then
      begin
        Inc(I);
        Continue;
      end;

      SavedI := I;
      case Cmd[1] of
        'M':
          begin
            if I + 1 >= Tokens.Count then Break;
            X := StrToFloatSafe(Tokens[I], 0);
            Y := StrToFloatSafe(Tokens[I + 1], 0);
            BeginSubPath(X, Y);
            Inc(I, 2);
            Cmd := 'L';
            PrevCmd := 'M';
          end;

        'm':
          begin
            if I + 1 >= Tokens.Count then Break;
            X := CurX + StrToFloatSafe(Tokens[I], 0);
            Y := CurY + StrToFloatSafe(Tokens[I + 1], 0);
            BeginSubPath(X, Y);
            Inc(I, 2);
            Cmd := 'l';
            PrevCmd := 'm';
          end;

        'L':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              X := StrToFloatSafe(Tokens[I], 0);
              Y := StrToFloatSafe(Tokens[I + 1], 0);
              CurX := X;
              CurY := Y;
              AddPoint(CurX, CurY);
              Inc(I, 2);
              PrevCmd := 'L';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'l':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              CurX := CurX + StrToFloatSafe(Tokens[I], 0);
              CurY := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              AddPoint(CurX, CurY);
              Inc(I, 2);
              PrevCmd := 'l';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'H':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurX := StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'H';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'h':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurX := CurX + StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'h';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'V':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurY := StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'V';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'v':
          begin
            while (I < Tokens.Count) and NextIsNumber do
            begin
              CurY := CurY + StrToFloatSafe(Tokens[I], 0);
              AddPoint(CurX, CurY);
              Inc(I);
              PrevCmd := 'v';
              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'C':
          begin
            while (I + 5 < Tokens.Count) and NextIsNumber do
            begin
              X1 := StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := StrToFloatSafe(Tokens[I + 1], 0);
              X2 := StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := StrToFloatSafe(Tokens[I + 3], 0);
              X3 := StrToFloatSafe(Tokens[I + 4], 0);
              Y3 := StrToFloatSafe(Tokens[I + 5], 0);

              AddCubicBezier(X1, Y1, X2, Y2, X3, Y3);
              Inc(I, 6);
              PrevCmd := 'C';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'c':
          begin
            while (I + 5 < Tokens.Count) and NextIsNumber do
            begin
              X1 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 3], 0);
              X3 := CurX + StrToFloatSafe(Tokens[I + 4], 0);
              Y3 := CurY + StrToFloatSafe(Tokens[I + 5], 0);

              AddCubicBezier(X1, Y1, X2, Y2, X3, Y3);
              Inc(I, 6);
              PrevCmd := 'c';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'S':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['C', 'c', 'S', 's'] then
              begin
                RX1 := 2 * CurX - LastC2X;
                RY1 := 2 * CurY - LastC2Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := StrToFloatSafe(Tokens[I + 1], 0);
              X3 := StrToFloatSafe(Tokens[I + 2], 0);
              Y3 := StrToFloatSafe(Tokens[I + 3], 0);

              AddCubicBezier(RX1, RY1, X2, Y2, X3, Y3);
              Inc(I, 4);
              PrevCmd := 'S';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        's':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['C', 'c', 'S', 's'] then
              begin
                RX1 := 2 * CurX - LastC2X;
                RY1 := 2 * CurY - LastC2Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X3 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y3 := CurY + StrToFloatSafe(Tokens[I + 3], 0);

              AddCubicBezier(RX1, RY1, X2, Y2, X3, Y3);
              Inc(I, 4);
              PrevCmd := 's';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'Q':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              X1 := StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := StrToFloatSafe(Tokens[I + 1], 0);
              X2 := StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := StrToFloatSafe(Tokens[I + 3], 0);

              AddQuadraticBezier(X1, Y1, X2, Y2);
              Inc(I, 4);
              PrevCmd := 'Q';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'q':
          begin
            while (I + 3 < Tokens.Count) and NextIsNumber do
            begin
              X1 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y1 := CurY + StrToFloatSafe(Tokens[I + 1], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 2], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 3], 0);

              AddQuadraticBezier(X1, Y1, X2, Y2);
              Inc(I, 4);
              PrevCmd := 'q';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'T':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['Q', 'q', 'T', 't'] then
              begin
                RX1 := 2 * CurX - LastQ1X;
                RY1 := 2 * CurY - LastQ1Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := StrToFloatSafe(Tokens[I + 1], 0);

              AddQuadraticBezier(RX1, RY1, X2, Y2);
              Inc(I, 2);
              PrevCmd := 'T';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        't':
          begin
            while (I + 1 < Tokens.Count) and NextIsNumber do
            begin
              if PrevCmd in ['Q', 'q', 'T', 't'] then
              begin
                RX1 := 2 * CurX - LastQ1X;
                RY1 := 2 * CurY - LastQ1Y;
              end
              else
              begin
                RX1 := CurX;
                RY1 := CurY;
              end;

              X2 := CurX + StrToFloatSafe(Tokens[I + 0], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 1], 0);

              AddQuadraticBezier(RX1, RY1, X2, Y2);
              Inc(I, 2);
              PrevCmd := 't';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'A':
          begin
            while (I + 6 < Tokens.Count) and NextIsNumber do
            begin
              ARX := StrToFloatSafe(Tokens[I + 0], 0);
              ARY := StrToFloatSafe(Tokens[I + 1], 0);
              AXRot := StrToFloatSafe(Tokens[I + 2], 0);
              ALarge := ParseIntSafe(Tokens[I + 3], 0);
              ASweep := ParseIntSafe(Tokens[I + 4], 0);
              X2 := StrToFloatSafe(Tokens[I + 5], 0);
              Y2 := StrToFloatSafe(Tokens[I + 6], 0);

              AddArc(ARX, ARY, AXRot, ALarge, ASweep, X2, Y2);
              Inc(I, 7);
              PrevCmd := 'A';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

        'a':
          begin
            while (I + 6 < Tokens.Count) and NextIsNumber do
            begin
              ARX := StrToFloatSafe(Tokens[I + 0], 0);
              ARY := StrToFloatSafe(Tokens[I + 1], 0);
              AXRot := StrToFloatSafe(Tokens[I + 2], 0);
              ALarge := ParseIntSafe(Tokens[I + 3], 0);
              ASweep := ParseIntSafe(Tokens[I + 4], 0);
              X2 := CurX + StrToFloatSafe(Tokens[I + 5], 0);
              Y2 := CurY + StrToFloatSafe(Tokens[I + 6], 0);

              AddArc(ARX, ARY, AXRot, ALarge, ASweep, X2, Y2);
              Inc(I, 7);
              PrevCmd := 'a';

              if (I < Tokens.Count) and IsPathCommand(Tokens[I]) then Break;
            end;
          end;

      else
        Inc(I);
      end;

      // Guard against an infinite loop: if handling a command consumed
      // no token (e.g. an incomplete set of operands at the end or badly joined
      // numbers), skip the stray token so that I always increases.
      if I = SavedI then
        Inc(I);
    end;

    CommitSubPath(False); // commit any trailing open sub-path
  finally
    Tokens.Free;
  end;

  if SubPathCount = 0 then Exit;

  // --- Fill pass: all sub-paths together with even-odd rule ---
  // Even-odd (ALTERNATE) creates holes where sub-paths overlap,
  // which is required for potrace/compound SVG paths.
  if HasFill then
  begin
    TotalPts := 0;
    SetLength(Counts, SubPathCount);
    for FJ := 0 to SubPathCount - 1 do
    begin
      Counts[FJ] := Length(SubPaths[FJ].Pts);
      Inc(TotalPts, Counts[FJ]);
    end;
    SetLength(AllPts, TotalPts);
    FK := 0;
    for FJ := 0 to SubPathCount - 1 do
    begin
      Move(SubPaths[FJ].Pts[0], AllPts[FK], Counts[FJ] * SizeOf(TPoint));
      Inc(FK, Counts[FJ]);
    end;

    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := SavedFillColor;
    ACanvas.Pen.Style   := psClear;

    SetPolyFillMode(ACanvas.Handle, ALTERNATE);
    Windows.PolyPolygon(ACanvas.Handle, AllPts[0], Counts[0], SubPathCount);
  end;

  // --- Stroke pass: each sub-path drawn as outline individually ---
  if HasStroke then
  begin
    ACanvas.Brush.Style := bsClear;
    ACanvas.Pen.Style   := SavedPenStyle;
    ACanvas.Pen.Color   := SavedPenColor;
    ACanvas.Pen.Width   := SavedPenWidth;
    for SJ := 0 to SubPathCount - 1 do
    begin
      if SubPaths[SJ].Closed then
        ACanvas.Polygon(SubPaths[SJ].Pts)
      else
        ACanvas.Polyline(SubPaths[SJ].Pts);
    end;
  end;
end;

procedure RenderNode(ANode: TDOMNode; ACanvas: TCanvas; const ParentState: TRenderState);
var
  N: string;
  X, Y, W, H: Double;
  CX, CY, R, RX, RY: Double;
  X1, Y1, X2, Y2: Double;
  Child: TDOMNode;
  State: TRenderState;
  LocalM: TMatrix2D;
  PX1, PY1, PX2, PY2: Integer;
begin
  if ANode = nil then Exit;

  State := ParentState;

  // Compose parent CTM with this node's local transform
  LocalM := ParseTransform(GetAttr(ANode, 'transform', ''));
  State.CTM := MatMul(ParentState.CTM, LocalM);

  N := LowerCase(ANode.NodeName);

  if N = 'rect' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    X := StrToFloatSafe(GetAttr(ANode, 'x', '0'), 0);
    Y := StrToFloatSafe(GetAttr(ANode, 'y', '0'), 0);
    W := StrToFloatSafe(GetAttr(ANode, 'width', '0'), 0);
    H := StrToFloatSafe(GetAttr(ANode, 'height', '0'), 0);

    MapPoint(X,     Y,     State, PX1, PY1);
    MapPoint(X + W, Y + H, State, PX2, PY2);
    ACanvas.Rectangle(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'circle' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    CX := StrToFloatSafe(GetAttr(ANode, 'cx', '0'), 0);
    CY := StrToFloatSafe(GetAttr(ANode, 'cy', '0'), 0);
    R  := StrToFloatSafe(GetAttr(ANode, 'r', '0'), 0);

    MapPoint(CX - R, CY - R, State, PX1, PY1);
    MapPoint(CX + R, CY + R, State, PX2, PY2);
    ACanvas.Ellipse(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'ellipse' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    CX := StrToFloatSafe(GetAttr(ANode, 'cx', '0'), 0);
    CY := StrToFloatSafe(GetAttr(ANode, 'cy', '0'), 0);
    RX := StrToFloatSafe(GetAttr(ANode, 'rx', '0'), 0);
    RY := StrToFloatSafe(GetAttr(ANode, 'ry', '0'), 0);

    MapPoint(CX - RX, CY - RY, State, PX1, PY1);
    MapPoint(CX + RX, CY + RY, State, PX2, PY2);
    ACanvas.Ellipse(
      Min(PX1, PX2), Min(PY1, PY2),
      Max(PX1, PX2), Max(PY1, PY2)
    );
  end
  else if N = 'line' then
  begin
    ApplyStyle(ANode, ACanvas, State);
    X1 := StrToFloatSafe(GetAttr(ANode, 'x1', '0'), 0);
    Y1 := StrToFloatSafe(GetAttr(ANode, 'y1', '0'), 0);
    X2 := StrToFloatSafe(GetAttr(ANode, 'x2', '0'), 0);
    Y2 := StrToFloatSafe(GetAttr(ANode, 'y2', '0'), 0);

    MapPoint(X1, Y1, State, PX1, PY1);
    MapPoint(X2, Y2, State, PX2, PY2);
    ACanvas.Line(PX1, PY1, PX2, PY2);
  end
  else if N = 'polyline' then
  begin
    DrawPolylineOrPolygon(ANode, ACanvas, State, False);
  end
  else if N = 'polygon' then
  begin
    DrawPolylineOrPolygon(ANode, ACanvas, State, True);
  end
  else if N = 'path' then
  begin
    DrawPath(ANode, ACanvas, State);
  end
  else if (N = 'svg') or (N = 'g') then
  begin
    Child := ANode.FirstChild;
    while Child <> nil do
    begin
      if Child is TDOMElement then
        RenderNode(Child, ACanvas, State);
      Child := Child.NextSibling;
    end;
  end;
end;

function RenderSimpleSVGToBitmap(const ASVGText: string; ABitmap: TBitmap;
  ABgColor: TColor = clWhite): Boolean;
var
  SS: TStringStream;
  Doc: TXMLDocument;
  Root: TDOMNode;
  State: TRenderState;
  W, H: Integer;
begin
  Result := False;
  if ABitmap = nil then Exit;

  SS := TStringStream.Create(ASVGText);
  Doc := nil;
  try
    ReadXMLFile(Doc, SS);
    if Doc = nil then Exit;

    Root := Doc.DocumentElement;
    if (Root = nil) or (LowerCase(Root.NodeName) <> 'svg') then
      Exit;

    W := ParseIntSafe(GetAttr(Root, 'width', '0'), 0);
    H := ParseIntSafe(GetAttr(Root, 'height', '0'), 0);

    if GetAttr(Root, 'viewBox', '') <> '' then
      ParseViewBox(GetAttr(Root, 'viewBox', ''), State.ViewX, State.ViewY, State.ViewW, State.ViewH)
    else
    begin
      State.ViewX := 0;
      State.ViewY := 0;
      State.ViewW := W;
      State.ViewH := H;
    end;

    if ABitmap.Width <= 0 then
      ABitmap.Width := Max(W, 1);
    if ABitmap.Height <= 0 then
      ABitmap.Height := Max(H, 1);

    if State.ViewW <= 0 then State.ViewW := ABitmap.Width;
    if State.ViewH <= 0 then State.ViewH := ABitmap.Height;

    State.BitmapW := ABitmap.Width;
    State.BitmapH := ABitmap.Height;
    State.CTM := IdentityMatrix;

    ABitmap.Canvas.Brush.Style := bsSolid;
    ABitmap.Canvas.Brush.Color := ABgColor;
    ABitmap.Canvas.FillRect(Rect(0, 0, ABitmap.Width, ABitmap.Height));

    if CSSClassStyles <> nil then
      CSSClassStyles.Clear;
    CollectCSSStyles(Root);

    RenderNode(Root, ABitmap.Canvas, State);
    Result := True;
  finally
    Doc.Free;
    SS.Free;
  end;
end;


finalization
  CSSClassStyles.Free;

end.
