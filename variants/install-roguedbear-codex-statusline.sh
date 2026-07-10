#!/bin/sh
# Install the Codex-native approximation of the roguedbear status line.
# Codex accepts a list of built-in footer items; it does not run a status command.

set -eu

STATUS_LINE='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir", "git-branch", "used-tokens", "run-state"]'
# 0.129.0 is the first stable release with this item set and theme-colored status lines.
MIN_CODEX_VERSION="0.129.0"

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: Codex CLI is not installed or is not on PATH." >&2
  echo "Install Codex first: https://developers.openai.com/codex/cli" >&2
  exit 1
fi

if ! CODEX_VERSION=$(codex --version 2>/dev/null); then
  echo "Error: unable to run 'codex --version'." >&2
  exit 1
fi

codex_semver=$(printf '%s\n' "$CODEX_VERSION" | awk '{ print $NF }')
codex_semver=${codex_semver#v}
codex_major=${codex_semver%%.*}
codex_rest=${codex_semver#*.}
codex_minor=${codex_rest%%.*}

case "$codex_major:$codex_minor" in
  *[!0-9:]* | :* | *:)
    echo "WARN: could not parse Codex version '$CODEX_VERSION'; continuing anyway." >&2
    ;;
  *)
    if [ "$codex_major" -eq 0 ] && [ "$codex_minor" -lt 129 ]; then
      echo "Error: this status line requires Codex CLI $MIN_CODEX_VERSION or newer; found $codex_semver." >&2
      echo "Update with: codex update" >&2
      exit 1
    fi
    ;;
esac

if [ -n "${CODEX_HOME:-}" ]; then
  CODEX_DIR=$CODEX_HOME
elif [ -n "${HOME:-}" ]; then
  CODEX_DIR="$HOME/.codex"
else
  echo "Error: neither CODEX_HOME nor HOME is set." >&2
  exit 1
fi

mkdir -p "$CODEX_DIR"
umask 077

