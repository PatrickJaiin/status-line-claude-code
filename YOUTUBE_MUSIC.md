# YouTube Music & Spotify integration

The `variants/roguedbear-statusline.sh` variant supports a now-playing display with a live progress bar. It reads from:

1. **YTMDesktop's Companion Server** (preferred) — local HTTP API exposed by [ytmdesktop/ytmdesktop](https://github.com/ytmdesktop/ytmdesktop) at `http://localhost:9863`
2. **Spotify** (fallback) — via AppleScript on macOS

If neither source is available, the music line is simply omitted.

---

## Why not Discord Rich Presence?

Discord RPC is a **write-only** protocol: apps push their presence *to* the Discord client over `/tmp/discord-ipc-0`, and there's no reciprocal `GET_ACTIVITY` opcode for reading what other apps have published. So tapping the Discord plugin to read YTM state isn't viable from a status-line script.

The Companion Server gives us a clean REST endpoint (`GET /api/v1/state`) with the title, author, track state, progress, duration, repeat mode, queue, and album art URL — everything we need and more.

---

## Setting up YTMDesktop Companion Server (macOS)

### 1. Make sure the app's code signature is valid

Some YTMDesktop builds ship with a broken ad-hoc signature where the CodeDirectory identifier doesn't match the Info.plist bundle ID. When this happens, `safeStorage.isEncryptionAvailable()` returns `false`, the Companion Server refuses to start, and Chromium's cookie store falls back to its default password (so logins don't persist properly either).

Check:

```bash
codesign --verify --deep --verbose=2 "/Applications/YouTube Music Desktop App.app"
```

If you see `invalid Info.plist (plist or signature have been modified)`, re-sign locally with ad-hoc:

```bash
codesign --force --deep --sign - \
  --identifier "com.electron.youtube-music-desktop-app" \
  "/Applications/YouTube Music Desktop App.app"
```

Then quit the app fully (Cmd+Q) and relaunch. You may need to log back into Google — that's expected (Chromium's OSCrypt regenerates its key against the Keychain on first valid launch, which invalidates the previous fallback-encrypted cookie store).

### 2. Enable both toggles in YTMDesktop

In **Settings → Integrations**, turn on:

- **Companion server** — starts the HTTP/WebSocket listener on port 9863
- **Companion authorization** — required to allow external clients to request tokens

Both must be ON. The server returns `403 AUTHORIZATION_DISABLED` on the auth endpoints if the second toggle is off.

### 3. Get an auth token

The Companion Server uses a two-step OAuth-style flow.

**Step A — request a 4-digit code:**

```bash
curl -s -X POST http://localhost:9863/api/v1/auth/requestcode \
  -H 'Content-Type: application/json' \
  -d '{"appId":"claude-statusline","appName":"Claude Code Statusline","appVersion":"1.0.0"}'
```

Returns `{"code":"NNNN"}`. A popup appears in the YTMDesktop app showing the same code.

**Step B — long-poll for the token (blocks until you click Approve in the app):**

```bash
curl -s --max-time 300 -X POST http://localhost:9863/api/v1/auth/request \
  -H 'Content-Type: application/json' \
  -d '{"appId":"claude-statusline","code":"NNNN"}'
```

Returns `{"token":"<hex string>"}`.

**Step C — save the token where `roguedbear-statusline.sh` looks for it:**

```bash
umask 077
printf '%s' '<token-from-step-B>' > ~/.claude/.ytmd-token
```

Mode 600. The variant reads this file on every refresh and uses it as the `Authorization` header.

### 4. Verify

```bash
curl -s http://localhost:9863/api/v1/state \
  -H "Authorization: $(cat ~/.claude/.ytmd-token)" | jq '.video.title'
```

Should return the current track title (or `null` if nothing's loaded).

---

## How the variant uses it

`refresh_nowplaying()` in `variants/roguedbear-statusline.sh`:

1. Reads `~/.claude/.ytmd-token`. If missing, falls back to Spotify.
2. Calls `GET /api/v1/state` with a 1.5s timeout.
3. Filters by `trackState ∈ {1 (Playing), 2 (Buffering)}` — skips paused/idle states so the music line disappears when nothing's playing.
4. Extracts author + title, current `videoProgress` (seconds), and `durationSeconds`.
5. Caches the result with **stale-while-revalidate** at TTL 6s (the endpoint is rate-limited to 1 req per 5s per token; 6s gives a 1s safety margin).
6. The renderer adds live progress between cache refreshes by computing `effective_pos = captured_pos + (now - captured_at)`, capped at `duration`.

Result: `♪ Artist — Title [●●●●○○○○] 1:23/3:14` as its own row.

### Rate limit note

The Companion Server's source comment for `/state` reads:

> *"API users: Please utilize the realtime websocket to get the state. Request this endpoint as necessary, such as initial state fetching."*

The right long-term answer is a small background daemon that holds a WebSocket connection to `/api/v1/realtime` and writes state snapshots to disk. The status line then reads the snapshot in microseconds without ever hitting the rate limit. That's a future improvement — the 6s-TTL polling approach is fine for steady-state but doesn't pick up track changes instantly.

---

## Spotify fallback

If `~/.claude/.ytmd-token` is missing OR the Companion Server is down, the variant tries Spotify via AppleScript:

```applescript
tell application "Spotify"
  if player state is playing then
    return artist of current track & " — " & name of current track
      & "||" & (player position as integer)
      & "||" & ((duration of current track) / 1000) as integer
  end if
end tell
```

No setup required beyond having Spotify open. Position/duration give us the same progress bar treatment.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Music line never appears | Companion Server toggle is off | Settings → Integrations → Companion server: ON |
| `401 UNAUTHORIZED` | Token missing or invalid | Re-run the auth flow above |
| `403 AUTHORIZATION_DISABLED` | Companion authorization toggle is off | Settings → Integrations → Companion authorization: ON |
| `429 Too Many Requests` | More than 1 call per 5s per token | Cache TTL must be ≥ 6s; check `cache_swr nowplaying 6 refresh_nowplaying` |
| Music line shows then disappears | Song just paused (`trackState=0`) | Working as intended — line hides on pause |
| Companion Server toggle is disabled with "safeStorage unavailable" | Broken code signature | Run the `codesign --force --deep --sign -` command above |
