#!/usr/bin/env bash
# Claude Code status line — multi-line stacked layout with full telemetry.
# Inspired by github.com/PatrickJaiin/status-line-claude-code with a
# multi-row tabular layout, reset timers, and a now-playing line with
# live progress bar (YTMDesktop Companion Server + Spotify fallback).
#
# Layout:
#   ┌─ user  cwd  model  (effort)
#   ├─ ctx [bar] %                                   cpu X%       ram X%
#   ├─ 5h  [bar] % resets Xh                         bat X%+      weather
#   ├─ 7d  [bar] % resets Xd
#   ├─ dur 23m  ·  $0.42
#   ├─ status: <state>  ·  vibes: <vibe>  ·  ♪ Artist — Title [bar] m:ss
#   └─$
#
# YTMDesktop is read via its Companion Server (token at ~/.claude/.ytmd-token);
# Spotify falls back to AppleScript. Weather, sysstat, and now-playing use
# stale-while-revalidate caching to keep renders snappy.

set -u

input=$(cat)

# ── Inputs ─────────────────────────────────────────────────────────────
user=$(whoami)
cwd=$(jq -r '.workspace.current_dir // ""'                              <<<"$input")
model=$(jq -r '.model.display_name // "claude"'                         <<<"$input")
effort=$(jq -r '.effort.level // empty'                                 <<<"$input")
ctx=$(jq -r '.context_window.used_percentage // 0'                      <<<"$input" | cut -d. -f1)
h5=$(jq -r '.rate_limits.five_hour.used_percentage // 0'                <<<"$input" | cut -d. -f1)
h5_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty'            <<<"$input")
d7=$(jq -r '.rate_limits.seven_day.used_percentage // 0'                <<<"$input" | cut -d. -f1)
d7_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty'            <<<"$input")
cost=$(jq -r '.cost.total_cost_usd // empty'                            <<<"$input")
lines_added=$(jq -r '.cost.total_lines_added // 0'                      <<<"$input")
lines_removed=$(jq -r '.cost.total_lines_removed // 0'                  <<<"$input")
duration_ms=$(jq -r '.cost.total_duration_ms // empty'                  <<<"$input")
term_cols=$(jq -r '.terminal.width // empty'                            <<<"$input")
[[ -z "$term_cols" || "$term_cols" == "null" ]] && term_cols=$(tput cols 2>/dev/null || echo 100)

# ── Colors ─────────────────────────────────────────────────────────────
ORANGE=$'\033[38;5;208m'
DIM=$'\033[90m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
WHITE=$'\033[37m'
RESET=$'\033[0m'
SEP="  ${DIM}·${RESET}  "

# ── Helpers ────────────────────────────────────────────────────────────
bar() {
  local p=${1:-0} w=${2:-10}
  [[ "$p" =~ ^[0-9]+$ ]] || p=0
  (( p > 100 )) && p=100
  local f=$(( p * w / 100 )) e=$(( w - p * w / 100 )) i color
  if   (( p >= 80 )); then color="$RED"
  elif (( p >= 50 )); then color="$YELLOW"
  else                    color="$GREEN"
  fi
  printf '%s' "$color"
  for (( i=0; i<f; i++ )); do printf '●'; done
  printf '%s' "$DIM"
  for (( i=0; i<e; i++ )); do printf '○'; done
  printf '%s' "$RESET"
}

color_for_pct() {
  local p=$1
  if   (( p >= 80 )); then printf '%s' "$RED"
  elif (( p >= 50 )); then printf '%s' "$YELLOW"
  else                    printf '%s' "$GREEN"
  fi
}

time_until() {
  local target=$1 now diff epoch clean
  now=$(date +%s)
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    diff=$(( target - now ))
  else
    # Try GNU date first, then BSD date with cleaned input
    epoch=$(date -d "$target" "+%s" 2>/dev/null)
    if [[ -z "$epoch" ]]; then
      clean=${target%.*}
      clean=${clean%Z}
      clean=${clean%+*}
      clean=${clean%-[0-9][0-9]:[0-9][0-9]}
      epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
    fi
    [[ -z "$epoch" ]] && { printf '?'; return; }
    diff=$(( epoch - now ))
  fi
  if   (( diff <= 0 ))     ; then printf 'now'
  elif (( diff >= 86400 )) ; then printf '%dd%dh' $((diff/86400)) $(((diff%86400)/3600))
  elif (( diff >= 3600 ))  ; then printf '%dh%dm' $((diff/3600))  $(((diff%3600)/60))
  else                             printf '%dm'    $((diff/60))
  fi
}

