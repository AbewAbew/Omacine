-- OmaCine on-screen controls.
--
-- Draws Netflix-style "Skip Intro" and "Next Episode" buttons over the video so
-- they are reachable in fullscreen, where OmaCine's own panel is not.
--
-- Loaded per launch with --script=, never installed into ~/.config/mpv, so it
-- cannot affect any other mpv session.
--
-- Two sources of state:
--   * Skip Intro comes from IntroDB first, and only then from a chapter the
--     release explicitly titled. Nothing is inferred from chapter shape and
--     nothing is detected from the video itself.
--   * Next Episode is pushed in by OmaCine over the IPC socket it already
--     opens, because only OmaCine knows what the next episode is and whether
--     its stream has been resolved yet.
--
-- Activating a button runs a native mpv command (playlist-next / seek), which
-- OmaCine's existing state poller already recognises. No callback channel back
-- into the panel is needed.

local mp = require "mp"
local assdraw = require "mp.assdraw"

local RES_X, RES_Y = 1920, 1080          -- virtual canvas; scales to any window

local overlay = mp.create_osd_overlay("ass-events")
overlay.res_x, overlay.res_y = RES_X, RES_Y

local state = {
    -- Next episode, pushed from OmaCine
    next_label = nil,        -- e.g. "S04E06 - 1080p"
    next_ready = false,      -- stream resolved and queued into the playlist
    next_countdown = nil,    -- seconds remaining, or nil

    -- Skip intro. Chapters come from the file and win; IntroDB is the
    -- crowd-sourced fallback for releases that ship none.
    intro_end = nil,         -- seek target while inside the intro
    in_intro = false,
    intro_from_db = nil,     -- {start, stop} pushed in by OmaCine
    intro_source = nil,      -- "chapters" | "introdb"

    -- Next episode still, as raw BGRA. libass cannot draw images, so the
    -- thumbnail is blitted separately through overlay-add, which works in real
    -- window pixels rather than the virtual canvas the buttons are drawn on.
    thumb = nil,             -- {path, w, h, stride}
    thumb_shown = false,
    hover = nil,             -- action currently under the pointer

    -- Shown over the black frame while a torrent finds peers. Cleared the
    -- moment real video starts, so it can never sit on top of playback.
    loading = nil,           -- {title, detail}
    started = false,
    failed = nil,            -- reason text when the stream could not be opened
}

local THUMB_OVERLAY_ID = 7

local buttons = {}           -- hit targets rebuilt on every draw

local INTRO_PATTERNS = {
    "^op$", "opening", "^intro$", "intro", "recap", "previously",
    "avant", "titles", "^ed$", "ending",
}

local function looks_like_intro(title)
    if not title then return false end
    local lowered = title:lower()
    for _, pattern in ipairs(INTRO_PATTERNS) do
        if lowered:find(pattern) then return true end
    end
    return false
end

-- Rounded-ish filled box in ASS drawing commands.
-- overlay-add works in real window pixels, while the buttons are drawn on a
-- fixed 1920x1080 canvas that libass scales. Convert, or the still lands in the
-- wrong place on every window size but one.
local function to_window(rect)
    local dims = mp.get_property_native("osd-dimensions")
    if not dims or not dims.w or dims.w == 0 or dims.h == 0 then return nil end
    return math.floor(rect.x * dims.w / RES_X + 0.5),
           math.floor(rect.y * dims.h / RES_Y + 0.5)
end

function hide_thumb()
    if state.thumb_shown then
        mp.commandv("overlay-remove", THUMB_OVERLAY_ID)
        state.thumb_shown = false
    end
end

function sync_thumb()
    local rect, thumb = state.thumb_rect, state.thumb
    if not rect or not thumb then hide_thumb() return end
    local x, y = to_window(rect)
    if not x then hide_thumb() return end
    -- dw/dh scale the source pixels to the card, so one converted still works
    -- at any window size.
    local dims = mp.get_property_native("osd-dimensions")
    local dw = math.floor(rect.w * dims.w / RES_X + 0.5)
    local dh = math.floor(rect.h * dims.h / RES_Y + 0.5)
    mp.commandv("overlay-add", THUMB_OVERLAY_ID, x, y, thumb.path, 0, "bgra",
                thumb.w, thumb.h, thumb.stride, dw, dh)
    state.thumb_shown = true
end

