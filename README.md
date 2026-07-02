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

### [`touchbar-statusline`](variants/touchbar-statusline.sh) — Touch Bar (Hammerspoon)

Renders the status on the **MacBook Pro Touch Bar** instead of the terminal. A shell script
can't draw to the Touch Bar, and Claude's per-session metrics only arrive on the status-line
command's stdin — so this variant bridges the two: the status-line script
([`touchbar-statusline.sh`](variants/touchbar-statusline.sh)) writes a JSON cache
(`~/.claude/touchbar/status.json`) on every render, and [Hammerspoon](https://www.hammerspoon.org)
([`touchbar-hammerspoon.lua`](variants/touchbar-hammerspoon.lua)) reads that cache and paints the
Touch Bar's wide app-region as a row of color-coded pills. The terminal keeps only a minimal one-liner.

```
⚡ ULTRACODE Opus 4.8  🎯 locked in  ♪ Tame Impala — The Less I Know  🧠 context 23%  ⏳ 5h 42% · 2h17m  📅 7d 18% · 4d  💰 $1.42  🖥 cpu 18%  🧮 ram 64%  🔋 battery 87%+  ☀️ +18°C  🕐 14:21
```

Why Hammerspoon: it's a **native Apple-Silicon** cask, and its Touch Bar module
([`hs._asm.undocumented.touchbar`](https://github.com/asmagill/hs._asm.undocumented.touchbar))
ships as a universal (x86_64+arm64) binary — so no Rosetta, unlike MTMR. The module is
experimental and uses undocumented APIs.

Features:
- **Opens from a "⌁" Control Strip button** — tap to bring up the bar, tap ✕ to close it and
  hand the Touch Bar back to other apps/tools; the button stays put for reopening.
- **Color-coded pills** (green/yellow/red by usage) with a playful **vibes** pill.
- **Live cpu / ram / battery / clock** computed by Hammerspoon — the bar stays alive even when
  Claude is idle. (RAM uses reclaimable-page accounting, not macOS's cache-inflated "used".)
- **Now playing** (Spotify / Apple Music) and **weather** (wttr.in), written into the cache by
  the shell script using the same `osascript`/`wttr.in` approach as the other variants.
- **Live rate-limit countdowns** from absolute reset epochs (accurate even between renders).
- **Drag to scroll**; auto-scrolls as a **ticker when plugged in**, fully static on battery to
  save power.
- **Ultracode mode** (high effort): shimmering label + spinner.

The installer adds Hammerspoon (via Homebrew), drops the universal module under `~/.hammerspoon/`,
installs the Lua config and the cache writer, and wires `settings.json` (backing up anything it
replaces). After install, grant Hammerspoon **Accessibility** permission and restart Claude Code.

Without GPS (weather location via IP):

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-touchbar-hammerspoon.sh | sh
```

With GPS (also installs [`CoreLocationCLI`](https://github.com/fulldecent/corelocationcli) for
accurate weather location):

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-touchbar-hammerspoon.sh | WITH_GPS=1 sh
```
