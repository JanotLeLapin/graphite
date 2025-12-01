{ zig
, stdenv }: stdenv.mkDerivation {
  pname = "graphite";
  version = "0.1";

  src = ./.;

  nativeBuildInputs = [ zig.hook ];
  buildInputs = [];
  buildPhase = ''
    zig build --release=fast
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/diogenic $out/bin/diogenic
  '';
}
