#!/bin/sh
# Builds MacShade.app (ad-hoc signed) with the ReShade dylib and the shader collection embedded.
set -e; cd "$(dirname "$0")"; ROOT=$(cd .. && pwd)
# MoltenVK (the Vulkan driver of the OpenGL/Metal bridge): MOLTENVK=/path/to/libMoltenVK.dylib overrides the Homebrew location
MOLTENVK=${MOLTENVK:-$(brew --prefix molten-vk 2>/dev/null)/lib/libMoltenVK.dylib}
[ -f "$MOLTENVK" ] || MOLTENVK=/opt/homebrew/lib/libMoltenVK.dylib
[ -f "$MOLTENVK" ] || { echo "libMoltenVK.dylib not found: brew install molten-vk, or set MOLTENVK=<path>" >&2; exit 1; }
[ "$1" = "--make" ] && (cd "$ROOT/mac/build" && make -j10)
need_arm64() { lipo -archs "$1" 2>/dev/null | grep -qw arm64 || { echo "$1 has no arm64 slice" >&2; exit 1; }; }
need_arm64 "$ROOT/mac/build/libmacshade.dylib"; need_arm64 "$MOLTENVK"
swift build -c release
A=MacShade.app; rm -rf $A; mkdir -p $A/Contents/MacOS $A/Contents/Resources
cp .build/release/MacShade $A/Contents/MacOS/
mkdir -p $A/Contents/Frameworks; ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework $A/Contents/Frameworks/Sparkle.framework   # updater
python3 gen_strings.py >/dev/null; cp -R Resources/*.lproj Resources/Presets $A/Contents/Resources/   # UI translations, presets shipped with the app
cp "$ROOT/mac/build/libmacshade.dylib" $A/Contents/Resources/
clang -fobjc-arc -arch arm64 -mmacosx-version-min=13.0 -framework Foundation -o $A/Contents/MacOS/MacShadeFilter Helper/MacShadeFilter.m   # screen filter mode helper (loads libmacshade)
cp Resources/AppIcon.icns $A/Contents/Resources/
cp "$MOLTENVK" $A/Contents/Resources/libMoltenVK.dylib   # driver for the OpenGL/Metal bridge
# effect collections (each: Shaders/ and Textures/)
C=$A/Contents/Resources/Collections; mkdir -p $C; cp -R Resources/Collections/* $C/; mkdir -p $C/reshade-shaders $C/reshade-shaders-legacy $C/qUINT $C/SweetFX
cp -R "$ROOT/third_party/reshade-shaders/Shaders" "$ROOT/third_party/reshade-shaders/Textures" $C/reshade-shaders/
cp -R "$ROOT/third_party/reshade-shaders-legacy/Shaders" $C/reshade-shaders-legacy/; [ -d "$ROOT/third_party/reshade-shaders-legacy/Textures" ] && cp -R "$ROOT/third_party/reshade-shaders-legacy/Textures" $C/reshade-shaders-legacy/
cp -R "$ROOT/third_party/qUINT/Shaders" $C/qUINT/
cp -R "$ROOT/third_party/SweetFX/Shaders" $C/SweetFX/; [ -d "$ROOT/third_party/SweetFX/Textures" ] && cp -R "$ROOT/third_party/SweetFX/Textures" $C/SweetFX/
cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacShade</string><key>CFBundleIdentifier</key><string>local.macshade</string>
<key>CFBundleDevelopmentRegion</key><string>en</string><key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>fr</string><string>es</string><string>it</string><string>pt</string><string>ja</string><string>zh-Hans</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleName</key><string>MacShade</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string><key>CFBundleVersion</key><string>5</string><key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/klotzbrocken/MacShade/main/appcast.xml</string>
<key>SUPublicEDKey</key><string>8WqgQSrOZQvlCDN3RrwljsPkuElckJc9ZJ8oPHyKkyc=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>MacShade captures the window of a game to apply ReShade effects (screen filter mode).</string></dict></plist>
P
codesign --force --deep -s - $A
codesign --verify --deep --strict $A && echo "signature ok"
for f in $A/Contents/Resources/*.dylib; do need_arm64 "$f"; done
echo "built $PWD/$A"
