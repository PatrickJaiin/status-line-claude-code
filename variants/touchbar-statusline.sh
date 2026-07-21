#!/bin/sh
# Claude Code status line — Touch Bar variant.
#
# Unlike the other variants, this one's real display lives on the Touch Bar (via Hammerspoon),
# not in the terminal. Claude Code only pipes session JSON to its status-line command on
# stdin, and only on render — a timer-driven Touch Bar widget can't see that stream. So this
# script acts as the bridge: it parses the stdin payload and writes a compact JSON cache that
# the Hammerspoon module reads. The terminal gets only a minimal one-liner.

CACHE_DIR="$HOME/.claude/touchbar"
CACHE="$CACHE_DIR/status.json"
mkdir -p "$CACHE_DIR"

# On/off switch shared by all variants: while ~/.claude/statusline-off exists,
# render nothing in the terminal and clear the Touch Bar (the cache gets
# {"off":true}, which the Hammerspoon module renders as a single dim pill).
# Flip it by running this script with:  toggle | on | off
TOGGLE_FLAG="$HOME/.claude/statusline-off"
case "${1:-}" in
  toggle|on|off)
    case "$1" in
      on)  rm -f "$TOGGLE_FLAG" ;;
      off) : > "$TOGGLE_FLAG" ;;
      *)   if [ -e "$TOGGLE_FLAG" ]; then rm -f "$TOGGLE_FLAG"; else : > "$TOGGLE_FLAG"; fi ;;
    esac
    if [ -e "$TOGGLE_FLAG" ]; then
      printf '{"off":true}\n' > "$CACHE"   # clear the Touch Bar right away, not on next render
      echo "Status line: OFF (Touch Bar cleared; run '$0 toggle' to re-enable)"
    else
      rm -f "$CACHE"                       # back to the idle state until the next render
      echo "Status line: ON (Touch Bar repopulates on the next render)"
    fi
    exit 0
    ;;
esac
if [ -e "$TOGGLE_FLAG" ]; then
  cat > /dev/null 2>&1 || true   # drain stdin so Claude Code never sees a broken pipe
  printf '{"off":true}\n' > "$CACHE"
  exit 0
fi

input=$(cat)

# --- Claude metrics (straight off the stdin JSON) -------------------------------------------
ctx_used=$(echo "$input"   | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input"| jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets=$(echo "$input"| jq -r '.rate_limits.seven_day.resets_at // empty')
# Fable-tier weekly limit — payload first (Claude Code doesn't send it yet); below,
# after the parse block, we fall back to the OAuth usage API that /usage reads.
fable_pct=$(echo "$input"  | jq -r '.rate_limits.seven_day_fable.used_percentage // .rate_limits.fable.used_percentage // empty')
fable_resets=$(echo "$input" | jq -r '.rate_limits.seven_day_fable.resets_at // .rate_limits.fable.resets_at // empty')
model=$(echo "$input"      | jq -r '.model.display_name // empty')
effort=$(echo "$input"     | jq -r '.effort.level // empty')
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
lines_added=$(echo "$input"| jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')
duration_ms=$(echo "$input"| jq -r '.cost.total_duration_ms // empty')

# No fable field in the payload — fall back to the OAuth usage API (the same
# source the /usage screen reads), where Fable appears as a weekly_scoped limit.
# Token comes from the Claude Code keychain entry (macOS) or credentials file
# (Linux). Cached 120s and refreshed in the background so renders stay fast.
if [ -z "$fable_pct" ]; then
  fable_cache="$HOME/.claude/.fable-usage-cache"
  fable_age=999999
  if [ -f "$fable_cache" ]; then
    fable_mtime=$(stat -c %Y "$fable_cache" 2>/dev/null || stat -f %m "$fable_cache" 2>/dev/null || echo 0)
    fable_age=$(( $(date +%s) - fable_mtime ))
  fi
  if [ "$fable_age" -ge 120 ]; then
    (
      tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | jq -r '.claudeAiOauth.accessToken // empty')
      [ -n "$tok" ] || tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
      out=""
      [ -n "$tok" ] && out=$(curl -fsS --max-time 3 \
        -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
        https://api.anthropic.com/api/oauth/usage 2>/dev/null \
        | jq -r 'first(.limits[]? | select(.kind=="weekly_scoped" and ((.scope.model.display_name // "") | ascii_downcase | contains("fable")))) // {} | if .percent == null then empty else "\(.percent)|\(.resets_at // "")" end')
      printf '%s' "$out" > "$fable_cache.tmp.$$" && mv "$fable_cache.tmp.$$" "$fable_cache"
    ) >/dev/null 2>&1 &
  fi
  fable_api=$(cat "$fable_cache" 2>/dev/null)
  if [ -n "$fable_api" ]; then
    fable_pct=${fable_api%%|*}
    fable_resets=${fable_api#*|}
  fi
fi

# Time-until-reset helper. Accepts an ISO-8601 timestamp (what Claude Code sends) or a raw unix
# epoch; outputs e.g. "4d", "1h23m", "45m". Mirrors the helper in the base install.sh.
time_until() {
  target="$1"
  now_ts=$(date +%s)
  case "$target" in
    ''|*[!0-9]*)
      epoch=$(date -d "$target" "+%s" 2>/dev/null)
      if [ -z "$epoch" ]; then
        clean=${target%.*}; clean=${clean%Z}; clean=${clean%+*}
        clean=${clean%-[0-9][0-9]:[0-9][0-9]}
        epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
      fi
      [ -z "$epoch" ] && { printf '?'; return; }
      ;;
    *) epoch="$target" ;;
  esac
  diff=$((epoch - now_ts))
  if [ "$diff" -le 0 ]; then printf 'now'
  elif [ "$diff" -ge 86400 ]; then printf '%dd' $((diff / 86400))
  elif [ "$diff" -ge 3600 ]; then
    printf '%dh%02dm' $((diff / 3600)) $(((diff % 3600) / 60))
  else printf '%dm' $((diff / 60)); fi
}

