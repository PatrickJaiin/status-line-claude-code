#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT_DIR/variants/install-codex-statusline.sh"
ROGUEDBEAR_WRAPPER="$ROOT_DIR/variants/install-roguedbear-codex-statusline.sh"
EXPECTED_DEFAULT='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "used-tokens"]'
EXPECTED_ROGUEDBEAR='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir", "git-branch", "total-input-tokens", "run-state"]'
EXPECTED_PIE='status_line = ["model", "context-used", "five-hour-limit", "weekly-limit", "used-tokens"]'
EXPECTED_TOUCHBAR='status_line = ["model-with-reasoning", "context-used", "used-tokens"]'
REAL_CODEX=$(command -v codex 2>/dev/null || true)

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-statusline-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/sh
if [ "${FAKE_CODEX_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "${FAKE_CODEX_VERSION_OUTPUT:-codex-cli 0.144.4}"
EOF
chmod +x "$FAKE_BIN/codex"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"
}

assert_count() {
  expected=$1
  pattern=$2
  file=$3
  actual=$(grep -F -c -- "$pattern" "$file" || true)
  [ "$actual" -eq "$expected" ] || fail "$file contains '$pattern' $actual times, expected $expected"
}

assert_valid_toml() {
  file=$1
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import pathlib
import sys
import tomllib

tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
PY
  fi
}

run_installer() {
  home=$1
  codex_home=$2
  preset=${3:-roguedbear}
  mkdir -p "$home"
  HOME="$home" CODEX_HOME="$codex_home" PATH="$FAKE_BIN:/usr/bin:/bin" sh "$INSTALLER" "$preset" >/dev/null
}

run_default_installer() {
  home=$1
  mkdir -p "$home"
  if [ "$#" -gt 1 ]; then
    preset=$2
    (
      unset CODEX_HOME
      HOME="$home" PATH="$FAKE_BIN:/usr/bin:/bin" sh "$INSTALLER" "$preset" >/dev/null
    )
  else
    (
      unset CODEX_HOME
      HOME="$home" PATH="$FAKE_BIN:/usr/bin:/bin" sh "$INSTALLER" >/dev/null
    )
  fi
}

test_creates_config_in_default_home() {
  home="$TEST_ROOT/default-home"
  config="$home/.codex/config.toml"

  run_default_installer "$home"

  [ -f "$config" ] || fail "default config was not created"
  assert_contains "$config" '[tui]'
  assert_contains "$config" "$EXPECTED_DEFAULT"
  assert_contains "$config" 'status_line_use_colors = true'
  assert_valid_toml "$config"
}

test_preserves_existing_config_and_is_idempotent() {
  home="$TEST_ROOT/existing-home"
  codex_home="$home/custom codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
model = "gpt-5.4"

[tui]
terminal_title = []
status_line = ["current-dir"]
status_line_use_colors = false

[features]
memories = true
EOF
  original="$TEST_ROOT/original-config.toml"
  cp "$config" "$original"

  run_installer "$home" "$codex_home"

  assert_contains "$config" 'model = "gpt-5.4"'
  assert_contains "$config" 'terminal_title = []'
  assert_contains "$config" '[features]'
  assert_contains "$config" 'memories = true'
  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_contains "$config" 'status_line_use_colors = true'
  assert_count 1 '[tui]' "$config"
  assert_count 1 'status_line = ' "$config"
  assert_count 1 'status_line_use_colors = ' "$config"
  assert_valid_toml "$config"
  [ -f "$config.bak" ] || fail "existing config was not backed up"
  cmp -s "$original" "$config.bak" || fail "backup does not match the pre-install config"

  first_result="$TEST_ROOT/first-result.toml"
  cp "$config" "$first_result"
  run_installer "$home" "$codex_home"
  if ! cmp -s "$first_result" "$config"; then
    diff -u "$first_result" "$config" >&2 || true
    fail "second install changed the config"
  fi
  cmp -s "$original" "$config.bak" || fail "second install overwrote the original backup"
}

test_replaces_multiline_status_line() {
  home="$TEST_ROOT/multiline-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
[tui]
# Keep this comment.
status_line = [
  "model]", # A comment containing another closing bracket: ]
  "current[dir",
]
terminal_title = ["project-name"]

[tui.keymap.global]
copy = "ctrl-y"
EOF

  run_installer "$home" "$codex_home"

  assert_contains "$config" '# Keep this comment.'
  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_contains "$config" 'terminal_title = ["project-name"]'
  assert_contains "$config" '[tui.keymap.global]'
  assert_contains "$config" 'copy = "ctrl-y"'
  assert_count 1 'status_line = ' "$config"
  if grep -F '  "model]",' "$config" >/dev/null || grep -F '  "current[dir",' "$config" >/dev/null; then
    fail "old multiline status line body was left behind"
  fi
  assert_valid_toml "$config"
}

