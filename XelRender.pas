unit XelRender;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Renderer: paints the box tree onto a TCanvas.
// Order: background (colour, tiled image) -> borders -> list markers
// -> lines (text, images, controls, inline boxes) -> children.

interface

uses
  Classes, SysUtils, Math, Graphics, Windows, Types,
  Generics.Collections, IntfGraphics, FPImage,
  XelLayout, XelStyle, XelDom, XelTextUtil, XelUrl, OTF, XelImageScale, XelSvgImage,
  XelForms, LazUTF8;

type
  TGetPictureFunc = function(const Url: string): TPicture of object;
  // returns the SVG text for the given URL ('' if it is not an SVG image)
  TGetSvgFunc = function(const Url: string): string of object;

  // TRenderer

  TRenderer = class
  public
    Canvas: TCanvas;
    OffsetX: Integer;            // horizontal scroll offset
    OffsetY: Integer;            // page scroll offset
    ViewHeight: Integer;         // window height — for skipping invisible content
    ViewWidth: Integer;          // window width — horizontal culling (0 = none)
    Engine: TLayoutEngine;       // for setting fonts
    FocusElement: TDOMElement;   // form control with keyboard focus (focus ring + caret)
    OnGetPicture: TGetPictureFunc;
    OnGetSvg: TGetSvgFunc;

    procedure Paint(Root: TLayoutBox);
  private
    procedure DrawBox(Box: TLayoutBox);
    procedure DrawBoxContent(Box: TLayoutBox; const R: TRect);
    procedure PaintBoxOpacity(Box: TLayoutBox; const R: TRect);
    procedure DrawBackground(Box: TLayoutBox; const R: TRect);
    procedure DrawBorders(Box: TLayoutBox; const R: TRect);
    procedure DrawLine(Box: TLayoutBox; Line: TLineBox);
    procedure DrawFrag(Frag: TLineFrag);
    procedure DrawImagePlaceholder(const R: TRect; const AltText: string);
    // Draws an image scaled via GDI+ (bicubic); falls back to StretchDraw.
    // RadX/RadY > 0 -> anti-aliased rounded corners.
    procedure DrawImageNice(const R: TRect; Pic: TPicture;
      RadX: Integer = 0; RadY: Integer = 0);
    procedure DrawGraphicNice(const R: TRect; G: TGraphic;
      RadX: Integer = 0; RadY: Integer = 0);
    // If the URL is an SVG image, rasterizes it at size R (with transparency,
    // cached by URL+size) and draws it. Returns True if drawn.
    function TryDrawSvg(const Url: string; const R: TRect;
      RadX: Integer = 0; RadY: Integer = 0): Boolean;
    // Draws text with the style's font: GDI+ (anti-aliasing) with a GDI fallback;
    // honours letter-spacing (SetTextCharacterExtra) and text-shadow.
    // (X, TopY) = top-left corner of the text cell.
    procedure DrawStyledText(const Text: string; X, TopY: Integer;
      St: TComputedStyle);
    procedure DrawStar(const R: TRect; St: TComputedStyle);
    procedure DrawBoxShadow(St: TComputedStyle; const R: TRect);
    // paints the box content as a separate stacking context (its own float pass)
    procedure PaintContentWithFloats(Box: TLayoutBox; const R: TRect);
  private
    // Floats are painted AFTER all in-flow blocks of the given context
    // (CSS 2.1 App. E), also above blocks from LATER sections — that is why
    // we defer them to a separate pass. Without it e.g. an infobox (float:right
    // from section 0) would not cover the heading border from section 1.
    FDeferFloats: Boolean;
    FDeferredFloats: Classes.TList;
  end;

// clears the cache of scaled images (call when the document changes)
procedure ClearRenderImageCache;

implementation

// TRenderer

procedure TRenderer.Paint(Root: TLayoutBox);
var
  I: Integer;
  SavedList: Classes.TList;
  SavedDefer: Boolean;
begin
  if Root = nil then
    Exit;
  // stacking context: collect floats during the traversal, draw them after the blocks
  SavedList := FDeferredFloats;
  SavedDefer := FDeferFloats;
  FDeferredFloats := Classes.TList.Create;
  FDeferFloats := True;
  try
    DrawBox(Root);
    FDeferFloats := False; // in the float pass draw them normally
    for I := 0 to FDeferredFloats.Count - 1 do
      DrawBox(TLayoutBox(FDeferredFloats[I]));
  finally
    FDeferredFloats.Free;
    FDeferredFloats := SavedList;
    FDeferFloats := SavedDefer;
  end;
end;

function ShiftRect(const R: TRect; DX, DY: Integer): TRect;
begin
  Result := Rect(R.Left - DX, R.Top - DY, R.Right - DX, R.Bottom - DY);
end;

// Corner ellipse dimensions (width/height) for RoundRect/region.
// Returns True when the box has rounded corners. A percentage radius (e.g. 50%)
// gives an oval (ellipse).
function GetCornerEllipse(St: TComputedStyle; W, H: Integer;
  out EW, EH: Integer): Boolean;
begin
  if St.BorderRadiusPct >= 0 then
  begin
    EW := Round(W * St.BorderRadiusPct / 100 * 2);
    EH := Round(H * St.BorderRadiusPct / 100 * 2);
    if EW > W then EW := W;
    if EH > H then EH := H;
  end
  else if St.BorderRadius > 0 then
  begin
    EW := Min(St.BorderRadius * 2, W);
    EH := Min(St.BorderRadius * 2, H);
  end
  else
  begin
    EW := 0; EH := 0;
  end;
  Result := (EW > 0) and (EH > 0);
