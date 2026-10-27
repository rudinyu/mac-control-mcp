#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary="$project_dir/.build/mac-exec-mcp"
stale=0
[ -x "$binary" ] || stale=1
for source_file in "$project_dir"/Sources/MacExec/*.swift; do
  if [ "$source_file" -nt "$binary" ]; then stale=1; fi
done

if [ "$stale" = 1 ]; then
  "$project_dir/scripts/build.sh" mac-exec >&2
fi

exec "$binary"
