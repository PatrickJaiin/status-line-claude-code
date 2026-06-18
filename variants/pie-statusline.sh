#!/bin/sh
# Claude Code status line — compact pie-chart layout.
# One glyph per metric: ○ ◔ ◑ ◕ ● (0/25/50/75/100%).
# Stays on one line when it fits; wraps greedily otherwise.

input=$(cat)

ctx_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
term_cols=$(echo "$input" | jq -r '.terminal.width // empty' 2>/dev/null)

RESET='\033[0m'
CYAN='\033[36m'
MAGENTA='\033[35m'
WHITE='\033[37m'
DIM='\033[90m'

# Pie glyph for a percentage
pie_glyph() {
  p=$(printf '%.0f' "$1")
  if   [ "$p" -lt 13 ]; then printf '○'
  elif [ "$p" -lt 38 ]; then printf '◔'
  elif [ "$p" -lt 63 ]; then printf '◑'
  elif [ "$p" -lt 88 ]; then printf '◕'
  else                       printf '●'
  fi
}

color_for_pct() {
  p=$(printf '%.0f' "$1")
  if   [ "$p" -lt 50 ]; then printf '\033[32m'
  elif [ "$p" -lt 80 ]; then printf '\033[33m'
  else                       printf '\033[31m'
  fi
}

time_until() {
  target="$1"
  now_ts=$(date +%s)
  # resets_at is an ISO-8601 string (what Claude Code sends) or a bare epoch;
  # normalize to epoch — GNU `date -d` on Linux, BSD `date -j` fallback on macOS.
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
  if   [ "$diff" -le 0 ]; then printf 'now'
  elif [ "$diff" -ge 86400 ]; then printf '%dd' $((diff/86400))
  elif [ "$diff" -ge 3600 ];  then printf '%dh%02dm' $((diff/3600)) $(((diff%3600)/60))
  else                              printf '%dm' $((diff/60))
  fi
}

# Cost
cost_str=""
if [ -n "$total_cost" ]; then
  cost_str=$(awk -v c="$total_cost" 'BEGIN { printf "$%.2f", c }')
fi

# Lines
lines_str=""
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  la=${lines_added:-0}; lr=${lines_removed:-0}
  if [ "$la" != "0" ] || [ "$lr" != "0" ]; then
    lines_str="+${la}/-${lr}"
  fi
fi

# Duration
duration_str=""
if [ -n "$duration_ms" ]; then
  total_s=$(echo "$duration_ms" | awk '{printf "%.0f", $1 / 1000}')
  if   [ "$total_s" -ge 3600 ]; then duration_str="$((total_s/3600))h$(((total_s%3600)/60))m"
  elif [ "$total_s" -ge 60 ];   then duration_str="$((total_s/60))m"
  else                               duration_str="${total_s}s"
  fi
fi

