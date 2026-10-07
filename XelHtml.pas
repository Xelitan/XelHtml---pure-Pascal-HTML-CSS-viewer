unit XelHtml;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// TXelHtml — an HTML + CSS rendering control: drop it on a form and build any
// kind of web browser around it. It has no navigation bar; it only shows the
// page (with its own scroll bars), handles links, forms, keyboard and mouse,
// keeps the navigation history and reports everything through events.
//
// Main thread: parses HTML, computes the layout and renders. When the
// download threads (XelNet) report a new resource, the notification arrives
// via Application.QueueAsyncCall; the control updates its state (parses CSS,
// decodes the image, registers the font) and repeats layout + painting.
// The document is kept in a TDOMDocument — future JS will be able to modify
// it with DOM methods, and a change of the document version forces a re-render.

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, StdCtrls, ExtCtrls, Forms, Menus,
  LCLType, Generics.Collections,
  XelDom, XelCssParser, XelStyle, XelNet, XelLayout, XelRender;

type
  // Before navigation: set Abort := True to cancel it.
  // URL = the address the control wants to go to (already resolved).
  TXelHtmlNavigateEvent = procedure(Sender: TObject; const URL: string;
    var Abort: Boolean) of object;
  // Events with a single address (e.g. document loaded, hovering over a link).
  TXelHtmlUrlEvent = procedure(Sender: TObject; const URL: string) of object;
  // Events with text (e.g. title change, status text change).
  TXelHtmlTextEvent = procedure(Sender: TObject; const Text: string) of object;
  // A page or resource failed to load.
  TXelHtmlErrorEvent = procedure(Sender: TObject;
    const URL, ErrorMsg: string) of object;
  // Loading progress: Pending = number of resources still downloading (0 = idle).
  TXelHtmlProgressEvent = procedure(Sender: TObject; Pending: Integer) of object;

  // Kind of sub-resource (for OnResourceRequest).
  TXelHtmlResourceKind = (hrkCss, hrkJs, hrkFont, hrkImage);
  // Before a sub-resource is fetched. The URL may be changed or Abort set.
  TXelHtmlResourceEvent = procedure(Sender: TObject; Kind: TXelHtmlResourceKind;
    var URL: string; var Abort: Boolean) of object;

  // Form submission (submit button or Enter in a text field).
  // Action = resolved target URL (for GET it already carries the ?query),
  // Method = 'GET' or 'POST', Data = urlencoded form data.
  TXelHtmlFormSubmitEvent = procedure(Sender: TObject;
    const Action, Method, Data: string; var Abort: Boolean) of object;

  // Right mouse button. Set Handled := True if handled.
  TXelHtmlContextMenuEvent = procedure(Sender: TObject; X, Y: Integer;
    const LinkURL, ImageURL: string; var Handled: Boolean) of object;

  // Keyboard commands of the control.
  TXelHtmlCommand = (hcReload, hcBack, hcForward, hcFocusAddress,
    hcScrollUp, hcScrollDown, hcPageUp, hcPageDown, hcHome, hcEnd);
  TXelHtmlCommandEvent = procedure(Sender: TObject; Command: TXelHtmlCommand;
    var Handled: Boolean) of object;

  // TXelHtml

  TXelHtml = class(TCustomControl)
  private
    FPaintBox: TPaintBox;
    FVScroll: TScrollBar;
    FHScroll: TScrollBar;
    FTimer: TTimer;
    FSelectMenu: TPopupMenu;
    FBuffer: TBitmap;

    // navigation history
    FHistory: TStringList;
    FHistPos: Integer;
    FNavFromHistory: Boolean;
    FHoverLink: string;
    FDocUrl: string; // URL of the loaded document (before <base> override)
    FStatusText: string;
    FUserAgent: string;

    FDoc: TDOMDocument;
    FDocVersionRendered: Integer;
    FBaseUrl: string;

    FMgr: TResourceManager; // created on first use (never at design time)
    FSheets: TObjectList<TCssStyleSheet>;
    FSheetByUrl: TDictionary<string, TCssStyleSheet>;
    FResolver: TStyleResolver;
    FEngine: TLayoutEngine;
    FRenderer: TRenderer;

    FPics: TDictionary<string, TPicture>;
    FSvgText: TDictionary<string, string>;  // SVG images (URL -> text), rasterized in the renderer
    FScripts: TStringList;     // loaded JS files: url=size
    FLoadedFontUrls: TStringList;
    FNeedRelayout: Boolean;
    FLastPending: Integer;

    // form controls
    FFocusEl: TDOMElement;     // text field with keyboard focus (nil = none)
    FSelectEl: TDOMElement;    // <select> whose option menu is open
    // state for the dynamic CSS pseudo-classes :hover and :target
    FHoverEl: TDOMElement;
    FTargetId: string;

    FOnNavigate: TXelHtmlNavigateEvent;
    FOnLocationChange: TXelHtmlUrlEvent;
    FOnDocumentComplete: TXelHtmlUrlEvent;
    FOnTitleChange: TXelHtmlTextEvent;
    FOnLinkHover: TXelHtmlUrlEvent;
    FOnStatusChange: TXelHtmlTextEvent;
    FOnLoadError: TXelHtmlErrorEvent;
    FOnNewWindow: TXelHtmlNavigateEvent;
    FOnProgress: TXelHtmlProgressEvent;
    FOnResourceRequest: TXelHtmlResourceEvent;
    FOnFormSubmit: TXelHtmlFormSubmitEvent;
    FOnContextMenu: TXelHtmlContextMenuEvent;
    FOnCommand: TXelHtmlCommandEvent;
    FOnHistoryChange: TNotifyEvent;

    function Mgr: TResourceManager;
    function GetTitle: string;
    function GetPendingCount: Integer;
    function GetDocHeight: Integer;
    function GetDocWidth: Integer;
    function GetScrollX: Integer;
    function GetScrollY: Integer;
    procedure SetScrollX(AValue: Integer);
    procedure SetScrollY(AValue: Integer);
    procedure SetUserAgent(const AValue: string);

    procedure PaintBoxPaint(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure PaintBoxMouseLeave(Sender: TObject);
    procedure ScrollChanged(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure PushHistory(const Url: string);
    procedure HistoryChanged;
    procedure ApplyCssGlobals;

    // event dispatch
    function DoNavigate(const URL: string): Boolean; // False = cancelled
    procedure NavigateCore(const Target: string);    // actual loading
    procedure SetStatus(const S: string);            // StatusText + OnStatusChange
    procedure SetLocation(const URL: string);        // OnLocationChange
    procedure DoLoadError(const URL, Msg: string);   // OnLoadError + status text
    // Fetches a sub-resource via OnResourceRequest (Abort/URL change).
    // Returns nil when blocked.
    function EnqueueRes(const URL: string; Kind: TResourceType;
      const Tag: string = ''): TResource;
    function DoCommand(Cmd: TXelHtmlCommand): Boolean; // True = handled by the handler
    procedure HandleClickAt(X, Y: Integer);          // left button: link/submit/new-window
    procedure HandleContextAt(X, Y: Integer);        // right button: OnContextMenu
    // form controls: focus, typing, checkboxes, <select> menu, submission
    function HandleControlClick(E: TDOMElement): Boolean;
    procedure SetFocusElement(E: TDOMElement);
    procedure SetHoverElement(E: TDOMElement);
    procedure ShowSelectMenu(Select: TDOMElement; X, Y: Integer);
    procedure SelectMenuClick(Sender: TObject);
    procedure SubmitForm(Form, Submitter: TDOMElement);
    procedure EditFocused(const Key: string);

    // resource notifications
    procedure ResourceLoadedThreaded(Res: TResource); // worker thread context!
    procedure AsyncResourceLoaded(Data: PtrInt);      // main thread
    procedure HandleResource(Res: TResource);
    procedure HandleCss(Res: TResource);
    procedure HandleCssResources(Sheet: TCssStyleSheet);
    procedure HandleImage(Res: TResource);
    procedure HandleFont(Res: TResource);

    procedure ScanResources;
    procedure AddDataUrlImage(const DataUrl: string);
    procedure UpdateStatus;
    function PageBackground: TColor;

    // callbacks for the layout engine and the renderer
    function GetImageSize(const Url: string; out W, H: Integer): Boolean;
    function GetPicture(const Url: string): TPicture;
    function GetSvg(const Url: string): string;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    class function GetControlClassDefaultSize: TSize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Loads a page: http(s):// URL or a local file path. Fires OnNavigate first.
    procedure Navigate(const URL: string);
    // Reads an HTML document from a stream. ABaseUrl resolves relative links
    // and resources; ACharset = charset from an HTTP header ('' = autodetect).
    procedure LoadFromStream(S: TStream; const ABaseUrl: string = '';
      const ACharset: string = '');
    // Shows HTML given as a (UTF-8) string.
    procedure LoadFromString(const AHtml: string; const ABaseUrl: string = '');
    procedure LoadFromFile(const FileName: string);
    procedure Reload;          // fetches the current page again
    procedure GoBack;
    procedure GoForward;
    function CanGoBack: Boolean;
    function CanGoForward: Boolean;
    // Runs the built-in action of a command (without firing OnCommand).
    procedure ExecuteCommand(Cmd: TXelHtmlCommand);
    procedure ScrollTo(X, Y: Integer);
    procedure ScrollBy(DX, DY: Integer);
    // Scrolls to the element with the given id (or <a name>). False = not found.
    function ScrollToAnchor(const Id: string): Boolean;
    // Lays the document out and repaints it (normally done automatically).
    procedure Relayout;
    // What is under a point given in client coordinates of the control.
    function HitTest(X, Y: Integer): THitInfo;

    property Document: TDOMDocument read FDoc;
    property URL: string read FDocUrl;           // current document
    property BaseUrl: string read FBaseUrl;      // after <base href>
    property Title: string read GetTitle;
    property StatusText: string read FStatusText;
    property PendingCount: Integer read GetPendingCount;
    property DocumentHeight: Integer read GetDocHeight;
    property DocumentWidth: Integer read GetDocWidth;
    property ScrollX: Integer read GetScrollX write SetScrollX;
    property ScrollY: Integer read GetScrollY write SetScrollY;
    property History: TStringList read FHistory; // visited URLs, oldest first
    property HistoryIndex: Integer read FHistPos;
  published
    property Align;
    property Anchors;
    property BorderSpacing;
    property Constraints;
    property Enabled;
    property ParentShowHint;
    property ShowHint;
    property TabOrder;
    property TabStop default True;
    property Visible;
    // User-Agent header sent with every request.
    property UserAgent: string read FUserAgent write SetUserAgent;

    property OnEnter;
    property OnExit;
    property OnKeyDown;
    property OnResize;

    // Before every navigation (link click, back/forward, form, Navigate call).
    // Set Abort := True to cancel.
    property OnNavigate: TXelHtmlNavigateEvent read FOnNavigate write FOnNavigate;
    // The address of the shown page changed (navigation started or finished) —
    // the place to update an address bar.
    property OnLocationChange: TXelHtmlUrlEvent
      read FOnLocationChange write FOnLocationChange;
    // The document is parsed and laid out (resources may still be loading).
    property OnDocumentComplete: TXelHtmlUrlEvent
      read FOnDocumentComplete write FOnDocumentComplete;
    // The document title (<title>) changed.
    property OnTitleChange: TXelHtmlTextEvent
      read FOnTitleChange write FOnTitleChange;
    // The cursor moved over a link (URL) or left it ('').
    property OnLinkHover: TXelHtmlUrlEvent read FOnLinkHover write FOnLinkHover;
    // The status text changed (loading progress, link under the cursor...).
    property OnStatusChange: TXelHtmlTextEvent
      read FOnStatusChange write FOnStatusChange;
    // A page or resource could not be loaded.
    property OnLoadError: TXelHtmlErrorEvent read FOnLoadError write FOnLoadError;
    // Click on a link with target="_blank"/"_new". Without a handler the link
    // opens in this control.
    property OnNewWindow: TXelHtmlNavigateEvent
      read FOnNewWindow write FOnNewWindow;
    // The number of downloading resources changed (Pending; 0 = finished).
    property OnProgress: TXelHtmlProgressEvent read FOnProgress write FOnProgress;
    // Before a sub-resource (CSS/JS/font/image) is fetched. The URL may be
    // changed or Abort := True set to block it (e.g. ad-block).
    property OnResourceRequest: TXelHtmlResourceEvent
      read FOnResourceRequest write FOnResourceRequest;
    // A form is submitted. Abort := True cancels it.
    property OnFormSubmit: TXelHtmlFormSubmitEvent
      read FOnFormSubmit write FOnFormSubmit;
    // Right mouse button. LinkURL/ImageURL = targets under the cursor ('' when none).
    property OnContextMenu: TXelHtmlContextMenuEvent
      read FOnContextMenu write FOnContextMenu;
    // Keyboard commands (F5, Alt+arrows, Ctrl+L, scrolling). Handled := True
    // skips the built-in action. hcFocusAddress (Ctrl+L) has no built-in action.
    property OnCommand: TXelHtmlCommandEvent read FOnCommand write FOnCommand;
    // The history changed (CanGoBack / CanGoForward may differ).
    property OnHistoryChange: TNotifyEvent
      read FOnHistoryChange write FOnHistoryChange;
  end;

procedure Register;

implementation

uses
  Windows, Math, FPImage, FPReadGif, IntfGraphics, GraphType, base64, LazUTF8,
  WebPImageX,     // TWebpImage, the WebP decoder (XelImageFormats package)
  OTF,            // font conversion and handling (WOFF/WOFF2/TTF/SVG -> OTF)
  XelHtmlParser, XelUrl,
  XelSvgImage,    // intrinsic SVG size (rasterization is in XelRender)
  XelForms;       // form controls and submission

{$R txelhtml_images.res}

const
  DEFAULT_USER_AGENT = 'Mozilla/5.0 (compatible; XelHtml/1.0)';

procedure Register;
begin
  RegisterComponents('Xelitan', [TXelHtml]);
end;

// Extract the charset token from a Content-Type header value,
// e.g. 'text/html; charset=ISO-8859-2' -> 'iso-8859-2'.
function CharsetFromContentType(const CT: string): string;
var
  P, E: Integer;
  L: string;
begin
  Result := '';
  L := LowerCase(CT);
  P := Pos('charset=', L);
  if P = 0 then
    Exit;
  P := P + 8;
  while (P <= Length(L)) and (L[P] in ['"', '''', ' ']) do
    Inc(P);
  E := P;
  while (E <= Length(L)) and not (L[E] in ['"', '''', ' ', ';']) do
    Inc(E);
  Result := Copy(L, P, E - P);
end;

// ---- image decoding ----

// Note: SVG is handled earlier in HandleImage (stored as text
// and rasterized in the renderer at display size). Here we decode raster
// formats.
function LoadPictureFromStream(S: TStream): TPicture;
var
  Magic: array[0..11] of AnsiChar;
  Img: TFPMemoryImage;
  Reader: TFPReaderGif;
  IntfImg: TLazIntfImage;
  Bmp: Graphics.TBitmap;
  WebP: TWebpImage;
  X, Y, N: Integer;
begin
  Result := nil;
  S.Position := 0;
  FillChar(Magic, SizeOf(Magic), 0);
  N := Min(S.Size, 12);
  if N > 0 then
    S.ReadBuffer(Magic, N);
  S.Position := 0;

  // WebP: RIFF....WEBP container, decoded by the pure-Pascal WebPImageX
  if (Magic[0] = 'R') and (Magic[1] = 'I') and (Magic[2] = 'F') and
     (Magic[3] = 'F') and (Magic[8] = 'W') and (Magic[9] = 'E') and
     (Magic[10] = 'B') and (Magic[11] = 'P') then
  begin
    WebP := TWebpImage.Create;
    try
      WebP.LoadFromStream(S);
      Result := TPicture.Create;
      Result.Bitmap.Assign(WebP.ToBitmap);
    finally
      WebP.Free;
    end;
    Exit;
  end;

  if (Magic[0] = 'G') and (Magic[1] = 'I') and (Magic[2] = 'F') then
  begin
    // GIF (static, first frame) via fcl-image
    Img := TFPMemoryImage.Create(0, 0);
    Reader := TFPReaderGif.Create;
    try
      Img.LoadFromStream(S, Reader);
      IntfImg := TLazIntfImage.Create(Img.Width, Img.Height,
        [riqfRGB, riqfAlpha]);
      try
        for Y := 0 to Img.Height - 1 do
          for X := 0 to Img.Width - 1 do
            IntfImg.Colors[X, Y] := Img.Colors[X, Y];
        Bmp := Graphics.TBitmap.Create;
        try
          Bmp.LoadFromIntfImage(IntfImg);
          Result := TPicture.Create;
          Result.Assign(Bmp);
        finally
          Bmp.Free;
        end;
      finally
        IntfImg.Free;
      end;
    finally
      Reader.Free;
      Img.Free;
    end;
    Exit;
  end;

  // PNG / JPEG / BMP / ICO — LCL detects the format from the content
  Result := TPicture.Create;
  try
    Result.LoadFromStream(S);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

// Returns the nearest ancestor element with the given tag (or nil).
function AncestorTag(E: TDOMElement; const Tag: string): TDOMElement;
var
  N: TDOMNode;
begin
  Result := nil;
  N := E;
  while N <> nil do
  begin
    if (N is TDOMElement) and SameText(TDOMElement(N).TagName, Tag) then
      Exit(TDOMElement(N));
    N := N.ParentNode;
  end;
end;

// The control a <label> refers to: for="id", else the first control inside it.
function LabelControl(Lbl: TDOMElement): TDOMElement;
const
  Controls: array[0..3] of string = ('input', 'select', 'textarea', 'button');
var
  Tag: string;
begin
  Result := nil;
  if Lbl.GetAttribute('for') <> '' then
    Exit(Lbl.OwnerDocument.GetElementById(Lbl.GetAttribute('for')));
  for Tag in Controls do
  begin
    Result := Lbl.FindFirstByTag(Tag);
    if Result <> nil then
      Exit;
  end;
end;

// maps the CSS cursor to an LCL cursor
function MapCssCursor(C: TCssCursor): TCursor;
begin
  case C of
    ccrPointer: Result := crHandPoint;
    ccrText: Result := crIBeam;
    ccrMove: Result := crSizeAll;
    ccrWait: Result := crHourGlass;
    ccrProgress: Result := crAppStart;
    ccrHelp: Result := crHelp;
    ccrCrosshair: Result := crCross;
    ccrNotAllowed: Result := crNo;
    ccrGrab: Result := crHandPoint;
    ccrColResize: Result := crHSplit;
    ccrRowResize: Result := crVSplit;
    ccrDefault: Result := crDefault;
  else
    Result := crDefault;
  end;
end;

// TXelHtml

class function TXelHtml.GetControlClassDefaultSize: TSize;
begin
  Result.cx := 400;
  Result.cy := 300;
end;

constructor TXelHtml.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csSetCaption, csAcceptsControls];
  with GetControlClassDefaultSize do
    SetInitialBounds(0, 0, cx, cy);
  TabStop := True;
  Color := clWhite;
  FUserAgent := DEFAULT_USER_AGENT;

  FBuffer := Graphics.TBitmap.Create;
  FPics := TDictionary<string, TPicture>.Create;
  FSvgText := TDictionary<string, string>.Create;
  FScripts := TStringList.Create;
  FLoadedFontUrls := TStringList.Create;
  FHistory := TStringList.Create;
  FHistPos := -1;
  FSheets := TObjectList<TCssStyleSheet>.Create(True);
  FSheetByUrl := TDictionary<string, TCssStyleSheet>.Create;

  FResolver := TStyleResolver.Create;
  FEngine := TLayoutEngine.Create;
  FEngine.Resolver := FResolver;
  FEngine.OnGetImageSize := GetImageSize;
  FRenderer := TRenderer.Create;
  FRenderer.Engine := FEngine;
  FRenderer.OnGetPicture := GetPicture;
  FRenderer.OnGetSvg := GetSvg;

  FVScroll := TScrollBar.Create(Self);
  FVScroll.Kind := sbVertical;
  FVScroll.Align := alRight;
  FVScroll.Width := 17;
  FVScroll.Min := 0;
  FVScroll.Max := 0;
  FVScroll.TabStop := False;
  FVScroll.OnChange := ScrollChanged;
  FVScroll.Parent := Self;

  FHScroll := TScrollBar.Create(Self);
  FHScroll.Kind := sbHorizontal;
  FHScroll.Align := alBottom;
  FHScroll.Height := 17;
  FHScroll.Min := 0;
  FHScroll.Max := 0;
  FHScroll.TabStop := False;
  FHScroll.OnChange := ScrollChanged;
  FHScroll.Parent := Self;

  FPaintBox := TPaintBox.Create(Self);
  FPaintBox.Align := alClient;
  FPaintBox.OnPaint := PaintBoxPaint;
  FPaintBox.OnMouseDown := PaintBoxMouseDown;
  FPaintBox.OnMouseMove := PaintBoxMouseMove;
  FPaintBox.OnMouseLeave := PaintBoxMouseLeave;
  FPaintBox.Parent := Self;

  FSelectMenu := TPopupMenu.Create(Self);

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 150;
  FTimer.OnTimer := TimerTick;
  // no downloads, layout timer or threads inside the form designer
  FTimer.Enabled := not (csDesigning in ComponentState);
end;

destructor TXelHtml.Destroy;
var
  Pic: TPicture;
begin
  FTimer.Enabled := False;
  if FMgr <> nil then
  begin
    FMgr.OnLoaded := nil;
    FMgr.Free; // stops and waits for the threads
  end;
  Application.RemoveAsyncCalls(Self);

  FRenderer.Free;
  FEngine.Free;
  FResolver.Free;
  FDoc.Free;
  FSheetByUrl.Free;
  FSheets.Free;
  for Pic in FPics.Values do
    Pic.Free;
  FPics.Free;
  FSvgText.Free;
  FScripts.Free;
  FLoadedFontUrls.Free;
  FHistory.Free;
  FBuffer.Free;
  inherited Destroy;
end;

function TXelHtml.Mgr: TResourceManager;
begin
  if FMgr = nil then
  begin
    FMgr := TResourceManager.Create;
    FMgr.UserAgent := FUserAgent;
    FMgr.OnLoaded := ResourceLoadedThreaded;
  end;
  Result := FMgr;
end;

procedure TXelHtml.SetUserAgent(const AValue: string);
begin
  FUserAgent := AValue;
  if FMgr <> nil then
    FMgr.UserAgent := AValue;
end;

function TXelHtml.GetTitle: string;
begin
  if FDoc <> nil then
    Result := FDoc.Title
  else
    Result := '';
end;

function TXelHtml.GetPendingCount: Integer;
begin
  if FMgr <> nil then
    Result := FMgr.PendingCount
  else
    Result := 0;
end;

function TXelHtml.GetDocHeight: Integer;
begin
  Result := FEngine.DocHeight;
end;

function TXelHtml.GetDocWidth: Integer;
begin
  Result := FEngine.DocWidth;
end;

function TXelHtml.GetScrollX: Integer;
begin
  Result := FHScroll.Position;
end;

function TXelHtml.GetScrollY: Integer;
begin
  Result := FVScroll.Position;
end;

procedure TXelHtml.SetScrollX(AValue: Integer);
begin
  FHScroll.Position := EnsureRange(AValue, 0,
    Max(0, FHScroll.Max - FHScroll.PageSize));
end;

procedure TXelHtml.SetScrollY(AValue: Integer);
begin
  FVScroll.Position := EnsureRange(AValue, 0,
    Max(0, FVScroll.Max - FVScroll.PageSize));
end;

procedure TXelHtml.ScrollTo(X, Y: Integer);
begin
  ScrollX := X;
  ScrollY := Y;
end;

procedure TXelHtml.ScrollBy(DX, DY: Integer);
begin
  ScrollTo(ScrollX + DX, ScrollY + DY);
end;

function TXelHtml.ScrollToAnchor(const Id: string): Boolean;
var
  AnchorY: Integer;
begin
  FTargetId := Id;      // :target follows the anchor
  FNeedRelayout := True;
  Result := FEngine.FindAnchorY(Id, AnchorY);
  if Result then
    ScrollY := AnchorY;
end;

function TXelHtml.HitTest(X, Y: Integer): THitInfo;
begin
  Result := FEngine.HitTest(X + ScrollX, Y + ScrollY);
end;

// ---- events ----

// Fires OnNavigate; returns False when the handler set Abort := True.
function TXelHtml.DoNavigate(const URL: string): Boolean;
var
  Abort: Boolean;
begin
  Result := True;
  if Assigned(FOnNavigate) then
  begin
    Abort := False;
    FOnNavigate(Self, URL, Abort);
    Result := not Abort;
  end;
end;

procedure TXelHtml.SetStatus(const S: string);
begin
  if S = FStatusText then
    Exit;
  FStatusText := S;
  if Assigned(FOnStatusChange) then
    FOnStatusChange(Self, S);
end;

procedure TXelHtml.SetLocation(const URL: string);
begin
  if Assigned(FOnLocationChange) then
    FOnLocationChange(Self, URL);
end;

procedure TXelHtml.DoLoadError(const URL, Msg: string);
begin
  SetStatus(Msg);
  if Assigned(FOnLoadError) then
    FOnLoadError(Self, URL, Msg);
end;

// Fires OnCommand; True = the application handled it (skip the built-in action).
function TXelHtml.DoCommand(Cmd: TXelHtmlCommand): Boolean;
begin
  Result := False;
  if Assigned(FOnCommand) then
    FOnCommand(Self, Cmd, Result);
end;

// Fires OnResourceRequest (which may change the URL/block it), then
// queues the resource. Returns nil when blocked.
function TXelHtml.EnqueueRes(const URL: string; Kind: TResourceType;
  const Tag: string): TResource;
const
  KindMap: array[TResourceType] of TXelHtmlResourceKind =
    (hrkCss, hrkJs, hrkCss, hrkFont, hrkImage); // rtHtml unused -> hrkCss
var
  U: string;
  Abort: Boolean;
begin
  U := URL;
  if Assigned(FOnResourceRequest) and (Kind <> rtHtml) then
  begin
    Abort := False;
    FOnResourceRequest(Self, KindMap[Kind], U, Abort);
    if Abort or (Trim(U) = '') then
      Exit(nil);
  end;
  Result := Mgr.Enqueue(U, Kind, Tag);
end;

// ---- navigation ----

procedure TXelHtml.Navigate(const URL: string);
var
  T: string;
begin
  T := Trim(URL);
  if T = '' then
    Exit;
  if not DoNavigate(T) then
    Exit; // cancelled by OnNavigate
  NavigateCore(T);
end;

// Actual loading — without firing OnNavigate (the caller has done that).
procedure TXelHtml.NavigateCore(const Target: string);
var
  T: string;
  Res: TResource;
begin
  T := Trim(Target);
  if T = '' then
    Exit;
  SetLocation(T);

  if IsHttpUrl(T) or IsHttpsUrl(T) then
  begin
    SetStatus('Loading: ' + T);
    Res := Mgr.Enqueue(T, rtHtml);
    if Res.State = rsLoaded then
      HandleResource(Res); // already in the cache
    Exit;
  end;

  // local file
  if SameText(Copy(T, 1, 8), 'file:///') then
    T := StringReplace(Copy(T, 9, MaxInt), '/', '\', [rfReplaceAll]);
  if not FileExists(T) then
  begin
    DoLoadError(T, 'File not found: ' + T);
    Exit;
  end;
  LoadFromFile(T);
end;

procedure TXelHtml.LoadFromFile(const FileName: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadFromStream(FS, ExpandFileName(FileName));
  finally
    FS.Free;
  end;
end;

procedure TXelHtml.LoadFromString(const AHtml: string; const ABaseUrl: string);
var
  SS: TStringStream;
begin
  SS := TStringStream.Create(AHtml);
  try
    LoadFromStream(SS, ABaseUrl, 'utf-8');
  finally
    SS.Free;
  end;
end;

procedure TXelHtml.Reload;
begin
  if FDocUrl = '' then
    Exit;
  if FMgr <> nil then
    FMgr.Forget(FDocUrl); // force a fresh fetch of the page itself
  FNavFromHistory := True; // do not duplicate the history entry
  Navigate(FDocUrl);
end;

// ---- navigation history ----

procedure TXelHtml.HistoryChanged;
begin
  if Assigned(FOnHistoryChange) then
    FOnHistoryChange(Self);
end;

procedure TXelHtml.PushHistory(const Url: string);
begin
  if FNavFromHistory then
  begin
    FNavFromHistory := False;
    HistoryChanged;
    Exit;
  end;
  if Url = '' then
    Exit; // documents loaded from a string/stream without a URL
  // drop the forward part after a fresh navigation
  while FHistory.Count > FHistPos + 1 do
    FHistory.Delete(FHistory.Count - 1);
  if (FHistory.Count = 0) or (FHistory[FHistory.Count - 1] <> Url) then
    FHistory.Add(Url);
  FHistPos := FHistory.Count - 1;
  HistoryChanged;
end;

function TXelHtml.CanGoBack: Boolean;
begin
  Result := FHistPos > 0;
end;

function TXelHtml.CanGoForward: Boolean;
begin
  Result := FHistPos < FHistory.Count - 1;
end;

procedure TXelHtml.GoBack;
begin
  if not CanGoBack then
    Exit;
  // fire OnNavigate before changing the position — cancelling does not break the history
  if not DoNavigate(FHistory[FHistPos - 1]) then
    Exit;
  Dec(FHistPos);
  FNavFromHistory := True;
  NavigateCore(FHistory[FHistPos]);
end;

procedure TXelHtml.GoForward;
begin
  if not CanGoForward then
    Exit;
  if not DoNavigate(FHistory[FHistPos + 1]) then
    Exit;
  Inc(FHistPos);
  FNavFromHistory := True;
  NavigateCore(FHistory[FHistPos]);
end;

// ---- mouse ----

procedure TXelHtml.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if csDesigning in ComponentState then
    Exit;
  if CanSetFocus and not Focused then
    SetFocus;
  if Button = mbLeft then
    HandleClickAt(X, Y)
  else if Button = mbRight then
    HandleContextAt(X, Y);
end;

procedure TXelHtml.SetFocusElement(E: TDOMElement);
begin
  if E = FFocusEl then
    Exit;
  FFocusEl := E;
  if (E <> nil) and CanSetFocus and not Focused then
    SetFocus; // keys go to the page
  if GUsesFocus then
    FNeedRelayout := True; // :focus / :focus-within rules may change
  FPaintBox.Invalidate;
end;

procedure TXelHtml.SetHoverElement(E: TDOMElement);
begin
  if E = FHoverEl then
    Exit;
  FHoverEl := E;
  if GUsesHover then
    FNeedRelayout := True; // applied by the timer, so fast mouse moves are batched
end;

procedure TXelHtml.PaintBoxMouseLeave(Sender: TObject);
begin
  SetHoverElement(nil);
end;

// Handles a click on a form control (or its <label>). True = consumed.
function TXelHtml.HandleControlClick(E: TDOMElement): Boolean;
var
  Form: TDOMElement;
  P: TPoint;
begin
  Result := False;
  if (E = nil) or IsDisabled(E) then
    Exit;
  if IsTextControl(E) then
  begin
    SetFocusElement(E);
    Exit(True);
  end;
  if IsCheckable(E) then
  begin
    SetFocusElement(nil);
    ToggleCheckable(E); // the DOM change triggers relayout + repaint
    Exit(True);
  end;
  if IsSelect(E) then
  begin
    SetFocusElement(nil);
    P := FPaintBox.ScreenToClient(Mouse.CursorPos);
    ShowSelectMenu(E, P.X, P.Y);
    Exit(True);
  end;
  if IsSubmitButton(E) then
  begin
    SetFocusElement(nil);
    Form := OwnerForm(E);
    if Form <> nil then
      SubmitForm(Form, E);
    Exit(True);
  end;
end;

procedure TXelHtml.ShowSelectMenu(Select: TDOMElement; X, Y: Integer);
var
  Opts: TList<TDOMElement>;
  Cur: TDOMElement;
  Item: TMenuItem;
  I: Integer;
  P: TPoint;
begin
  FSelectMenu.Items.Clear;
  FSelectEl := Select;
  Cur := SelectedOption(Select);
  Opts := TList<TDOMElement>.Create;
  try
    GetOptions(Select, Opts);
    for I := 0 to Opts.Count - 1 do
    begin
      Item := TMenuItem.Create(FSelectMenu);
      Item.Caption := OptionLabel(Opts[I]);
      Item.Tag := PtrInt(Opts[I]);
      Item.Checked := Opts[I] = Cur;
      Item.RadioItem := True;
      Item.Enabled := not Opts[I].HasAttribute('disabled');
      Item.OnClick := SelectMenuClick;
      FSelectMenu.Items.Add(Item);
    end;
  finally
    Opts.Free;
  end;
  if FSelectMenu.Items.Count = 0 then
    Exit;
  P := FPaintBox.ClientToScreen(Classes.Point(X, Y)); // Windows.POINT shadows Point()
  FSelectMenu.PopUp(P.X, P.Y);
end;

procedure TXelHtml.SelectMenuClick(Sender: TObject);
begin
  // the menu is modal: the document cannot change while it is open
  if (FSelectEl <> nil) and (Sender is TMenuItem) then
    SelectOption(FSelectEl, TDOMElement(TMenuItem(Sender).Tag));
  FSelectEl := nil;
end;

procedure TXelHtml.SubmitForm(Form, Submitter: TDOMElement);
var
  Method, Url, Body: string;
  Abort: Boolean;
begin
  PrepareSubmission(Form, Submitter, FBaseUrl, Method, Url, Body);
  if Assigned(FOnFormSubmit) then
  begin
    Abort := False;
    if Method = 'GET' then
      FOnFormSubmit(Self, Url, Method, Copy(Url, Pos('?', Url) + 1, MaxInt), Abort)
    else
      FOnFormSubmit(Self, Url, Method, Body, Abort);
    if Abort then
      Exit;
  end;
  if Method = 'GET' then
    Navigate(Url)
  else if IsHttpUrl(Url) or IsHttpsUrl(Url) then
  begin
    if not DoNavigate(Url) then
      Exit;
    SetLocation(Url);
    SetStatus('Submitting: ' + Url);
    Mgr.EnqueuePost(Url, Body);
  end
  else
    DoLoadError(Url, 'POST is only supported for http:// and https:// addresses');
end;

procedure TXelHtml.HandleClickAt(X, Y: Integer);
var
  Hit: THitInfo;
  Href, Target, ATarget: string;
  LabelEl: TDOMElement;
  Abort: Boolean;
begin
  Hit := HitTest(X, Y);

  // form controls (also through their <label>)
  if Hit.IsControl and HandleControlClick(Hit.Element) then
    Exit;
  if (Hit.Element <> nil) and (Hit.LinkHref = '') then
  begin
    LabelEl := AncestorTag(Hit.Element, 'label');
    if (LabelEl <> nil) and HandleControlClick(LabelControl(LabelEl)) then
      Exit;
  end;
  SetFocusElement(nil);

  Href := Hit.LinkHref;
  if Href = '' then
    Exit;
  if Href[1] = '#' then
  begin
    // in-page anchor - scroll to the target and update :target
    ScrollToAnchor(Copy(Href, 2, MaxInt));
    Exit;
  end;
  Target := ResolveUrl(FBaseUrl, Href);

  // target="_blank"/"_new" -> OnNewWindow
  ATarget := LowerCase(Trim(Hit.LinkTarget));
  if (ATarget = '_blank') or (ATarget = '_new') then
  begin
    if Assigned(FOnNewWindow) then
    begin
      Abort := False;
      FOnNewWindow(Self, Target, Abort);
      Exit; // handled (or cancelled) by the application
    end;
    // no handler: open in this control
  end;

  Navigate(Target);
end;

procedure TXelHtml.HandleContextAt(X, Y: Integer);
var
  Hit: THitInfo;
  LinkURL, ImageURL: string;
  Handled: Boolean;
begin
  if not Assigned(FOnContextMenu) then
    Exit;
  Hit := HitTest(X, Y);
  LinkURL := '';
  if Hit.LinkHref <> '' then LinkURL := ResolveUrl(FBaseUrl, Hit.LinkHref);
  ImageURL := '';
  if Hit.ImageUrl <> '' then ImageURL := ResolveUrl(FBaseUrl, Hit.ImageUrl);
  Handled := False;
  FOnContextMenu(Self, X, Y, LinkURL, ImageURL, Handled);
end;

procedure TXelHtml.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  Href: string;
  PageX, PageY: Integer;
  Cur: TCssCursor;
begin
  if FEngine.Root = nil then
    Exit;
  PageX := X + ScrollX;
  PageY := Y + ScrollY;
  Href := FEngine.HitTestLink(PageX, PageY);
  if GUsesHover then
    SetHoverElement(FEngine.HitTest(PageX, PageY).Element);

  // the CSS cursor wins; otherwise a hand over a link, else the default
  Cur := FEngine.CursorAt(PageX, PageY);
  if Cur <> ccrAuto then
    FPaintBox.Cursor := MapCssCursor(Cur)
  else if Href <> '' then
    FPaintBox.Cursor := crHandPoint
  else
    FPaintBox.Cursor := crDefault;

  if Href <> FHoverLink then
  begin
    FHoverLink := Href;
    if Href = '' then
    begin
      UpdateStatus;
      if Assigned(FOnLinkHover) then FOnLinkHover(Self, '');
    end
    else
    begin
      SetStatus(ResolveUrl(FBaseUrl, Href));
      if Assigned(FOnLinkHover) then FOnLinkHover(Self, ResolveUrl(FBaseUrl, Href));
    end;
  end;
end;

function TXelHtml.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  if not Result then
  begin
    if ssShift in Shift then
      ScrollBy(-Sign(WheelDelta) * 120, 0)
    else
      ScrollBy(0, -Sign(WheelDelta) * 120);
    Result := True;
  end;
end;

// ---- keyboard ----

procedure TXelHtml.ExecuteCommand(Cmd: TXelHtmlCommand);
var
  Page: Integer;
begin
  Page := Max(40, FPaintBox.ClientHeight - 40);
  case Cmd of
    hcReload: Reload;
    hcBack: GoBack;
    hcForward: GoForward;
    hcFocusAddress: ; // the address bar belongs to the application
    hcScrollUp: ScrollBy(0, -40);
    hcScrollDown: ScrollBy(0, 40);
    hcPageUp: ScrollBy(0, -Page);
    hcPageDown: ScrollBy(0, Page);
    hcHome: ScrollY := 0;
    hcEnd: ScrollY := MaxInt div 2;
  end;
end;

procedure TXelHtml.KeyDown(var Key: Word; Shift: TShiftState);

  procedure Command(Cmd: TXelHtmlCommand);
  begin
    if not DoCommand(Cmd) then
      ExecuteCommand(Cmd);
    Key := 0;
  end;

begin
  inherited KeyDown(Key, Shift); // OnKeyDown may consume the key
  if Key = 0 then
    Exit;
  if Key = VK_F5 then
    Command(hcReload)
  else if (ssCtrl in Shift) and (Key = VK_L) then
    Command(hcFocusAddress)
  else if (ssAlt in Shift) and (Key = VK_LEFT) then
    Command(hcBack)
  else if (ssAlt in Shift) and (Key = VK_RIGHT) then
    Command(hcForward)
  else if Shift * [ssAlt, ssCtrl] = [] then
    case Key of
      VK_UP: Command(hcScrollUp);
      VK_DOWN: Command(hcScrollDown);
      VK_PRIOR: Command(hcPageUp);
      VK_NEXT: Command(hcPageDown);
      VK_HOME: if FFocusEl = nil then Command(hcHome);
      VK_END: if FFocusEl = nil then Command(hcEnd);
      VK_SPACE: if FFocusEl = nil then Command(hcPageDown);
    end;
end;

procedure TXelHtml.UTF8KeyPress(var UTF8Key: TUTF8Char);
begin
  inherited UTF8KeyPress(UTF8Key);
  if FFocusEl = nil then
    Exit;
  if (UTF8Key = #8) or (UTF8Key = #13) or (UTF8Key >= ' ') then
    EditFocused(UTF8Key);
  if UTF8Key = #27 then
    SetFocusElement(nil);
  UTF8Key := '';
end;

// Applies one key to the focused text field: a character, #8 (backspace),
// #13 (Enter: new line in <textarea>, otherwise submits the form).
procedure TXelHtml.EditFocused(const Key: string);
var
  V: string;
  Form: TDOMElement;
begin
  if (FFocusEl = nil) or FFocusEl.HasAttribute('readonly') then
    Exit;
  V := GetControlValue(FFocusEl);
  if Key = #8 then
  begin
    if V <> '' then
      UTF8Delete(V, UTF8Length(V), 1);
  end
  else if Key = #13 then
  begin
    if FFocusEl.TagName = 'textarea' then
      V := V + #10
    else
    begin
      // implicit submission
      Form := OwnerForm(FFocusEl);
      if Form <> nil then
        SubmitForm(Form, nil);
      Exit;
    end;
  end
  else
  begin
    if (FFocusEl.TagName = 'input') and
       (StrToIntDef(FFocusEl.GetAttribute('maxlength'), -1) >= 0) and
       (UTF8Length(V) >= StrToInt(FFocusEl.GetAttribute('maxlength'))) then
      Exit;
    V := V + Key;
  end;
  SetControlValue(FFocusEl, V);
  Relayout; // immediate feedback instead of waiting for the timer
end;

procedure TXelHtml.DoEnter;
begin
  inherited DoEnter;
  FPaintBox.Invalidate; // the caret of a focused field is shown again
end;

procedure TXelHtml.DoExit;
begin
  inherited DoExit;
  FPaintBox.Invalidate;
end;

// ---- document loading ----

// The CSS engine keeps its environment in globals; set them for this control
// before parsing CSS or resolving styles (several controls may coexist).
procedure TXelHtml.ApplyCssGlobals;
begin
  XelCssParser.GMediaWidth := Max(320, FPaintBox.ClientWidth);
  XelCssParser.GHoverElement := FHoverEl;
  XelCssParser.GFocusElement := FFocusEl;
  XelCssParser.GTargetId := FTargetId;
end;

procedure TXelHtml.LoadFromStream(S: TStream; const ABaseUrl: string;
  const ACharset: string);
var
  BaseEl: TDOMElement;
begin
  // the new document replaces the old one
  FEngine.Run(nil); // free the old layout tree (it points into the DOM)
  FFocusEl := nil;  // these point into the old DOM too
  FSelectEl := nil;
  FHoverEl := nil;
  // :target = the fragment of the document URL
  if Pos('#', ABaseUrl) > 0 then
    FTargetId := Copy(ABaseUrl, Pos('#', ABaseUrl) + 1, MaxInt)
  else
    FTargetId := '';
  // viewport width for evaluating @media queries (min/max-width)
  ApplyCssGlobals;
  FreeAndNil(FDoc);
  FSheetByUrl.Clear;
  FSheets.Clear;
  FResolver.ClearAuthorSheets;
  FHoverLink := '';
  FPaintBox.Cursor := crDefault;

  FDocUrl := ABaseUrl;
  FBaseUrl := ABaseUrl;
  FDoc := TDOMDocument.Create;
  FDoc.BaseUrl := ABaseUrl;
  ParseHtmlStream(S, FDoc, ACharset);

  // <base href> overrides the base URL for relative resources
  if FDoc.Head <> nil then
  begin
    BaseEl := FDoc.Head.FindFirstByTag('base');
    if (BaseEl <> nil) and (BaseEl.GetAttribute('href') <> '') then
    begin
      FBaseUrl := ResolveUrl(ABaseUrl, BaseEl.GetAttribute('href'));
      FDoc.BaseUrl := FBaseUrl;
    end;
  end;

  if Assigned(FOnTitleChange) then
    FOnTitleChange(Self, FDoc.Title);
  if FDocUrl <> '' then
    SetLocation(FDocUrl);

  PushHistory(FDocUrl);
  ScanResources;
  FVScroll.Position := 0;
  FHScroll.Position := 0;
  Relayout;
  if FTargetId <> '' then
    ScrollToAnchor(FTargetId);

  // document parsed and initially laid out (resources may arrive in the background)
  if Assigned(FOnDocumentComplete) then
    FOnDocumentComplete(Self, FDocUrl);
end;

procedure TXelHtml.ScanResources;
var
  All: TList<TDOMElement>;
  I: Integer;
  E: TDOMElement;
  Url, Rel: string;
  Sheet: TCssStyleSheet;
  Res: TResource;
begin
  if FDoc = nil then
    Exit;
  All := TList<TDOMElement>.Create;
  try
    if FDoc.DocumentElement <> nil then
      FDoc.DocumentElement.GetElementsByTagName('*', All);
    if FDoc.DocumentElement <> nil then
      All.Insert(0, FDoc.DocumentElement);

    for I := 0 to All.Count - 1 do
    begin
      E := All[I];
      if E.TagName = 'script' then
      begin
        Url := E.GetAttribute('src');
        if Url <> '' then
        begin
          Res := EnqueueRes(ResolveUrl(FBaseUrl, Url), rtJS);
          if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
            HandleResource(Res);
        end;
      end
      else if E.TagName = 'link' then
      begin
        Rel := LowerCase(E.GetAttribute('rel'));
        if Pos('stylesheet', Rel) > 0 then
        begin
          Url := ResolveUrl(FBaseUrl, E.GetAttribute('href'));
          if not FSheetByUrl.ContainsKey(Url) then
          begin
            Sheet := TCssStyleSheet.Create;
            Sheet.BaseUrl := Url;
            FSheets.Add(Sheet); // document order preserved
            FSheetByUrl.Add(Url, Sheet);
            Res := EnqueueRes(Url, rtCSS);
            if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
              HandleResource(Res);
          end;
        end;
      end
      else if E.TagName = 'style' then
      begin
        Sheet := TCssStyleSheet.Create;
        FSheets.Add(Sheet);
        ApplyCssGlobals;
        ParseCss(E.TextContent, FBaseUrl, Sheet);
        HandleCssResources(Sheet); // fonts/imports/images from the inline style sheet
      end
      else if E.TagName = 'img' then
      begin
        Url := E.GetAttribute('src');
        if Url <> '' then
        begin
          if SameText(Copy(Url, 1, 5), 'data:') then
            AddDataUrlImage(Url) // embedded image - decode in place
          else
          begin
            Res := EnqueueRes(ResolveUrl(FBaseUrl, Url), rtImage);
            if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
              HandleResource(Res);
          end;
        end;
      end;
    end;
  finally
    All.Free;
  end;

  // register the style sheets in the resolver
  FResolver.ClearAuthorSheets;
  for I := 0 to FSheets.Count - 1 do
    FResolver.AddAuthorSheet(FSheets[I]);
end;

// Decodes a data: URI image (base64 or percent-encoded) straight into
// the picture cache. The cache key is the full data: URL, which is what
// the layout engine asks for after URL resolution.
procedure TXelHtml.AddDataUrlImage(const DataUrl: string);
var
  P, I: Integer;
  Meta, Payload, Raw: string;
  MS: TMemoryStream;
  Pic: TPicture;
begin
  if FPics.ContainsKey(DataUrl) then
    Exit;
  P := Pos(',', DataUrl);
  if P = 0 then
    Exit;
  Meta := LowerCase(Copy(DataUrl, 6, P - 6));
  Payload := Copy(DataUrl, P + 1, MaxInt);

  try
    // percent-decode first (Acid2 encodes '/','+','=' even in base64)
    Raw := '';
    I := 1;
    while I <= Length(Payload) do
    begin
      if (Payload[I] = '%') and (I + 2 <= Length(Payload)) then
      begin
        Raw := Raw + Chr(StrToIntDef('$' + Copy(Payload, I + 1, 2), 32));
        Inc(I, 3);
      end
      else
      begin
        Raw := Raw + Payload[I];
        Inc(I);
      end;
    end;
    if Pos('base64', Meta) > 0 then
      Raw := DecodeStringBase64(Raw);

    MS := TMemoryStream.Create;
    try
      if Raw <> '' then
        MS.WriteBuffer(Raw[1], Length(Raw));
      MS.Position := 0;
      Pic := LoadPictureFromStream(MS);
      FPics.Add(DataUrl, Pic);
    finally
      MS.Free;
    end;
  except
    // broken embedded image - the placeholder will be drawn instead
  end;
end;

// ---- resource notifications ----

procedure TXelHtml.ResourceLoadedThreaded(Res: TResource);
begin
  // worker thread context — hand over to the main thread
  Application.QueueAsyncCall(AsyncResourceLoaded, PtrInt(Res));
end;

procedure TXelHtml.AsyncResourceLoaded(Data: PtrInt);
begin
  HandleResource(TResource(Data));
end;

procedure TXelHtml.HandleResource(Res: TResource);
begin
  if Res = nil then
    Exit;
  if Res.State = rsError then
  begin
    DoLoadError(Res.Url, 'Error: ' + Res.Url + ' — ' + Res.ErrorMsg);
    Exit;
  end;
  if Res.State <> rsLoaded then
    Exit;

  case Res.ResType of
    rtHtml:
      begin
        Res.Data.Position := 0;
        LoadFromStream(Res.Data, Res.Url,
          CharsetFromContentType(Res.ContentType));
      end;
    rtJS:
      begin
        // JS is only stored — there is no script engine yet
        if FScripts.IndexOfName(Res.Url) < 0 then
          FScripts.Add(Res.Url + '=' + IntToStr(Res.Data.Size));
      end;
    rtCSS:
      HandleCss(Res);
    rtImage:
      HandleImage(Res);
    rtFont:
      HandleFont(Res);
  end;
  UpdateStatus;
end;

procedure TXelHtml.HandleCssResources(Sheet: TCssStyleSheet);
var
  I: Integer;
  Res: TResource;
  ImpSheet: TCssStyleSheet;
begin
  // fonts from @font-face
  for I := 0 to High(Sheet.FontFaces) do
  begin
    Res := EnqueueRes(Sheet.FontFaces[I].Url, rtFont,
      Sheet.FontFaces[I].Family);
    if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
      HandleResource(Res);
  end;
  // further style sheets from @import
  for I := 0 to Sheet.Imports.Count - 1 do
    if not FSheetByUrl.ContainsKey(Sheet.Imports[I]) then
    begin
      ImpSheet := TCssStyleSheet.Create;
      ImpSheet.BaseUrl := Sheet.Imports[I];
      FSheets.Add(ImpSheet);
      FSheetByUrl.Add(Sheet.Imports[I], ImpSheet);
      FResolver.AddAuthorSheet(ImpSheet);
      Res := EnqueueRes(Sheet.Imports[I], rtCSS);
      if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
        HandleResource(Res);
    end;
  // background images from url(...)
  for I := 0 to Sheet.ImageUrls.Count - 1 do
  begin
    Res := EnqueueRes(Sheet.ImageUrls[I], rtImage);
    if (Res <> nil) and (Res.State in [rsLoaded, rsError]) then
      HandleResource(Res);
  end;
end;

procedure TXelHtml.HandleCss(Res: TResource);
var
  Sheet: TCssStyleSheet;
  Text: string;
  N: Int64;
begin
  if not FSheetByUrl.TryGetValue(Res.Url, Sheet) then
    Exit; // style sheet from the previous document
  if Sheet.Loaded then
    Exit;

  Res.Data.Position := 0;
  N := Res.Data.Size;
  SetLength(Text, N);
  if N > 0 then
    Res.Data.ReadBuffer(Text[1], N);

  ApplyCssGlobals;
  ParseCss(Text, Res.Url, Sheet);
  HandleCssResources(Sheet);
  FNeedRelayout := True;
end;

procedure TXelHtml.HandleImage(Res: TResource);
var
  Pic: TPicture;
  Head, Txt: string;
  N: Integer;
begin
  if FPics.ContainsKey(Res.Url) or FSvgText.ContainsKey(Res.Url) then
    Exit;
  try
    // detect SVG (by content or Content-Type) — store the text, the renderer
    // rasterizes it at display size, with transparency
    Res.Data.Position := 0;
    N := Min(Res.Data.Size, 512);
    SetLength(Head, N);
    if N > 0 then
      Res.Data.ReadBuffer(Head[1], N);
    Res.Data.Position := 0;
    if (Pos('<svg', LowerCase(Head)) > 0) or
       (Pos('svg', LowerCase(Res.ContentType)) > 0) then
    begin
      SetLength(Txt, Res.Data.Size);
      if Res.Data.Size > 0 then
        Res.Data.ReadBuffer(Txt[1], Res.Data.Size);
      FSvgText.Add(Res.Url, Txt);
      FNeedRelayout := True;
      Exit;
    end;
    Pic := LoadPictureFromStream(Res.Data);
    FPics.Add(Res.Url, Pic);
    FNeedRelayout := True;
  except
    on E: Exception do
      DoLoadError(Res.Url, 'Image: ' + Res.Url + ' — ' + E.Message);
  end;
end;

procedure TXelHtml.HandleFont(Res: TResource);
var
  Raw: TBytes;
  N: Int64;
  Fmt: TFontFormat;
  InternalFamily: string;
begin
  if FLoadedFontUrls.IndexOf(Res.Url) >= 0 then
    Exit;

  // load the raw font bytes from the resource
  Res.Data.Position := 0;
  N := Res.Data.Size;
  SetLength(Raw, N);
  if N > 0 then
    Res.Data.ReadBuffer(Raw[0], N);

  // Registration via OTF.pas: conversion WOFF/WOFF2/TTF/SVG -> OTF, then
  // AddFontMemResourceEx (measurement in GDI) + private GDI+ collection (nice,
  // anti-aliased rendering). GDI does not support WOFF/WOFF2 — hence the conversion.
  Fmt := DetectFontFormatBytes(Raw);
  if RegisterBrowserFont(Raw, Res.Tag, InternalFamily) then
  begin
    FLoadedFontUrls.Add(Res.Url);
    if Res.Tag <> '' then
    begin
      // map the @font-face family to the font's internal name — GDI registers
      // the font under the name from the 'name' table, so measurement/fallback must use it
      if InternalFamily = '' then
        InternalFamily := Res.Tag;
      FEngine.ExtraFonts.Values[Res.Tag] := InternalFamily;
    end;
    FNeedRelayout := True;
  end
  else
    SetStatus('Could not register font (' +
      FontFormatName(Fmt) + '): ' + Res.Url);
end;

// ---- layout and painting ----

procedure TXelHtml.Relayout;
var
  MaxScroll: Integer;
begin
  FNeedRelayout := False;
  if FDoc = nil then
    Exit;

  if (FBuffer.Width <> FPaintBox.ClientWidth) or
     (FBuffer.Height <> FPaintBox.ClientHeight) then
  begin
    FBuffer.SetSize(Max(1, FPaintBox.ClientWidth),
      Max(1, FPaintBox.ClientHeight));
  end;

  FEngine.Canvas := FBuffer.Canvas;
  FEngine.ViewportWidth := Max(100, FPaintBox.ClientWidth);
  FEngine.ViewportHeight := Max(100, FPaintBox.ClientHeight);
  // state for :hover / :focus / :target, read while styles are resolved
  ApplyCssGlobals;
  FDoc.Lock;
  try
    FEngine.Run(FDoc);
    FDocVersionRendered := FDoc.Version;
  finally
    FDoc.Unlock;
  end;

  MaxScroll := Max(0, FEngine.DocHeight - FPaintBox.ClientHeight);
  FVScroll.Max := Max(0, FEngine.DocHeight);
  FVScroll.PageSize := Min(FVScroll.Max, FPaintBox.ClientHeight);
  FVScroll.LargeChange := Max(1, FPaintBox.ClientHeight - 40);
  FVScroll.SmallChange := 40;
  if FVScroll.Position > MaxScroll then
    FVScroll.Position := MaxScroll;

  // horizontal scrolling for content wider than the viewport
  MaxScroll := Max(0, FEngine.DocWidth - FPaintBox.ClientWidth);
  FHScroll.Max := Max(0, FEngine.DocWidth);
  FHScroll.PageSize := Min(FHScroll.Max, FPaintBox.ClientWidth);
  FHScroll.LargeChange := Max(1, FPaintBox.ClientWidth - 40);
  FHScroll.SmallChange := 40;
  if FHScroll.Position > MaxScroll then
    FHScroll.Position := MaxScroll;
  FHScroll.Enabled := MaxScroll > 0;

  FPaintBox.Invalidate;
end;

function TXelHtml.PageBackground: TColor;
var
  I: Integer;
  Box: TLayoutBox;
begin
  Result := Color;
  if FEngine.Root = nil then
    Exit;
  if FEngine.Root.Style.HasBgColor then
    Exit(FEngine.Root.Style.BgColor);
  for I := 0 to FEngine.Root.Children.Count - 1 do
  begin
    Box := FEngine.Root.Children[I];
    if (Box.Element <> nil) and (Box.Element.TagName = 'body') and
       Box.Style.HasBgColor then
      Exit(Box.Style.BgColor);
  end;
end;

procedure TXelHtml.PaintBoxPaint(Sender: TObject);
const
  DesignText = 'TXelHtml';
begin
  if (FBuffer.Width <> FPaintBox.ClientWidth) or
     (FBuffer.Height <> FPaintBox.ClientHeight) then
    FBuffer.SetSize(Max(1, FPaintBox.ClientWidth),
      Max(1, FPaintBox.ClientHeight));

  FBuffer.Canvas.Brush.Style := bsSolid;
  FBuffer.Canvas.Brush.Color := PageBackground;
  FBuffer.Canvas.FillRect(0, 0, FBuffer.Width, FBuffer.Height);

  if FEngine.Root <> nil then
  begin
    FRenderer.Canvas := FBuffer.Canvas;
    // the caret is shown only while the control has the keyboard focus
    if Focused then
      FRenderer.FocusElement := FFocusEl
    else
      FRenderer.FocusElement := nil;
    FRenderer.OffsetX := ScrollX;
    FRenderer.OffsetY := ScrollY;
    FRenderer.ViewHeight := FBuffer.Height;
    FRenderer.ViewWidth := FBuffer.Width;
    FRenderer.Paint(FEngine.Root);
  end
  else if csDesigning in ComponentState then
  begin
    // placeholder in the form designer
    FBuffer.Canvas.Pen.Color := clGray;
    FBuffer.Canvas.Pen.Style := psDash;
    FBuffer.Canvas.Rectangle(0, 0, FBuffer.Width, FBuffer.Height);
    FBuffer.Canvas.Font.Color := clGray;
    FBuffer.Canvas.TextOut((FBuffer.Width - FBuffer.Canvas.TextWidth(DesignText)) div 2,
      (FBuffer.Height - FBuffer.Canvas.TextHeight(DesignText)) div 2, DesignText);
    FBuffer.Canvas.Pen.Style := psSolid;
  end;

  FPaintBox.Canvas.Draw(0, 0, FBuffer);
end;

procedure TXelHtml.Paint;
begin
  // only the corner between the two scroll bars is not covered by a child
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(ClientRect);
end;

procedure TXelHtml.ScrollChanged(Sender: TObject);
begin
  FPaintBox.Invalidate;
end;

procedure TXelHtml.Resize;
begin
  inherited Resize;
  FNeedRelayout := True;
end;

procedure TXelHtml.TimerTick(Sender: TObject);
begin
  // main thread: waits for new files and renders again
  if FNeedRelayout then
    Relayout
  else if (FDoc <> nil) and (FDoc.Version <> FDocVersionRendered) then
    Relayout; // DOM changed (in the future by JS)
  UpdateStatus;
end;

procedure TXelHtml.UpdateStatus;
var
  Pending: Integer;
begin
  Pending := PendingCount;
  if (Pending <> FLastPending) and Assigned(FOnProgress) then
    FOnProgress(Self, Pending);
  FLastPending := Pending;
  if FHoverLink <> '' then
    Exit; // the status shows the link under the cursor
  if Pending > 0 then
    SetStatus(Format(
      'Loading resources: %d pending | images: %d | style sheets: %d | scripts: %d',
      [Pending, FPics.Count, FSheets.Count, FScripts.Count]))
  else if FDoc <> nil then
    SetStatus(Format(
      'Done | images: %d | style sheets: %d | scripts: %d | page height: %d px',
      [FPics.Count, FSheets.Count, FScripts.Count, FEngine.DocHeight]));
end;

// ---- callbacks ----

function TXelHtml.GetImageSize(const Url: string; out W, H: Integer): Boolean;
var
  Pic: TPicture;
  Txt: string;
begin
  W := 0;
  H := 0;
  Result := False;
  if FPics.TryGetValue(Url, Pic) then
  begin
    W := Pic.Width;
    H := Pic.Height;
    Result := (W > 0) and (H > 0);
  end
  else if FSvgText.TryGetValue(Url, Txt) then
  begin
    SvgIntrinsicSize(Txt, W, H);   // intrinsic SVG size (width/height/viewBox)
    Result := (W > 0) and (H > 0);
  end;
end;

function TXelHtml.GetPicture(const Url: string): TPicture;
begin
  if not FPics.TryGetValue(Url, Result) then
    Result := nil;
end;

function TXelHtml.GetSvg(const Url: string): string;
begin
  if not FSvgText.TryGetValue(Url, Result) then
    Result := '';
end;

end.