CONFIG_PATH="$CODEX_DIR/config.toml"
CONFIG=$CONFIG_PATH
symlink_count=0
while [ -L "$CONFIG" ]; do
  symlink_count=$((symlink_count + 1))
  if [ "$symlink_count" -gt 20 ]; then
    echo "Error: too many symbolic links while resolving $CONFIG_PATH." >&2
    exit 1
  fi

  link_target=$(readlink "$CONFIG")
  case "$link_target" in
    /*) CONFIG=$link_target ;;
    *) CONFIG="$(dirname "$CONFIG")/$link_target" ;;
  esac
done

if [ -e "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
  echo "Error: Codex config is not a regular file: $CONFIG" >&2
  exit 1
fi

CONFIG_DIR=$(dirname "$CONFIG")
mkdir -p "$CONFIG_DIR"

tmp=$(mktemp "$CONFIG_DIR/.codex-config.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

input=/dev/null
[ -f "$CONFIG" ] && input=$CONFIG

if ! awk -v status_line="$STATUS_LINE" '
function scan_multiline(line, initial, state, quote, escaped, pos, character) {
  state = initial
  quote = ""
  escaped = 0

  for (pos = 1; pos <= length(line); pos++) {
    character = substr(line, pos, 1)

    if (state != "") {
      if (substr(line, pos, 3) == state && (state == "\047\047\047" || !escaped)) {
        state = ""
        pos += 2
        escaped = 0
      } else if (state == "\"\"\"" && character == "\\") {
        escaped = !escaped
      } else {
        escaped = 0
      }
    } else if (quote == "\"") {
      if (escaped) {
        escaped = 0
      } else if (character == "\\") {
        escaped = 1
      } else if (character == "\"") {
        quote = ""
      }
    } else if (quote == "\047") {
      if (character == "\047") {
        quote = ""
      }
    } else if (character == "#") {
      break
    } else if (substr(line, pos, 3) == "\"\"\"") {
      state = "\"\"\""
      pos += 2
    } else if (substr(line, pos, 3) == "\047\047\047") {
      state = "\047\047\047"
      pos += 2
    } else if (character == "\"" || character == "\047") {
      quote = character
    }
  }

  return state
}

function bracket_delta(value, quote, escaped, pos, character, delta) {
  quote = ""
  escaped = 0
  delta = 0

  for (pos = 1; pos <= length(value); pos++) {
    character = substr(value, pos, 1)

    if (quote == "\"") {
      if (escaped) {
        escaped = 0
      } else if (character == "\\") {
        escaped = 1
      } else if (character == "\"") {
        quote = ""
      }
    } else if (quote == "\047") {
      if (character == "\047") {
        quote = ""
      }
    } else if (character == "#") {
      break
    } else if (character == "\"" || character == "\047") {
      quote = character
    } else if (character == "[") {
      delta++
    } else if (character == "]") {
      delta--
    }
  }

  return delta
}

function opening_multiline_delimiter(line, code, double_quote, single_quote) {
  return scan_multiline(line, "")
}

function emit_missing_settings(added) {
  added = 0
  if (!saw_status_line) {
    print status_line
    saw_status_line = 1
    added = 1
  }
  if (!saw_colors) {
    print "status_line_use_colors = true"
    saw_colors = 1
    added = 1
  }
  return added
}

function is_tui_table(line) {
  return line ~ /^[[:space:]]*\[[[:space:]]*(tui|"tui"|\047tui\047)[[:space:]]*\][[:space:]]*(#.*)?$/
}

function is_nested_tui_table(line) {
  return line ~ /^[[:space:]]*\[[[:space:]]*(tui|"tui"|\047tui\047)[[:space:]]*[.]/
}

function is_any_table(line) {
  return line ~ /^[[:space:]]*\[/
}

function is_status_line_key(line) {
  return line ~ /^[[:space:]]*(status_line|"status_line"|\047status_line\047)[[:space:]]*=/
}

function is_status_line_colors_key(line) {
  return line ~ /^[[:space:]]*(status_line_use_colors|"status_line_use_colors"|\047status_line_use_colors\047)[[:space:]]*=/
}

BEGIN {
  in_tui = 0
  saw_tui = 0
  saw_status_line = 0
  saw_colors = 0
  skipping_status_line = 0
  status_line_depth = 0
  status_multiline_delimiter = ""
  at_root = 1
  multiline_delimiter = ""
}

{
  line = $0

  if (skipping_status_line) {
    if (status_multiline_delimiter != "") {
      status_multiline_delimiter = scan_multiline(line, status_multiline_delimiter)
      next
    }

    delimiter = opening_multiline_delimiter(line)
    if (delimiter != "") {
      status_multiline_delimiter = delimiter
      next
    }

    status_line_depth += bracket_delta(line)
    if (status_line_depth <= 0) {
      skipping_status_line = 0
    }
    next
  }

  if (multiline_delimiter != "") {
    print line
    multiline_delimiter = scan_multiline(line, multiline_delimiter)
    next
  }

  delimiter = opening_multiline_delimiter(line)
  if (delimiter != "") {
    print line
    multiline_delimiter = delimiter
    next
  }

  if (is_tui_table(line)) {
    if (saw_tui) {
      print "Error: config contains more than one [tui] table; refusing to rewrite it." > "/dev/stderr"
      exit 42
    }
    saw_tui = 1
    in_tui = 1
    at_root = 0
    print line
    next
  }

  if (!saw_tui && is_nested_tui_table(line)) {
    print "[tui]"
    emit_missing_settings()
    print ""
    saw_tui = 1
    in_tui = 0
    at_root = 0
    print line
    next
  }

  if (is_any_table(line)) {
    if (in_tui && emit_missing_settings()) {
      print ""
    }
    in_tui = 0
    at_root = 0
    print line
    next
  }

  if (at_root && line ~ /^[[:space:]]*(tui|"tui"|\047tui\047)[[:space:]]*([.][^=]*)?=/) {
    print "Error: inline or dotted tui configuration is not supported by this installer; use /statusline instead." > "/dev/stderr"
    exit 43
  }

  if (in_tui && is_status_line_key(line)) {
    if (saw_status_line) {
      print "Error: config contains duplicate tui.status_line keys; refusing to rewrite it." > "/dev/stderr"
      exit 44
    }
    print status_line
    saw_status_line = 1

    value = line
    sub(/^[^=]*=/, "", value)
    status_line_depth = bracket_delta(value)
    status_multiline_delimiter = opening_multiline_delimiter(value)
    if (status_line_depth > 0) {
      skipping_status_line = 1
    }
    next
  }

  if (in_tui && is_status_line_colors_key(line)) {
    if (saw_colors) {
      print "Error: config contains duplicate tui.status_line_use_colors keys; refusing to rewrite it." > "/dev/stderr"
      exit 45
    }
    print "status_line_use_colors = true"
    saw_colors = 1
    next
  }

  print line
}

END {
  if (multiline_delimiter != "") {
    print "Error: config contains an unterminated multiline string." > "/dev/stderr"
    exit 47
  }

  if (skipping_status_line) {
    print "Error: tui.status_line contains an unterminated array." > "/dev/stderr"
    exit 46
  }

  if (in_tui) {
    emit_missing_settings()
  } else if (!saw_tui) {
    if (NR > 0) {
      print ""
    }
    print "[tui]"
    emit_missing_settings()
  }
}
' "$input" > "$tmp"; then
  echo "Codex config was not changed." >&2
  exit 1
fi

if [ -f "$CONFIG" ] && cmp -s "$CONFIG" "$tmp"; then
  echo "roguedbear Codex status line is already configured in $CONFIG_PATH."
  exit 0
fi

backup=""
if [ -f "$CONFIG" ]; then
  backup="$CONFIG.bak"
  if [ ! -e "$backup" ]; then
    cp -p "$CONFIG" "$backup"
  fi
fi

mv "$tmp" "$CONFIG"
trap - EXIT HUP INT TERM

echo "roguedbear Codex status line configured in $CONFIG_PATH ($CODEX_VERSION)."
if [ "$CONFIG" != "$CONFIG_PATH" ]; then
  echo "Symlink target updated: $CONFIG"
fi
if [ -n "$backup" ]; then
  echo "Original config backup: $backup"
fi
echo "Restart Codex to use it, or run /statusline to customize the footer."
echo "Note: Codex supports a one-line native footer, so weather, music, CPU/RAM, battery, cost, and custom bars are unavailable."
