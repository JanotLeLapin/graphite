{ zig
, zls
, gcc
, mkShell
}: mkShell {
  buildInputs = [ zig zls gcc ];
}
