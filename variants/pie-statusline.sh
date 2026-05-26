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
  diff=$((target - now_ts))
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

# CPU + RAM (macOS top)
cpu_pct=""
ram_pct=""
if command -v top >/dev/null 2>&1; then
  top_out=$(top -l 1 -n 0 2>/dev/null)
  cpu_idle=$(echo "$top_out" | awk -F'[:,]' '/CPU usage/ {
    for (i=1;i<=NF;i++) if ($i ~ /idle/) { gsub(/[^0-9.]/,"",$i); print $i; exit }
  }')
  if [ -n "$cpu_idle" ]; then
    cpu_pct=$(awk -v idle="$cpu_idle" 'BEGIN { v=100-idle; if(v<0)v=0; printf "%.0f", v }')
  fi
  phys=$(echo "$top_out" | grep -E '^PhysMem')
  if [ -n "$phys" ]; then
    used_raw=$(echo "$phys"   | sed -nE 's/.*PhysMem:[[:space:]]*([0-9]+[GMK]?) used.*/\1/p')
    unused_raw=$(echo "$phys" | sed -nE 's/.*,[[:space:]]*([0-9]+[GMK]?) unused.*/\1/p')
    to_mb() {
      v="$1"
      n=$(printf '%s' "$v" | sed -E 's/[^0-9.]//g')
      u=$(printf '%s' "$v" | sed -E 's/[0-9.]//g')
      case "$u" in
        G) awk -v n="$n" 'BEGIN{printf "%.0f", n*1024}' ;;
        K) awk -v n="$n" 'BEGIN{printf "%.0f", n/1024}' ;;
        *) awk -v n="$n" 'BEGIN{printf "%.0f", n}' ;;
      esac
    }
    if [ -n "$used_raw" ] && [ -n "$unused_raw" ]; then
      um=$(to_mb "$used_raw"); fm=$(to_mb "$unused_raw"); tm=$((um+fm))
      [ "$tm" -gt 0 ] && ram_pct=$(awk -v u="$um" -v t="$tm" 'BEGIN{printf "%.0f", u*100/t}')
    fi
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

# Weather (cached ~10min)
weather=""
weather_cache="/tmp/.claude_pie_weather"
weather_ts_cache="/tmp/.claude_pie_weather_ts"
now=$(date +%s)
last=0
[ -f "$weather_ts_cache" ] && last=$(cat "$weather_ts_cache" 2>/dev/null || echo 0)
age=$((now - last))
if [ "$age" -gt 600 ] || [ ! -f "$weather_cache" ]; then
  fetched=$(curl -sf --max-time 3 "https://wttr.in/?format=%c+%t" 2>/dev/null)
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
