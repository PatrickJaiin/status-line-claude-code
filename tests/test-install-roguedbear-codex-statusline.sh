#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT_DIR/variants/install-roguedbear-codex-statusline.sh"
EXPECTED_STATUS_LINE='status_line = ["model-with-reasoning", "context-used", "five-hour-limit", "weekly-limit", "current-dir", "git-branch", "used-tokens", "run-state"]'

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/roguedbear-codex-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/sh
echo "codex-cli ${FAKE_CODEX_VERSION:-0.144.1}"
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
  mkdir -p "$home"
  HOME="$home" CODEX_HOME="$codex_home" PATH="$FAKE_BIN:/usr/bin:/bin" sh "$INSTALLER" >/dev/null
}

run_default_installer() {
  home=$1
  mkdir -p "$home"
  (
    unset CODEX_HOME
    HOME="$home" PATH="$FAKE_BIN:/usr/bin:/bin" sh "$INSTALLER" >/dev/null
  )
}

test_creates_config_in_default_home() {
  home="$TEST_ROOT/default-home"
  config="$home/.codex/config.toml"

  run_default_installer "$home"

  [ -f "$config" ] || fail "default config was not created"
  assert_contains "$config" '[tui]'
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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
  assert_contains "$target" "$EXPECTED_STATUS_LINE"
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
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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

  assert_contains "$config" "$EXPECTED_STATUS_LINE"
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

  export FAKE_CODEX_VERSION=0.128.0
  if run_installer "$home" "$codex_home" 2>/dev/null; then
    unset FAKE_CODEX_VERSION
    fail "unsupported Codex version unexpectedly succeeded"
  fi
  unset FAKE_CODEX_VERSION

  [ ! -e "$config" ] || fail "unsupported Codex version created a config"
}

test_inserts_parent_before_nested_tui_table() {
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

  tui_line=$(grep -n -F '[tui]' "$config" | cut -d: -f1)
  nested_line=$(grep -n -F '[tui.keymap.global]' "$config" | cut -d: -f1)
  [ "$tui_line" -lt "$nested_line" ] || fail "[tui] was not inserted before its nested table"
  assert_contains "$config" "$EXPECTED_STATUS_LINE"
  assert_contains "$config" 'copy = "ctrl-y"'
  assert_valid_toml "$config"
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
test_inserts_parent_before_nested_tui_table

echo "PASS: roguedbear Codex installer"