visible_len() {
  local s
  s=$(printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g')
  printf '%s' "$s" | awk '{ printf "%d", length($0) }'
}

trunc() {
  local s=$1 max=${2:-60}
  if (( ${#s} > max )); then printf '%s…' "${s:0:$((max-1))}"
  else                       printf '%s' "$s"
  fi
}

# ── Cache (stale-while-revalidate) ─────────────────────────────────────
CACHE_DIR="$HOME/.cache/claude-statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null

cache_swr() {
  local key=$1
  local ttl=$2
  local fn=$3
  local file="$CACHE_DIR/$key"
  local age=0
  if [[ -f "$file" ]]; then
    local mtime
    mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    cat "$file"
    if (( age >= ttl )); then
      ( "$fn" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" ) >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  else
    ( "$fn" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

refresh_weather() {
  curl -fsS --max-time 3 'wttr.in/?format=%c+%t' 2>/dev/null | tr -d '\n'
}

refresh_sysstat() {
  top -l 1 -n 0 2>/dev/null | awk '
    /CPU usage/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /idle/) { gsub(/[^0-9.]/, "", $(i-1)); idle = $(i-1) }
      }
    }
    /^PhysMem/ {
      used = $2
      for (i = 1; i <= NF; i++) if ($i == "unused.") unused = $(i-1)
    }
    END {
      cpu = (idle == "") ? 0 : 100 - idle
      if (cpu < 0) cpu = 0
      printf "%d|%s|%s", cpu, used, unused
    }
  '
}

refresh_nowplaying() {
  # Output: "SRC|track|progress_s|duration_s|captured_epoch"
  local token="" state="" track="" pos="" dur="" raw="" rest=""
  local now_epoch
  now_epoch=$(date +%s)

  # ── YTMDesktop Companion Server (port 9863, token at ~/.claude/.ytmd-token) ──
  if [[ -r ~/.claude/.ytmd-token ]]; then
    token=$(cat ~/.claude/.ytmd-token 2>/dev/null)
    if [[ -n "$token" ]]; then
      state=$(curl -fsS --max-time 1.5 http://localhost:9863/api/v1/state \
        -H "Authorization: $token" 2>/dev/null || true)
      if [[ -n "$state" ]]; then
        IFS=$'\t' read -r track pos dur < <(jq -r '
          select((.player.trackState // -1) == 1 or (.player.trackState // -1) == 2)
          | [(.video.author // "?") + " — " + (.video.title // "?"),
             (.player.videoProgress // 0 | floor),
             (.video.durationSeconds // 0)]
          | @tsv' <<<"$state" 2>/dev/null) || true
        track=${track:-}
        if [[ -n "$track" && "$track" != "? — ?" ]]; then
          printf 'YTM|%s|%s|%s|%s' "$track" "${pos:-}" "${dur:-}" "$now_epoch"
          return
        fi
      fi
    fi
  fi

  # ── Spotify fallback ──
  if pgrep -x 'Spotify' >/dev/null 2>&1; then
    raw=$(osascript 2>/dev/null <<'OSA'
try
  tell application "Spotify"
    if player state is playing then
      set artistName to artist of current track
      set trackName to name of current track
      set pos to (player position as integer)
      set dur to ((duration of current track) / 1000) as integer
      return artistName & " — " & trackName & "||" & pos & "||" & dur
    end if
  end tell
end try
OSA
)
    if [[ -n "$raw" ]]; then
      track=${raw%%"||"*}
      rest=${raw#*"||"}
      pos=${rest%%"||"*}
      dur=${rest#*"||"}
      printf 'SPOT|%s|%s|%s|%s' "$track" "$pos" "$dur" "$now_epoch"
      return 0
    fi
  fi

  return 1   # no music data — let cache_swr preserve previous value
}

# ── Collect data ───────────────────────────────────────────────────────
now=$(date '+%H:%M')

cost_str=""
[[ -n "$cost" ]] && cost_str=$(awk -v c="$cost" 'BEGIN { printf "$%.2f", c }')

dur_str=""
if [[ -n "$duration_ms" ]]; then
  total_s=$(( ${duration_ms%.*} / 1000 ))
  if   (( total_s >= 3600 )); then dur_str=$(printf 'dur %dh%dm' $((total_s/3600)) $(((total_s%3600)/60)))
  elif (( total_s >= 60 ))  ; then dur_str=$(printf 'dur %dm'    $((total_s/60)))
  else                              dur_str=$(printf 'dur %ds'    "$total_s")
  fi
fi

weather=$(cache_swr weather 600 refresh_weather)
sysstat=$(cache_swr sysstat 5 refresh_sysstat)
np=$(cache_swr nowplaying 6 refresh_nowplaying)

cpu_pct=$(awk -F'|' '{print $1}' <<<"$sysstat")
ram_used_raw=$(awk -F'|' '{print $2}' <<<"$sysstat")
ram_unused_raw=$(awk -F'|' '{print $3}' <<<"$sysstat")

to_mb() {
  local v=$1 n u
  n=$(printf '%s' "$v" | sed -E 's/[^0-9.]//g')
  u=$(printf '%s' "$v" | sed -E 's/[0-9.]//g')
  case "$u" in
    G|g) awk -v n="$n" 'BEGIN{printf "%.0f", n * 1024}' ;;
    M|m) awk -v n="$n" 'BEGIN{printf "%.0f", n}' ;;
    K|k) awk -v n="$n" 'BEGIN{printf "%.0f", n / 1024}' ;;
    *)   printf '0' ;;
  esac
}

ram_pct=""
if [[ -n "$ram_used_raw" && -n "$ram_unused_raw" ]]; then
  um=$(to_mb "$ram_used_raw")
  fm=$(to_mb "$ram_unused_raw")
  tm=$(( um + fm ))
  (( tm > 0 )) && ram_pct=$(awk -v u="$um" -v t="$tm" 'BEGIN{printf "%.0f", u*100/t}')
fi

bat_str=""
bat_color=""
if command -v pmset >/dev/null 2>&1; then
  pmset_out=$(pmset -g batt 2>/dev/null)
  bat_pct=$(echo "$pmset_out" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
  if [[ -n "$bat_pct" ]]; then
    charging=""
    echo "$pmset_out" | grep -qE 'AC Power|charging' && charging="+"
    if   (( bat_pct >= 50 )); then bat_color="$GREEN"
    elif (( bat_pct >= 20 )); then bat_color="$YELLOW"
    else                            bat_color="$RED"
    fi
    bat_str="bat ${bat_pct}%${charging}"
  fi
fi

music=""
format_secs() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
if [[ -n "$np" ]]; then
  IFS='|' read -r mp_src mp_track mp_pos mp_dur mp_captured <<<"$np"
  icon=""
  case "$mp_src" in
    YTM)  icon="${MAGENTA}♪${RESET}" ;;
    SPOT) icon="${GREEN}♫${RESET}"   ;;
  esac
  if [[ -n "$icon" && -n "$mp_track" ]]; then
    music="$icon $(trunc "$mp_track" 50)"
    if [[ "$mp_pos" =~ ^[0-9]+$ && "$mp_dur" =~ ^[0-9]+$ && "$mp_dur" -gt 0 ]]; then
      live_pos=$mp_pos
      if [[ "$mp_captured" =~ ^[0-9]+$ ]]; then
        elapsed=$(( $(date +%s) - mp_captured ))
        live_pos=$(( mp_pos + elapsed ))
        (( live_pos > mp_dur )) && live_pos=$mp_dur
        (( live_pos < 0 )) && live_pos=0
      fi
      mus_pct=$(( live_pos * 100 / mp_dur ))
      music="$music $(bar "$mus_pct" 8) ${DIM}$(format_secs "$live_pos")/$(format_secs "$mp_dur")${RESET}"
    fi
  fi
fi

COL2=46
COL3=62

render_bar_row() {
  local label=$1 pct=$2 reset_info=$3 col2=$4 col3=$5
  local row pad
  row=$(printf '%s ' "$label")
  row+=$(bar "$pct")
  row+=$(printf ' %s%3d%%%s' "$DIM" "$pct" "$RESET")
  [[ -n "$reset_info" ]] && row+=$(printf ' %sresets %s%s' "$DIM" "$reset_info" "$RESET")

  if [[ -n "$col2" ]]; then
    pad=$(( COL2 - $(visible_len "$row") ))
    (( pad < 2 )) && pad=2
    row+=$(printf '%*s' "$pad" '')
    row+="$col2"
  fi
  if [[ -n "$col3" ]]; then
    pad=$(( COL3 - $(visible_len "$row") ))
    (( pad < 2 )) && pad=2
    row+=$(printf '%*s' "$pad" '')
    row+="$col3"
  fi

  printf '%s├─%s %b\n' "$ORANGE" "$RESET" "$row"
}

join_segs() {
  local out="" s
  for s in "$@"; do
    [[ -z "$s" ]] && continue
    if [[ -z "$out" ]]; then out="$s"
    else                     out="${out}${SEP}${s}"
    fi
  done
  printf '%s' "$out"
}

# ── Segments ───────────────────────────────────────────────────────────
seg_cpu=""; seg_ram=""; seg_bat=""; seg_weather=""; seg_dur=""; seg_cost=""
[[ -n "$cpu_pct"  ]] && { cc=$(color_for_pct "$cpu_pct"); seg_cpu="${cc}cpu ${cpu_pct}%${RESET}"; }
[[ -n "$ram_pct"  ]] && { rc=$(color_for_pct "$ram_pct"); seg_ram="${rc}ram ${ram_pct}%${RESET}"; }
[[ -n "$bat_str"  ]] && seg_bat="${bat_color}${bat_str}${RESET}"
[[ -n "$weather"  ]] && seg_weather="${WHITE}${weather}${RESET}"
[[ -n "$dur_str"  ]] && seg_dur="${DIM}${dur_str}${RESET}"
[[ -n "$cost_str" ]] && seg_cost="${MAGENTA}${cost_str}${RESET}"

durcost_line=$(join_segs "$seg_dur" "$seg_cost")

# Dynamic verdict — shifts with context window pressure
if   (( ctx >= 80 )); then status_v="${RED}cooked 💀${RESET}";       vibes_v="${DIM}time to commit${RESET}"
elif (( ctx >= 50 )); then status_v="${YELLOW}locked in 🔒${RESET}"; vibes_v="${DIM}holding${RESET}"
else                       status_v="${GREEN}winning ✨${RESET}";     vibes_v="${DIM}cruising${RESET}"
fi
verdict="status: ${status_v}${SEP}vibes: ${vibes_v}"
[[ -n "$music" ]] && verdict="${verdict}${SEP}${music}"

# ── Render ─────────────────────────────────────────────────────────────
header="${DIM}${user}${RESET} ${BLUE}${cwd}${RESET} ${model}"
[[ -n "$effort" ]] && header="${header} ${MAGENTA}(${effort})${RESET}"
printf '%s┌─%s %b\n' "$ORANGE" "$RESET" "$header"

h5_reset_str=""; d7_reset_str=""
[[ -n "$h5_reset" ]] && h5_reset_str=$(time_until "$h5_reset")
[[ -n "$d7_reset" ]] && d7_reset_str=$(time_until "$d7_reset")

render_bar_row "ctx" "$ctx" ""               "$seg_cpu" "$seg_ram"
render_bar_row "5h " "$h5"  "$h5_reset_str"  "$seg_bat" "$seg_weather"
render_bar_row "7d " "$d7"  "$d7_reset_str"  ""         ""

[[ -n "$durcost_line" ]] && printf '%s├─%s %b\n' "$ORANGE" "$RESET" "$durcost_line"

printf '%s├─%s %b\n' "$ORANGE" "$RESET" "$verdict"

printf '%s└─$%s ' "$ORANGE" "$RESET"