end;

// ---- image scaling via GDI+ (bicubic, with alpha) ----

type
  TArgbEntry = class
    W, H: Integer;
    Data: TBytes;   // B,G,R,A per pixel
  end;

var
  GArgbCache: TDictionary<Pointer, TArgbEntry> = nil;
  // rasterized SVG (by URL+size) -> bitmap with alpha
  GSvgCache: TDictionary<string, Graphics.TBitmap> = nil;

// Converts a graphic into an ARGB buffer (B,G,R,A); cached by graphic pointer.
function GetArgb(G: TGraphic): TArgbEntry;
var
  Tmp: Graphics.TBitmap;
  Laz: TLazIntfImage;
  X, Y, I: Integer;
  C: TFPColor;
  HasAlpha: Boolean;
begin
  if GArgbCache = nil then
    GArgbCache := TDictionary<Pointer, TArgbEntry>.Create;
  if GArgbCache.TryGetValue(Pointer(G), Result) then
    if (Result.W = G.Width) and (Result.H = G.Height) then
      Exit
    else
    begin
      GArgbCache.Remove(Pointer(G));
      Result.Free;
    end;

  Result := nil;
  Tmp := Graphics.TBitmap.Create;
  try
    Tmp.Assign(G);
    if (Tmp.Width <= 0) or (Tmp.Height <= 0) then Exit;
    Laz := Tmp.CreateIntfImage;
    try
      HasAlpha := Laz.DataDescription.AlphaPrec > 0;
      Result := TArgbEntry.Create;
      Result.W := Tmp.Width;
      Result.H := Tmp.Height;
      SetLength(Result.Data, Result.W * Result.H * 4);
      for Y := 0 to Result.H - 1 do
        for X := 0 to Result.W - 1 do
        begin
          C := Laz.Colors[X, Y];
          I := (Y * Result.W + X) * 4;
          Result.Data[I]     := C.Blue shr 8;
          Result.Data[I + 1] := C.Green shr 8;
          Result.Data[I + 2] := C.Red shr 8;
          if HasAlpha then
            Result.Data[I + 3] := C.Alpha shr 8
          else
            Result.Data[I + 3] := 255;
        end;
    finally
      Laz.Free;
    end;
  finally
    Tmp.Free;
  end;
  if Result <> nil then
    GArgbCache.AddOrSetValue(Pointer(G), Result);
end;

procedure ClearRenderImageCache;
var
  E: TArgbEntry;
  B: Graphics.TBitmap;
begin
  if GSvgCache <> nil then
  begin
    for B in GSvgCache.Values do
      B.Free;
    GSvgCache.Clear;
  end;
  if GArgbCache = nil then Exit;
  for E in GArgbCache.Values do
    E.Free;
  GArgbCache.Clear;
end;

// Paints a gradient background (linear/radial, multi-stop) into rectangle R.
// Draws on a temporary bitmap (ScanLine), optionally clipped to
// rounded corners.
procedure PaintGradient(ACanvas: TCanvas; const R: TRect; St: TComputedStyle);
var
  W, H, X, Y, Seg, NStops, Rad, RadH: Integer;
  Bmp: Graphics.TBitmap;
  P: PByte;
  T, Ft, Cx, Cy, Ang, Dx, Dy, Len, Proj, MaxR: Double;
  C0, C1: TColor;
  Rgn: HRGN;
begin
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  NStops := Length(St.GradColors);
  if (W <= 0) or (H <= 0) or (NStops < 2) then
    Exit;
  // safeguard: do not allocate a gigantic bitmap (broken/huge geometry)
  // — fill with the last colour
  if (W > 4096) or (H > 8192) then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := St.GradColors[NStops - 1];
    ACanvas.Pen.Style := psClear;
    ACanvas.FillRect(R);
    ACanvas.Pen.Style := psSolid;
    Exit;
  end;

  Bmp := Graphics.TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(W, H);
    Cx := W / 2;
    Cy := H / 2;
    Ang := St.GradAngle * Pi / 180;
    Dx := Sin(Ang);            // CSS: 0deg = upwards
    Dy := -Cos(Ang);
    Len := Abs(W * Dx) + Abs(H * Dy);
    if Len < 1 then Len := 1;
    MaxR := Sqrt(Cx * Cx + Cy * Cy);
    if MaxR < 1 then MaxR := 1;

    for Y := 0 to H - 1 do
    begin
      P := Bmp.ScanLine[Y];
      for X := 0 to W - 1 do
      begin
        if St.GradKind = gkRadial then
          Proj := Sqrt(Sqr(X - Cx) + Sqr(Y - Cy)) / MaxR
        else
          Proj := ((X - Cx) * Dx + (Y - Cy) * Dy) / Len + 0.5;
        if Proj < 0 then Proj := 0
        else if Proj > 1 then Proj := 1;
        Ft := Proj * (NStops - 1);
        Seg := Trunc(Ft);
        if Seg > NStops - 2 then Seg := NStops - 2;
        T := Ft - Seg;
        C0 := St.GradColors[Seg];
        C1 := St.GradColors[Seg + 1];
        // TColor = 0x00BBGGRR; ScanLine pf24 = B,G,R
        P^ := Round((C0 shr 16 and $FF) + ((C1 shr 16 and $FF) - (C0 shr 16 and $FF)) * T); Inc(P);
        P^ := Round((C0 shr 8 and $FF) + ((C1 shr 8 and $FF) - (C0 shr 8 and $FF)) * T); Inc(P);
        P^ := Round((C0 and $FF) + ((C1 and $FF) - (C0 and $FF)) * T); Inc(P);
      end;
    end;

    Rad := St.BorderRadius;
    if GetCornerEllipse(St, W, H, Rad, RadH) then
    begin
      if (Rad >= W) and (RadH >= H) then
        Rgn := CreateEllipticRgn(R.Left, R.Top, R.Right + 1, R.Bottom + 1)
      else
        Rgn := CreateRoundRectRgn(R.Left, R.Top, R.Right + 1, R.Bottom + 1,
          Rad, RadH);
      SelectClipRgn(ACanvas.Handle, Rgn);
      ACanvas.Draw(R.Left, R.Top, Bmp);
      SelectClipRgn(ACanvas.Handle, 0);
      DeleteObject(Rgn);
    end
    else
      ACanvas.Draw(R.Left, R.Top, Bmp);
  finally
    Bmp.Free;
  end;
