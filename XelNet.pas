unit XelNet;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Network resource manager.
// Each resource type has its own queue and its own download threads:
//   HTML   - 1 thread
//   JS     - 1 thread
//   CSS    - 1 thread
//   Fonts  - 1 thread
//   Images - IMAGE_THREADS (2) threads
// Supports: http://, https:// and local files. HTTPS needs a TLS handler
// registered in fcl-net: add the XelHtmlTls unit (package XelHtmlTlsPkg,
// TlsLib4Pascal — pure Pascal TLS 1.2/1.3, no DLLs) to the program's uses
// clause. It is not linked here because TlsLib is a runtime-only package and
// this unit is part of XelHtmlPkg, which is installed in the IDE. Compressed responses (gzip, deflate, br) are decoded
// by XelContentEncoding. Completion notifications
// reach the main thread via Application.QueueAsyncCall
// (callback set by the form).

interface

uses
  Classes, SysUtils, syncobjs, Generics.Collections;

type
  TResourceType = (rtHtml, rtJS, rtCSS, rtFont, rtImage);
  TResourceState = (rsQueued, rsLoading, rsLoaded, rsError);

  TResource = class
  public
    Url: string;
    ResType: TResourceType;
    State: TResourceState;
    Data: TMemoryStream;
    ErrorMsg: string;
    Tag: string;         // extra info, e.g. font family name for rtFont
    ContentType: string; // Content-Type response header (charset hint)
    Method: string;      // 'GET' (default) or 'POST'
    PostBody: RawByteString; // urlencoded form data for 'POST'
    constructor Create(const AUrl: string; AType: TResourceType);
    destructor Destroy; override;
  end;

  // called from a worker thread! the receiver must hand it over to the main thread
  TResourceNotify = procedure(Res: TResource) of object;

  TResourceManager = class;

  TDownloadThread = class(TThread)
  private
    FMgr: TResourceManager;
    FResType: TResourceType;
    procedure Download(Res: TResource);
  protected
    procedure Execute; override;
  public
    constructor Create(AMgr: TResourceManager; AType: TResourceType);
  end;

  TResourceManager = class
  private
    FLock: TCriticalSection;
    FAll: TDictionary<string, TResource>; // deduplication by URL
    FQueues: array[TResourceType] of TQueue<TResource>;
    FEvents: array[TResourceType] of TEvent;
    FThreads: TList<TDownloadThread>;
    FNotify: TResourceNotify;
    FShutdown: Boolean;
    FPostSeq: Integer;
    FUserAgent: string;
    function GetUserAgent: string;
    procedure SetUserAgent(const AValue: string);
    function Pop(AType: TResourceType): TResource;
    procedure NotifyLoaded(Res: TResource);
  public
    constructor Create;
    destructor Destroy; override;

    // Adds a URL to the queue of the matching type. Returns the existing resource
    // if the URL was already requested (deduplication).
    function Enqueue(const AUrl: string; AType: TResourceType;
      const ATag: string = ''): TResource;
    // Queues an HTML form POST (application/x-www-form-urlencoded). Never
    // deduplicated or served from the cache: every submission is sent.
    function EnqueuePost(const AUrl: string; const ABody: RawByteString): TResource;
    function Find(const AUrl: string): TResource;
    function PendingCount: Integer;

    // Drops a finished resource from the cache so the next Enqueue
    // fetches it again (page reload). Ignored while still loading.
    procedure Forget(const AUrl: string);

    property OnLoaded: TResourceNotify read FNotify write FNotify;
    // User-Agent header sent with every request (thread-safe)
    property UserAgent: string read GetUserAgent write SetUserAgent;
  end;

implementation

uses
  fphttpclient, sslsockets,
  XelUrl, XelContentEncoding;

const
  IMAGE_THREADS = 2;
  DEFAULT_USER_AGENT = 'Mozilla/5.0 (compatible; XelHtml/1.0)';  // gentle on rate-limited servers (e.g. Wikimedia 429)

// TResource

constructor TResource.Create(const AUrl: string; AType: TResourceType);
begin
  inherited Create;
  Url := AUrl;
  ResType := AType;
  Method := 'GET';
  State := rsQueued;
  Data := TMemoryStream.Create;
end;

destructor TResource.Destroy;
begin
  Data.Free;
  inherited Destroy;
end;

// TDownloadThread

constructor TDownloadThread.Create(AMgr: TResourceManager; AType: TResourceType);
begin
  FMgr := AMgr;
  FResType := AType;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDownloadThread.Download(Res: TResource);
var
  Client: TFPHttpClient;
  FS: TFileStream;
  Body: TRawByteStringStream;
  Path, Encoding: string;
  I, Attempt: Integer;
  DataBytes: RawByteString;
  DataMime: string;
