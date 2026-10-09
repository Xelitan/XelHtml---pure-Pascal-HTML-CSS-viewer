unit XelSvgImage;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// This is a hack for now. Later XelSimpleSVG will simply be updated to support alpha
// channel transparency natively.
// Helper for rasterizing SVG images (via XelSimpleSVG) with TRANSPARENCY.
// XelSimpleSVG renders onto an opaque background, so the alpha channel is recovered
// with the two-background method: the same SVG is drawn on white and on black, and
// the alpha and true colour of every pixel are computed from the colour difference.
//
// For a pixel (per channel):
//   Cw = a*Cr + (1-a)*255   (on white)
//   Cb = a*Cr + (1-a)*0     (on black)
// hence:
//   a  = 1 - (Cw - Cb)/255
//   Cr = Cb / a
//
// RasterizeSvg renders directly at the target size (W x H), so the image is
// sharp at the given zoom (rasterized at display size).

interface

uses
  SysUtils, Graphics;

// Intrinsic SVG size from the width/height attributes of the <svg> tag or from viewBox.
// Returns a sensible size (clamped).
procedure SvgIntrinsicSize(const SvgText: string; out W, H: Integer);

// Rasterizes SVG into a 32-bit bitmap with an alpha channel, at size W x H.
// Returns a new TBitmap (caller frees it) or nil on error.
function RasterizeSvg(const SvgText: string; W, H: Integer): Graphics.TBitmap;

implementation

uses
  {$IFDEF MSWINDOWS}Windows,{$ELSE}LCLType, LCLIntf,{$ENDIF}
  IntfGraphics, GraphType, FPImage, XelSimpleSVG;

procedure SvgIntrinsicSize(const SvgText: string; out W, H: Integer);
var
  LT, Tag: string;
  P, E: Integer;
  FS: TFormatSettings;

  function NumAttr(const Name: string): Integer;
  var Q, K: Integer; V: string;
  begin
    Result := 0;
    Q := Pos(' ' + Name + '=', Tag);   // leading space — so that stroke-width is not matched
    if Q = 0 then Exit;
    Inc(Q, Length(Name) + 2);
    while (Q <= Length(Tag)) and (Tag[Q] in [' ', '"', '''']) do Inc(Q);
    V := '';
    K := Q;
    while (K <= Length(Tag)) and (Tag[K] in ['0'..'9', '.']) do
    begin V := V + Tag[K]; Inc(K); end;
    Result := Round(StrToFloatDef(V, 0, FS));
  end;

  procedure FromViewBox;
  var Q: Integer; V: string; Nums: array[0..3] of Double; NC: Integer;
  begin
    Q := Pos('viewbox=', Tag);
    if Q = 0 then Exit;
    Inc(Q, 8);
    while (Q <= Length(Tag)) and (Tag[Q] in [' ', '"', '''']) do Inc(Q);
    NC := 0;
    while (Q <= Length(Tag)) and (Tag[Q] <> '"') and (Tag[Q] <> '''') and (NC < 4) do
    begin
      while (Q <= Length(Tag)) and not (Tag[Q] in ['0'..'9', '.', '-']) do Inc(Q);
      V := '';
      while (Q <= Length(Tag)) and (Tag[Q] in ['0'..'9', '.', '-']) do
      begin V := V + Tag[Q]; Inc(Q); end;
      if V = '' then Break;
      Nums[NC] := StrToFloatDef(V, 0, FS); Inc(NC);
    end;
    if NC = 4 then
    begin
      if W <= 0 then W := Round(Nums[2]);
      if H <= 0 then H := Round(Nums[3]);
    end;
  end;

begin
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  W := 0; H := 0;
  LT := LowerCase(SvgText);
  P := Pos('<svg', LT);
  if P = 0 then Exit;
  E := P;
  while (E <= Length(LT)) and (LT[E] <> '>') do Inc(E);
  Tag := Copy(LT, P, E - P + 1);
  W := NumAttr('width');
  H := NumAttr('height');
  if (W <= 0) or (H <= 0) then FromViewBox;
  if W <= 0 then W := 300;
  if H <= 0 then H := 150;
  // sensible limits for the intrinsic size
  if W > 1024 then begin H := MulDiv(H, 1024, W); W := 1024; end;
  if H > 1024 then begin W := MulDiv(W, 1024, H); H := 1024; end;
  if W < 1 then W := 1;
  if H < 1 then H := 1;
end;

function RasterizeSvg(const SvgText: string; W, H: Integer): Graphics.TBitmap;
var
  BmpW, BmpB: Graphics.TBitmap;
  ImgW, ImgB, ImgOut: TLazIntfImage;
  Desc: TRawImageDescription;
  X, Y: Integer;
  Cw, Cb: TFPColor;
  Rw, Gw, Bw, Rb, Gb, Bb, Ar, Ag, Ab, A, Cr, Cg, Cc: Integer;
begin
  Result := nil;
  if (W < 1) or (H < 1) then Exit;
  // limit on the rasterization size (e.g. broken geometry)
  if W > 4096 then W := 4096;
  if H > 4096 then H := 4096;

  BmpW := Graphics.TBitmap.Create;
  BmpB := Graphics.TBitmap.Create;
  ImgW := nil; ImgB := nil; ImgOut := nil;
  try
    BmpW.PixelFormat := pf24bit; BmpW.SetSize(W, H);
    BmpB.PixelFormat := pf24bit; BmpB.SetSize(W, H);
    if not RenderSimpleSVGToBitmap(SvgText, BmpW, clWhite) then Exit;
    if not RenderSimpleSVGToBitmap(SvgText, BmpB, clBlack) then Exit;

    ImgW := BmpW.CreateIntfImage;
    ImgB := BmpB.CreateIntfImage;

    ImgOut := TLazIntfImage.Create(0, 0);
    Desc.Init_BPP32_B8G8R8A8_BIO_TTB(W, H);
    ImgOut.DataDescription := Desc;

    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
      begin
        Cw := ImgW.Colors[X, Y];
        Cb := ImgB.Colors[X, Y];
        Rw := Cw.Red shr 8;   Gw := Cw.Green shr 8;   Bw := Cw.Blue shr 8;
        Rb := Cb.Red shr 8;   Gb := Cb.Green shr 8;   Bb := Cb.Blue shr 8;
        // alpha from each channel (they should agree); take the average
        Ar := 255 - (Rw - Rb);
        Ag := 255 - (Gw - Gb);
        Ab := 255 - (Bw - Bb);
        A := (Ar + Ag + Ab) div 3;
        if A < 0 then A := 0 else if A > 255 then A := 255;
        if A = 0 then
          ImgOut.Colors[X, Y] := FPColor(0, 0, 0, 0)
        else
        begin
          // true colour: Cr = Cb / a  (Cb is the render on black = a*Cr)
          Cr := Rb * 255 div A;
          Cg := Gb * 255 div A;
          Cc := Bb * 255 div A;
          if Cr > 255 then Cr := 255;
          if Cg > 255 then Cg := 255;
          if Cc > 255 then Cc := 255;
          ImgOut.Colors[X, Y] := FPColor(Cr * 257, Cg * 257, Cc * 257, A * 257);
        end;
      end;

    Result := Graphics.TBitmap.Create;
    Result.LoadFromIntfImage(ImgOut);
  finally
    ImgW.Free; ImgB.Free; ImgOut.Free;
    BmpW.Free; BmpB.Free;
  end;
end;

end.
