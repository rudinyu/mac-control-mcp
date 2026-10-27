#!/bin/sh
# Creates the local agent configuration from examples/, with this clone's absolute path filled in:
#   .mcp.json and CLAUDE.md for Claude Code, .codex/config.toml and AGENTS.md for Codex.
# Existing files are kept unless --force is given. Claude Desktop's configuration is shared with
# other servers, so it is printed for you to merge instead of being written.
set -eu

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help)
      echo "Usage: sh scripts/init-agents.sh [--force]"
      echo "Creates .mcp.json, CLAUDE.md, .codex/config.toml, and AGENTS.md from examples/."
      exit 0 ;;
    *) echo "Unknown option: $arg (use --help)" >&2; exit 2 ;;
  esac
done

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
placeholder="/path/to/mac-control-mcp"

newline='
'
case "$project_dir" in
  *'"'*|*'\'*|*'|'*|*'&'*|*"$newline"*)
    echo "The project path contains a character this script cannot write safely: $project_dir" >&2
    echo "Move the clone, or copy the files in examples/ by hand." >&2
    exit 1 ;;
esac

render() {
  sed "s|$placeholder|$project_dir|g" "$project_dir/examples/$1"
}

install_file() {
  source_name=$1
  target="$project_dir/$2"
  if [ -e "$target" ] && [ "$force" = 0 ]; then
    echo "kept     $2 (already exists; use --force to replace it)"
    return
  fi
  mkdir -p "$(dirname -- "$target")"
  if ! render "$source_name" > "$target.tmp" || ! mv "$target.tmp" "$target"; then
    rm -f "$target.tmp"
    echo "Could not write $2" >&2
    exit 1
  fi
  echo "wrote    $2"
}

install_file mcp.json .mcp.json
install_file CLAUDE.md CLAUDE.md
install_file codex/config.toml .codex/config.toml
install_file AGENTS.md AGENTS.md

cat <<EOF

For Claude Desktop, merge the "mac-control" entry below into "mcpServers" in
~/Library/Application Support/Claude/claude_desktop_config.json, then quit and reopen Claude:

EOF
render claude_desktop_config.json
cat <<EOF

Then grant Accessibility and Screen & System Audio Recording, in System Settings > Privacy & Security,
to the app that starts the server: your terminal for Claude Code or Codex, or Claude for Claude Desktop.
EOF
