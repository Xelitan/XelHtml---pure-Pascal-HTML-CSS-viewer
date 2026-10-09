program httpstest;
{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

uses Classes, SysUtils, fphttpclient, opensslsockets;
var
  C: TFPHttpClient;
  M: TMemoryStream;
  S: string;
begin
  C := TFPHttpClient.Create(nil);
  M := TMemoryStream.Create;
  try
    C.AllowRedirect := True;
    C.IOTimeout := 20000;
    C.AddHeader('User-Agent', 'Mozilla/5.0 (compatible; FPHtmlViewer/0.1)');
    C.AddHeader('Accept-Encoding', 'identity');
    C.Get('https://example.com/', M);
    SetLength(S, M.Size);
    M.Position := 0;
    if M.Size > 0 then M.ReadBuffer(S[1], M.Size);
    writeln('HTTPS OK, bytes: ', M.Size);
    writeln('Has <title>: ', Pos('<title', LowerCase(S)) > 0);
  finally
    M.Free;
    C.Free;
  end;
end.
