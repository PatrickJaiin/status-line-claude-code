-- Claude Code status on the Touch Bar — Hammerspoon host (native Apple Silicon, no Rosetta).
--
-- MTMR is Intel-only, so on Apple Silicon this is the native path. The status-line script
-- (touchbar-statusline.sh, run by Claude Code) writes ~/.claude/touchbar/status.json on each
-- render; this config paints it into the Touch Bar's wide app-region as a row of color-coded
-- pills. Features:
--   * rounded color-coded pills (green/yellow/red by usage), with a playful "vibes" pill
--   * live cpu / ram / battery / clock computed by Hammerspoon (alive even when Claude is idle)
--   * now-playing (Spotify/Music) + weather, written into the cache by the shell script
--   * live rate-limit countdowns (from absolute reset epochs)
--   * drag a finger to scroll; auto-scrolls as a ticker when plugged in, static on battery
--   * "ultracode" mode (high effort): shimmering label + spinner
--
-- Requires the experimental touchbar module (universal binary) under ~/.hammerspoon, and is
-- loaded from ~/.hammerspoon/init.lua with:  require("claude_touchbar")

local ok, touchbar = pcall(require, "hs._asm.undocumented.touchbar")
if not ok or type(touchbar) ~= "table" then
  hs.printf("[claude_touchbar] touchbar module not found under ~/.hammerspoon — see installer")
  return {}
end

local M = {}

local CACHE = os.getenv("HOME") .. "/.claude/touchbar/status.json"
local STALE, WIDTH, BAR_H, REFRESH = 90, 600, 30, 2
local PAD, PADX, GAP = 6, 9, 6                              -- left margin / pill inner pad / gap
local TICK_INT, TICK_STEP, PAUSE_AFTER_DRAG = 0.04, 0.5, 3  -- ticker interval / px-per-frame / post-drag pause(s)

local COL = {
  green = { hex = "#43c66b" }, yellow = { hex = "#e8b23a" }, red = { hex = "#f0655f" },
  dim = { hex = "#8a8a8e" }, white = { hex = "#ececec" }, accent = { hex = "#c9a9ff" },
}
local function colorFor(p)
  if not p then return COL.dim end
  if p < 50 then return COL.green elseif p < 80 then return COL.yellow else return COL.red end
end
-- Live countdown from an absolute reset epoch, so the timer stays accurate even when Claude is idle.
local function fmtUntil(epoch)
  if not epoch or epoch <= 0 then return nil end
  local d = epoch - os.time()
  if d <= 0 then return "now" end
  if d >= 86400 then return math.floor(d / 86400) .. "d" end
  if d >= 3600 then return string.format("%dh%02dm", math.floor(d / 3600), math.floor((d % 3600) / 60)) end
  return math.floor(d / 60) .. "m"
end
local FONT = "Menlo"  -- known-present; invalid names render text as invisible black-on-black
local function styled(text, color)
  return hs.styledtext.new(text, { font = { name = FONT, size = 13 }, color = color })
end

-- ---- Ultracode mode: shimmer + spinner (mimics the terminal "working" animation) ------------
-- Trigger: effort level. Repoint ULTRA_EFFORT if "ultracode" maps to something else for you.
local ULTRA_EFFORT = "xhigh"
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.phase, M.spin = 0, 0
local function shimmerText(text)
  local out
  for i = 1, #text do
    local b = 0.5 + 0.5 * (0.5 + 0.5 * math.sin((M.phase or 0) + i * 0.6)) -- 0.5..1.0 brightness wave
    local seg = hs.styledtext.new(text:sub(i, i), { font = { name = FONT, size = 13 },
      color = { red = 0.62 * b + 0.18, green = 0.42 * b + 0.12, blue = b } })
    out = out and (out .. seg) or seg
  end
  return out