end;

procedure TRenderer.DrawBackground(Box: TLayoutBox; const R: TRect);
var
  Pic: TPicture;
  X, Y, EW, EH: Integer;
  GW, GH: Integer;
  DR: TRect;
begin
  if Box.Style.GradKind <> gkNone then
    PaintGradient(Canvas, R, Box.Style);
  if Box.Style.HasBgColor then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := Box.Style.BgColor;
    if GetCornerEllipse(Box.Style, R.Right - R.Left, R.Bottom - R.Top, EW, EH) then
    begin
      // pen in the background colour so that RoundRect does not draw a black outline
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Color := Box.Style.BgColor;
      Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, EW, EH);
    end
    else
      Canvas.FillRect(R);
  end;
  if (Box.Style.BgImage <> '') and Assigned(OnGetPicture) then
  begin
    Pic := OnGetPicture(Box.Style.BgImage);
    if (Pic <> nil) and (Pic.Graphic <> nil) and not Pic.Graphic.Empty then
    begin
      GW := Pic.Width;
      GH := Pic.Height;
      if Box.Style.BgSizeW > 0 then
        GW := Box.Style.BgSizeW;
      if Box.Style.BgSizeH > 0 then
        GH := Box.Style.BgSizeH;
      if (GW > 0) and (GH > 0) then
      begin
        // tiling within the box
        if Box.Style.BgRepeat then
          Y := R.Top
        else
          Y := R.Top + Round(((R.Bottom - R.Top) - GH) *
            Box.Style.BgPosYPct / 100);
        while Y < R.Bottom do
        begin
          if Box.Style.BgRepeat then
            X := R.Left
          else
            X := R.Left + Round(((R.Right - R.Left) - GW) *
              Box.Style.BgPosXPct / 100);
          while X < R.Right do
          begin
            DR := Rect(X, Y, X + GW, Y + GH);
            DrawImageNice(DR, Pic);
            Inc(X, GW);
            if not Box.Style.BgRepeat then
              Break;
          end;
          Inc(Y, GH);
          if not Box.Style.BgRepeat then
            Break;
        end;
      end;
    end;
  end;
end;

procedure TRenderer.DrawBorders(Box: TLayoutBox; const R: TRect);
var
  St: TComputedStyle;
  EW, EH: Integer;

  procedure EdgeDashed(const ER: TRect; Horizontal: Boolean; Dot: Boolean);
  var
    Thick, Dash, Gap, Pos, E: Integer;
  begin
    if Horizontal then Thick := ER.Bottom - ER.Top
    else Thick := ER.Right - ER.Left;
    if Dot then begin Dash := Max(1, Thick); Gap := Max(1, Thick); end
    else begin Dash := Max(3, Thick * 2); Gap := Max(2, Thick); end;
    if Horizontal then
    begin
      Pos := ER.Left;
      while Pos < ER.Right do
      begin
        E := Min(Pos + Dash, ER.Right);
        Canvas.FillRect(Rect(Pos, ER.Top, E, ER.Bottom));
        Inc(Pos, Dash + Gap);
      end;
    end
    else
    begin
      Pos := ER.Top;
      while Pos < ER.Bottom do
      begin
        E := Min(Pos + Dash, ER.Bottom);
        Canvas.FillRect(Rect(ER.Left, Pos, ER.Right, E));
        Inc(Pos, Dash + Gap);
      end;
    end;
  end;

  procedure EdgeDouble(const ER: TRect; Horizontal: Boolean);
  var
    Thick, T3: Integer;
  begin
    if Horizontal then Thick := ER.Bottom - ER.Top
    else Thick := ER.Right - ER.Left;
    T3 := Max(1, Thick div 3);
    if Horizontal then
    begin
      Canvas.FillRect(Rect(ER.Left, ER.Top, ER.Right, ER.Top + T3));
      Canvas.FillRect(Rect(ER.Left, ER.Bottom - T3, ER.Right, ER.Bottom));
    end
    else
    begin
      Canvas.FillRect(Rect(ER.Left, ER.Top, ER.Left + T3, ER.Bottom));
      Canvas.FillRect(Rect(ER.Right - T3, ER.Top, ER.Right, ER.Bottom));
    end;
  end;

  procedure DrawEdge(const ER: TRect; Horizontal: Boolean; Color: TColor);
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := Color;
    case St.BorderStyle of
      cbsDashed: EdgeDashed(ER, Horizontal, False);
      cbsDotted: EdgeDashed(ER, Horizontal, True);
      cbsDouble: EdgeDouble(ER, Horizontal);
    else
      Canvas.FillRect(ER);
    end;
  end;

