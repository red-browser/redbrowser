{
  description = "Red Browser - GPU Accelerated Renderer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, rust-overlay, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default rust-overlay.overlays.default ];
          config.allowUnfree = true;
        };

        zigToolchain = zig-overlay.packages.${system}."0.14.0";
        rustToolchain = pkgs.rust-bin.stable.latest.default;

        buildInputs = with pkgs; [
          sdl3
          freetype
          harfbuzz
          libglvnd
          gdb
          wayland
          wayland-protocols
          wayland-scanner
          zlib
          cmake
          extra-cmake-modules
          llvm_14
          clang_14
          lld_14
          glibc
        ];

        libPath = pkgs.lib.makeLibraryPath buildInputs;

      in
      {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          name = "redbrowser";
          src = self;
          nativeBuildInputs = [ zigToolchain rustToolchain pkgs.pkg-config pkgs.cmake pkgs.zon2nix ];
          buildInputs = buildInputs;
          
          LIBRARY_PATH = libPath;
          LD_LIBRARY_PATH = libPath;
          
          CC = "${pkgs.clang_14}/bin/clang";
          CXX = "${pkgs.clang_14}/bin/clang++";
          CPPFLAGS = "-I${pkgs.llvm_14}/include";
          LDFLAGS = "-L${pkgs.llvm_14}/lib -L${pkgs.llvm_14}/lib/c++";
          CLANG_INCLUDE_DIRS = "${pkgs.llvm_14}/include";
          LLD_LIBRARIES = "${pkgs.llvm_14}/lib";
          LLD_INCLUDE_DIRS = "${pkgs.llvm_14}/include";
          CMAKE_PREFIX_PATH = "${pkgs.llvm_14}";
          
          buildPhase = ''
            export HOME=$(mktemp -d)
            export PATH="${pkgs.cmake}/bin:$PATH"
            which cmake
            cmake --version
            cd rust-piston-bindings
            cargo build --release
            cd ..
            zon2nix generate
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zigToolchain rustToolchain pkgs.pkg-config pkgs.cmake pkgs.zon2nix ];
          buildInputs = buildInputs;
          
          LIBRARY_PATH = libPath;
          LD_LIBRARY_PATH = libPath;
          
          CC = "${pkgs.clang_14}/bin/clang";
          CXX = "${pkgs.clang_14}/bin/clang++";
          CPPFLAGS = "-I${pkgs.llvm_14}/include";
          LDFLAGS = "-L${pkgs.llvm_14}/lib -L${pkgs.llvm_14}/lib/c++";
          CLANG_INCLUDE_DIRS = "${pkgs.llvm_14}/include";
          LLD_LIBRARIES = "${pkgs.llvm_14}/lib";
          LLD_INCLUDE_DIRS = "${pkgs.llvm_14}/include";
          CMAKE_PREFIX_PATH = "${pkgs.llvm_14}";
          
          shellHook = ''
            export PATH="${zigToolchain}/bin:${rustToolchain}/bin:${pkgs.cmake}/bin:$PATH"
            export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPath "lib/pkgconfig" buildInputs}"
            echo "Zig: $(zig version)"
            echo "Rust: $(rustc --version)"
            echo "Clang: $(clang --version)"
            echo "LLD: $(ld.lld --version)"
          '';
        };

        formatter.${system} = pkgs.alejandra;
      }
    );
}
