#!/bin/sh
# One-line installer for the roguedbear-statusline variant.
# Downloads the variant script to ~/.claude/ and wires up settings.json.

set -e

DEST="$HOME/.claude/roguedbear-statusline.sh"
SRC_URL="https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/roguedbear-statusline.sh"

mkdir -p "$HOME/.claude"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SRC_URL" -o "$DEST"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$SRC_URL" -O "$DEST"
else
  echo "Error: need curl or wget to download the variant script." >&2
  exit 1
fi

chmod +x "$DEST"

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo "{}" > "$SETTINGS"

CMD="bash $DEST"

if command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq --arg cmd "$CMD" '.statusLine = {type:"command", command:$cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  python3 - "$SETTINGS" "$CMD" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    d = {}
d["statusLine"] = {"type": "command", "command": cmd}
json.dump(d, open(path, "w"), indent=2)
PY
fi

echo "roguedbear-statusline installed at $DEST."
echo "See YOUTUBE_MUSIC.md for optional YTMDesktop setup."
echo "Restart Claude Code to see it."