begin
  St := Box.Style;
  if (St.BorderStyle = cbsNone) then
    Exit;
  if GetCornerEllipse(St, R.Right - R.Left, R.Bottom - R.Top, EW, EH) then
  begin
    // rounded — single colour, outline with the pen
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := St.BorderColorT;
    Canvas.Pen.Width := Max(1, Max(Max(St.BordL, St.BordR),
      Max(St.BordT, St.BordB)));
    Canvas.Brush.Style := bsClear;
    if (EW >= R.Right - R.Left) and (EH >= R.Bottom - R.Top) then
      Canvas.Ellipse(R.Left, R.Top, R.Right, R.Bottom)
    else
      Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, EW, EH);
    Canvas.Pen.Width := 1;
    Exit;
  end;
  // each edge with its own colour and style
  if St.BordT > 0 then
    DrawEdge(Rect(R.Left, R.Top, R.Right, R.Top + St.BordT), True, St.BorderColorT);
  if St.BordB > 0 then
    DrawEdge(Rect(R.Left, R.Bottom - St.BordB, R.Right, R.Bottom), True, St.BorderColorB);
  if St.BordL > 0 then
    DrawEdge(Rect(R.Left, R.Top, R.Left + St.BordL, R.Bottom), False, St.BorderColorL);
  if St.BordR > 0 then
    DrawEdge(Rect(R.Right - St.BordR, R.Top, R.Right, R.Bottom), False, St.BorderColorR);
end;

procedure TRenderer.DrawImagePlaceholder(const R: TRect; const AltText: string);
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := TColor($F0F0F0);
  Canvas.FillRect(R);
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := TColor($A0A0A0);
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(R);
  if (AltText <> '') and (R.Right - R.Left > 20) then
  begin
    Canvas.Font.Name := 'Arial';
    Canvas.Font.Height := -11;
    Canvas.Font.Style := [];
    Canvas.Font.Color := TColor($606060);
    Canvas.TextRect(R, R.Left + 3, R.Top + 3, AltText);
  end;
end;

procedure TRenderer.DrawGraphicNice(const R: TRect; G: TGraphic;
  RadX: Integer; RadY: Integer);
var
  E: TArgbEntry;
  DW, DH: Integer;
  OK: Boolean;
begin
  if (G = nil) or G.Empty then
    Exit;
  E := GetArgb(G);
  if (E <> nil) and (Length(E.Data) > 0) then
  begin
    DW := R.Right - R.Left;
    DH := R.Bottom - R.Top;
    if (RadX > 0) or (RadY > 0) then
      OK := DrawImageArgbRounded(Canvas.Handle, @E.Data[0], E.W, E.H,
        R.Left, R.Top, DW, DH, RadX, RadY)
    else
      OK := DrawImageArgbScaled(Canvas.Handle, @E.Data[0], E.W, E.H,
        R.Left, R.Top, DW, DH);
    if OK then
      Exit;
  end;
  Canvas.StretchDraw(R, G);   // fallback when GDI+ is unavailable
end;

procedure TRenderer.DrawImageNice(const R: TRect; Pic: TPicture;
  RadX: Integer; RadY: Integer);
begin
  if (Pic = nil) then Exit;
  DrawGraphicNice(R, Pic.Graphic, RadX, RadY);
end;

function TRenderer.TryDrawSvg(const Url: string; const R: TRect;
  RadX: Integer; RadY: Integer): Boolean;
var
  Svg, Key: string;
  W, H: Integer;
  Bmp: Graphics.TBitmap;
begin
  Result := False;
  if (Url = '') or not Assigned(OnGetSvg) then Exit;
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  if (W < 1) or (H < 1) then Exit;
  Svg := OnGetSvg(Url);
  if Svg = '' then Exit;

  Key := Url + '|' + IntToStr(W) + 'x' + IntToStr(H);
  if GSvgCache = nil then
    GSvgCache := TDictionary<string, Graphics.TBitmap>.Create;
  if not GSvgCache.TryGetValue(Key, Bmp) then
  begin
    Bmp := RasterizeSvg(Svg, W, H);   // rasterized at display size
    GSvgCache.AddOrSetValue(Key, Bmp);  // nil is cached too (no retries)
  end;
  if Bmp = nil then Exit;

  DrawGraphicNice(R, Bmp, RadX, RadY);
  Result := True;
end;

procedure TRenderer.DrawStyledText(const Text: string; X, TopY: Integer;
  St: TComputedStyle);
var
  TM: TTextMetric;
  Ascent: Integer;

  // a single drawing pass in the given colour and position
  procedure DrawPass(PX, PYTop: Integer; AColor: TColor);
  begin
    if St.LetterSpacing <> 0 then
    begin
      // letter-spacing: GDI honours SetTextCharacterExtra (consistent with measurement)
      Canvas.Font.Color := AColor;
      SetTextCharacterExtra(Canvas.Handle, St.LetterSpacing);
      Canvas.TextOut(PX, PYTop, Text);
      SetTextCharacterExtra(Canvas.Handle, 0);
    end
    else if not DrawTextGdiPlus(Canvas.Handle, Engine.MapFontName(St.FontFamily),
         St.FontSizePx, St.Bold, St.Italic, LongWord(AColor),
         PX, PYTop + Ascent, Text, True) then
    begin
      Canvas.Font.Color := AColor;
      Canvas.TextOut(PX, PYTop, Text);
    end;
  end;

begin
  if Text = '' then
    Exit;
  // set the GDI font — needed for metrics, glyph advances (the same ones the
  // layout measured) and a possible fallback
  Engine.SetCanvasFont(Canvas, St);
  Canvas.Brush.Style := bsClear;
  if GetTextMetrics(Canvas.Handle, TM) then
    Ascent := TM.tmAscent
  else
    Ascent := Round(Canvas.TextHeight('Hg') * 0.8);
  // text-shadow: the shadow is drawn first, under the actual text (blur is ignored)
  if St.HasTextShadow then
    DrawPass(X + St.TextShadowX, TopY + St.TextShadowY, St.TextShadowColor);
  DrawPass(X, TopY, St.Color);