test_preserves_symlinked_config() {
  home="$TEST_ROOT/symlink-home"
  codex_home="$home/.codex"
  target_dir="$home/dotfiles"
  target="$target_dir/codex.toml"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home" "$target_dir"
  cat > "$target" <<'EOF'
model = "gpt-5.4"
EOF
  ln -s ../dotfiles/codex.toml "$config"

  run_installer "$home" "$codex_home"

  [ -L "$config" ] || fail "installer replaced the config symlink"
  assert_contains "$target" 'model = "gpt-5.4"'
  assert_contains "$target" "$EXPECTED_ROGUEDBEAR"
  [ -f "$target.bak" ] || fail "symlink target was not backed up"
  assert_valid_toml "$target"
}

test_rejects_inline_tui_without_changes() {
  home="$TEST_ROOT/inline-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
tui = { status_line = ["current-dir"] }
EOF
  original="$TEST_ROOT/inline-original.toml"
  cp "$config" "$original"

  if run_installer "$home" "$codex_home" 2>/dev/null; then
    fail "inline tui config unexpectedly succeeded"
  fi
  cmp -s "$original" "$config" || fail "inline tui config was changed after rejection"
  [ ! -e "$config.bak" ] || fail "rejected config unexpectedly created a backup"
}

test_updates_quoted_tui_keys() {
  home="$TEST_ROOT/quoted-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
["tui"]
"status_line" = ["current-dir"]
'status_line_use_colors' = false
terminal_title = []
EOF

  run_installer "$home" "$codex_home"

  assert_contains "$config" '["tui"]'
  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_contains "$config" 'status_line_use_colors = true'
  assert_contains "$config" 'terminal_title = []'
  assert_count 1 'status_line = ' "$config"
  assert_count 1 'status_line_use_colors = ' "$config"
  if grep -F '"status_line" =' "$config" >/dev/null || grep -F "'status_line_use_colors' =" "$config" >/dev/null; then
    fail "quoted status-line keys were left behind"
  fi
  assert_valid_toml "$config"
}

test_ignores_table_text_inside_multiline_strings() {
  home="$TEST_ROOT/multiline-string-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
literal_marker = "literal ''' marker"
developer_instructions = """
This is example text, not configuration:
[tui]
status_line = ["not-config"]
"""
instructions = '''
Another example:
[tui]
status_line = ["also-not-config"]
'''
model = "gpt-5.4"
EOF

  run_installer "$home" "$codex_home"

  assert_contains "$config" 'status_line = ["not-config"]'
  assert_contains "$config" 'status_line = ["also-not-config"]'
  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_count 3 '[tui]' "$config"
  assert_valid_toml "$config"
}

test_replaces_status_line_with_triple_quoted_item() {
  home="$TEST_ROOT/triple-status-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
[tui]
status_line = [
  """old
  value""",
]
terminal_title = []
EOF

  run_installer "$home" "$codex_home"

  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_contains "$config" 'terminal_title = []'
  if grep -F 'old' "$config" >/dev/null || grep -F 'value' "$config" >/dev/null; then
    fail "old triple-quoted status-line item was left behind"
  fi
  assert_valid_toml "$config"
}

test_rejects_unsupported_codex() {
  home="$TEST_ROOT/old-codex-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"

  export FAKE_CODEX_VERSION_OUTPUT='codex-cli 0.128.0'
  if run_installer "$home" "$codex_home" 2>/dev/null; then
    unset FAKE_CODEX_VERSION_OUTPUT
    fail "unsupported Codex version unexpectedly succeeded"
  fi
  unset FAKE_CODEX_VERSION_OUTPUT

  [ ! -e "$config" ] || fail "unsupported Codex version created a config"
}

