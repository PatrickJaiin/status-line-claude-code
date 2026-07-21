#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT_DIR/variants/install-touchbar-hammerspoon.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/touchbar-installer-assets.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_embedded_asset() {
  marker=$1
  output=$2

  awk -v marker="$marker" '
    index($0, marker) { found = 1; next }
    found && /^printf %s / {
      line = $0
      sub(/^[^\047]*\047/, "", line)
      sub(/\047[[:space:]]*\\?[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$INSTALLER" | base64 -d > "$output"

  [ -s "$output" ] || fail "could not extract embedded asset after: $marker"
}

embedded_writer="$TEST_ROOT/touchbar-statusline.sh"
embedded_lua="$TEST_ROOT/touchbar-hammerspoon.lua"

extract_embedded_asset 'Write the status-line cache writer' "$embedded_writer"
extract_embedded_asset 'Write the Hammerspoon Lua module' "$embedded_lua"

cmp -s "$ROOT_DIR/variants/touchbar-statusline.sh" "$embedded_writer" ||
  fail "embedded cache writer is out of sync with variants/touchbar-statusline.sh"
cmp -s "$ROOT_DIR/variants/touchbar-hammerspoon.lua" "$embedded_lua" ||
  fail "embedded Lua module is out of sync with variants/touchbar-hammerspoon.lua"

grep -F 't.stale = not captured' "$embedded_lua" >/dev/null ||
  fail "embedded Lua module is missing stale-cache handling"
grep -F 'addToSystemTray(true)' "$embedded_lua" >/dev/null ||
  fail "embedded Lua module is missing the Control Strip trigger"

echo "PASS: Touch Bar installer assets"
