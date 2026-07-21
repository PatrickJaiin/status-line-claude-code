#!/bin/sh
# Install a Codex-native status-line preset.
#
# Usage:
#   install-codex-statusline.sh [default|roguedbear|pie|touchbar]
#
# Codex accepts an ordered list of built-in footer items. It does not run a
# custom status command, so these presets preserve each layout's information
# priority rather than its Claude-only glyphs, bars, or external telemetry.

set -eu

PRESET=${1:-${CODEX_STATUSLINE_PRESET:-default}}
case "$PRESET" in
  default | base)
    PRESET=default
    STATUS_LINE='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "used-tokens"]'
    ;;
  roguedbear | rogue)
    PRESET=roguedbear
    STATUS_LINE='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir", "git-branch", "total-input-tokens", "run-state"]'
    ;;
  pie | compact)
    PRESET=pie
    STATUS_LINE='status_line = ["model", "context-used", "five-hour-limit", "weekly-limit", "used-tokens"]'
    ;;
  touchbar | touchbar-fallback)
    PRESET=touchbar
    STATUS_LINE='status_line = ["model-with-reasoning", "context-used", "used-tokens"]'
    ;;
  *)
    echo "Error: unknown Codex status-line preset '$PRESET'." >&2
    echo "Choose one of: default, roguedbear, pie, touchbar." >&2
    exit 2
    ;;
esac

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

codex_semver=$(printf '%s\n' "$CODEX_VERSION" | awk '
  {
    for (i = 1; i <= NF; i++) {
      candidate = $i
      sub(/^v/, "", candidate)
      if (candidate ~ /^[0-9]+[.][0-9]+([.][0-9]+)?([-+].*)?$/) {
        print candidate
        exit
      }
    }
  }
')
codex_semver=${codex_semver#v}
# Strip any prerelease/build suffix ("0.130-rc1" -> "0.130") before splitting;
# the field-scan regex above deliberately admits suffixed versions.
codex_core=${codex_semver%%[-+]*}
codex_major=${codex_core%%.*}
codex_rest=${codex_core#*.}
codex_minor=${codex_rest%%.*}
codex_patch=0
case "$codex_core" in *.*.*) codex_patch=${codex_core##*.} ;; esac

case "$codex_major" in '' | *[!0-9]*) codex_version_invalid=1 ;; *) codex_version_invalid=0 ;; esac
case "$codex_minor" in '' | *[!0-9]*) codex_version_invalid=1 ;; esac
case "$codex_patch" in '' | *[!0-9]*) codex_patch=0 ;; esac
if [ "$codex_version_invalid" -eq 1 ]; then
  echo "Error: could not parse Codex version '$CODEX_VERSION'." >&2
  exit 1
