#!/bin/zsh
# Compile FanPilot.app sans Xcode (Command Line Tools suffisent).
#   ./build.sh            -> build/FanPilot.app
#   ./build.sh install    -> copie aussi dans /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FanPilot.app
OBJ=build/obj
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

echo "→ SMC (C)"
clang -c -O2 -Wall -mmacosx-version-min=14.0 Sources/SMC/smc.c -o "$OBJ/smc.o"
clang -c -O2 -Wall -mmacosx-version-min=14.0 Sources/SMC/procs.c -o "$OBJ/procs.o"

echo "→ Helper root"
clang -O2 -Wall -mmacosx-version-min=14.0 -ISources/SMC Sources/Helper/main.c "$OBJ/smc.o" "$OBJ/procs.o" \
  -framework IOKit -o "$APP/Contents/MacOS/fanpilot-helper"

echo "→ Application (Swift)"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -import-objc-header Sources/SMC/Bridging.h \
  Sources/App/*.swift "$OBJ/smc.o" "$OBJ/procs.o" \
  -framework IOKit -framework SwiftUI -framework AppKit -framework Charts -framework ServiceManagement -lsqlite3 \
  -o "$APP/Contents/MacOS/FanPilot"

# Identifiant de l'app : local.<compte Mac> par défaut (les autorisations macOS restent valables d'une
# compilation à l'autre), ou BUNDLE_PREFIX=… ./build.sh pour une version à distribuer.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-local.$(id -un)}"
sed "s/__BUNDLE_PREFIX__/$BUNDLE_PREFIX/" Resources/Info.plist > "$APP/Contents/Info.plist"
[[ -f build/AppIcon.icns ]] || swift Resources/make_icon.swift build >/dev/null
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signature ad hoc"
codesign --force --sign - "$APP/Contents/MacOS/fanpilot-helper"
codesign --force --sign - "$APP"

echo "✓ $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x FanPilot 2>/dev/null && sleep 1 || true
  rm -rf /Applications/FanPilot.app
  cp -R "$APP" /Applications/
  echo "✓ installé dans /Applications/FanPilot.app"
fi
