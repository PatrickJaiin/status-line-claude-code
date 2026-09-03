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

# Install a /toggle slash command so the status line can be flipped from inside
# Claude Code. Skipped if an unrelated /toggle command already exists.
CMD_FILE="$HOME/.claude/commands/toggle.md"
mkdir -p "$HOME/.claude/commands"
if [ -f "$CMD_FILE" ] && ! grep -q statusline "$CMD_FILE" 2>/dev/null; then
  echo "Note: $CMD_FILE already exists; skipping the /toggle command install."
else
  cat > "$CMD_FILE" <<EOF
---
description: Toggle the Claude Code status line on or off
allowed-tools: Bash(sh $DEST:*)
---

!\`sh $DEST toggle\`

The command above already flipped the status line. Tell the user its new state in one short sentence.
EOF
fi

# Install a `claude --yolo` shorthand for `claude --dangerously-skip-permissions`.
# A shell function in the login shell's rc file rewrites the flag and hands off
# to the real binary. Marker-guarded, so re-running the installer is a no-op.
case "$(basename "${SHELL:-sh}")" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash)
    if [ -f "$HOME/.bashrc" ] || [ ! -f "$HOME/.bash_profile" ]; then
      RC_FILE="$HOME/.bashrc"
    else
      RC_FILE="$HOME/.bash_profile"
    fi
    ;;
  *)    RC_FILE="" ;;
esac
if [ -z "$RC_FILE" ]; then
  echo "Note: login shell ${SHELL:-unknown} is not bash/zsh; skipping the 'claude --yolo' alias."
elif grep -q 'claude-statusline: yolo alias' "$RC_FILE" 2>/dev/null; then
  : # already installed
else
  cat >> "$RC_FILE" <<'EOF'

# >>> claude-statusline: yolo alias >>>
# `claude --yolo` == `claude --dangerously-skip-permissions`
claude() {
  local _args=() _a
  for _a in "$@"; do
    [ "$_a" = "--yolo" ] && _a="--dangerously-skip-permissions"
    _args+=("$_a")
  done
  command claude "${_args[@]}"
}
# <<< claude-statusline: yolo alias <<<
EOF
  echo "Added 'claude --yolo' alias to $RC_FILE (open a new shell to use it)."
fi

echo "pie-statusline installed at $DEST."
echo "Restart Claude Code to see it."