local function box(ass, x, y, w, h, colour, alpha)
    ass:new_event()
    ass:append(string.format("{\\pos(0,0)\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}", colour, alpha))
    ass:draw_start()
    ass:rect_cw(x, y, x + w, y + h)
    ass:draw_stop()
end

local function label(ass, x, y, size, colour, text, bold)
    ass:new_event()
    ass:append(string.format("{\\pos(%d,%d)\\an4\\fs%d\\bord2\\shad1\\1c&H%s&\\3c&H000000&%s}",
                             x, y, size, colour, bold and "\\b1" or ""))
    ass:append(text)
end

-- mpv has no way to change the pointer shape - it exposes only cursor-autohide
-- and input-cursor, nothing about the cursor image - so hover is communicated
-- by lighting the button instead.
local function hovered(action)
    return state.hover == action
end

-- A centred card while the stream spins up. mpv otherwise shows nothing at
-- all, which is indistinguishable from a hang.
local function draw_loading(ass)
    local w, h = 900, 190
    local x, y = (RES_X - w) / 2, (RES_Y - h) / 2
    box(ass, x, y, w, h, "101010", 0x20)
    box(ass, x, y, 8, h, "FFFFFF", 0x00)
    label(ass, x + 34, y + 58, 40, "FFFFFF", state.loading.title or "Loading", true)
    label(ass, x + 34, y + 108, 26, "BBBBBB", state.loading.detail or "", false)

    -- An indeterminate bar: the byte counts a torrent reports early on are not
    -- a reliable fraction of anything, so this shows liveness, not progress.
    local bar_w, bar_h = w - 68, 6
    local bx, by = x + 34, y + h - 42
    box(ass, bx, by, bar_w, bar_h, "3A3A3A", 0x40)
    local period, chunk = 2.2, 0.28
    local t = (mp.get_time() % period) / period
    local sweep = bar_w * chunk
    local px = bx + (bar_w + sweep) * t - sweep
    local visible_x = math.max(bx, px)
    local visible_w = math.min(px + sweep, bx + bar_w) - visible_x
    if visible_w > 0 then
        box(ass, visible_x, by, visible_w, bar_h, "FFFFFF", 0x10)
    end
end

-- Shown when mpv could not open the stream at all. Without this the window
-- simply disappears, which is indistinguishable from a crash.
local function draw_failed(ass)
    local w, h = 900, 180
    local x, y = (RES_X - w) / 2, (RES_Y - h) / 2
    box(ass, x, y, w, h, "1A0E0E", 0x18)
    box(ass, x, y, 8, h, "D05050", 0x00)
    label(ass, x + 34, y + 58, 38, "FFFFFF", "Could not load this stream", true)
    label(ass, x + 34, y + 104, 24, "CCAAAA", state.failed or "", false)
    label(ass, x + 34, y + 140, 22, "999999",
          "Press q to close, then pick another source in OmaCine.", false)
end

