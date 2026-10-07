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
// Windows certificate store. It lives in its own runtime-only package because
// the TlsLib packages are runtime only and cannot be installed in the IDE,
// while XelHtmlPkg (the component) is.

interface

uses
  TlsLibFclNetTls; // registers TTlsLibSocketHandler as fcl-net's default TLS handler

implementation

initialization
  // TlsLib is fail-closed: without a trust source every https:// connection
  // is refused. Verify server certificates against the OS store, like curl.
  TlsLibFclNetTrustDefaults.UseSystemTrust := True;

end.
