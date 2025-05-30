{
  description = "Red Browser - GPU Accelerated Renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
          config.allowUnfree = true;
        };

        zigToolchain = zig-overlay.packages.${system}."0.14.0";

        buildInputs = with pkgs; [
          glfw
          freetype
          harfbuzz
          libglvnd  
          libxkbcommon
          wayland
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
          zlib
        ];

      in
      {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          name = "red-gpu";
          src = self;
          nativeBuildInputs = [ zigToolchain pkgs.pkg-config ];
          buildInputs = buildInputs;
          
          LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          
          buildPhase = ''
            export HOME=$(mktemp -d)
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zigToolchain pkgs.pkg-config ];
          buildInputs = buildInputs;
          
          LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          
          shellHook = ''
            export PATH="${zigToolchain}/bin:$PATH"
            echo "Zig: $(zig version)"
          '';
        };

        formatter.${system} = pkgs.alejandra;
      }
    );
}