test_preserves_nested_tui_table_without_parent() {
  home="$TEST_ROOT/nested-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
model = "gpt-5.4"

[tui.keymap.global]
copy = "ctrl-y"
EOF

  run_installer "$home" "$codex_home"

  assert_contains "$config" '[tui]'
  assert_contains "$config" "$EXPECTED_ROGUEDBEAR"
  assert_contains "$config" 'copy = "ctrl-y"'
  # Pure-shell placement check (assert_valid_toml no-ops without python3):
  # the injected status_line must sit under the [tui] header, before any
  # later table header.
  tui_line=$(grep -n -x -F '[tui]' "$config" | head -1 | cut -d: -f1)
  sl_line=$(grep -n -F "$EXPECTED_ROGUEDBEAR" "$config" | head -1 | cut -d: -f1)
  [ -n "$tui_line" ] && [ -n "$sl_line" ] && [ "$tui_line" -lt "$sl_line" ] \
    || fail "status_line was not emitted after the [tui] header"
  next_table=$(awk -v start="$tui_line" 'NR > start && /^[[:space:]]*\[/ { print NR; exit }' "$config")
  [ -z "$next_table" ] || [ "$sl_line" -lt "$next_table" ] \
    || fail "status_line landed outside the [tui] table"
  assert_valid_toml "$config"
}

test_presets_have_distinct_native_layouts() {
  home="$TEST_ROOT/preset-home"

  for preset in default roguedbear pie touchbar; do
    codex_home="$home/$preset"
    run_installer "$home" "$codex_home" "$preset"
    config="$codex_home/config.toml"
    assert_contains "$config" '[tui]'
    assert_contains "$config" 'status_line_use_colors = true'
    assert_count 1 'status_line = ' "$config"
    assert_valid_toml "$config"

    case "$preset" in
      default) assert_contains "$config" "$EXPECTED_DEFAULT" ;;
      roguedbear) assert_contains "$config" "$EXPECTED_ROGUEDBEAR" ;;
      pie) assert_contains "$config" "$EXPECTED_PIE" ;;
      touchbar) assert_contains "$config" "$EXPECTED_TOUCHBAR" ;;
    esac
  done
}

test_roguedbear_compatibility_wrapper() {
  home="$TEST_ROOT/compat-wrapper-home"
  codex_home="$home/.codex"
  mkdir -p "$home"

  HOME="$home" \
    CODEX_HOME="$codex_home" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    sh "$ROGUEDBEAR_WRAPPER" >/dev/null

  assert_contains "$codex_home/config.toml" "$EXPECTED_ROGUEDBEAR"
}

test_real_codex_loads_each_preset() {
  [ -n "$REAL_CODEX" ] || return 0

  for preset in default roguedbear pie touchbar; do
    # Install into this test's own fixture so the check never depends on
    # another test's directory layout or ordering.
    home="$TEST_ROOT/doctor-home/$preset"
    codex_home="$home/.codex"
    run_installer "$home" "$codex_home" "$preset"

    doctor_output=$(
      CODEX_HOME="$codex_home" "$REAL_CODEX" --strict-config doctor --json 2>/dev/null
    ) || true
    if [ -z "$doctor_output" ]; then
      # Older Codex builds (including 0.129.x) predate `doctor --json`; a
      # correct installer is not a test failure on those.
      echo "note: skipping real-Codex preset check; 'codex --strict-config doctor --json' is unsupported by $REAL_CODEX" >&2
      return 0
    fi
    # Find the "status" that belongs to config.load. Works for both
    # pretty-printed (status on a later line) and compact one-line JSON
    # (first status after the config.load key on the same record).
    if ! printf '%s\n' "$doctor_output" | awk '
      index($0, "\"config.load\"") {
        rest = substr($0, index($0, "\"config.load\""))
        if (match(rest, /"status"[[:space:]]*:[[:space:]]*"[A-Za-z_]+"/)) {
          found = (substr(rest, RSTART, RLENGTH) ~ /"ok"$/) ? 1 : 0
          decided = 1
          exit
        }
        in_config = 1
        next
      }
      in_config && /"status"[[:space:]]*:/ {
        found = ($0 ~ /"status"[[:space:]]*:[[:space:]]*"ok"/) ? 1 : 0
        decided = 1
        exit
      }
      END { exit((decided && found) ? 0 : 1) }
    '; then
      fail "real Codex could not load the $preset preset"
    fi
  done
}

test_switches_presets_without_duplicate_keys() {
  home="$TEST_ROOT/switch-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"

  run_installer "$home" "$codex_home" default
  run_installer "$home" "$codex_home" pie

  assert_contains "$config" "$EXPECTED_PIE"
  if grep -F -- "$EXPECTED_DEFAULT" "$config" >/dev/null; then
    fail "switching to pie left the default preset behind"
  fi
  assert_count 1 'status_line = ' "$config"
  assert_count 1 'status_line_use_colors = ' "$config"
  assert_valid_toml "$config"
}