end;

procedure TRenderer.DrawStar(const R: TRect; St: TComputedStyle);
var
  Pts: array[0..9] of TPoint;
  I: Integer;
  Cx, Cy, RO, RI, Ang, Rad: Double;
begin
  RO := St.FontSizePx * 0.55;        // outer radius
  RI := RO * 0.42;                   // inner radius
  Cx := R.Left + RO;
  Cy := R.Top + (R.Bottom - R.Top) / 2;
  for I := 0 to 9 do
  begin
    Ang := -Pi / 2 + I * Pi / 5;     // start at the top, every 36°
    if (I and 1) = 0 then Rad := RO else Rad := RI;
    Pts[I].X := Round(Cx + Rad * Cos(Ang));
    Pts[I].Y := Round(Cy + Rad * Sin(Ang));
  end;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := TColor($00C8FF);   // yellow-orange (BGR)
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Color := TColor($00A0E0);
  Canvas.Polygon(Pts);
end;

procedure TRenderer.DrawBoxShadow(St: TComputedStyle; const R: TRect);
var
  SR: TRect;
  EW, EH: Integer;
begin
  // outer shadow only (outset); blur approximated by a sharp edge
  if (not St.HasBoxShadow) or St.BoxShadowInset then
    Exit;
  SR := Rect(R.Left + St.BoxShadowX - St.BoxShadowSpread,
             R.Top + St.BoxShadowY - St.BoxShadowSpread,
             R.Right + St.BoxShadowX + St.BoxShadowSpread,
             R.Bottom + St.BoxShadowY + St.BoxShadowSpread);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := St.BoxShadowColor;
  Canvas.Pen.Style := psClear;
  if GetCornerEllipse(St, SR.Right - SR.Left, SR.Bottom - SR.Top, EW, EH) then
    Canvas.RoundRect(SR.Left, SR.Top, SR.Right, SR.Bottom, EW, EH)
  else
    Canvas.FillRect(SR);
  Canvas.Pen.Style := psSolid;
end;

procedure TRenderer.DrawFrag(Frag: TLineFrag);
var
  R: TRect;
  Pic: TPicture;
  Lbl, Typ: string;
  TW, TH, EW, EH, I, CX, CY: Integer;
  Tag: string;
  Disabled, IsTextInput, IsPlaceholder, Focused, Checked: Boolean;
  BgC, BorderC, TextC: TColor;
  Lines: TStringList;