# Battery (macOS)
bat_pct=""
bat_charging=""
if command -v pmset >/dev/null 2>&1; then
  pmset_out=$(pmset -g batt 2>/dev/null)
  bat_pct=$(echo "$pmset_out" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
  if echo "$pmset_out" | grep -qE 'AC Power|charging'; then bat_charging="+"; fi
fi

# CPU + RAM via `top -l 2 -n 0`. The SECOND sample is the instantaneous reading;
# the first reports usage averaged since boot. Two samples take ~2-3s, so we read
# a cached value and refresh in the background — the render never blocks on top.
cpu_pct=""
ram_pct=""
if command -v top >/dev/null 2>&1; then
  sysstat_cache="/tmp/.claude_pie_sysstat"
  sysstat_ts_cache="/tmp/.claude_pie_sysstat_ts"
  sys_now=$(date +%s)
  sys_last=0
  [ -f "$sysstat_ts_cache" ] && sys_last=$(cat "$sysstat_ts_cache" 2>/dev/null || echo 0)
  if [ $((sys_now - sys_last)) -gt 5 ]; then
    # Refresh in the background; this render uses whatever is already cached.
    # stdout/stderr → /dev/null so the child never holds the render's pipe open.
    {
      # CPU: `-l 2`'s second sample is the instantaneous reading (the first
      # reports usage averaged since boot). Keep the last idle figure.
      idle=$(top -l 2 -n 0 2>/dev/null | awk '
        /CPU usage/ {
          for (i = 1; i <= NF; i++)
            if ($i ~ /idle/) { gsub(/[^0-9.]/, "", $(i-1)); v = $(i-1) }
        }
        END { print v }')
      cpu=$(awk -v idle="$idle" 'BEGIN { c = (idle == "") ? 0 : 100 - idle; if (c < 0) c = 0; printf "%d", c }')

      # RAM: top's "PhysMem ... used" counts reclaimable cached files as used, so
      # it reads ~80%+ even when idle. Instead derive true usage from vm_stat the
      # way Activity Monitor's "Memory Used" does: app memory (anonymous minus
      # purgeable) + wired + compressed, as a fraction of physical RAM.
      total=$(sysctl -n hw.memsize 2>/dev/null)
      sval=$(vm_stat 2>/dev/null | awk -v total="$total" -v cpu="$cpu" '
        /page size of/                  { page  = $8 }
        /Pages wired down/              { wired = $4 }
        /Pages occupied by compressor/  { comp  = $5 }
        /Anonymous pages/               { anon  = $3 }
        /Pages purgeable/               { purge = $3 }
        END {
          gsub(/[^0-9]/, "", wired); gsub(/[^0-9]/, "", comp)
          gsub(/[^0-9]/, "", anon);  gsub(/[^0-9]/, "", purge)
          app  = anon - purge; if (app < 0) app = 0
          used = (app + wired + comp) * page
          pct  = (total > 0) ? used * 100 / total : 0
          printf "%d|%d", cpu, pct
        }')
      printf '%s' "$sval" > "$sysstat_cache.tmp" 2>/dev/null \
        && mv "$sysstat_cache.tmp" "$sysstat_cache" 2>/dev/null
      printf '%s' "$sys_now" > "$sysstat_ts_cache" 2>/dev/null
    } >/dev/null 2>&1 &
  fi

  sysstat=$(cat "$sysstat_cache" 2>/dev/null)
  if [ -n "$sysstat" ]; then
    cpu_pct=$(printf '%s' "$sysstat" | cut -d'|' -f1)
    ram_pct=$(printf '%s' "$sysstat" | cut -d'|' -f2)
    # Guard against a stale cache from the previous (raw-MB) format.
    case "$cpu_pct" in ''|*[!0-9]*) cpu_pct="" ;; esac
    case "$ram_pct" in ''|*[!0-9]*) ram_pct="" ;; esac
  fi
fi

# Spotify (macOS)
spotify_track=""
if command -v osascript >/dev/null 2>&1; then
  running=$(osascript -e 'tell application "System Events" to (name of processes) contains "Spotify"' 2>/dev/null)
  if [ "$running" = "true" ]; then
    raw=$(osascript 2>/dev/null <<'APPLESCRIPT'
tell application "Spotify"
  if player state is playing then
    return (artist of current track) & " — " & (name of current track)
  end if
end tell
APPLESCRIPT
)
    if [ -n "$raw" ]; then
      if [ ${#raw} -gt 36 ]; then spotify_track="$(printf '%.33s' "$raw")…"
      else                        spotify_track="$raw"
      fi
    fi
  fi
fi

# Location (GPS via CoreLocationCLI → whereami → IP fallback). Cached 1h.
coords=""
coord_cache="/tmp/.claude_pie_coords"
coord_ts_cache="/tmp/.claude_pie_coords_ts"
coord_last=0
[ -f "$coord_ts_cache" ] && coord_last=$(cat "$coord_ts_cache" 2>/dev/null || echo 0)
now=$(date +%s)
if [ $((now - coord_last)) -gt 3600 ] || [ ! -f "$coord_cache" ]; then
  if command -v CoreLocationCLI >/dev/null 2>&1; then
    coords=$(CoreLocationCLI -once -format "%latitude,%longitude" 2>/dev/null \
      | tr -d ' ' | grep -E '^-?[0-9.]+,-?[0-9.]+$' | head -1)
  fi
  if [ -z "$coords" ] && command -v whereami >/dev/null 2>&1; then
    raw=$(whereami 2>/dev/null)
    lat=$(printf '%s' "$raw" | awk -F': *' '/Latitude:/  {print $2; exit}')
    lon=$(printf '%s' "$raw" | awk -F': *' '/Longitude:/ {print $2; exit}')
    [ -n "$lat" ] && [ -n "$lon" ] && coords="${lat},${lon}"
  fi
  printf '%s' "$coords" > "$coord_cache"
  printf '%s' "$now"    > "$coord_ts_cache"
else
  coords=$(cat "$coord_cache" 2>/dev/null)
fi

# Weather (cached ~10min). Uses GPS coords if available, else IP.
weather=""
weather_cache="/tmp/.claude_pie_weather"
weather_ts_cache="/tmp/.claude_pie_weather_ts"
last=0
[ -f "$weather_ts_cache" ] && last=$(cat "$weather_ts_cache" 2>/dev/null || echo 0)
age=$((now - last))
if [ "$age" -gt 600 ] || [ ! -f "$weather_cache" ]; then
  if [ -n "$coords" ]; then
    wttr_path="https://wttr.in/${coords}"
  else
    wttr_path="https://wttr.in/"
  fi
  fetched=$(curl -sf --max-time 3 "${wttr_path}?format=%c+%t" 2>/dev/null)
  if [ -n "$fetched" ]; then
    printf '%s' "$fetched" > "$weather_cache"
    printf '%s' "$now"     > "$weather_ts_cache"
    weather="$fetched"
  fi
else
  weather=$(cat "$weather_cache" 2>/dev/null)
fi

# Terminal width
if [ -z "$term_cols" ] || [ "$term_cols" = "null" ]; then
  term_cols=$(tput cols 2>/dev/null || echo 100)
fi
max_w=$((term_cols - 2))
[ "$max_w" -lt 20 ] && max_w=20

# Build segments
segments=""
add_seg() {
  if [ -n "$segments" ]; then segments="${segments}
$1"
  else                        segments="$1"
  fi
}

# Model + effort
if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    add_seg "$(printf "${CYAN}%s${RESET} ${DIM}%s${RESET}" "$model" "$effort")"
  else
    add_seg "$(printf "${CYAN}%s${RESET}" "$model")"
  fi
fi

# CTX
if [ -n "$ctx_used" ]; then
  c=$(color_for_pct "$ctx_used"); g=$(pie_glyph "$ctx_used")
  add_seg "$(printf "${c}%s ctx %.0f%%${RESET}" "$g" "$ctx_used")"
fi

# 5h
if [ -n "$five_pct" ]; then
  c=$(color_for_pct "$five_pct"); g=$(pie_glyph "$five_pct")
  r=""; [ -n "$five_resets" ] && r=" ${DIM}($(time_until "$five_resets"))${RESET}"
  add_seg "$(printf "${c}%s 5h %.0f%%${RESET}%b" "$g" "$five_pct" "$r")"
fi

# 7d
if [ -n "$week_pct" ]; then
  c=$(color_for_pct "$week_pct"); g=$(pie_glyph "$week_pct")
  r=""; [ -n "$week_resets" ] && r=" ${DIM}($(time_until "$week_resets"))${RESET}"
  add_seg "$(printf "${c}%s 7d %.0f%%${RESET}%b" "$g" "$week_pct" "$r")"
fi

[ -n "$cost_str" ]      && add_seg "$(printf "${MAGENTA}%s${RESET}" "$cost_str")"
[ -n "$lines_str" ]     && add_seg "$(printf "${WHITE}%s${RESET}" "$lines_str")"
[ -n "$duration_str" ]  && add_seg "$(printf "${DIM}%s${RESET}" "$duration_str")"

if [ -n "$cpu_pct" ]; then
  c=$(color_for_pct "$cpu_pct"); g=$(pie_glyph "$cpu_pct")
  add_seg "$(printf "${c}%s cpu %s%%${RESET}" "$g" "$cpu_pct")"
fi
if [ -n "$ram_pct" ]; then
  c=$(color_for_pct "$ram_pct"); g=$(pie_glyph "$ram_pct")
  add_seg "$(printf "${c}%s ram %s%%${RESET}" "$g" "$ram_pct")"
fi
if [ -n "$bat_pct" ]; then
  # Battery: green >= 30, yellow 15-29, red < 15
  if   [ "$bat_pct" -ge 30 ]; then bc='\033[32m'
  elif [ "$bat_pct" -ge 15 ]; then bc='\033[33m'
  else                              bc='\033[31m'
  fi
  g=$(pie_glyph "$bat_pct")
  add_seg "$(printf "${bc}%s bat %s%%%s${RESET}" "$g" "$bat_pct" "$bat_charging")"
fi

[ -n "$spotify_track" ] && add_seg "$(printf "${WHITE}♪ %s${RESET}" "$spotify_track")"
[ -n "$weather" ]       && add_seg "$(printf "${WHITE}%s${RESET}" "$weather")"

# Visible width (strip ANSI)
visible_len() {
  s=$(printf '%b' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g')
  printf '%s' "$s" | awk '{ printf "%d", length($0) }'
}

# Greedy wrap with two-space separator
out=""; cur_line=""; cur_w=0; sep_w=2
IFS='
'
for seg in $segments; do
  seg_w=$(visible_len "$seg")
  if [ -z "$cur_line" ]; then
    cur_line="$seg"; cur_w=$seg_w
  else
    new_w=$((cur_w + sep_w + seg_w))
    if [ "$new_w" -le "$max_w" ]; then
      cur_line="${cur_line}  ${seg}"; cur_w=$new_w
    else
      if [ -z "$out" ]; then out="$cur_line"
      else                   out="${out}
${cur_line}"
      fi
      cur_line="$seg"; cur_w=$seg_w
    fi
  fi
done
unset IFS

if [ -n "$cur_line" ]; then
  if [ -z "$out" ]; then out="$cur_line"
  else                   out="${out}
${cur_line}"
  fi
fi

printf '%b' "$out"