test_rejects_unknown_preset_without_changes() {
  home="$TEST_ROOT/unknown-preset-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  printf '%s\n' 'model = "gpt-5.4"' > "$config"
  original="$TEST_ROOT/unknown-preset-original.toml"
  cp "$config" "$original"

  if run_installer "$home" "$codex_home" not-a-preset 2>/dev/null; then
    fail "unknown preset unexpectedly succeeded"
  fi
  cmp -s "$original" "$config" || fail "unknown preset changed the config"
  [ ! -e "$config.bak" ] || fail "unknown preset created a backup"
}

test_accepts_parent_table_after_nested_table() {
  home="$TEST_ROOT/parent-after-child-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  cat > "$config" <<'EOF'
[tui.keymap.global]
copy = "ctrl-y"

[tui]
status_line = ["current-dir"]
terminal_title = []
EOF

  run_installer "$home" "$codex_home" pie

  assert_contains "$config" "$EXPECTED_PIE"
  assert_contains "$config" 'copy = "ctrl-y"'
  assert_contains "$config" 'terminal_title = []'
  assert_count 1 '[tui]' "$config"
  assert_valid_toml "$config"
}

test_rejects_malformed_codex_version() {
  home="$TEST_ROOT/malformed-version-home"
  codex_home="$home/.codex"

  export FAKE_CODEX_VERSION_OUTPUT='codex-cli development-build'
  if run_installer "$home" "$codex_home" default 2>/dev/null; then
    unset FAKE_CODEX_VERSION_OUTPUT
    fail "malformed Codex version unexpectedly succeeded"
  fi
  unset FAKE_CODEX_VERSION_OUTPUT

  [ ! -e "$codex_home/config.toml" ] || fail "malformed Codex version created a config"
}

test_accepts_future_major_codex_version() {
  home="$TEST_ROOT/future-version-home"
  codex_home="$home/.codex"

  export FAKE_CODEX_VERSION_OUTPUT='codex-cli v1.0.0-beta.1'
  run_installer "$home" "$codex_home" default
  unset FAKE_CODEX_VERSION_OUTPUT

  assert_contains "$codex_home/config.toml" "$EXPECTED_DEFAULT"
}

test_rejects_dangling_backup_symlink() {
  home="$TEST_ROOT/backup-symlink-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  outside="$TEST_ROOT/backup-symlink-outside"
  mkdir -p "$codex_home"
  printf '%s\n' 'model = "gpt-5.4"' > "$config"
  ln -s "$outside" "$config.bak"
  original="$TEST_ROOT/backup-symlink-original.toml"
  cp "$config" "$original"

  if run_installer "$home" "$codex_home" default 2>/dev/null; then
    fail "dangling backup symlink unexpectedly succeeded"
  fi
  cmp -s "$original" "$config" || fail "backup rejection changed the config"
  [ ! -e "$outside" ] || fail "backup symlink target was written"
}

test_preserves_config_permissions() {
  home="$TEST_ROOT/permissions-home"
  codex_home="$home/.codex"
  config="$codex_home/config.toml"
  mkdir -p "$codex_home"
  printf '%s\n' 'model = "gpt-5.4"' > "$config"
  chmod 640 "$config"

  run_installer "$home" "$codex_home" default

  # GNU stat treats -f as --file-system, so probe -c first (fails cleanly on BSD).
  mode=$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")
  [ "$mode" = "640" ] || fail "config mode changed to $mode, expected 640"
}

test_creates_config_in_default_home
test_preserves_existing_config_and_is_idempotent
test_replaces_multiline_status_line
test_preserves_symlinked_config
test_rejects_inline_tui_without_changes
test_updates_quoted_tui_keys
test_ignores_table_text_inside_multiline_strings
test_replaces_status_line_with_triple_quoted_item
test_rejects_unsupported_codex
test_preserves_nested_tui_table_without_parent
test_presets_have_distinct_native_layouts
test_roguedbear_compatibility_wrapper
test_real_codex_loads_each_preset
test_switches_presets_without_duplicate_keys
test_rejects_unknown_preset_without_changes
test_accepts_parent_table_after_nested_table
test_rejects_malformed_codex_version
test_accepts_future_major_codex_version
test_rejects_dangling_backup_symlink
test_preserves_config_permissions

echo "PASS: Codex status-line installer"
