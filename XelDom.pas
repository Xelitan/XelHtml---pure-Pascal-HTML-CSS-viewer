unit XelDom;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Document model (DOM) — as in real browsers.
// The whole page lives in TDOMDocument; the structure can be modified
// with methods (AppendChild, RemoveChild, SetAttribute...), so
// a future JS engine will be able to change the document.
// The document has a version counter (Version) — the renderer checks it
// to know that the layout must be recomputed. Lock/Unlock protects
// the structure during access from multiple threads.

interface

uses
  Classes, SysUtils, syncobjs, Generics.Collections;

type
  TDomNodeType = (ntDocument, ntElement, ntText, ntComment);
  // document mode from the DOCTYPE (HTML spec "quirks mode"): layout differs
  // in details, e.g. the line-height strut is not applied in quirks mode
  TDocCompatMode = (dcmQuirks, dcmLimitedQuirks, dcmStandards);

  TDOMDocument = class;
  TDOMElement = class;

  // TDOMNode

  TDOMNode = class
  private
    FOwnerDoc: TDOMDocument;
    FParent: TDOMNode;
    FChildren: TList<TDOMNode>;
    FNodeType: TDomNodeType;
    FNodeName: string;   // tag name (lower case) for elements
    FNodeValue: string;  // content of text and comment nodes
    function GetChild(Index: Integer): TDOMNode;
    function GetChildCount: Integer;
    procedure SetNodeValue(const AValue: string);
  protected
    procedure Mutated;
  public
    constructor Create(AOwner: TDOMDocument; AType: TDomNodeType);
    destructor Destroy; override;

    // Structure mutations — future API for JS
    function AppendChild(ANode: TDOMNode): TDOMNode;
    function InsertBefore(ANew, ARef: TDOMNode): TDOMNode;
    function RemoveChild(ANode: TDOMNode): TDOMNode; // detaches, does not free
    function ReplaceChild(ANew, AOld: TDOMNode): TDOMNode; // returns the detached old one
    procedure ClearChildren; // removes and frees all children

    function FirstChild: TDOMNode;
    function LastChild: TDOMNode;
    function NextSibling: TDOMNode;
    function PreviousSibling: TDOMNode;
    function IndexOfChild(ANode: TDOMNode): Integer;

    // Combined text of the node and its descendants
    function TextContent: string;

    property OwnerDocument: TDOMDocument read FOwnerDoc;
    property ParentNode: TDOMNode read FParent;
    property NodeType: TDomNodeType read FNodeType;
    property NodeName: string read FNodeName;
    property NodeValue: string read FNodeValue write SetNodeValue;
    property ChildCount: Integer read GetChildCount;
    property Children[Index: Integer]: TDOMNode read GetChild; default;
  end;

  // TDOMElement

  TDOMElement = class(TDOMNode)
  private
    FAttrNames: TStringList;
    FAttrValues: TStringList;
    function GetTagName: string;
    function GetAttrCount: Integer;
    function GetAttrName(Index: Integer): string;
    function GetAttrValue(Index: Integer): string;
  public
    constructor Create(AOwner: TDOMDocument; const ATag: string);
    destructor Destroy; override;

    function GetAttribute(const AName: string): string;
    procedure SetAttribute(const AName, AValue: string);
    function HasAttribute(const AName: string): Boolean;
    procedure RemoveAttribute(const AName: string);

    function GetId: string;
    function HasClass(const AClass: string): Boolean;

    procedure GetElementsByTagName(const ATag: string; AList: TList<TDOMElement>);
    function FindFirstByTag(const ATag: string): TDOMElement;

    property TagName: string read GetTagName;
    property AttrCount: Integer read GetAttrCount;
    property AttrNames[Index: Integer]: string read GetAttrName;
    property AttrValues[Index: Integer]: string read GetAttrValue;
  end;

  // TDOMText

  TDOMText = class(TDOMNode)
  public
    constructor Create(AOwner: TDOMDocument; const AText: string);
  end;

  // TDOMComment

  TDOMComment = class(TDOMNode)
  public
    constructor Create(AOwner: TDOMDocument; const AText: string);
  end;

  // TDOMDocument

  TDOMDocument = class(TDOMNode)
  private
    FLock: TCriticalSection;
    FVersion: Integer;
    FBaseUrl: string;
    FTitle: string;
  public
    CompatMode: TDocCompatMode; // set by the parser; quirks without a DOCTYPE
    constructor Create;
    destructor Destroy; override;

    // Node factories — like document.createElement in JS
    function CreateElement(const ATag: string): TDOMElement;
    function CreateTextNode(const AText: string): TDOMText;
    function CreateComment(const AText: string): TDOMComment;

    function DocumentElement: TDOMElement; // <html>
    function Head: TDOMElement;
    function Body: TDOMElement;
    function GetElementById(const AId: string): TDOMElement;

    // Lock for multi-threaded access (for the future: JS in a separate thread)
    procedure Lock;
    procedure Unlock;
    procedure Touch; // increments the version — a signal for the renderer

    property Version: Integer read FVersion;
    property BaseUrl: string read FBaseUrl write FBaseUrl;
    property Title: string read FTitle write FTitle;
  end;

