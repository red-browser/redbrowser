#!/usr/bin/env bash
# Build and run Red Browser.
#
#   ./run.sh                     # open the start page
#   ./run.sh example.com hn.com  # open URLs (or a search query); extra args open extra tabs
#   RELEASE=1 ./run.sh           # optimised build (Rust --release + Zig ReleaseFast)
#   ./run.sh --build-only
#
# Zig 0.14 can't link against recent macOS SDKs (neither the `zig build` runner
# nor `zig build-exe`), so on macOS Zig emits an object file and the system `cc`
# links it. build.zig describes the same build for toolchains where it works.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

ZIG="${ZIG:-$(command -v zig || echo ~/.local/zig-macos-aarch64-0.14.0/zig)}"
BUILD_ONLY=0
if [[ "${1:-}" == "--build-only" ]]; then BUILD_ONLY=1; shift; fi

# 1. Axolotl (in-house engine, still used by rust-piston-bindings)
if [ -d "../axolotl" ]; then
    echo "==> Building axolotl (../axolotl)..."
    (cd ../axolotl && cargo build -q)
fi

# 2. Rust engine bridge: WebRender + html5ever
if [[ "${RELEASE:-0}" == "1" ]]; then
    PROFILE=release; ZIG_OPT=ReleaseFast; CARGO_FLAGS=(--release)
else
    PROFILE=debug; ZIG_OPT=Debug; CARGO_FLAGS=()
fi
echo "==> Building redengine (WebRender + html5ever + SpiderMonkey, $PROFILE)..."
cargo build -q --manifest-path engine/Cargo.toml ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"}
ENGINE_LIB="engine/target/$PROFILE/libredengine.a"

# 3. Zig browser
echo "==> Building redbrowser (Zig, $ZIG_OPT)..."
mkdir -p zig-out/bin zig-out/obj
case "$(uname -s)" in
Darwin)
    SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
    ARCH="$(uname -m)"; [[ "$ARCH" == "arm64" ]] && ARCH=aarch64
    "$ZIG" build-obj src/main.zig -target "$ARCH-macos" -O "$ZIG_OPT" -lc -fcompiler-rt \
        -I/opt/homebrew/include -I"$SDK/usr/include" \
        --name redbrowser -femit-bin=zig-out/obj/redbrowser.o
    # SpiderMonkey is C++ (libc++, zlib). -dead_strip mirrors rustc's own link
    # and is required: the prebuilt archive has sections ld64 rejects otherwise.
    cc zig-out/obj/redbrowser.o "$ENGINE_LIB" -o zig-out/bin/redbrowser \
        -L/opt/homebrew/lib -lSDL3 -liconv -lc++ -lz -Wl,-dead_strip \
        -framework CoreFoundation -framework CoreGraphics -framework CoreText \
        -framework Foundation -framework AppKit -framework Security \
        -framework SystemConfiguration -framework OpenGL

    # 4. App bundle so the Dock / Cmd-Tab / Finder show the icon.
    APP="zig-out/Red Browser.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    # Replace (not overwrite) the binary: macOS caches code signatures per file
    # and SIGKILLs a signed executable whose bytes changed in place.
    rm -f "$APP/Contents/MacOS/redbrowser"
    cp zig-out/bin/redbrowser "$APP/Contents/MacOS/redbrowser"
    if [[ ! -f assets/AppIcon.png || brand/png/R.png -nt assets/AppIcon.png ]]; then
        swift tools/make_icon.swift brand/png/R.png assets/AppIcon.png
    fi
    cp assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
    mkdir -p "$APP/Contents/Resources/fonts"
    cp assets/fonts/*.ttf assets/fonts/OFL.txt "$APP/Contents/Resources/fonts/"
    if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" || assets/AppIcon.png -nt "$APP/Contents/Resources/AppIcon.icns" ]]; then
        ICONSET="zig-out/obj/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
        for s in 16 32 128 256 512; do
            sips -z $s $s assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
            sips -z $((s*2)) $((s*2)) assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    fi
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Red Browser</string>
  <key>CFBundleDisplayName</key><string>Red Browser</string>
  <key>CFBundleIdentifier</key><string>org.redbrowser.RedBrowser</string>
  <key>CFBundleExecutable</key><string>redbrowser</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    touch "$APP"
    RUN_BIN="$APP/Contents/MacOS/redbrowser"
    ;;
*)
    "$ZIG" build-exe src/main.zig "$ENGINE_LIB" -O "$ZIG_OPT" \
        -lSDL3 -lc -ldl -lpthread -lm -lstdc++ -lz \
        --name redbrowser -femit-bin=zig-out/bin/redbrowser
    RUN_BIN=zig-out/bin/redbrowser
    ;;
esac

[[ "$BUILD_ONLY" == "1" ]] && exit 0

echo "==> Running Red Browser..."
exec "$RUN_BIN" "$@"
