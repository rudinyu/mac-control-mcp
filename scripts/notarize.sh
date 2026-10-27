#!/bin/sh
# Notarizes and staples a signed MacControl DMG built by `sh scripts/build-app.sh --sign`.
#   sh scripts/notarize.sh .build/app/MacControl-<version>.dmg
# Credentials come from a notarytool keychain profile (default "maccontrol"), stored once with:
#   xcrun notarytool store-credentials maccontrol --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>
set -eu

dmg="${1:-}"
profile="${MACCONTROL_NOTARY_PROFILE:-maccontrol}"
# In CI the profile lives in a temporary keychain instead of the login keychain.
notary() {
  if [ -n "${MACCONTROL_NOTARY_KEYCHAIN:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$profile" --keychain "$MACCONTROL_NOTARY_KEYCHAIN"
  else
    xcrun notarytool "$@" --keychain-profile "$profile"
  fi
}
if [ -z "$dmg" ] || [ ! -f "$dmg" ]; then
  echo "Usage: sh scripts/notarize.sh <signed dmg>" >&2
  exit 2
fi
if ! codesign --verify --strict "$dmg" 2>/dev/null; then
  echo "$dmg is not signed. Build it with: sh scripts/build-app.sh --sign" >&2
  exit 1
fi

echo "Submitting $dmg to the Apple notary service (usually a few minutes)…"
if ! notary submit "$dmg" --wait --output-format plist > "$dmg.notary.plist"; then
  cat "$dmg.notary.plist" >&2
  echo "Submission failed. Check the keychain profile \"$profile\" (xcrun notarytool history --keychain-profile $profile)." >&2
  exit 1
fi
status=$(/usr/libexec/PlistBuddy -c "Print status" "$dmg.notary.plist")
id=$(/usr/libexec/PlistBuddy -c "Print id" "$dmg.notary.plist")
if [ "$status" != "Accepted" ]; then
  echo "Notarization status: $status. Apple's log:" >&2
  notary log "$id" >&2 || true
  exit 1
fi
rm -f "$dmg.notary.plist"

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
# Check the app inside the DMG the way Gatekeeper will.
mount=$(mktemp -d)
trap 'hdiutil detach -quiet "$mount" 2>/dev/null; rmdir "$mount" 2>/dev/null' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
spctl --assess --type execute -vv "$mount/MacControl.app"
codesign --verify --deep --strict "$mount/MacControl.app"
spctl --assess --type open --context context:primary-signature -vv "$dmg"
echo "Notarized and stapled: $dmg"