# Convert an ISO-8601 timestamp (or raw epoch) to a unix epoch — empty on failure. The Touch Bar
# host counts down from this live, so the reset timer stays accurate even when Claude is idle.
iso_to_epoch() {
  target="$1"
  case "$target" in
    ''|*[!0-9]*)
      e=$(date -d "$target" "+%s" 2>/dev/null)
      if [ -z "$e" ]; then
        clean=${target%.*}; clean=${clean%Z}; clean=${clean%+*}
        clean=${clean%-[0-9][0-9]:[0-9][0-9]}
        e=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
      fi
      printf '%s' "$e" ;;
    *) printf '%s' "$target" ;;
  esac
}

# --- Derived display strings ----------------------------------------------------------------
five_reset_str=""; five_reset_epoch=""
[ -n "$five_resets" ] && { five_reset_str=$(time_until "$five_resets"); five_reset_epoch=$(iso_to_epoch "$five_resets"); }
week_reset_str=""; week_reset_epoch=""
[ -n "$week_resets" ] && { week_reset_str=$(time_until "$week_resets"); week_reset_epoch=$(iso_to_epoch "$week_resets"); }
fable_reset_str=""; fable_reset_epoch=""
[ -n "$fable_resets" ] && { fable_reset_str=$(time_until "$fable_resets"); fable_reset_epoch=$(iso_to_epoch "$fable_resets"); }

cost_str=""
[ -n "$total_cost" ] && cost_str=$(awk -v c="$total_cost" 'BEGIN { printf "$%.2f", c }')

lines_str=""
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  la=${lines_added:-0}; lr=${lines_removed:-0}
  if [ "$la" != "0" ] || [ "$lr" != "0" ]; then lines_str="+${la}/-${lr}"; fi
fi

dur_str=""
if [ -n "$duration_ms" ]; then
  total_s=$(echo "$duration_ms" | awk '{printf "%.0f", $1 / 1000}')
  if [ "$total_s" -ge 3600 ]; then
    dur_str="$((total_s / 3600))h$(((total_s % 3600) / 60))m"
  elif [ "$total_s" -ge 60 ]; then dur_str="$((total_s / 60))m"
  else dur_str="${total_s}s"; fi
fi

# Round percentages to integers (jq --argjson wants valid numbers, not "23.4").
round() { [ -n "$1" ] && printf '%.0f' "$1" || printf ''; }
ctx_i=$(round "$ctx_used")
five_i=$(round "$five_pct")
week_i=$(round "$week_pct")
fable_i=$(round "$fable_pct")

