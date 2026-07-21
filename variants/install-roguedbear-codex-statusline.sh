#!/bin/sh
# Backward-compatible RogueDBear entry point.

set -eu

INSTALLER_URL=${CODEX_STATUSLINE_INSTALLER_URL:-https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-codex-statusline.sh}

# This legacy entry point always installs the roguedbear preset. Presets are
# selected via the shared installer (install-codex-statusline.sh).
if [ "$#" -gt 0 ]; then
  echo "Note: arguments are ignored; this legacy URL always installs the roguedbear preset." >&2
  echo "For other presets use: curl -fsSL $INSTALLER_URL | sh -s -- <preset>" >&2
fi

if [ -n "${CODEX_STATUSLINE_INSTALLER_PATH:-}" ]; then
  exec sh "$CODEX_STATUSLINE_INSTALLER_PATH" roguedbear
fi

# Prefer a checked-out sibling installer. dirname handles a slash-less $0
# ("sh install-roguedbear-codex-statusline.sh") by resolving to ".". Guard the
# cd so a failure falls through to the download path instead of aborting.
if SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd); then
  if [ -f "$SCRIPT_DIR/install-codex-statusline.sh" ]; then
    exec sh "$SCRIPT_DIR/install-codex-statusline.sh" roguedbear
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to download the shared Codex status-line installer." >&2
  exit 1
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/codex-statusline-installer.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
curl -fsSL "$INSTALLER_URL" -o "$tmp"
sh "$tmp" roguedbear
