#!/bin/sh
# Builds MacControl.app as a universal (Apple silicon + Intel) app in .build/app.
#   sh scripts/build-app.sh          ad-hoc signed, for testing on this Mac
#   sh scripts/build-app.sh --sign   signed with Developer ID for distribution, plus a signed DMG
# The identity comes from MACCONTROL_SIGN_IDENTITY, defaulting to the project's Developer ID.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sign=0
for arg in "$@"; do
  case "$arg" in
    --sign) sign=1 ;;
    *) echo "Unknown option: $arg (use --sign)" >&2; exit 2 ;;
  esac
done
identity="${MACCONTROL_SIGN_IDENTITY:-Developer ID Application: chienchung Yu (LYK4LV2859)}"
bundle_id="tw.com.eaman.MacControl"
out="$project_dir/.build/app"
app="$out/MacControl.app"
cache="$project_dir/.build/module-cache"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$project_dir/App/Info.plist")

if [ "$sign" = 1 ] && ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
  echo "The signing identity \"$identity\" is not in the keychain." >&2
  echo "Import the Developer ID certificate and its private key first (see docs/APP.md)." >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out/obj" "$cache"

# Builds one universal executable from the given sources.
universal() {
  name=$1; shift
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -module-cache-path "$cache" -target "$arch-apple-macos14" \
      "$@" -o "$out/obj/$name-$arch"
  done
  lipo -create "$out/obj/$name-arm64" "$out/obj/$name-x86_64" -output "$out/obj/$name"
}

universal mac-control-mcp "$project_dir"/Sources/MacControl/*.swift
universal mac-exec-mcp "$project_dir"/Sources/MacExec/*.swift
# The app shares the sandbox code with mac-exec, but not its server entry point.
universal MacControl "$project_dir"/App/Sources/*.swift \
  "$project_dir/Sources/MacExec/ProcessRunner.swift" \
  "$project_dir/Sources/MacExec/ContainerRuntime.swift" \
  "$project_dir/Sources/MacExec/PathGuard.swift"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/sandbox"
cp "$project_dir/App/Info.plist" "$app/Contents/Info.plist"
cp "$out/obj/MacControl" "$app/Contents/MacOS/MacControl"
cp "$out/obj/mac-control-mcp" "$out/obj/mac-exec-mcp" "$app/Contents/Helpers/"
cp "$project_dir/sandbox/Dockerfile" "$app/Contents/Resources/sandbox/Dockerfile"
cp "$project_dir/App/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Translations are kept as JSON; a binary plist is a valid .strings file and needs no escaping.
for table in "$project_dir"/App/Localization/*.json; do
  language=$(basename "$table" .json)
  mkdir -p "$app/Contents/Resources/$language.lproj"
  plutil -convert binary1 -o "$app/Contents/Resources/$language.lproj/Localizable.strings" "$table"
done
rm -rf "$out/obj"

if [ "$sign" = 1 ]; then
  signer="$identity"
  extra="--timestamp"
else
  signer="-"
  extra=""
fi
# Helpers first, then the app that contains them. The hardened runtime is required for notarization.
# shellcheck disable=SC2086
codesign --force --options runtime $extra --sign "$signer" -i "$bundle_id.control" "$app/Contents/Helpers/mac-control-mcp"
# shellcheck disable=SC2086
codesign --force --options runtime $extra --sign "$signer" -i "$bundle_id.exec" "$app/Contents/Helpers/mac-exec-mcp"
# shellcheck disable=SC2086
codesign --force --options runtime $extra --sign "$signer" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app ($version, $( [ "$sign" = 1 ] && echo "signed by $identity" || echo "ad-hoc signed" ))."

if [ "$sign" = 1 ]; then
  staging="$out/dmg"
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  dmg="$out/MacControl-$version.dmg"
  hdiutil create -quiet -volname "MacControl" -srcfolder "$staging" -ov -format UDZO "$dmg"
  rm -rf "$staging"
  codesign --force --timestamp --sign "$identity" "$dmg"
  echo "Built $dmg. Notarize it with: sh scripts/notarize.sh \"$dmg\""
fi
