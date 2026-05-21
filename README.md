# status-line-claude-code

A Claude Code status line that shows context window, rate limits, session cost, lines changed, session duration, CPU/RAM, battery, current Spotify track, and weather.

## Install

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/install.sh | sh
```

## Variants

Alternative implementations live under `variants/`:

| Variant | Description |
|---|---|
| [`variants/roguedbear-statusline.sh`](variants/roguedbear-statusline.sh) | Multi-line stacked layout (`┌─├─└─`) with three-column tabular alignment, reset timers next to the 5h/7d bars, and a now-playing line with a live progress bar. Sources: YTMDesktop Companion Server + Spotify. See [`YOUTUBE_MUSIC.md`](YOUTUBE_MUSIC.md) for setup. |

Variants are standalone scripts — point `~/.claude/settings.json` `statusLine.command` at the one you want.