implementation

// TDOMNode

constructor TDOMNode.Create(AOwner: TDOMDocument; AType: TDomNodeType);
begin
  inherited Create;
  FOwnerDoc := AOwner;
  FNodeType := AType;
  FChildren := TList<TDOMNode>.Create;
end;

destructor TDOMNode.Destroy;
begin
  ClearChildren;
  FChildren.Free;
  inherited Destroy;
end;

procedure TDOMNode.Mutated;
begin
  if FOwnerDoc <> nil then
    FOwnerDoc.Touch;
end;

function TDOMNode.GetChild(Index: Integer): TDOMNode;
begin
  Result := FChildren[Index];
end;

function TDOMNode.GetChildCount: Integer;
begin
  Result := FChildren.Count;
end;

procedure TDOMNode.SetNodeValue(const AValue: string);
begin
  if FNodeValue <> AValue then
  begin
    FNodeValue := AValue;
    Mutated;
  end;
end;

function TDOMNode.AppendChild(ANode: TDOMNode): TDOMNode;
begin
  Result := ANode;
  if ANode = nil then
    Exit;
  if ANode.FParent <> nil then
    ANode.FParent.RemoveChild(ANode);
  ANode.FParent := Self;
  FChildren.Add(ANode);
  Mutated;
end;

function TDOMNode.InsertBefore(ANew, ARef: TDOMNode): TDOMNode;
var
  Idx: Integer;
begin
  Result := ANew;
  if ANew = nil then
    Exit;
  if ARef = nil then
  begin
    AppendChild(ANew);
    Exit;
  end;
  Idx := FChildren.IndexOf(ARef);
  if Idx < 0 then
    raise Exception.Create('InsertBefore: reference node is not a child');
  if ANew.FParent <> nil then
    ANew.FParent.RemoveChild(ANew);
  ANew.FParent := Self;
  // the index may have changed if ANew was an earlier child of this node
  Idx := FChildren.IndexOf(ARef);
  FChildren.Insert(Idx, ANew);
  Mutated;
end;

function TDOMNode.RemoveChild(ANode: TDOMNode): TDOMNode;
var
  Idx: Integer;
begin
  Result := ANode;
  Idx := FChildren.IndexOf(ANode);
  if Idx < 0 then
    Exit;
  FChildren.Delete(Idx);
  ANode.FParent := nil;
  Mutated;
end;

function TDOMNode.ReplaceChild(ANew, AOld: TDOMNode): TDOMNode;
var
  Idx: Integer;
begin
  Result := AOld;
  Idx := FChildren.IndexOf(AOld);
  if Idx < 0 then
    raise Exception.Create('ReplaceChild: old node is not a child');
  if ANew.FParent <> nil then
    ANew.FParent.RemoveChild(ANew);
  Idx := FChildren.IndexOf(AOld);
  FChildren[Idx] := ANew;
  ANew.FParent := Self;
  AOld.FParent := nil;
  Mutated;
end;

procedure TDOMNode.ClearChildren;
var
  I: Integer;
