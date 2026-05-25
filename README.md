# status-line-claude-code

A Claude Code status line that shows context window, rate limits, session cost, lines changed, session duration, CPU/RAM, battery, current Spotify track, and weather.

## Install

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/install.sh | sh
```

## Variants

Alternative implementations live under `variants/`:

### [`variants/roguedbear-statusline.sh`](variants/roguedbear-statusline.sh)

Multi-line stacked layout (`┌─├─└─`) with three-column tabular alignment, reset timers next to the 5h/7d bars, and a now-playing line with a live progress bar. Sources: YTMDesktop Companion Server + Spotify. See [`YOUTUBE_MUSIC.md`](YOUTUBE_MUSIC.md) for setup.

```
curl -fsSL https://github.com/PatrickJaiin/status-line-claude-code/raw/main/variants/install-roguedbear-statusline.sh | sh
```

Variants are standalone scripts — the installer drops the script under `~/.claude/` and points `~/.claude/settings.json` at it. To switch variants by hand, edit `statusLine.command` directly.
