#!/bin/sh
# Verifies the `claude --yolo` alias that every Claude Code installer appends to
# the login shell's rc file: it is installed once (idempotent), rewrites --yolo
# to --dangerously-skip-permissions, and passes every other argument through
# untouched, in both bash and zsh.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/yolo-alias.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Fake `claude` binary that echoes its arguments one per line.
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod +x "$TEST_ROOT/bin/claude"

# Run the installer under a throwaway HOME, pretending the login shell is $1.
run_installer() {
  home="$TEST_ROOT/home-$1"
  mkdir -p "$home"
  HOME="$home" SHELL="/bin/$1" sh "$ROOT_DIR/install.sh" >/dev/null 2>&1 \
    || fail "install.sh failed for SHELL=$1"
}

check_rc() {
  shell=$1
  rc=$2
  home="$TEST_ROOT/home-$shell"
  command -v "$shell" >/dev/null 2>&1 || { echo "skip: $shell not installed"; return; }

  run_installer "$shell"
  run_installer "$shell"   # second run must not duplicate the block
  [ -f "$home/$rc" ] || fail "$shell: $rc was not created"
  n=$(grep -c '>>> claude-statusline: yolo alias >>>' "$home/$rc")
  [ "$n" = "1" ] || fail "$shell: expected 1 alias block in $rc, found $n"

  out=$(PATH="$TEST_ROOT/bin:$PATH" "$shell" -c ". '$home/$rc'; claude --yolo -p 'hi there' --model opus")
  expected=$(printf '%s\n' --dangerously-skip-permissions -p 'hi there' --model opus)
  [ "$out" = "$expected" ] || fail "$shell: got:
$out
expected:
$expected"

  out=$(PATH="$TEST_ROOT/bin:$PATH" "$shell" -c ". '$home/$rc'; claude --yolo")
  [ "$out" = "--dangerously-skip-permissions" ] || fail "$shell: bare --yolo not rewritten: $out"

  out=$(PATH="$TEST_ROOT/bin:$PATH" "$shell" -c ". '$home/$rc'; claude")
  [ -z "$out" ] || fail "$shell: no-arg call leaked arguments: $out"
  echo "ok: $shell ($rc)"
}

check_rc zsh .zshrc
check_rc bash .bashrc

# Unsupported login shell: no rc file touched, installer still succeeds.
home="$TEST_ROOT/home-fish"; mkdir -p "$home"
HOME="$home" SHELL=/usr/bin/fish sh "$ROOT_DIR/install.sh" >/dev/null 2>&1 || fail "install.sh failed for fish"
[ ! -f "$home/.zshrc" ] && [ ! -f "$home/.bashrc" ] || fail "fish: rc file should not be created"
echo "ok: fish (skipped alias)"

# Every Claude Code installer carries the same block.
for f in install.sh variants/install-pie-statusline.sh \
         variants/install-roguedbear-statusline.sh variants/install-touchbar-hammerspoon.sh; do
  grep -q 'claude-statusline: yolo alias' "$ROOT_DIR/$f" || fail "$f lacks the yolo alias block"
done
echo "ok: all installers carry the alias block"
echo "PASS"