local function draw()
    buttons = {}
    local ass = assdraw.ass_new()

    if state.failed then
        draw_failed(ass)
    elseif state.loading then
        draw_loading(ass)
    end

    -- Sit above uosc's timeline rather than under it.
    local margin_x, base_y = 96, RES_Y - 230
    local h = 68

    -- Skip Intro sits left; Next Episode right, so they never overlap.
    if state.in_intro and state.intro_end then
        local w = 260
        local x, y = margin_x, base_y
        local lit = hovered("skip_intro")
        box(ass, x, y, w, h, lit and "3A3A3A" or "1A1A1A", lit and 0x10 or 0x30)
        box(ass, x, y, lit and 10 or 6, h, "FFFFFF", 0x00)
        local caption = "Skip Intro"
        if state.intro_source == "introdb" and state.intro_from_db
           and (state.intro_from_db.submissions or 0) <= 1 then
            caption = "Skip Intro?"      -- one unverified submission
        end
        label(ass, x + 28, y + h / 2, 34, "FFFFFF", caption, true)
        buttons[#buttons + 1] = { x = x, y = y, w = w, h = h, action = "skip_intro" }
    end

    if state.next_label then
        local text = state.next_ready and "Next Episode" or "Preparing next episode"
        if state.next_countdown and state.next_ready then
            text = string.format("Next Episode  %ds", state.next_countdown)
        end
        -- With a still, the card grows to hold it and the text sits beside it.
        local thumb_w, thumb_h = 0, 0
        if state.thumb then
            thumb_h = 96
            thumb_w = math.floor(thumb_h * 16 / 9)
        end
        local card_h = state.thumb and (thumb_h + 24) or h
        local w = math.max(360, #text * 15 + 120) + thumb_w
        local x = RES_X - margin_x - w
        local y = base_y + h - card_h          -- keep the bottom edge aligned
        local lit = hovered("next_episode") and state.next_ready
        local fill = lit and "3A3A3A" or (state.next_ready and "1A1A1A" or "2A2A2A")
        box(ass, x, y, w, card_h, fill, lit and 0x10 or 0x30)
        if state.next_ready then box(ass, x, y, lit and 10 or 6, card_h, "FFFFFF", 0x00) end

        local text_x = x + 28 + thumb_w + (state.thumb and 18 or 0)
        label(ass, text_x, y + card_h / 2 - 11, 32, "FFFFFF", text, true)
        label(ass, text_x, y + card_h / 2 + 16, 22, "BBBBBB", state.next_label, false)
        if state.next_ready then
            buttons[#buttons + 1] = { x = x, y = y, w = w, h = card_h, action = "next_episode" }
        end
        state.thumb_rect = state.thumb and
            { x = x + 12, y = y + 12, w = thumb_w, h = thumb_h } or nil
    else
        state.thumb_rect = nil
    end

    overlay.data = ass.text
    overlay:update()
    sync_thumb()
end

local function clear()
    buttons = {}
    overlay.data = ""
    overlay:update()
    hide_thumb()
end

local function refresh()
    if state.failed or state.loading or state.in_intro or state.next_label then draw() else clear() end
end

-- The sweep has to be redrawn to animate, but only while a card is up.
local loading_timer = mp.add_periodic_timer(0.06, function()
    if state.loading then draw() end
end)
loading_timer:kill()

local function set_loading(card)
    state.loading = card
    if card then loading_timer:resume() else loading_timer:kill() end
    refresh()
end

-- ---------------------------------------------------------------- chapters

local function scan_chapters()
    state.intro_end, state.in_intro = nil, false
    local chapters = mp.get_property_native("chapter-list") or {}
    for index, chapter in ipairs(chapters) do
        if looks_like_intro(chapter.title) then
            local next_chapter = chapters[index + 1]
            -- Only useful if we know where to skip to.
            if next_chapter then
                chapter.skip_to = next_chapter.time
            end
        end
    end
    state.chapters = chapters
end

-- Only a chapter the release actually titled counts. Judging an untitled
-- chapter by its shape cannot tell a theme song from a cold open, which is
-- exactly the guessing IntroDB exists to replace.

local function update_intro(time_pos)
    if not time_pos then return end
    local active_end, source = nil, nil

    -- IntroDB first: a submission comes from somebody who watched the episode,
    -- where a chapter is at best a label somebody attached to the release. It
    -- arrives asynchronously, and this re-runs when it does.
    if state.intro_from_db then
        local window = state.intro_from_db
        if time_pos >= window.start and time_pos < window.stop then
            active_end, source = window.stop, "introdb"
        end
    end

    -- Fall back to a chapter only when it is explicitly titled as an intro or
    -- a recap, and only when IntroDB had nothing for this episode.
    if not active_end then
        for index, chapter in ipairs(state.chapters or {}) do
            local next_chapter = (state.chapters or {})[index + 1]
            local ends = next_chapter and next_chapter.time or nil
            if ends and looks_like_intro(chapter.title)
               and time_pos >= chapter.time and time_pos < ends then
                active_end, source = ends, "chapters"
                break
            end
        end
    end
    state.intro_source = source
    local was = state.in_intro
    state.in_intro = active_end ~= nil
    state.intro_end = active_end
    if was ~= state.in_intro then refresh() end
end

-- ---------------------------------------------------------------- actions

local function activate(action)
    if action == "skip_intro" and state.intro_end then
        mp.commandv("seek", state.intro_end, "absolute", "exact")
        state.in_intro = false
        refresh()
    elseif action == "next_episode" then
        -- OmaCine's poller sees the path change and takes it from there.
        mp.commandv("playlist-next", "force")
        state.next_label, state.next_ready, state.next_countdown = nil, false, nil
        refresh()
    end
end

local function hit_test()
    local mouse = mp.get_property_native("mouse-pos")
    local dims = mp.get_property_native("osd-dimensions")
    if not mouse or not dims or not dims.w or dims.w == 0 then return nil end
    -- Window pixels -> the virtual canvas the buttons were drawn on.
    local x = mouse.x / dims.w * RES_X
    local y = mouse.y / dims.h * RES_Y
    for _, button in ipairs(buttons) do
        if x >= button.x and x <= button.x + button.w
           and y >= button.y and y <= button.y + button.h then
            return button.action
        end
    end
    return nil
end

-- Cheap hover polling. mp.observe_property on mouse-pos fires constantly, so
-- this only redraws when the button under the pointer actually changes.
local hover_timer = mp.add_periodic_timer(0.15, function()
    if not (state.in_intro or state.next_label) then
        if state.hover then state.hover = nil end
        return
    end
    local now = hit_test()
    if now ~= state.hover then
        state.hover = now
        draw()
    end
end)

mp.add_key_binding("MBTN_LEFT", "omacine-click", function()
    local action = hit_test()
    if action then activate(action) end
end, { complex = false })

-- Keyboard equivalents, so the overlay is usable without a pointer.
mp.add_key_binding("s", "omacine-skip-intro", function() activate("skip_intro") end)
mp.add_key_binding("n", "omacine-next-episode", function() activate("next_episode") end)

-- ---------------------------------------------------------------- from OmaCine

-- omacine-upnext <label> <ready:0|1> [countdown]
mp.register_script_message("omacine-upnext", function(label_text, ready, countdown)
    state.next_label = (label_text ~= nil and label_text ~= "") and label_text or nil
    state.next_ready = ready == "1"
    state.next_countdown = tonumber(countdown)
    refresh()
end)

-- omacine-intro <start> <end> <submissions>
mp.register_script_message("omacine-intro", function(start_s, end_s, submissions)
    local start_v, end_v = tonumber(start_s), tonumber(end_s)
    if start_v and end_v and end_v > start_v then
        state.intro_from_db = { start = start_v, stop = end_v,
                                submissions = tonumber(submissions) or 0 }
    else
        state.intro_from_db = nil
    end
    update_intro(mp.get_property_number("time-pos"))
    refresh()
end)

-- omacine-thumb <path> <w> <h> <stride>   (empty path clears it)
mp.register_script_message("omacine-thumb", function(path, w, h, stride)
    local width, height, row = tonumber(w), tonumber(h), tonumber(stride)
    if path and path ~= "" and width and height and row then
        state.thumb = { path = path, w = width, h = height, stride = row }
    else
        state.thumb = nil
        hide_thumb()
    end
    refresh()
end)

-- omacine-loading <title> <detail>   (empty title dismisses it)
mp.register_script_message("omacine-loading", function(title, detail)
    if title and title ~= "" and not state.started then
        set_loading({ title = title, detail = detail or "" })
    else
        set_loading(nil)
    end
end)

mp.register_script_message("omacine-clear", function()
    state.next_label, state.next_ready, state.next_countdown = nil, false, nil
    state.thumb = nil
    hide_thumb()
    refresh()
end)

-- ---------------------------------------------------------------- lifecycle

-- reason is "error" when the source could not be opened or died mid-stream.
mp.register_event("end-file", function(event)
    if event and event.reason == "error" then
        local why = event.file_error or "the source stopped responding"
        state.failed = tostring(why)
        set_loading(nil)
        refresh()
    end
end)

mp.register_event("start-file", function()
    state.failed = nil
end)

mp.register_event("file-loaded", function()
    state.failed = nil
    state.started = false
    set_loading(nil)
    state.thumb = nil
    hide_thumb()
    state.next_label, state.next_ready, state.next_countdown = nil, false, nil
    state.intro_from_db, state.intro_source = nil, nil
    scan_chapters()
    refresh()
end)

mp.observe_property("time-pos", "number", function(_, value)
    -- Real frames are playing, so the loading card has served its purpose.
    if value and value > 0.2 and state.loading then
        state.started = true
        set_loading(nil)
    end
    update_intro(value)
end)
mp.observe_property("chapter-list", "native", function() scan_chapters() end)
-- A resize changes the pixel mapping, so the still has to be re-placed.
mp.observe_property("osd-dimensions", "native", function()
    if state.thumb_rect then sync_thumb() end
end)
