#!/bin/sh
# Writes Version.swift into the given folder, so both servers report the version in App/Info.plist and a
# release changes it in one place. Prints the file's path.
#   sh scripts/write-version.sh <folder>
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
folder="${1:?Usage: sh scripts/write-version.sh <folder>}"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$project_dir/App/Info.plist")
mkdir -p "$folder"
printf '// Generated from App/Info.plist by scripts/write-version.sh.\nlet productVersion = "%s"\n' "$version" > "$folder/Version.swift"
echo "$folder/Version.swift"