begin
  try
    if IsHttpsUrl(Res.Url) and (TSSLSocketHandler.GetDefaultHandlerClass = nil) then
      raise Exception.Create('HTTPS support is not linked into the program: ' +
        'add the XelHtmlTls unit (package XelHtmlTlsPkg) to the uses clause');
    if DecodeDataUrl(Res.Url, DataBytes, DataMime) then
    begin
      // data: URL (e.g. a <link> to data:text/css,...): the bytes are in the URL
      if DataBytes <> '' then
        Res.Data.WriteBuffer(DataBytes[1], Length(DataBytes));
      Res.Data.Position := 0;
      Res.State := rsLoaded;
    end
    else if IsHttpUrl(Res.Url) or IsHttpsUrl(Res.Url) then
    begin
      Client := TFPHttpClient.Create(nil);
      try
        Client.AllowRedirect := True;
        Client.MaxRedirects := 5;
        Client.IOTimeout := 20000;
        Client.ConnectTimeout := 10000;
        Client.AddHeader('User-Agent', FMgr.UserAgent);
        Client.AddHeader('Accept', '*/*');
        Client.AddHeader('Accept-Encoding', ACCEPT_ENCODING);
        if Res.Method = 'POST' then
        begin
          // form submission: sent once, never retried (it may not be idempotent);
          // the response page is shown whatever its status code
          Body := TRawByteStringStream.Create(Res.PostBody);
          try
            Client.RequestBody := Body;
            Client.AddHeader('Content-Type', 'application/x-www-form-urlencoded');
            Client.Post(Res.Url, Res.Data);
          finally
            Client.RequestBody := nil;
            Body.Free;
          end;
        end
        else
        begin
          // retry on 429/503 (server rate limit, e.g. Wikimedia)
          // with an increasing delay
          Attempt := 0;
          while True do
          begin
            Res.Data.Clear;
            try
              Client.Get(Res.Url, Res.Data);
              Break;
            except
              on E: EHTTPClient do
              begin
                if ((Client.ResponseStatusCode = 429) or
                    (Client.ResponseStatusCode = 503)) and (Attempt < 6) then
                begin
                  Inc(Attempt);
                  Sleep(500 * Attempt + Random(400));
                end
                else
                  raise;
              end;
            end;
          end;
        end;
        Res.Data.Position := 0;
        // capture Content-Type header - carries the charset for HTML
        Encoding := '';
        for I := 0 to Client.ResponseHeaders.Count - 1 do
          if SameText(Copy(Client.ResponseHeaders[I], 1, 13),
            'Content-Type:') then
            Res.ContentType :=
              Trim(Copy(Client.ResponseHeaders[I], 14, MaxInt))
          else if SameText(Copy(Client.ResponseHeaders[I], 1, 17),
            'Content-Encoding:') then
            Encoding := Trim(Copy(Client.ResponseHeaders[I], 18, MaxInt));
        DecodeContentEncoding(Encoding, Res.Data);
        Res.State := rsLoaded;
      finally
        Client.Free;
      end;
    end
    else
    begin
      // local file
      Path := FileUrlToPath(Res.Url);
      if not FileExists(Path) then
      begin
        Res.State := rsError;
        Res.ErrorMsg := 'File not found: ' + Path;
        Exit;
      end;
      FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
      try
        Res.Data.CopyFrom(FS, 0);
        Res.Data.Position := 0;
        Res.State := rsLoaded;
      finally
        FS.Free;
      end;
    end;
  except
    on E: Exception do
    begin
      Res.State := rsError;
      Res.ErrorMsg := E.Message;
    end;
  end;
end;

procedure TDownloadThread.Execute;
var
  Res: TResource;
begin
  while not Terminated do
  begin
    Res := FMgr.Pop(FResType);
    if Res = nil then
    begin
      FMgr.FEvents[FResType].WaitFor(500);
      Continue;
    end;
    Res.State := rsLoading;
    Download(Res);
    if not Terminated then
      FMgr.NotifyLoaded(Res);
  end;
end;

// TResourceManager

