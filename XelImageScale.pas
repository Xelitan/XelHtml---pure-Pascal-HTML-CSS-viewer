unit XelImageScale;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Image scaling and drawing via GDI+ (gdiplus.dll, flat API):
// high-quality bicubic interpolation that preserves the alpha channel, plus
// optional anti-aliased rounded corners (texture brush + path).
//
// The unit is self-contained with respect to GDI+ (its own initialization), so it
// does not depend on the font layer (OTF.pas).

interface

uses
  Windows;

// Scales and draws an image via GDI+ (bicubic, preserving alpha).
// Argb points to SrcW*SrcH 32bpp pixels in B,G,R,A order (like
// PixelFormat32bppARGB). Draws into the rectangle (DX,DY,DW,DH) on DC; honours
// the DC's current clipping region. Returns False on failure.
function DrawImageArgbScaled(DC: HDC; Argb: PByte; SrcW, SrcH: Integer;
  DX, DY, DW, DH: Integer): Boolean;

// Same as above, but clips to a rectangle with rounded corners (radii RadX/
// RadY) with ANTI-ALIASING (GDI+ texture brush + smoothed path).
// RadX = DW/2 and RadY = DH/2 gives a full ellipse (circle).
function DrawImageArgbRounded(DC: HDC; Argb: PByte; SrcW, SrcH,
  DX, DY, DW, DH, RadX, RadY: Integer): Boolean;

implementation

type
  GpStatus   = Integer;
  GpGraphics = Pointer;
  GpImage    = Pointer;
  GpBrush    = Pointer;
  GpPath     = Pointer;
  ULONG_PTR  = PtrUInt;

  TGdiplusStartupInput = record
    GdiplusVersion: LongWord;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: LongBool;
    SuppressExternalCodecs: LongBool;
  end;

const
  InterpolationModeHighQualityBicubic = 7;
  PixelOffsetModeHalf                 = 2;
  PixelFormat32bppARGB                = $0026200A;
  SmoothingModeAntiAlias              = 4;
  WrapModeClamp                       = 4;
  MatrixOrderAppend                   = 1;

function GdiplusStartup(out token: ULONG_PTR;
  const input: TGdiplusStartupInput; output: Pointer): GpStatus; stdcall;
  external 'gdiplus.dll';
procedure GdiplusShutdown(token: ULONG_PTR); stdcall;
  external 'gdiplus.dll';
