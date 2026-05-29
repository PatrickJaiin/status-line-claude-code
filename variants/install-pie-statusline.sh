#!/bin/sh
# One-line installer for the pie-statusline variant.
# Downloads the variant script to ~/.claude/ and wires up settings.json.

set -e

DEST="$HOME/.claude/pie-statusline.sh"
SRC_URL="https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/pie-statusline.sh"

mkdir -p "$HOME/.claude"

# Optional: install a GPS helper so weather pings the right place.
if [ "${WITH_GPS:-0}" = "1" ]; then
  if command -v CoreLocationCLI >/dev/null 2>&1 || command -v whereami >/dev/null 2>&1; then
    echo "GPS helper already installed; skipping."
  elif command -v brew >/dev/null 2>&1; then
    echo "Installing CoreLocationCLI (you'll get a Location Services prompt on first use)..."
    brew install corelocationcli || echo "WARN: corelocationcli install failed; will fall back to IP."
  else
    echo "WARN: WITH_GPS=1 set but Homebrew not found; weather will use IP geolocation."
  fi
fi

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

CMD="sh $DEST"

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

echo "pie-statusline installed at $DEST."
echo "Restart Claude Code to see it."