end
local function ultraStext()
  local lead = M.plugged and SPIN[((M.spin or 0) % #SPIN) + 1] or "⚡"
  local head = hs.styledtext.new(lead .. " ", { font = { name = FONT, size = 13 }, color = COL.accent })
  local tail = hs.styledtext.new("  " .. (M.ultraModel or "Claude"), { font = { name = FONT, size = 13 }, color = COL.accent })
  return head .. shimmerText("ULTRACODE") .. tail
end
local function pillFill(color) return { hex = color.hex, alpha = 0.16 } end
local function measure(stext)
  local okm, sz = pcall(hs.drawing.getTextDrawingSize, stext)
  if okm and sz and sz.w then return sz.w end
  return #tostring(stext) * 8
end
local function readStatus()
  local okR, t = pcall(hs.json.read, CACHE)
  if okR and type(t) == "table" then return t end
  return nil
end

-- ---- Live system stats, computed by Hammerspoon itself (independent of Claude renders) -------
local memStr = (hs.execute("sysctl -n hw.memsize") or ""):gsub("%s", "")  -- takes 1st return only
local TOTAL_BYTES = tonumber(memStr)
local prevTicks
local function liveCPU()
  local okT, t = pcall(hs.host.cpuUsageTicks)
  if not okT or not t or not t.overall then return nil end
  local o = t.overall
  local active = o.active or ((o.user or 0) + (o.system or 0) + (o.nice or 0))
  local idle = o.idle or 0
  local cpu
  if prevTicks then
    local da, di = active - prevTicks.active, idle - prevTicks.idle
    if da + di > 0 then cpu = math.floor(da * 100 / (da + di) + 0.5) end
  end
  prevTicks = { active = active, idle = idle }
  return cpu
end
local function liveRAM()
  -- Reclaimable pages (free+inactive+speculative+purgeable) count as available — avoids macOS's
  -- file-cache making everything look ~99% used.
  local okV, v = pcall(hs.host.vmStat)
  if not okV or type(v) ~= "table" or not TOTAL_BYTES then return nil end
  local ps = v.pageSize or 16384
  local avail = ((v.pagesFree or 0) + (v.pagesInactive or 0) + (v.pagesSpeculative or 0) + (v.pagesPurgeable or 0)) * ps
  local used = TOTAL_BYTES - avail
  if used < 0 then used = 0 end
  return math.floor(used * 100 / TOTAL_BYTES + 0.5)
end
local function liveBat()
  local okP, p = pcall(hs.battery.percentage)
  local okC, c = pcall(hs.battery.isCharging)
  if not okP or type(p) ~= "number" then return nil, "" end
  return math.floor(p + 0.5), (okC and c) and "+" or ""
end

-- Now playing + weather are produced by the shell cache writer (repo-style osascript + wttr.in,
-- with GPS via CoreLocationCLI when installed) and read straight from the cache here.
local function truncate(s, n) if #s > n then return s:sub(1, n - 1) .. "…" end return s end

-- A playful "vibes" read derived from the highest usage pressure (context / 5h / 7d).
local function vibe(p)
  if not p then return "✨ booting up", COL.accent end
  if p < 30 then return "😎 cruising", COL.green
  elseif p < 55 then return "🎯 locked in", COL.green
  elseif p < 75 then return "🌤 warming up", COL.yellow
  elseif p < 90 then return "🌶 spicy", COL.yellow
  else return "🔥 sweating it", COL.red end
end

-- Build the ordered list of {text,color} pills. Claude metrics come from the cache; cpu/ram/
-- battery/clock are always live, so the bar stays bright and alive even when Claude is idle.
local function segments()
  local s = readStatus()
  local L = {}
  local function add(t, c) L[#L + 1] = { text = t, color = c } end

  local model = (s and s.model) or "Claude"
  M.ultra = (s and s.effort == ULTRA_EFFORT) or false
  if M.ultra then
    M.ultraModel = model
    L[#L + 1] = { text = "⚡ ULTRACODE " .. model, color = COL.accent, ultra = true, stext = ultraStext() }
  else
    if s and s.effort and s.effort ~= "" then model = model .. " · " .. s.effort end
    add("⌁ " .. model, COL.accent)
  end

  local pressure
  if s then pressure = math.max(s.ctx or 0, s.five or 0, s.seven or 0) end
  local vword, vcolor = vibe(pressure)
  add(vword, vcolor)

  if s and s.np and s.np ~= "" then add("♪ " .. truncate(s.np, 34), COL.accent) end

  if s and s.ctx then add("🧠 context " .. s.ctx .. "%", colorFor(s.ctx)) end
  if s and s.five then
    local t = "⏳ 5h " .. s.five .. "%"
    local r = fmtUntil(s.five_reset_epoch) or (s.five_reset ~= "" and s.five_reset or nil)
    if r then t = t .. " · " .. r end
    add(t, colorFor(s.five))
  end
  if s and s.seven then
    local t = "📅 7d " .. s.seven .. "%"
    local r = fmtUntil(s.seven_reset_epoch) or (s.seven_reset ~= "" and s.seven_reset or nil)
    if r then t = t .. " · " .. r end
    add(t, colorFor(s.seven))
  end
  if s and s.cost and s.cost ~= "" then add("💰 " .. s.cost, COL.white) end
  if s and s.dur and s.dur ~= "" then add("⏱ " .. s.dur, COL.white) end

  -- Always-live pills (a heartbeat independent of Claude).
  local cpu = liveCPU(); if cpu then add("🖥 cpu " .. cpu .. "%", colorFor(cpu)) end
  local ram = liveRAM(); if ram then add("🧮 ram " .. ram .. "%", colorFor(ram)) end
  local bat, chg = liveBat()
  if bat then add("🔋 battery " .. bat .. "%" .. chg, (bat < 20 and chg ~= "+") and COL.red or COL.green) end
  if s and s.weather and s.weather ~= "" then add(s.weather, COL.white) end
  add("🕐 " .. os.date("%H:%M"), COL.white)
  return L
end

-- Measure + position pills in content space; stash on M.segs and compute scroll bounds.
local function layout()
  local segs = segments()
  local x = PAD
  M.ultraSeg = nil
  for _, seg in ipairs(segs) do
    seg.stext = seg.stext or styled(seg.text, seg.color)  -- ultra pill ships its own shimmer stext
    seg.w = measure(seg.stext) + 2 * PADX
    seg.x = x
    x = x + seg.w + GAP
    if seg.ultra then M.ultraSeg = seg end
  end
  M.segs = segs
  M.contentW = x - GAP + PAD
  M.maxOffset = math.max(0, M.contentW - WIDTH)
  if M.offset > M.maxOffset then M.offset = M.maxOffset end
  if M.offset < 0 then M.offset = 0 end
end

local function render()
  if not M.canvas then return end
  local elems = { {
    type = "rectangle", action = "fill", fillColor = { alpha = 0 },
    frame = { x = 0, y = 0, w = WIDTH, h = BAR_H }, id = "bg",
    trackMouseDown = true, trackMouseUp = true, trackMouseMove = true,
  } }
  for _, seg in ipairs(M.segs or {}) do
    local fx = seg.x - M.offset
    if fx + seg.w > -2 and fx < WIDTH + 2 then  -- cull pills outside the viewport
      elems[#elems + 1] = {
        type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 8, yRadius = 8 },
        fillColor = pillFill(seg.color), frame = { x = fx, y = 4, w = seg.w, h = BAR_H - 8 },
      }
      elems[#elems + 1] = {
        type = "text", text = seg.stext,
        frame = { x = fx + PADX, y = 7, w = seg.w - 2 * PADX + 2, h = BAR_H - 12 },
      }
    end
  end
  -- subtle scroll hints
  if M.maxOffset > 0 and M.offset < M.maxOffset then
    elems[#elems + 1] = { type = "text", text = hs.styledtext.new("›", { color = COL.dim, font = { size = 16 } }),
      frame = { x = WIDTH - 14, y = 5, w = 14, h = BAR_H - 8 } }
  end
  if M.offset > 0 then
    elems[#elems + 1] = { type = "text", text = hs.styledtext.new("‹", { color = COL.dim, font = { size = 16 } }),
      frame = { x = 0, y = 5, w = 14, h = BAR_H - 8 } }
  end
  M.canvas:replaceElements(elems)
end

-- ---- Power-aware ticker: auto-scroll on AC, fully static on battery to save power -----------
local function isPluggedIn()
  local okS, src = pcall(hs.battery.powerSource)
  if okS and src then return src == "AC Power" end
  local okC, c = pcall(hs.battery.isCharging)
  return (okC and c) or false
end
local function tick()
  local dirty = false
  -- Ultracode shimmer/spinner (only runs while the ticker is alive, i.e. plugged in).
  if M.ultra and M.ultraSeg then
    M.phase = (M.phase or 0) + 0.35
    M.spinAcc = (M.spinAcc or 0) + 1
    if M.spinAcc % 3 == 0 then M.spin = (M.spin or 0) + 1 end
    M.ultraSeg.stext = ultraStext()
    dirty = true
  end
  -- Ticker scroll (paused briefly after a manual drag).
  if (M.maxOffset or 0) > 0 and not M.drag and (os.time() - (M.lastInteract or 0)) >= PAUSE_AFTER_DRAG then
    M.offset = M.offset + (M.dir or 1) * TICK_STEP
    if M.offset >= M.maxOffset then M.offset = M.maxOffset; M.dir = -1     -- bounce back at the end
    elseif M.offset <= 0 then M.offset = 0; M.dir = 1 end
    dirty = true
  end
  if dirty then render() end
end
local function startTicker() if not M.scrollTimer then M.scrollTimer = hs.timer.doEvery(TICK_INT, tick) end end
local function stopTicker() if M.scrollTimer then M.scrollTimer:stop(); M.scrollTimer = nil end end
local function updatePower()
  M.plugged = isPluggedIn()
  if M.plugged then
    startTicker()
  else
    stopTicker()                 -- timer fully stopped → no periodic CPU wakeups on battery
    M.offset, M.dir = 0, 1       -- park at the start so model/vibes/context stay in view
    render()
  end
end

function M.start()
  M.offset, M.dir, M.lastInteract = 0, 1, 0
  liveCPU() -- prime tick baseline
  local canvas = hs.canvas.new({ x = 0, y = 0, w = WIDTH, h = BAR_H })
  M.canvas = canvas
  layout(); render()

  -- drag-to-scroll: Touch Bar touches arrive as canvas mouse events
  canvas:canvasMouseEvents(true, true, false, true)
  canvas:mouseCallback(function(_, msg, _, x)
    M.lastInteract = os.time()   -- any touch pauses the ticker briefly so you can read
    if msg == "mouseDown" then
      M.drag, M.dragX, M.startOffset = true, x, M.offset
    elseif msg == "mouseUp" then
      M.drag = false
    elseif msg == "mouseMove" and M.drag then
      M.offset = math.max(0, math.min(M.maxOffset, M.startOffset - (x - M.dragX)))
      render()
    end
  end)

  -- Present in the wide app-region via a modal bar (the system-tray slot is too narrow).
  local item = touchbar.item.newCanvas(canvas, "claudeStatus"):canvasWidth(WIDTH)
  local bar = touchbar.bar.new()
  bar:templateItems({ item }); bar:defaultIdentifiers({ "claudeStatus" })
  M.item, M.bar = item, bar

  local function present()
    local visOk, vis = pcall(function() return bar:isVisible() end)
    if visOk and vis then return end
    pcall(function() bar:presentModalBar() end)
  end
  present()

  M.timer = hs.timer.doEvery(REFRESH, function() layout(); render() end)
  M.keep  = hs.timer.doEvery(5, present)                       -- re-present if something replaced the bar
  M.powerWatcher = hs.battery.watcher.new(updatePower):start() -- plug in → ticker; unplug → static
  updatePower()
end

function M.stop()
  if M.timer then M.timer:stop() end
  if M.keep then M.keep:stop() end
  if M.scrollTimer then M.scrollTimer:stop(); M.scrollTimer = nil end
  if M.powerWatcher then M.powerWatcher:stop() end
  if M.bar then pcall(function() M.bar:dismissModalBar() end) end
end

pcall(M.start)  -- never let an error here break the rest of the user's Hammerspoon config
return M
