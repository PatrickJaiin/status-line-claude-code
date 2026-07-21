# status-line-claude-code

Status-line variants for [Claude Code](https://claude.com/claude-code) and [Codex](https://developers.openai.com/codex).
Pick one, paste its install command, restart Claude Code (or Codex). That's it.

All Claude variants can show: context, rate limits, session cost, lines changed, duration,
CPU/RAM, battery, now playing, and weather (located by IP).

| Variant | Style |
|---|---|
| [Classic](#classic) | Two lines, bar graphs |
| [RogueDBear](#roguedbear) | Stacked box layout, tabular columns |
| [Pie](#pie) | One compact line, pie glyphs |
| [Touch Bar](#touch-bar) | Pills on the MacBook Pro Touch Bar |
| [Codex presets](#codex-presets) | Codex's native footer |

## Classic

**Preview:**

```
Claude Opus 4.7  effort:high  CTX [██▒▒▒▒▒▒▒▒] 23%  5h [████▒▒▒▒▒▒] 42% resets 2h17m
7d [██▒▒▒▒▒▒▒▒] 18% resets 4d  fable [████████▒▒] 85% resets 4d  $1.42  +127/-43
dur 23m  cpu 18%  ram 64%  bat 87%+
```

**Installation (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/install.sh | sh
```

## RogueDBear

**Preview:**

```
┌─ shiv  ~/repo  Claude Opus 4.7  (high)
├─ ctx [●●○○○○○○○○]  23%                         cpu 18%      ram 64%
├─ 5h  [●●●●○○○○○○]  42%  resets 2h17m           bat 87%+     ☀️ +18°C
├─ 7d  [●●○○○○○○○○]  18%  resets 4d
├─ fbl [●●●●●●●●○○]  85%  resets 4d
├─ dur 23m  ·  $1.42  ·  12.3k tok
├─ status: winning ✨  ·  vibes: cruising  ·  ♪ Tame Impala — The Less I Know [●●●○○○○○] 2:14/3:38
└─$
```

**Installation (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-roguedbear-statusline.sh | sh
```

<details>
<summary>Details</summary>

Multi-line stacked layout ([`roguedbear-statusline.sh`](variants/roguedbear-statusline.sh)) with
three-column tabular alignment, reset timers next to the 5h/7d bars, and a now-playing line with
a live progress bar (YTMDesktop Companion Server + Spotify — see
[`YOUTUBE_MUSIC.md`](YOUTUBE_MUSIC.md) for setup).
</details>

## Pie

**Preview:**

```
Claude Opus 4.7  ◔ ctx 23%  ◑ 5h 42% (2h17m)  ◔ 7d 18% (4d)  ◕ fable 85% (4d)  $1.42  …
```

**Installation (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-pie-statusline.sh | sh
```

<details>
<summary>Details</summary>

Single line ([`pie-statusline.sh`](variants/pie-statusline.sh)): bar graphs are replaced with
pie glyphs (`○ ◔ ◑ ◕ ●`) — one character per metric, color-coded by usage, reset timers in
parentheses.
</details>

## Touch Bar

Renders on the **MacBook Pro Touch Bar** via [Hammerspoon](https://www.hammerspoon.org); the
terminal keeps a minimal one-liner.

**Preview:**

```
🧠 context 23%  ⏳ 5h 42% · 2h17m  📖 fable 85% · 4d  💰 $1.42  🖥 cpu 18%  🔋 87%+  …
```

**Installation (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-touchbar-hammerspoon.sh | sh
```

After install, grant Hammerspoon **Accessibility** permission, then restart Claude Code.

<details>
<summary>Details</summary>

A shell script can't draw to the Touch Bar, and Claude's per-session metrics only arrive on the
status-line command's stdin — so [`touchbar-statusline.sh`](variants/touchbar-statusline.sh)
writes a JSON cache (`~/.claude/touchbar/status.json`) on every render, and
[`touchbar-hammerspoon.lua`](variants/touchbar-hammerspoon.lua) reads it and paints the Touch
Bar's wide app-region as a row of color-coded pills.

- Opens from a "⌁" Control Strip button — tap to show, ✕ to hand the Touch Bar back.
- Color-coded pills (green/yellow/red by usage) with a playful vibes pill.
- Live cpu / ram / battery / clock computed by Hammerspoon — alive even when Claude is idle
  (RAM uses reclaimable-page accounting, not macOS's cache-inflated "used").
- Now playing (Spotify / Apple Music) and weather (wttr.in) from the cache writer.
- Live rate-limit countdowns from absolute reset epochs.
- Drag to scroll; auto-scrolls as a ticker when plugged in, static on battery.
- Ultracode mode (high effort): shimmering label + spinner.

Why Hammerspoon: native Apple-Silicon cask, and its Touch Bar module
([`hs._asm.undocumented.touchbar`](https://github.com/asmagill/hs._asm.undocumented.touchbar))
ships universal (x86_64+arm64) — no Rosetta, unlike MTMR. The module is experimental and uses
undocumented APIs.

The installer adds Hammerspoon (via Homebrew), drops the module under `~/.hammerspoon/`,
installs the Lua config and cache writer, and wires `settings.json`, backing up an existing
`~/.hammerspoon/init.lua` first.
</details>

## Fable usage bar

Claude Code's status-line payload only carries the 5h/7d limits, so the Fable
weekly bar reads the same OAuth usage API the `/usage` screen does (token from
the Claude Code keychain entry on macOS, `~/.claude/.credentials.json` on
Linux), cached for 120s and refreshed in the background. Accounts with no
Fable-scoped limit simply don't get the bar. If Claude Code ever ships fable
data in the payload (`rate_limits.seven_day_fable` / `rate_limits.fable`),
that takes priority automatically.

## Toggle on / off

Every Claude Code variant shares one switch: while `~/.claude/statusline-off`
exists, the script renders nothing and the status line disappears. Flip it by
running your installed variant with `toggle` (or force a state with `on` / `off`):

```sh
sh   ~/.claude/statusline-command.sh    toggle   # Classic
bash ~/.claude/roguedbear-statusline.sh toggle   # RogueDBear
sh   ~/.claude/pie-statusline.sh        toggle   # Pie
sh   ~/.claude/touchbar-statusline.sh   toggle   # Touch Bar (also clears the pills)
```

The change shows on the next status-line render. Terminal status lines are plain
text, so there's no clickable button — but the Touch Bar variant has real tap
controls: `⌁` in the Control Strip opens the bar, `✕` hides it, and the toggle
above additionally blanks the pills until you switch back on.

## Codex presets

Codex's footer is a fixed list of [built-in fields](https://developers.openai.com/codex/config-reference/#tui),
so these presets keep each variant's information priority, not its bars or glyphs.
One installer, pick a preset:

**Installation (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-codex-statusline.sh | sh
```

**Installation with a preset (paste in terminal):**

```sh
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-codex-statusline.sh | sh -s -- roguedbear
```

| Preset | Adds |
|---|---|
| *(default)* | Model + reasoning, context, usage limits, session tokens |
| `roguedbear` | + working directory, Git branch, input tokens, run state |
| `pie` | Shorter model label, compact usage/token set |
| `touchbar` | Minimal model/context/token fallback |

<details>
<summary>Details</summary>

Append the preset name after `sh -s --` (as in the `roguedbear` example above). The original
RogueDBear URL (`variants/install-roguedbear-codex-statusline.sh`) remains supported.

The installer merges the preset into `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`),
preserves other `[tui]` settings, and keeps a backup at `config.toml.bak`. Requires Codex CLI
0.129.0+. Restart Codex after install, or use `/statusline` to inspect the fields.

Codex's native footer can't display custom bars, CPU/RAM, battery, weather, music, cost,
duration, or vibes text — those need a terminal/tmux integration or a custom Codex build.
Codex also can't invoke a cache writer per render, so there is no native Codex Touch Bar port.
</details>

## How it works

Each variant is a standalone script. Claude installers drop it under `~/.claude/` and point
`statusLine.command` in `~/.claude/settings.json` at it — switch variants any time by rerunning
an installer or editing that key.

Tests:

```sh
sh tests/test-install-codex-statusline.sh
sh tests/test-touchbar-installer-assets.sh
```