begin
  R := ShiftRect(Frag.R, OffsetX, OffsetY);
  if (R.Bottom < 0) or (R.Top > ViewHeight) then
    Exit;

  case Frag.Kind of
    fkText:
      begin
        // ⭐/★ are colour emoji — GDI/GDI+ cannot render them; we draw
        // a yellow star as vectors
        if (Pos(#$E2#$AD#$90, Frag.Text) > 0) or
           (Pos(#$E2#$98#$85, Frag.Text) > 0) then
          DrawStar(R, Frag.Style)
        else
          DrawStyledText(Frag.Text, R.Left, R.Top, Frag.Style);
        Canvas.Pen.Style := psSolid;
        Canvas.Pen.Color := Frag.Style.Color;
        if Frag.Style.Underline then
          Canvas.Line(R.Left, R.Top + Frag.Ascent + 1,
            R.Right, R.Top + Frag.Ascent + 1);
        if Frag.Style.Strike then
          Canvas.Line(R.Left, R.Top + (R.Bottom - R.Top) div 2,
            R.Right, R.Top + (R.Bottom - R.Top) div 2);
      end;

    fkImage:
      begin
        if GetCornerEllipse(Frag.Style, R.Right - R.Left, R.Bottom - R.Top,
             EW, EH) then
        begin EW := EW div 2; EH := EH div 2; end
        else begin EW := 0; EH := 0; end;
        // SVG first (rasterized at display size, with alpha)
        if TryDrawSvg(Frag.Url, R, EW, EH) then
          // drawn
        else
        begin
          Pic := nil;
          if Assigned(OnGetPicture) then
            Pic := OnGetPicture(Frag.Url);
          if (Pic <> nil) and (Pic.Graphic <> nil) and not Pic.Graphic.Empty then
            DrawImageNice(R, Pic, EW, EH)
          else if Frag.Element <> nil then
            DrawImagePlaceholder(R, Frag.Element.GetAttribute('alt'))
          else
            DrawImagePlaceholder(R, '');
        end;
      end;

    fkControl:
      begin
        // simple control: background + border + label
        Tag := '';
        Typ := '';
        Disabled := False;
        Checked := False;
        if Frag.Element <> nil then
        begin
          Tag := Frag.Element.TagName;
          Typ := LowerCase(Frag.Element.GetAttribute('type'));
          Disabled := IsDisabled(Frag.Element);
          Checked := Frag.Element.HasAttribute('checked');
        end;
        IsTextInput := IsTextControl(Frag.Element);
        Focused := (Frag.Element <> nil) and (Frag.Element = FocusElement);

        BgC := clWhite;
        if Frag.Style.HasBgColor then BgC := Frag.Style.BgColor;
        BorderC := Frag.Style.BorderColor;
        TextC := Frag.Style.Color;
        if Disabled then
        begin
          BgC := TColor($EBEBEB);
          BorderC := TColor($B0B0B0);
          TextC := TColor($888888);
        end;

        Canvas.Brush.Style := bsSolid;
        Canvas.Brush.Color := BgC;
        Canvas.Pen.Style := psSolid;
        Canvas.Pen.Color := BorderC;
        if Focused then
          Canvas.Pen.Color := TColor($D77800); // focus ring (BGR)
        if (Tag = 'input') and (Typ = 'radio') then
          Canvas.Ellipse(R)
        else if GetCornerEllipse(Frag.Style, R.Right - R.Left, R.Bottom - R.Top,
             EW, EH) then
          Canvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, EW, EH)
        else
        begin
          Canvas.FillRect(R);
          Canvas.Brush.Style := bsClear;
          Canvas.Rectangle(R);
          if Focused then
            Canvas.Rectangle(R.Left + 1, R.Top + 1, R.Right - 1, R.Bottom - 1);
        end;

        // checked state: a tick for checkboxes, a dot for radio buttons
        if Checked and (Tag = 'input') and ((Typ = 'checkbox') or (Typ = 'radio')) then
        begin
          Canvas.Pen.Color := TextC;
          Canvas.Brush.Color := TextC;
          Canvas.Brush.Style := bsSolid;
          if Typ = 'radio' then
            Canvas.Ellipse(R.Left + 4, R.Top + 4, R.Right - 4, R.Bottom - 4)
          else
          begin
            Canvas.Pen.Width := 2;
            Canvas.MoveTo(R.Left + 3, R.Top + (R.Bottom - R.Top) div 2);
            Canvas.LineTo(R.Left + (R.Right - R.Left) * 2 div 5, R.Bottom - 4);
            Canvas.LineTo(R.Right - 3, R.Top + 3);
            Canvas.Pen.Width := 1;
          end;
          Exit;
        end;

        // label/value; for an empty text field — the placeholder in grey
        Lbl := Frag.Text;
        if (Tag = 'input') and (Typ = 'password') then
          Lbl := StringOfChar('*', UTF8LengthFast(Lbl));
        IsPlaceholder := False;
        if (Lbl = '') and IsTextInput and (Frag.Element <> nil) then
        begin
          Lbl := Frag.Element.GetAttribute('placeholder');
          IsPlaceholder := Lbl <> '';
        end;
        if Lbl <> '' then
        begin
          Engine.SetCanvasFont(Canvas, Frag.Style);
          if IsPlaceholder then
            Canvas.Font.Color := TColor($888888)
          else
            Canvas.Font.Color := TextC;
          Canvas.Brush.Style := bsClear;
          TW := Canvas.TextWidth(Lbl);
          TH := Canvas.TextHeight('Hg');
          if Tag = 'textarea' then
          begin
            // multi-line text from the top-left corner
            Lines := TStringList.Create;
            try
              Lines.Text := Lbl;
              for I := 0 to Lines.Count - 1 do
                Canvas.TextRect(R, R.Left + 6, R.Top + 4 + I * TH, Lines[I]);
            finally
              Lines.Free;
            end;
          end
          else if IsTextInput then
            Canvas.TextRect(R, R.Left + 6,
              R.Top + Max(2, ((R.Bottom - R.Top) - TH) div 2), Lbl)
          else
            Canvas.TextRect(R,
              R.Left + Max(4, ((R.Right - R.Left) - TW) div 2),
              R.Top + Max(2, ((R.Bottom - R.Top) - TH) div 2), Lbl);
        end;

        // caret after the text of the focused field (editing always appends)
        if Focused and IsTextInput then
        begin
          Engine.SetCanvasFont(Canvas, Frag.Style);
          TH := Canvas.TextHeight('Hg');
          if IsPlaceholder then
            Lbl := '';
          if Tag = 'textarea' then
          begin
            Lines := TStringList.Create;
            try
              Lines.Text := Lbl;
              if (Lbl = '') or (Lbl[Length(Lbl)] = #10) then
                Lines.Add('');
              CX := R.Left + 6 + Canvas.TextWidth(Lines[Lines.Count - 1]);
              CY := R.Top + 4 + (Lines.Count - 1) * TH;
            finally
              Lines.Free;
            end;
          end
          else
          begin
            CX := R.Left + 6 + Canvas.TextWidth(Lbl);
            CY := R.Top + Max(2, ((R.Bottom - R.Top) - TH) div 2);
          end;
          if CX < R.Right - 2 then
          begin
            Canvas.Pen.Color := TextC;
            Canvas.MoveTo(CX, CY);
            Canvas.LineTo(CX, CY + TH);
          end;
        end;
      end;

    fkBox:
      if Frag.Box <> nil then
        DrawBox(Frag.Box);
  end;
end;

procedure TRenderer.DrawLine(Box: TLayoutBox; Line: TLineBox);
var
  I: Integer;
begin
  if (Line.Y + Line.H - OffsetY < 0) or (Line.Y - OffsetY > ViewHeight) then
    Exit;
  for I := 0 to Line.Frags.Count - 1 do
    DrawFrag(Line.Frags[I]);
end;

function CompareBoxZ(Item1, Item2: Pointer): Integer;
var
  A, B: TLayoutBox;
begin
  A := TLayoutBox(Item1);
  B := TLayoutBox(Item2);
  Result := A.Style.ZIndex - B.Style.ZIndex;
end;

// Painting order within a single z-index (CSS 2.1 App. E):
// in-flow blocks (0) < floats (1) < positioned elements (2).
// Thanks to this a float (e.g. an infobox) paints ON TOP of a heading border
// that comes after it in the DOM — otherwise the border line would cross the float.
function PaintRank(B: TLayoutBox): Integer;
begin
  if B.Style.Position <> cpStatic then
    Result := 2
  else if B.Style.Float_ <> cfNone then
    Result := 1
  else
    Result := 0;
end;

// True when A should be painted LATER (higher) than B.
function BoxPaintsAfter(A, B: TLayoutBox): Boolean;
begin
  if A.Style.ZIndex <> B.Style.ZIndex then
    Result := A.Style.ZIndex > B.Style.ZIndex
  else
    Result := PaintRank(A) > PaintRank(B);
end;

procedure TRenderer.DrawBox(Box: TLayoutBox);
var
  R: TRect;
  SavedOX, SavedOY: Integer;
begin
  // position:fixed — stuck to the viewport: draw without the scroll offset
  if Box.Style.Position = cpFixed then
  begin
    SavedOX := OffsetX; SavedOY := OffsetY;
    OffsetX := 0; OffsetY := 0;
    try
      R := Rect(Box.X, Box.Y, Box.X + Box.W, Box.Y + Box.H);
      if not ((R.Bottom < -50) or (R.Top > ViewHeight + 50)) then
        DrawBoxContent(Box, R);
    finally
      OffsetX := SavedOX; OffsetY := SavedOY;
    end;
    Exit;
  end;

  R := ShiftRect(Rect(Box.X, Box.Y, Box.X + Box.W, Box.Y + Box.H),
    OffsetX, OffsetY);
  if (R.Bottom < -50) or (R.Top > ViewHeight + 50) then
    Exit; // off screen — but float children may stick out, 50px margin
  // horizontal culling — also protects against elements with a broken, huge X position
  if (ViewWidth > 0) and ((R.Left > ViewWidth + 200) or (R.Right < -200)) then
    Exit;

  // opacity < 1: render the subtree into a buffer and alpha-blend it
  if (not Box.IsAnonymous) and (Box.Style.Opacity < 1.0) and
     (R.Right > R.Left) and (R.Bottom > R.Top) then
  begin
    PaintBoxOpacity(Box, R);
    Exit;
  end;
  DrawBoxContent(Box, R);
end;

procedure TRenderer.DrawBoxContent(Box: TLayoutBox; const R: TRect);
var
  I, J, SavedDC, EW, EH: Integer;
  MarkerW, MarkerX, MarkerY, IW, IH: Integer;
  ClipContent, HasMarkerImg: Boolean;
  Sorted: Classes.TList;
  Child: TLayoutBox;
  Pic: TPicture;
  CR: TRect;
  Url: string;
begin
  if not Box.IsAnonymous then
  begin
    DrawBoxShadow(Box.Style, R);
    DrawBackground(Box, R);
    DrawBorders(Box, R);
  end;

  // block image (display:block/inline-block as a box) — draw it;
  // inline images are drawn by DrawFrag, but a boxed <img> has no fragment
  if (not Box.IsAnonymous) and (Box.Element <> nil) and
     (Box.Element.TagName = 'img') then
  begin
    CR := Rect(R.Left + Box.Style.BordL + Box.Style.PadL,
               R.Top + Box.Style.BordT + Box.Style.PadT,
               R.Right - Box.Style.BordR - Box.Style.PadR,
               R.Bottom - Box.Style.BordB - Box.Style.PadB);
    Url := '';
    if Box.Element.OwnerDocument <> nil then
      Url := XelUrl.ResolveUrl(Box.Element.OwnerDocument.BaseUrl,
        Box.Element.GetAttribute('src'));
    if GetCornerEllipse(Box.Style, CR.Right - CR.Left, CR.Bottom - CR.Top,
         EW, EH) then
    begin EW := EW div 2; EH := EH div 2; end
    else begin EW := 0; EH := 0; end;
    // SVG first (rasterized at display size, with alpha)
    if TryDrawSvg(Url, CR, EW, EH) then
      // drawn
    else
    begin
      Pic := nil;
      if Assigned(OnGetPicture) and (Url <> '') then
        Pic := OnGetPicture(Url);
      if (Pic <> nil) and (Pic.Graphic <> nil) and not Pic.Graphic.Empty then
        DrawImageNice(CR, Pic, EW, EH)
      else
        DrawImagePlaceholder(CR, Box.Element.GetAttribute('alt'));
    end;
  end;

  ClipContent := (Box.Style.OverflowX <> coVisible) or
    (Box.Style.OverflowY <> coVisible);
  SavedDC := 0;
  if ClipContent then
  begin
    SavedDC := Windows.SaveDC(Canvas.Handle);
    Windows.IntersectClipRect(Canvas.Handle, R.Left, R.Top, R.Right, R.Bottom);
  end;

  // list marker: image (list-style-image) or bullet/number
  if (Box.BulletText <> '') or (Box.Style.ListImage <> '') then
  begin
    MarkerY := R.Top + Box.Style.BordT + Box.Style.PadT;
    HasMarkerImg := False;
    if (Box.Style.ListImage <> '') and Assigned(OnGetPicture) then
    begin
      Pic := OnGetPicture(Box.Style.ListImage);
      if (Pic <> nil) and (Pic.Graphic <> nil) and not Pic.Graphic.Empty then
      begin
        IW := Pic.Width;
        IH := Pic.Height;
        if (IH > Box.Style.FontSizePx) and (IH > 0) then
        begin
          IW := MulDiv(IW, Box.Style.FontSizePx, IH);
          IH := Box.Style.FontSizePx;
        end;
        // list-style-position: inside -> at the content edge; outside -> in the margin
        if Box.Style.ListInside then
          MarkerX := R.Left + Box.Style.BordL + Box.Style.PadL
        else
          MarkerX := R.Left - IW - 6;
        DrawImageNice(Rect(MarkerX, MarkerY, MarkerX + IW, MarkerY + IH), Pic);
        HasMarkerImg := True;
      end;
    end;
    if (not HasMarkerImg) and (Box.BulletText <> '') then
    begin
      Engine.SetCanvasFont(Canvas, Box.Style);
      Canvas.Font.Color := Box.Style.Color;
      Canvas.Brush.Style := bsClear;
      MarkerW := Canvas.TextWidth(Box.BulletText);
      if Box.Style.ListInside then
        MarkerX := R.Left + Box.Style.BordL + Box.Style.PadL
      else
        MarkerX := R.Left - MarkerW - 8;
      DrawStyledText(Box.BulletText, MarkerX, MarkerY, Box.Style);
    end;
  end;

  for I := 0 to Box.Lines.Count - 1 do
    DrawLine(Box, Box.Lines[I]);

  Sorted := Classes.TList.Create;
  try
    for I := 0 to Box.Children.Count - 1 do
      Sorted.Add(Box.Children[I]);
    // stable sort by (z-index, paint layer) — equal keys
    // keep document order (CSS: the later one is drawn on top);
    // floats paint after in-flow blocks, positioned ones last
    for I := 1 to Sorted.Count - 1 do
    begin
      Child := TLayoutBox(Sorted[I]);
      J := I - 1;
      while (J >= 0) and
            BoxPaintsAfter(TLayoutBox(Sorted[J]), Child) do
      begin
        Sorted[J + 1] := Sorted[J];
        Dec(J);
      end;
      Sorted[J + 1] := Child;
    end;
    for I := 0 to Sorted.Count - 1 do
    begin
      Child := TLayoutBox(Sorted[I]);
      // in-flow float -> defer to the float pass (painted after the blocks
      // of the whole stacking context, including later sections)
      if FDeferFloats and (Child.Style.Float_ <> cfNone) and
         (Child.Style.Position = cpStatic) then
        FDeferredFloats.Add(Child)
      else
        DrawBox(Child);
    end;
  finally
    Sorted.Free;
  end;

  if ClipContent then
    Windows.RestoreDC(Canvas.Handle, SavedDC);
end;

type
  TBlendFunc = packed record
    BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat: Byte;
  end;

function MsAlphaBlend(hdcDest: HDC; xD, yD, wD, hD: Integer; hdcSrc: HDC;
  xS, yS, wS, hS: Integer; bf: TBlendFunc): LongBool; stdcall;
  external 'msimg32.dll' name 'AlphaBlend';

procedure TRenderer.PaintContentWithFloats(Box: TLayoutBox; const R: TRect);
var
  SavedList: Classes.TList;
  SavedDefer: Boolean;
  K: Integer;
begin
  SavedList := FDeferredFloats;
  SavedDefer := FDeferFloats;
  FDeferredFloats := Classes.TList.Create;
  FDeferFloats := True;
  try
    DrawBoxContent(Box, R);
    FDeferFloats := False;
    for K := 0 to FDeferredFloats.Count - 1 do
      DrawBox(TLayoutBox(FDeferredFloats[K]));
  finally
    FDeferredFloats.Free;
    FDeferredFloats := SavedList;
    FDeferFloats := SavedDefer;
  end;
end;

procedure TRenderer.PaintBoxOpacity(Box: TLayoutBox; const R: TRect);
var
  W, H, OldOX, OldOY, OldVH: Integer;
  OldCanvas: TCanvas;
  Tmp: Graphics.TBitmap;
  Bf: TBlendFunc;
  R2: TRect;
begin
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  // safeguard: for a huge area skip the alpha buffer and draw opaquely
  if (W <= 0) or (H <= 0) or (W > 4096) or (H > 8192) then
  begin
    PaintContentWithFloats(Box, R);
    Exit;
  end;
  Tmp := Graphics.TBitmap.Create;
  try
    Tmp.PixelFormat := pf24bit;
    Tmp.SetSize(W, H);
    // copy the current background under the box — unpainted areas stay unchanged
    Windows.BitBlt(Tmp.Canvas.Handle, 0, 0, W, H, Canvas.Handle,
      R.Left, R.Top, SRCCOPY);

    // redirect drawing to the buffer (the box maps to 0,0)
    OldCanvas := Canvas; OldOX := OffsetX; OldOY := OffsetY; OldVH := ViewHeight;
    Canvas := Tmp.Canvas;
    OffsetX := OldOX + R.Left;
    OffsetY := OldOY + R.Top;
    ViewHeight := H + OldOY + R.Top + 100;
    R2 := ShiftRect(Rect(Box.X, Box.Y, Box.X + Box.W, Box.Y + Box.H),
      OffsetX, OffsetY);
    PaintContentWithFloats(Box, R2);
    Canvas := OldCanvas; OffsetX := OldOX; OffsetY := OldOY; ViewHeight := OldVH;

    // blend the buffer with the background using a constant alpha
    Bf.BlendOp := 0;           // AC_SRC_OVER
    Bf.BlendFlags := 0;
    Bf.SourceConstantAlpha := Round(Box.Style.Opacity * 255);
    Bf.AlphaFormat := 0;
    MsAlphaBlend(Canvas.Handle, R.Left, R.Top, W, H,
      Tmp.Canvas.Handle, 0, 0, W, H, Bf);
  finally
    Tmp.Free;
  end;
end;

initialization

finalization
  ClearRenderImageCache;
  if GArgbCache <> nil then
    GArgbCache.Free;
  if GSvgCache <> nil then
    GSvgCache.Free;

end.