function GdipCreateFromHDC(hdc: HDC; out graphics: GpGraphics): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDeleteGraphics(graphics: GpGraphics): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipDeleteBrush(brush: GpBrush): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipSetSmoothingMode(graphics: GpGraphics; mode: Integer): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipCreateBitmapFromScan0(width, height, stride, format: Integer;
  scan0: PByte; out bitmap: GpImage): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDisposeImage(image: GpImage): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipSetInterpolationMode(graphics: GpGraphics;
  interpolationMode: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipSetPixelOffsetMode(graphics: GpGraphics;
  pixelOffsetMode: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipDrawImageRectI(graphics: GpGraphics; image: GpImage;
  x, y, width, height: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipCreateTexture(image: GpImage; wrapMode: Integer;
  out texture: GpBrush): GpStatus; stdcall; external 'gdiplus.dll';
function GdipScaleTextureTransform(brush: GpBrush; sx, sy: Single;
  order: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipTranslateTextureTransform(brush: GpBrush; dx, dy: Single;
  order: Integer): GpStatus; stdcall; external 'gdiplus.dll';
function GdipCreatePath(brushMode: Integer; out path: GpPath): GpStatus;
  stdcall; external 'gdiplus.dll';
function GdipDeletePath(path: GpPath): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipAddPathArc(path: GpPath; x, y, width, height, startAngle,
  sweepAngle: Single): GpStatus; stdcall; external 'gdiplus.dll';
function GdipClosePathFigure(path: GpPath): GpStatus; stdcall;
  external 'gdiplus.dll';
function GdipFillPath(graphics: GpGraphics; brush: GpBrush;
  path: GpPath): GpStatus; stdcall; external 'gdiplus.dll';

var
  GToken: ULONG_PTR = 0;
  GReady: Boolean = False;
  GTried: Boolean = False;

function GdiPlusReady: Boolean;
var
  Inp: TGdiplusStartupInput;
begin
  if not GTried then
  begin
    GTried := True;
    FillChar(Inp, SizeOf(Inp), 0);
    Inp.GdiplusVersion := 1;
    GReady := GdiplusStartup(GToken, Inp, nil) = 0;
  end;
  Result := GReady;
end;

function DrawImageArgbScaled(DC: HDC; Argb: PByte; SrcW, SrcH: Integer;
  DX, DY, DW, DH: Integer): Boolean;
var
  G: GpGraphics;
  Img: GpImage;
begin
  Result := False;
  if (Argb = nil) or (SrcW <= 0) or (SrcH <= 0) or (DW <= 0) or (DH <= 0) then
    Exit;
  if not GdiPlusReady then Exit;
  G := nil; Img := nil;
  try
    if GdipCreateBitmapFromScan0(SrcW, SrcH, SrcW * 4, PixelFormat32bppARGB,
         Argb, Img) <> 0 then Exit;
    if GdipCreateFromHDC(DC, G) <> 0 then Exit;
    GdipSetInterpolationMode(G, InterpolationModeHighQualityBicubic);
    GdipSetPixelOffsetMode(G, PixelOffsetModeHalf);
    Result := GdipDrawImageRectI(G, Img, DX, DY, DW, DH) = 0;
  finally
    if G <> nil then GdipDeleteGraphics(G);
    if Img <> nil then GdipDisposeImage(Img);
  end;
end;

function DrawImageArgbRounded(DC: HDC; Argb: PByte; SrcW, SrcH,
  DX, DY, DW, DH, RadX, RadY: Integer): Boolean;
var
  G: GpGraphics;
  Img: GpImage;
  Brush: GpBrush;
  Path: GpPath;
  Rx, Ry: Single;
begin
  Result := False;
  if (Argb = nil) or (SrcW <= 0) or (SrcH <= 0) or (DW <= 0) or (DH <= 0) then
    Exit;
  if not GdiPlusReady then Exit;
  if RadX * 2 > DW then RadX := DW div 2;
  if RadY * 2 > DH then RadY := DH div 2;
  if RadX < 1 then RadX := 1;
  if RadY < 1 then RadY := 1;
  Rx := RadX; Ry := RadY;

  G := nil; Img := nil; Brush := nil; Path := nil;
  try
    if GdipCreateBitmapFromScan0(SrcW, SrcH, SrcW * 4, PixelFormat32bppARGB,
         Argb, Img) <> 0 then Exit;
    if GdipCreateTexture(Img, WrapModeClamp, Brush) <> 0 then Exit;
    // map the texture (0,0,Src) -> destination rectangle
    GdipScaleTextureTransform(Brush, DW / SrcW, DH / SrcH, MatrixOrderAppend);
    GdipTranslateTextureTransform(Brush, DX, DY, MatrixOrderAppend);
    // path: rounded rectangle made of 4 arcs (Rx=DW/2 -> ellipse)
    if GdipCreatePath(0, Path) <> 0 then Exit;
    GdipAddPathArc(Path, DX, DY, 2 * Rx, 2 * Ry, 180, 90);
    GdipAddPathArc(Path, DX + DW - 2 * Rx, DY, 2 * Rx, 2 * Ry, 270, 90);
    GdipAddPathArc(Path, DX + DW - 2 * Rx, DY + DH - 2 * Ry, 2 * Rx, 2 * Ry, 0, 90);
    GdipAddPathArc(Path, DX, DY + DH - 2 * Ry, 2 * Rx, 2 * Ry, 90, 90);
    GdipClosePathFigure(Path);
    if GdipCreateFromHDC(DC, G) <> 0 then Exit;
    GdipSetSmoothingMode(G, SmoothingModeAntiAlias);
    GdipSetInterpolationMode(G, InterpolationModeHighQualityBicubic);
    GdipSetPixelOffsetMode(G, PixelOffsetModeHalf);
    Result := GdipFillPath(G, Brush, Path) = 0;
  finally
    if Path <> nil then GdipDeletePath(Path);
    if Brush <> nil then GdipDeleteBrush(Brush);
    if G <> nil then GdipDeleteGraphics(G);
    if Img <> nil then GdipDisposeImage(Img);
  end;
end;

initialization

finalization
  if GReady and (GToken <> 0) then
    GdiplusShutdown(GToken);

end.
