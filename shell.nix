{ zig
, zls
, gcc
, liburing
, mkShell
}: mkShell {
  buildInputs = [ zig zls gcc liburing ];
}
