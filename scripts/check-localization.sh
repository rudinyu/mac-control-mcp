#!/bin/sh
# Checks App/Localization/*.json against the strings the app actually uses. The Swift compiler lists every
# localizable string (SwiftUI text literals and String(localized:)); each must have a translation whose
# format specifiers match, and no translation may be left over.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$project_dir/.build/locstrings"
rm -rf "$out"
mkdir -p "$out/obj"
cd "$out/obj"
swiftc -parse-as-library -module-cache-path "$project_dir/.build/module-cache" -target x86_64-apple-macos14 \
  -emit-localized-strings -emit-localized-strings-path "$out" -module-name MacControl -c \
  "$project_dir"/App/Sources/*.swift \
  "$project_dir/Sources/MacExec/ProcessRunner.swift" \
  "$project_dir/Sources/MacExec/ContainerRuntime.swift" \
  "$project_dir/Sources/MacExec/PathGuard.swift"
python3 "$project_dir/tests/check_localization.py" "$out" "$project_dir"/App/Localization/*.json
