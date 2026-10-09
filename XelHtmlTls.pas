unit XelHtmlTls;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// HTTPS for TXelHtml through TlsLib4Pascal (pure Pascal TLS 1.2/1.3, no DLLs).
// Add this unit to the uses clause of the program (package XelHtmlTlsPkg):
//
//   uses Interfaces, Forms, XelHtmlTls, ...
//
// It registers TlsLib as fcl-net's TLS handler, so every https:// download of
// TXelHtml goes through it, and verifies server certificates against the
// operating system's trusted roots: the Windows certificate store, or the CA
// bundle file on Linux (/etc/ssl/certs/ca-certificates.crt and the other usual
// locations, or the file named by SSL_CERT_FILE). It lives in its own
// runtime-only package because the TlsLib packages are runtime only and cannot
// be installed in the IDE, while XelHtmlPkg (the component) is.

interface

uses
  TlsLibFclNetTls; // registers TTlsLibSocketHandler as fcl-net's default TLS handler

implementation

{$IFDEF UNIX}
uses
  SysUtils, Classes, sslsockets,
  TlpITlsConfig, TlpITlsConfigBuilder, TlpTlsPresets, TlpDefaultCryptoProvider,
  TlpInMemorySessionCache, TlpSystemTrustFacade;

// On Linux the trusted roots come from a CA bundle file, and TlsLib then accepts
// a chain only if it ends exactly at a root of that file. Many servers (e.g.
// every Cloudflare site with an SSL.com certificate) send a cross-signed copy
// of a root whose own issuer was removed from the bundle; OpenSSL and the
// Windows verifier stop at the trusted copy of that root. TlsLib does the same
// only in its path-building fallback, which runs when intermediate certificates
// are configured - so the client config gets the bundle as intermediates. They
// are never trusted by themselves: a path must still end at a trusted root.

type
  TXelTlsHandler = class(TTlsLibSocketHandler)
  public
    constructor Create; override;
  end;

const
  // the CA bundle locations TlsLib's Unix trust store reads (TlpUnixSystemTrust)
  CA_BUNDLES: array[0..5] of string = (
    '/etc/ssl/certs/ca-certificates.crt',     // Debian, Ubuntu, Alpine, Gentoo
    '/etc/pki/tls/certs/ca-bundle.crt',        // Fedora, RHEL, CentOS
    '/etc/ssl/ca-bundle.pem',                  // openSUSE
    '/etc/ssl/cert.pem',                       // OpenBSD, Alpine, DragonFly
    '/usr/local/etc/ssl/cert.pem',             // FreeBSD
    '/usr/local/share/certs/ca-root-nss.crt'); // FreeBSD (ports)

var
  GLock: TRTLCriticalSection;
  GClientConfig: ITlsClientConfig = nil;

function LoadCaBundle: TBytes;
var
  Files: array of string;
  FileName: string;
  FS: TFileStream;
  I: Integer;
begin
  Result := nil;
  SetLength(Files, Length(CA_BUNDLES) + 1);
  Files[0] := GetEnvironmentVariable('SSL_CERT_FILE'); // same override as TlsLib
  for I := 0 to High(CA_BUNDLES) do
    Files[I + 1] := CA_BUNDLES[I];
  for FileName in Files do
    if (FileName <> '') and FileExists(FileName) then
    try
      FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
      try
        SetLength(Result, FS.Size);
        if FS.Size > 0 then
          FS.ReadBuffer(Result[0], FS.Size);
        Exit;
      finally
        FS.Free;
      end;
    except
      Result := nil; // unreadable: try the next location
    end;
end;

function ClientConfig: ITlsClientConfig;
var
  B: ITlsClientConfigBuilder;
  Bundle: TBytes;
begin
  // handlers are created in the download threads
  EnterCriticalSection(GLock);
  try
    if GClientConfig = nil then
    begin
      B := TTlsPresets.Compatible(TDefaultCryptoProvider.Shared).Client;
      TSystemTrust.WithSystemTrust(B, TDefaultCryptoProvider.Shared);
      Bundle := LoadCaBundle;
      if Length(Bundle) > 0 then
        B.WithIntermediateCertificates(Bundle);
      B.WithResumption(True);
      B.WithSessionCache(TInMemorySessionCache.Shared);
      GClientConfig := B.Build;
    end;
    Result := GClientConfig;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

constructor TXelTlsHandler.Create;
begin
  inherited Create;
  // the trust is part of the supplied config; the handler must not name it too
  UseSystemTrust := False;
  ClientConfig := XelHtmlTls.ClientConfig;
end;
{$ENDIF}

initialization
  // TlsLib is fail-closed: without a trust source every https:// connection
  // is refused. Verify server certificates against the OS store, like curl.
  TlsLibFclNetTrustDefaults.UseSystemTrust := True;
  {$IFDEF UNIX}
  InitCriticalSection(GLock);
  TSSLSocketHandler.SetDefaultHandlerClass(TXelTlsHandler);
  {$ENDIF}

finalization
  {$IFDEF UNIX}
  GClientConfig := nil;
  DoneCriticalSection(GLock);
  {$ENDIF}

end.
