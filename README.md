# status-line-claude-code

A Claude Code status line that surfaces context window, rate limits, session cost, lines changed, session duration, CPU/RAM, battery, current Spotify track, and weather.

```
Claude Opus 4.7  effort:high  CTX [██▒▒▒▒▒▒▒▒] 23%  5h [████▒▒▒▒▒▒] 42% resets 2h17m
7d [██▒▒▒▒▒▒▒▒] 18% resets 4d  $1.42  +127/-43  dur 23m  cpu 18%  ram 64%  bat 87%+
Tame Impala - The Less I Know   ☀️ +18°C
```

## Install

Without GPS (weather location via IP):

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/install.sh | sh
```

With GPS (also installs [`CoreLocationCLI`](https://github.com/fulldecent/corelocationcli) for accurate weather location — first run triggers a macOS Location Services prompt):

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/install.sh | WITH_GPS=1 sh
```

Restart Claude Code after install.

## Variants

Alternative implementations live under `variants/`. Each is a standalone script; the installer drops it under `~/.claude/` and points `~/.claude/settings.json` at it. To switch variants by hand, edit `statusLine.command` directly. Both install commands below accept the same `WITH_GPS=1` opt-in.

### [`roguedbear-statusline`](variants/roguedbear-statusline.sh)

Multi-line stacked layout with three-column tabular alignment, reset timers next to the 5h/7d bars, and a now-playing line with a live progress bar. Sources: YTMDesktop Companion Server + Spotify. See [`YOUTUBE_MUSIC.md`](YOUTUBE_MUSIC.md) for setup.

```
┌─ shiv  ~/repo  Claude Opus 4.7  (high)
├─ ctx [●●○○○○○○○○]  23%                         cpu 18%      ram 64%
├─ 5h  [●●●●○○○○○○]  42%  resets 2h17m           bat 87%+     ☀️ +18°C
├─ 7d  [●●○○○○○○○○]  18%  resets 4d
├─ dur 23m  ·  $1.42  ·  12.3k tok
├─ status: winning ✨  ·  vibes: cruising  ·  ♪ Tame Impala — The Less I Know [●●●○○○○] 2:14
└─$
```

Without GPS:

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-roguedbear-statusline.sh | sh
```

With GPS:

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-roguedbear-statusline.sh | WITH_GPS=1 sh
```

### [`pie-statusline`](variants/pie-statusline.sh)

Single-line, compact variant that swaps bar graphs for pie-chart glyphs (`○ ◔ ◑ ◕ ●`). One character per metric, color-coded by usage; reset timers shown in parentheses.

```
Claude Opus 4.7 high  ◔ ctx 23%  ◑ 5h 42% (2h17m)  ◔ 7d 18% (4d)  $1.42  +127/-43  23m  ◔ cpu 18%  ◑ ram 64%  ● bat 87%+  ♪ Tame Impala — The Less I Know  ☀️ +18°C
```

Without GPS:

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-pie-statusline.sh | sh
```

With GPS:

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-pie-statusline.sh | WITH_GPS=1 sh
```