# --- System metrics -------------------------------------------------------------------------
# Battery via pmset (macOS).
bat_pct=""; bat_chg=""
if command -v pmset >/dev/null 2>&1; then
  pmset_out=$(pmset -g batt 2>/dev/null)
  bat_pct=$(echo "$pmset_out" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
  echo "$pmset_out" | grep -qE 'AC Power|charging' && bat_chg="+"
fi

# CPU via `top -l 2` (second sample = instantaneous). Two samples take ~2-3s, so we cache the
# result with a 5s TTL and refresh in the background — the render never blocks on top.
cpu_used=""
if command -v top >/dev/null 2>&1; then
  sys_cache="/tmp/.claude_touchbar_sysstat"
  sys_ts_cache="/tmp/.claude_touchbar_sysstat_ts"
  sys_now=$(date +%s); sys_last=0
  [ -f "$sys_ts_cache" ] && sys_last=$(cat "$sys_ts_cache" 2>/dev/null || echo 0)
  if [ $((sys_now - sys_last)) -gt 5 ]; then
    {
      cval=$(top -l 2 -n 0 2>/dev/null | awk '
        /CPU usage/ {
          for (i = 1; i <= NF; i++) if ($i ~ /idle/) { gsub(/[^0-9.]/, "", $(i-1)); idle = $(i-1) }
        }
        END { cpu = (idle == "") ? 0 : 100 - idle; if (cpu < 0) cpu = 0; printf "%d", cpu }')
      printf '%s' "$cval" > "$sys_cache.tmp" 2>/dev/null && mv "$sys_cache.tmp" "$sys_cache" 2>/dev/null
      printf '%s' "$sys_now" > "$sys_ts_cache" 2>/dev/null
    } >/dev/null 2>&1 &
  fi
  cpu_used=$(cat "$sys_cache" 2>/dev/null)
fi

# RAM via vm_stat — report *real* memory pressure, not macOS's cache-inflated "used". macOS keeps
# nearly all RAM occupied by reclaimable file cache, so top's "unused" is ~0 and reads ~99%.
# Instead: available = free + inactive + speculative + purgeable; used% = (total - available)/total.
ram_pct=""
if command -v vm_stat >/dev/null 2>&1; then
  ps=$(sysctl -n hw.pagesize 2>/dev/null)
  total=$(sysctl -n hw.memsize 2>/dev/null)
  if [ -n "$ps" ] && [ -n "$total" ] && [ "$total" -gt 0 ]; then
    ram_pct=$(vm_stat 2>/dev/null | awk -v ps="$ps" -v total="$total" '
      function pages(line,   v) { v = line; gsub(/[^0-9]/, "", v); return v + 0 }
      /Pages free/        { free = pages($0) }
      /Pages inactive/    { inactive = pages($0) }
      /Pages speculative/ { spec = pages($0) }
      /Pages purgeable/   { purg = pages($0) }
      END {
        avail = (free + inactive + spec + purg) * ps
        used = total - avail; if (used < 0) used = 0
        printf "%.0f", used * 100 / total
      }')
  fi
fi

# --- Now playing — Spotify, then Apple Music (same osascript approach as the repo variants) --
np_str=""
if command -v osascript >/dev/null 2>&1; then
  for np_app in Spotify Music; do
    np_running=$(osascript -e "tell application \"System Events\" to (name of processes) contains \"$np_app\"" 2>/dev/null)
    [ "$np_running" = "true" ] || continue
    np_raw=$(osascript 2>/dev/null <<APPLESCRIPT
tell application "$np_app"
  if player state is playing then
    return (artist of current track) & " — " & (name of current track)
  end if
end tell
APPLESCRIPT
)
    if [ -n "$np_raw" ]; then
      if [ ${#np_raw} -gt 40 ]; then np_str="$(printf '%.37s' "$np_raw")…"; else np_str="$np_raw"; fi
      break
    fi
  done
fi

# --- Location + weather (GPS via CoreLocationCLI → whereami → IP fallback; wttr.in). ----------
# WITH_GPS install adds CoreLocationCLI for precise coords; otherwise wttr.in geolocates by IP.
nowt=$(date +%s)
coords=""
coord_cache="/tmp/.claude_touchbar_coords"; coord_ts_cache="/tmp/.claude_touchbar_coords_ts"
coord_last=0; [ -f "$coord_ts_cache" ] && coord_last=$(cat "$coord_ts_cache" 2>/dev/null || echo 0)
if [ $((nowt - coord_last)) -gt 3600 ] || [ ! -f "$coord_cache" ]; then
  if command -v CoreLocationCLI >/dev/null 2>&1; then
    coords=$(CoreLocationCLI -once -format "%latitude,%longitude" 2>/dev/null \
      | tr -d ' ' | grep -E '^-?[0-9.]+,-?[0-9.]+$' | head -1)
  fi
  if [ -z "$coords" ] && command -v whereami >/dev/null 2>&1; then
    wraw=$(whereami 2>/dev/null)
    lat=$(printf '%s' "$wraw" | awk -F': *' '/Latitude:/  {print $2; exit}')
    lon=$(printf '%s' "$wraw" | awk -F': *' '/Longitude:/ {print $2; exit}')
    [ -n "$lat" ] && [ -n "$lon" ] && coords="${lat},${lon}"
  fi
  printf '%s' "$coords" > "$coord_cache"; printf '%s' "$nowt" > "$coord_ts_cache"
else
  coords=$(cat "$coord_cache" 2>/dev/null)
fi

weather_str=""
weather_cache="/tmp/.claude_touchbar_weather"; weather_ts_cache="/tmp/.claude_touchbar_weather_ts"
wlast=0; [ -f "$weather_ts_cache" ] && wlast=$(cat "$weather_ts_cache" 2>/dev/null || echo 0)
if [ $((nowt - wlast)) -gt 600 ] || [ ! -f "$weather_cache" ]; then
  if [ -n "$coords" ]; then wttr_path="https://wttr.in/${coords}"; else wttr_path="https://wttr.in/"; fi
  fetched=$(curl -sf --max-time 3 "${wttr_path}?format=%c+%t" 2>/dev/null)
  if [ -n "$fetched" ]; then
    printf '%s' "$fetched" > "$weather_cache"; printf '%s' "$nowt" > "$weather_ts_cache"
    weather_str="$fetched"
  fi
else
  weather_str=$(cat "$weather_cache" 2>/dev/null)
fi

# --- Write the cache atomically -------------------------------------------------------------
# jq -n with typed args guarantees valid JSON; absent values become null and the reader
# renders them as blanks/idle markers.
num() { [ -n "$1" ] && printf '%s' "$1" || printf 'null'; }
jq -n \
  --argjson ts   "$(date +%s)" \
  --arg model    "$model" \
  --arg effort   "$effort" \
  --argjson ctx  "$(num "$ctx_i")" \
  --argjson five "$(num "$five_i")" \
  --arg five_reset "$five_reset_str" \
  --argjson five_reset_epoch "$(num "$five_reset_epoch")" \
  --argjson seven "$(num "$week_i")" \
  --arg seven_reset "$week_reset_str" \
  --argjson seven_reset_epoch "$(num "$week_reset_epoch")" \
  --argjson fable "$(num "$fable_i")" \
  --arg fable_reset "$fable_reset_str" \
  --argjson fable_reset_epoch "$(num "$fable_reset_epoch")" \
  --arg cost     "$cost_str" \
  --arg lines    "$lines_str" \
  --arg dur      "$dur_str" \
  --argjson cpu  "$(num "$cpu_used")" \
  --argjson ram  "$(num "$ram_pct")" \
  --argjson bat  "$(num "$bat_pct")" \
  --arg bat_chg  "$bat_chg" \
  --arg np       "$np_str" \
  --arg weather  "$weather_str" \
  '{ts:$ts, model:$model, effort:$effort, ctx:$ctx,
    five:$five, five_reset:$five_reset, five_reset_epoch:$five_reset_epoch,
    seven:$seven, seven_reset:$seven_reset, seven_reset_epoch:$seven_reset_epoch,
    fable:$fable, fable_reset:$fable_reset, fable_reset_epoch:$fable_reset_epoch,
    cost:$cost, lines:$lines, dur:$dur,
    cpu:$cpu, ram:$ram, bat:$bat, bat_chg:$bat_chg, np:$np, weather:$weather}' \
  > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null

# --- Minimal terminal one-liner (the Touch Bar is the real display) -------------------------
line=""
[ -n "$model" ] && line="$model"
[ -n "$ctx_i" ] && line="${line:+$line · }ctx ${ctx_i}%"
[ -n "$cost_str" ] && line="${line:+$line · }$cost_str"
printf '%s' "$line"