fi
min_major=${MIN_CODEX_VERSION%%.*}
min_rest=${MIN_CODEX_VERSION#*.}
min_minor=${min_rest%%.*}
min_patch=${min_rest#*.}
if [ "$codex_major" -lt "$min_major" ] ||
  { [ "$codex_major" -eq "$min_major" ] && [ "$codex_minor" -lt "$min_minor" ]; } ||
  { [ "$codex_major" -eq "$min_major" ] && [ "$codex_minor" -eq "$min_minor" ] && [ "$codex_patch" -lt "$min_patch" ]; }; then
  echo "Error: this status line requires Codex CLI $MIN_CODEX_VERSION or newer; found $codex_semver." >&2
  echo "Update with: codex update" >&2
  exit 1
fi

if [ -n "${CODEX_HOME:-}" ]; then
  CODEX_DIR=$CODEX_HOME
elif [ -n "${HOME:-}" ]; then
  CODEX_DIR="$HOME/.codex"
else
  echo "Error: neither CODEX_HOME nor HOME is set." >&2
  exit 1
fi

umask 077
mkdir -p "$CODEX_DIR"

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

function opening_multiline_delimiter(line) {
  return scan_multiline(line, "")
}

# Walk one line of the old status_line value in a single pass, updating the
# shared skip state: status_multiline_delimiter (open triple-quote, if any),
# status_line_depth (net bracket depth outside strings), and status_escaped.
# Basic strings cannot span lines in TOML, so status_quote resets on entry.
function status_skip_line(line, pos, character) {
  status_quote = ""
  pos = 1
  while (pos <= length(line)) {
    character = substr(line, pos, 1)
    if (status_multiline_delimiter != "") {
      if (substr(line, pos, 3) == status_multiline_delimiter && (status_multiline_delimiter == "\047\047\047" || !status_escaped)) {
        status_multiline_delimiter = ""
        status_escaped = 0
        pos += 3
        continue
      }
      if (status_multiline_delimiter == "\"\"\"" && character == "\\") {
        status_escaped = !status_escaped
      } else {
        status_escaped = 0
      }
      pos++
      continue
    }
    if (status_quote == "\"") {
      if (status_escaped) {
        status_escaped = 0
      } else if (character == "\\") {
        status_escaped = 1
      } else if (character == "\"") {
        status_quote = ""
      }
      pos++
      continue
    }
    if (status_quote == "\047") {
      if (character == "\047") {
        status_quote = ""
      }
      pos++
      continue
    }
    if (character == "#") {
      break
    }
    if (substr(line, pos, 3) == "\"\"\"") {
      status_multiline_delimiter = "\"\"\""
      pos += 3
      continue
    }
    if (substr(line, pos, 3) == "\047\047\047") {
      status_multiline_delimiter = "\047\047\047"
      pos += 3
      continue
    }
    if (character == "\"" || character == "\047") {
      status_quote = character
      pos++
      continue
    }
    if (character == "[") {
      status_line_depth++
    }
    if (character == "]") {
      status_line_depth--
    }
    pos++
  }
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
  status_escaped = 0
  status_quote = ""
  at_root = 1
  multiline_delimiter = ""
  array_depth = 0
}

{
  line = $0

  if (skipping_status_line) {
    status_skip_line(line)
    if (status_multiline_delimiter == "" && status_line_depth <= 0) {
      skipping_status_line = 0
    }
    next
  }

  if (multiline_delimiter != "") {
    print line
    multiline_delimiter = scan_multiline(line, multiline_delimiter)
    next
  }

  # Continuation lines of a multiline array value (any key other than
  # status_line) pass through verbatim — a leading "[" here is an array
  # item, not a table header.
  if (array_depth > 0) {
    print line
    delimiter = opening_multiline_delimiter(line)
    if (delimiter != "") {
      multiline_delimiter = delimiter
    } else {
      array_depth += bracket_delta(line)
      if (array_depth < 0) array_depth = 0
    }
    next
  }

  # Check for the status_line key before the generic multiline handling so a
  # value opening a triple-quoted string on the key line is still replaced.
  if (in_tui && is_status_line_key(line)) {
    if (saw_status_line) {
      print "Error: config contains duplicate tui.status_line keys; refusing to rewrite it." > "/dev/stderr"
      exit 44
    }
    print status_line
    saw_status_line = 1

    value = line
    sub(/^[^=]*=/, "", value)
    status_line_depth = 0
    status_multiline_delimiter = ""
    status_escaped = 0
    status_skip_line(value)
    if (status_line_depth > 0 || status_multiline_delimiter != "") {
      skipping_status_line = 1
    }
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

  if (in_tui && is_status_line_colors_key(line)) {
    if (saw_colors) {
      print "Error: config contains duplicate tui.status_line_use_colors keys; refusing to rewrite it." > "/dev/stderr"
      exit 45
    }
    print "status_line_use_colors = true"
    saw_colors = 1
    next
  }

  array_depth += bracket_delta(line)
  if (array_depth < 0) array_depth = 0
  print line
}

END {
  if (multiline_delimiter != "") {
    print "Error: config contains an unterminated multiline string." > "/dev/stderr"
    exit 47
  }

  if (skipping_status_line) {
    print "Error: tui.status_line contains an unterminated value." > "/dev/stderr"
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
  echo "$PRESET Codex status line is already configured in $CONFIG_PATH."
  exit 0
fi

backup=""
if [ -f "$CONFIG" ]; then
  backup="$CONFIG.bak"
  if [ ! -f "$backup" ]; then
    # A copy is about to happen: never write through a symlink (including a
    # dangling one) or onto a non-regular path. A backup that already exists
    # as a regular file — even via a symlink — is left alone above.
    if [ -L "$backup" ] || [ -e "$backup" ]; then
      echo "Error: refusing to write backup to a non-regular path: $backup" >&2
      exit 1
    fi
    cp -p "$CONFIG" "$backup"
  fi

  # GNU stat treats -f as --file-system (printing a filesystem block to stdout),
  # so probe -c first; BSD/macOS stat -c fails cleanly with no stdout.
  config_mode=$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG" 2>/dev/null || true)
  case "$config_mode" in '' | *[!0-7]*) config_mode="" ;; esac
  if [ -n "$config_mode" ]; then
    chmod "$config_mode" "$tmp"
  fi
fi

mv "$tmp" "$CONFIG"
trap - EXIT HUP INT TERM

echo "$PRESET Codex status line configured in $CONFIG_PATH ($CODEX_VERSION)."
if [ "$CONFIG" != "$CONFIG_PATH" ]; then
  echo "Symlink target updated: $CONFIG"
fi
if [ -n "$backup" ]; then
  echo "Original config backup: $backup"
fi
echo "Restart Codex to use it, or run /statusline to customize the footer."
echo "Note: Codex supports a one-line native footer, so weather, music, CPU/RAM, battery, cost, and custom bars are unavailable."