begin
  for I := FChildren.Count - 1 downto 0 do
  begin
    FChildren[I].FParent := nil;
    FChildren[I].Free;
  end;
  FChildren.Clear;
end;

function TDOMNode.FirstChild: TDOMNode;
begin
  if FChildren.Count > 0 then
    Result := FChildren[0]
  else
    Result := nil;
end;

function TDOMNode.LastChild: TDOMNode;
begin
  if FChildren.Count > 0 then
    Result := FChildren[FChildren.Count - 1]
  else
    Result := nil;
end;

function TDOMNode.NextSibling: TDOMNode;
var
  Idx: Integer;
begin
  Result := nil;
  if FParent = nil then
    Exit;
  Idx := FParent.FChildren.IndexOf(Self);
  if (Idx >= 0) and (Idx < FParent.FChildren.Count - 1) then
    Result := FParent.FChildren[Idx + 1];
end;

function TDOMNode.PreviousSibling: TDOMNode;
var
  Idx: Integer;
begin
  Result := nil;
  if FParent = nil then
    Exit;
  Idx := FParent.FChildren.IndexOf(Self);
  if Idx > 0 then
    Result := FParent.FChildren[Idx - 1];
end;

function TDOMNode.IndexOfChild(ANode: TDOMNode): Integer;
begin
  Result := FChildren.IndexOf(ANode);
end;

function TDOMNode.TextContent: string;
var
  I: Integer;
begin
  if FNodeType in [ntText, ntComment] then
    Result := FNodeValue
  else
  begin
    Result := '';
    for I := 0 to FChildren.Count - 1 do
      if FChildren[I].NodeType in [ntText, ntElement] then
        Result := Result + FChildren[I].TextContent;
  end;
end;

// TDOMElement

constructor TDOMElement.Create(AOwner: TDOMDocument; const ATag: string);
begin
  inherited Create(AOwner, ntElement);
  FNodeName := LowerCase(ATag);
  FAttrNames := TStringList.Create;
  FAttrValues := TStringList.Create;
end;

destructor TDOMElement.Destroy;
begin
  FAttrNames.Free;
  FAttrValues.Free;
  inherited Destroy;
end;

function TDOMElement.GetTagName: string;
begin
  Result := FNodeName;
end;

function TDOMElement.GetAttrCount: Integer;
begin
  Result := FAttrNames.Count;
end;

function TDOMElement.GetAttrName(Index: Integer): string;
begin
  Result := FAttrNames[Index];
end;

function TDOMElement.GetAttrValue(Index: Integer): string;
begin
  Result := FAttrValues[Index];
end;

function TDOMElement.GetAttribute(const AName: string): string;
var
  Idx: Integer;
begin
  Idx := FAttrNames.IndexOf(LowerCase(AName));
  if Idx >= 0 then
    Result := FAttrValues[Idx]
  else
    Result := '';
end;

procedure TDOMElement.SetAttribute(const AName, AValue: string);
var
  Idx: Integer;
begin
  Idx := FAttrNames.IndexOf(LowerCase(AName));
  if Idx >= 0 then
    FAttrValues[Idx] := AValue
  else
  begin
    FAttrNames.Add(LowerCase(AName));
    FAttrValues.Add(AValue);
  end;
  Mutated;
end;

function TDOMElement.HasAttribute(const AName: string): Boolean;
begin
  Result := FAttrNames.IndexOf(LowerCase(AName)) >= 0;
end;

procedure TDOMElement.RemoveAttribute(const AName: string);
var
  Idx: Integer;
begin
  Idx := FAttrNames.IndexOf(LowerCase(AName));
  if Idx >= 0 then
  begin
    FAttrNames.Delete(Idx);
    FAttrValues.Delete(Idx);
    Mutated;
  end;
end;

function TDOMElement.GetId: string;
begin
  Result := GetAttribute('id');
end;

function TDOMElement.HasClass(const AClass: string): Boolean;
var
  Cls: string;
  P, Start: Integer;
  Token: string;
