unit XelTextUtil;

{$mode delphi}{$H+}

// Author: xelitan.com
// License: MIT

// Small text helpers — FPC 3.2.2 in Delphi mode does not support
// case-of-string, so matching is done with functions.

interface

// whether S equals any of the elements (case-sensitive)
function StrIn(const S: string; const A: array of string): Boolean;

// index of S in the array, or -1 (case-sensitive)
function StrIndex(const S: string; const A: array of string): Integer;

implementation

function StrIndex(const S: string; const A: array of string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if S = A[I] then
      Exit(I);
  Result := -1;
end;

function StrIn(const S: string; const A: array of string): Boolean;
begin
  Result := StrIndex(S, A) >= 0;
end;

end.