constructor TResourceManager.Create;
var
  RT: TResourceType;
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FUserAgent := DEFAULT_USER_AGENT;
  FAll := TDictionary<string, TResource>.Create;
  FThreads := TList<TDownloadThread>.Create;
  for RT := Low(TResourceType) to High(TResourceType) do
  begin
    FQueues[RT] := TQueue<TResource>.Create;
    {$IFDEF UNIX}
    // without a thread manager (cthreads) FPC cannot create events or threads
    try
      FEvents[RT] := TEvent.Create(nil, False, False, '');
    except
      on E: Exception do
        raise Exception.Create('TXelHtml needs threads: add {$IFDEF UNIX}cthreads,' +
          '{$ENDIF} as the first unit in the uses clause of the program (' +
          E.Message + ')');
    end;
    {$ELSE}
    FEvents[RT] := TEvent.Create(nil, False, False, '');
    {$ENDIF}
  end;

  // one thread each for HTML, JS, CSS and fonts; images — five
  FThreads.Add(TDownloadThread.Create(Self, rtHtml));
  FThreads.Add(TDownloadThread.Create(Self, rtJS));
  FThreads.Add(TDownloadThread.Create(Self, rtCSS));
  FThreads.Add(TDownloadThread.Create(Self, rtFont));
  for I := 1 to IMAGE_THREADS do
    FThreads.Add(TDownloadThread.Create(Self, rtImage));
end;

destructor TResourceManager.Destroy;
var
  I: Integer;
  RT: TResourceType;
  Res: TResource;
begin
  FShutdown := True;
  for I := 0 to FThreads.Count - 1 do
    FThreads[I].Terminate;
  for RT := Low(TResourceType) to High(TResourceType) do
    FEvents[RT].SetEvent;
  for I := 0 to FThreads.Count - 1 do
  begin
    FEvents[FThreads[I].FResType].SetEvent;
    FThreads[I].WaitFor;
    FThreads[I].Free;
  end;
  FThreads.Free;
  for RT := Low(TResourceType) to High(TResourceType) do
  begin
    FQueues[RT].Free;
    FEvents[RT].Free;
  end;
  for Res in FAll.Values do
    Res.Free;
  FAll.Free;
  FLock.Free;
  inherited Destroy;
end;

function TResourceManager.Enqueue(const AUrl: string; AType: TResourceType;
  const ATag: string): TResource;
begin
  FLock.Acquire;
  try
    if FAll.TryGetValue(AUrl, Result) then
    begin
      if (ATag <> '') and (Result.Tag = '') then
        Result.Tag := ATag;
      Exit;
    end;
    Result := TResource.Create(AUrl, AType);
    Result.Tag := ATag;
    FAll.Add(AUrl, Result);
    FQueues[AType].Enqueue(Result);
  finally
    FLock.Release;
  end;
  FEvents[AType].SetEvent;
end;

function TResourceManager.EnqueuePost(const AUrl: string;
  const ABody: RawByteString): TResource;
begin
  FLock.Acquire;
  try
    Inc(FPostSeq);
    Result := TResource.Create(AUrl, rtHtml);
    Result.Method := 'POST';
    Result.PostBody := ABody;
    // a unique key: the resource is owned by FAll but never matched by URL
    FAll.Add(#1'POST#' + IntToStr(FPostSeq) + ' ' + AUrl, Result);
    FQueues[rtHtml].Enqueue(Result);
  finally
    FLock.Release;
  end;
  FEvents[rtHtml].SetEvent;
end;

function TResourceManager.GetUserAgent: string;
begin
  FLock.Acquire;
  try
    Result := FUserAgent;
    UniqueString(Result); // the caller may be another thread
  finally
    FLock.Release;
  end;
end;

procedure TResourceManager.SetUserAgent(const AValue: string);
begin
  FLock.Acquire;
  try
    FUserAgent := AValue;
    UniqueString(FUserAgent);
  finally
    FLock.Release;
  end;
end;

function TResourceManager.Find(const AUrl: string): TResource;
begin
  FLock.Acquire;
  try
    if not FAll.TryGetValue(AUrl, Result) then
      Result := nil;
  finally
    FLock.Release;
  end;
end;

procedure TResourceManager.Forget(const AUrl: string);
var
  Res: TResource;
begin
  FLock.Acquire;
  try
    if FAll.TryGetValue(AUrl, Res) and (Res.State in [rsLoaded, rsError]) then
    begin
      FAll.Remove(AUrl);
      Res.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TResourceManager.PendingCount: Integer;
var
  Res: TResource;
begin
  Result := 0;
  FLock.Acquire;
  try
    for Res in FAll.Values do
      if Res.State in [rsQueued, rsLoading] then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TResourceManager.Pop(AType: TResourceType): TResource;
begin
  FLock.Acquire;
  try
    if FQueues[AType].Count > 0 then
    begin
      Result := FQueues[AType].Dequeue;
      // wake the other threads of this type if anything is still waiting
      if FQueues[AType].Count > 0 then
        FEvents[AType].SetEvent;
    end
    else
      Result := nil;
  finally
    FLock.Release;
  end;
end;

procedure TResourceManager.NotifyLoaded(Res: TResource);
var
  N: TResourceNotify;
begin
  if FShutdown then
    Exit;
  N := FNotify;
  if Assigned(N) then
    N(Res); // note: worker thread context
end;

end.
