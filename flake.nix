{
  description = "Red Browser - GPU Accelerated Browser";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, zig-overlay, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            rust-overlay.overlays.default
            zig-overlay.overlays.default
          ];
          config.allowUnfree = true;
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rustfmt" "clippy" ];
        };

        zigToolchain = zig-overlay.packages.${system}."0.12.0";

        nativeBuildInputs = with pkgs; [
          rustToolchain
          zigToolchain
          bazel_6
          bazel-buildtools
          pkg-config
        ];

        buildInputs = with pkgs; [
          glfw
          vulkan-loader
          libxkbcommon
          wayland
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;
          
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          
          shellHook = ''
            export PATH="${rustToolchain}/bin:${zigToolchain}/bin:$PATH"
            echo "Rust: $(rustc --version)"
            echo "Zig: $(zig version)"
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          name = "red-browser";
          src = self;
          inherit nativeBuildInputs buildInputs;
          
          buildPhase = ''
            export HOME=$(mktemp -d)
            bazel build //:red-browser
          '';
          
          installPhase = ''
            mkdir -p $out/bin
            cp bazel-bin/red-browser $out/bin/
          '';
        };

        formatter.${system} = pkgs.alejandra;
      }
    );
}