begin
  Result := False;
  Cls := GetAttribute('class');
  if Cls = '' then
    Exit;
  Start := 1;
  for P := 1 to Length(Cls) + 1 do
    if (P > Length(Cls)) or (Cls[P] in [' ', #9, #10, #13]) then
    begin
      Token := Copy(Cls, Start, P - Start);
      Start := P + 1;
      if (Token <> '') and SameText(Token, AClass) then
        Exit(True);
    end;
end;

procedure TDOMElement.GetElementsByTagName(const ATag: string; AList: TList<TDOMElement>);
var
  I: Integer;
  T: string;
begin
  T := LowerCase(ATag);
  for I := 0 to ChildCount - 1 do
    if Children[I] is TDOMElement then
    begin
      if (T = '*') or (TDOMElement(Children[I]).TagName = T) then
        AList.Add(TDOMElement(Children[I]));
      TDOMElement(Children[I]).GetElementsByTagName(ATag, AList);
    end;
end;

function TDOMElement.FindFirstByTag(const ATag: string): TDOMElement;
var
  I: Integer;
  T: string;
begin
  Result := nil;
  T := LowerCase(ATag);
  for I := 0 to ChildCount - 1 do
    if Children[I] is TDOMElement then
    begin
      if TDOMElement(Children[I]).TagName = T then
        Exit(TDOMElement(Children[I]));
      Result := TDOMElement(Children[I]).FindFirstByTag(ATag);
      if Result <> nil then
        Exit;
    end;
end;

// TDOMText

constructor TDOMText.Create(AOwner: TDOMDocument; const AText: string);
begin
  inherited Create(AOwner, ntText);
  FNodeName := '#text';
  FNodeValue := AText;
end;

// TDOMComment

constructor TDOMComment.Create(AOwner: TDOMDocument; const AText: string);
begin
  inherited Create(AOwner, ntComment);
  FNodeName := '#comment';
  FNodeValue := AText;
end;

// TDOMDocument

constructor TDOMDocument.Create;
begin
  inherited Create(nil, ntDocument);
  FOwnerDoc := Self;
  FNodeName := '#document';
  FLock := TCriticalSection.Create;
  FVersion := 0;
end;

destructor TDOMDocument.Destroy;
begin
  ClearChildren;
  FLock.Free;
  inherited Destroy;
end;

function TDOMDocument.CreateElement(const ATag: string): TDOMElement;
begin
  Result := TDOMElement.Create(Self, ATag);
end;

function TDOMDocument.CreateTextNode(const AText: string): TDOMText;
begin
  Result := TDOMText.Create(Self, AText);
end;

function TDOMDocument.CreateComment(const AText: string): TDOMComment;
begin
  Result := TDOMComment.Create(Self, AText);
end;

function TDOMDocument.DocumentElement: TDOMElement;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to ChildCount - 1 do
    if Children[I] is TDOMElement then
      Exit(TDOMElement(Children[I]));
end;

function TDOMDocument.Head: TDOMElement;
var
  Root: TDOMElement;
begin
  Result := nil;
  Root := DocumentElement;
  if Root <> nil then
    Result := Root.FindFirstByTag('head');
end;

function TDOMDocument.Body: TDOMElement;
var
  Root: TDOMElement;
begin
  Result := nil;
  Root := DocumentElement;
  if Root <> nil then
    Result := Root.FindFirstByTag('body');
end;

function FindById(Node: TDOMNode; const AId: string): TDOMElement;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Node.ChildCount - 1 do
    if Node.Children[I] is TDOMElement then
    begin
      if TDOMElement(Node.Children[I]).GetId = AId then
        Exit(TDOMElement(Node.Children[I]));
      Result := FindById(Node.Children[I], AId);
      if Result <> nil then
        Exit;
    end;
end;

function TDOMDocument.GetElementById(const AId: string): TDOMElement;
begin
  Result := FindById(Self, AId);
end;

procedure TDOMDocument.Lock;
begin
  FLock.Acquire;
end;

procedure TDOMDocument.Unlock;
begin
  FLock.Release;
end;

procedure TDOMDocument.Touch;
begin
  InterlockedIncrement(FVersion);
end;

end.
