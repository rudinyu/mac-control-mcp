#!/bin/sh
# Notarizes a MacControl.app built by `sh scripts/build-app.sh --sign`, staples its ticket, then packs it into
# a signed DMG and notarizes and staples that too.
#   sh scripts/notarize.sh [.build/app/MacControl.app]
# The app carries its own ticket, so it opens without a network check once copied out of the DMG. Stapling
# changes the app, so the DMG can only be made afterwards and needs a second submission.
# Credentials come from a notarytool keychain profile (default "maccontrol"), stored once with:
#   xcrun notarytool store-credentials maccontrol --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>
# The DMG is signed with MACCONTROL_SIGN_IDENTITY, defaulting to the project's Developer ID.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="${1:-$project_dir/.build/app/MacControl.app}"
profile="${MACCONTROL_NOTARY_PROFILE:-maccontrol}"
identity="${MACCONTROL_SIGN_IDENTITY:-Developer ID Application: chienchung Yu (LYK4LV2859)}"
# In CI the profile lives in a temporary keychain instead of the login keychain.
notary() {
  if [ -n "${MACCONTROL_NOTARY_KEYCHAIN:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$profile" --keychain "$MACCONTROL_NOTARY_KEYCHAIN"
  else
    xcrun notarytool "$@" --keychain-profile "$profile"
  fi
}
# Submits a file and waits; stops with Apple's log unless it is accepted.
submit() {
  echo "Submitting $1 to the Apple notary service (usually a few minutes)…"
  if ! notary submit "$1" --wait --output-format plist > "$1.notary.plist"; then
    cat "$1.notary.plist" >&2
    echo "Submission failed. Check the keychain profile \"$profile\" (xcrun notarytool history --keychain-profile $profile)." >&2
    exit 1
  fi
  status=$(/usr/libexec/PlistBuddy -c "Print status" "$1.notary.plist")
  id=$(/usr/libexec/PlistBuddy -c "Print id" "$1.notary.plist")
  if [ "$status" != "Accepted" ]; then
    echo "Notarization status: $status. Apple's log:" >&2
    notary log "$id" >&2 || true
    exit 1
  fi
  rm -f "$1.notary.plist"
}

if [ ! -d "$app" ]; then
  echo "Usage: sh scripts/notarize.sh [signed MacControl.app]" >&2
  exit 2
fi
if ! codesign --verify --deep --strict "$app" 2>/dev/null || ! codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application'; then
  echo "$app is not signed with Developer ID. Build it with: sh scripts/build-app.sh --sign" >&2
  exit 1
fi
out=$(dirname -- "$app")
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
work=$(mktemp -d)
mount="$work/mount"
trap 'hdiutil detach -quiet "$mount" 2>/dev/null; rm -rf "$work"' EXIT

# The app, sent as a ZIP since notarytool does not take a bundle.
zip="$work/MacControl-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
submit "$zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

# The DMG, made from the stapled app.
staging="$work/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$out/MacControl-$version.dmg"
hdiutil create -quiet -volname "MacControl" -srcfolder "$staging" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
submit "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

# Check the app inside the DMG the way Gatekeeper will.
mkdir -p "$mount"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
spctl --assess --type execute -vv "$mount/MacControl.app"
codesign --verify --deep --strict "$mount/MacControl.app"
xcrun stapler validate "$mount/MacControl.app"
spctl --assess --type open --context context:primary-signature -vv "$dmg"
echo "Notarized and stapled: $app and $dmg"
