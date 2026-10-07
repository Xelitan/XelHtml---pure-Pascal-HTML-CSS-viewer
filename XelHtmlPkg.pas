{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit XelHtmlPkg;

{$warn 5023 off : no warning about unused units}
interface

uses
  XelHtml, XelDom, XelHtmlParser, XelCssParser, XelStyle, XelLayout, XelRender, XelForms, XelNet, XelContentEncoding, XelUrl, XelTextUtil, XelImageScale, XelSvgImage, XelSimpleSVG, OTF, FontTypes, TTFParser, CFFBuilder, WOFFCodec, WOFF2Codec, SVGFontReader,
  LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('XelHtml', @XelHtml.Register);
end;

initialization
  RegisterPackage('XelHtmlPkg', @Register);
end.
