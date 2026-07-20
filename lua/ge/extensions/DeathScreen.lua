-- Death Screen (CLIENT)
-- Blacks out the whole screen for a few seconds after a HARD crash, GTA-style,
-- so you get a clean "moment" to show off the wreck. Pure client-side visual:
-- works in singleplayer freeroam and on BeamMP servers, no server plugin needed.
--
-- How it detects a HARD crash (and ignores light taps):
-- BeamNG publishes each vehicle's cumulative crash damage (dissipated energy)
-- to the game engine every frame as `map.objects[vehId].damage`. We watch our
-- own vehicle's damage and sum up how much NEW damage it takes inside a short
-- rolling window (~0.8 s). A gentle bump adds almost nothing; a real crash dumps
-- a huge amount of energy in a fraction of a second. When that windowed damage
-- crosses a tunable threshold, we black out. This is severity-based, so brushing
-- a wall at speed no longer triggers it (the old speed-based check did).
--
-- The blackout itself is a full-screen <div> injected into the game's browser
-- UI via be:executeJS, which fades to black, holds for the tunable duration,
-- then fades back. The settings window is imgui; open it with the keybind.

local M = {}

local im = ui_imgui
local ffi = require('ffi')

--------------------------------------------------------------------------------
-- SETTINGS  (persisted to settings/DeathScreen/settings.json)
--------------------------------------------------------------------------------
local SETTINGS_PATH = "settings/DeathScreen/settings.json"
local SOUND_DIR     = "/settings/DeathScreen/"   -- bare filenames resolve here
local PRESETS_DIR   = "/settings/DeathScreen/Presets/"   -- one .json per preset (shareable: drop a file in)
local TEXT_CAP = 48
local SUB_CAP  = 64
local PRESET_CAP = 48

-- imgui-backed setting pointers (these ARE the live settings)
local enabledPtr   = im.BoolPtr(true)     -- GLOBAL master: off = nothing fires at all
local blackoutPtr  = im.BoolPtr(true)     -- the blackout/death-screen itself (vs blur/vignette)
local durationPtr  = im.FloatPtr(4.0)     -- seconds held at full black (the "3-5s")
local fadeInPtr    = im.FloatPtr(0.12)    -- seconds to snap to black
local fadeOutPtr   = im.FloatPtr(0.9)     -- seconds to fade back in
local thresholdPtr = im.FloatPtr(90000)   -- windowed crash damage needed to trigger ("hardcore" gate)
local minSpeedPtr  = im.FloatPtr(5.0)     -- km/h floor (ignores fire/parked damage, slow crushes)
-- Pass-out (upside-down) settings grouped in a table (keeps the file under LuaJIT's
-- 200-locals-per-chunk cap; same reason as the SM slow-mo table).
local PASSOUT = {
    on        = im.BoolPtr(true),   -- "pass out" (blackout) after being upside down for a while
    time      = im.FloatPtr(13.5),  -- seconds upside down before you pass out
    fadeIn    = im.FloatPtr(1.5),   -- seconds to fade to black when passing out (gradual faint, NOT the crash snap)
    fadeOut   = im.FloatPtr(1.2),   -- seconds for vision to return when you come to (flipped back / reset)
    playSound = im.BoolPtr(true),   -- also play the custom death sound when you pass out (vs only on a crash)
    soundVol  = im.FloatPtr(1.0),   -- volume for the pass-out sound (its own knob, separate from the crash sound)
    angle     = im.FloatPtr(120.0), -- degrees tipped from upright before you pass out (90=on side, 180=full roof); cos(120)=-0.5
}
local opacityPtr   = im.FloatPtr(1.0)     -- how black (1.0 = fully black)
local scalePtr     = im.BoolPtr(false)    -- scale the blackout with how hard the crash was
local scaleMinPtr  = im.FloatPtr(1.5)     -- shortest blackout (a crash that just barely triggers)
local scaleMinDarkPtr = im.FloatPtr(0.5)  -- lightest darkness (a crash that just barely triggers)
local scaleFullPtr = im.FloatPtr(200000)  -- crash force at/above which you get the full blackout
local soundCutPtr  = im.BoolPtr(true)     -- mute all game audio while the screen is black
local soundBackPtr = im.BoolPtr(true)     -- bring game audio back BEFORE the screen clears (hear before you see)
local soundBackAtPtr = im.FloatPtr(1.5)   -- seconds after the crash when game audio returns (while still black)
local soundBackFadePtr = im.FloatPtr(0.8) -- seconds to swell the game audio back in when it returns (0 = instant)
local showTextPtr  = im.BoolPtr(false)    -- draw a centered "WASTED"-style message once black
local textBuf      = ffi.new("char[?]", TEXT_CAP)
local subBuf       = ffi.new("char[?]", SUB_CAP)
local presetNameBuf = ffi.new("char[?]", PRESET_CAP)  -- UI-only: the name box for saving a preset
local textSizePtr  = im.FloatPtr(88)      -- title font size in px
local textDelayPtr = im.FloatPtr(0.26)    -- seconds after full-black before the message slams in
local colorArr     = im.ArrayFloat(3)     -- title color (RGB 0..1) for the imgui color picker
-- extra text customization (message section)
local subColorArr    = im.ArrayFloat(3)   -- subtitle color
local subSizePtr     = im.FloatPtr(36)    -- subtitle font size (px)
local textShadowPtr  = im.BoolPtr(true)   -- text shadow / glow behind the message
local textShadowStrPtr = im.FloatPtr(0.05) -- shadow/glow spread (0..1)
local textShadowColorArr = im.ArrayFloat(3) -- shadow/glow color
local textPosPtr     = im.IntPtr(1)       -- vertical position: 0 top / 1 centre / 2 bottom
local textBoldPtr    = im.BoolPtr(true)    -- bold vs normal weight
local textItalicPtr  = im.BoolPtr(false)  -- italic
local textSpacingPtr = im.FloatPtr(8)     -- letter spacing (px)
local textFontPtr    = im.IntPtr(0)       -- index into FONTS

-- extras
local EVENT_CAP       = 96
-- Slow-mo (bullet-time) settings grouped in one table: LuaJIT caps a function (incl.
-- the file's main chunk) at 200 locals and we were bumping it -- a table is one local.
local SM = {
    on        = im.BoolPtr(false),  -- bullet-time on crash
    factor    = im.FloatPtr(0.3),   -- time scale during slow-mo (1 = normal); the DEEP end when scaling
    dur       = im.FloatPtr(2.0),   -- real seconds the slow-mo lasts; the FULL length when scaling
    scale     = im.BoolPtr(false),  -- scale slow-mo length + depth with how hard the crash was
    minDur    = im.FloatPtr(0.5),   -- shortest slow-mo (a crash that just barely triggers)
    minFactor = im.FloatPtr(0.6),   -- mildest game speed (barely-triggering crash); deepens toward SM.factor
    full      = im.FloatPtr(200000),-- crash force at/above which slow-mo is at full length + depth
}
local soundPtr        = im.BoolPtr(false) -- play a death sting on trigger
local soundVolPtr     = im.FloatPtr(1.0)  -- sting volume
local soundFadePtr    = im.BoolPtr(false) -- fade the sting out near its end instead of a hard cut
local soundFadeDurPtr = im.FloatPtr(1.0)  -- fade-out length (seconds)
local soundEventBuf   = ffi.new("char[?]", EVENT_CAP)
PASSOUT.soundBuf      = ffi.new("char[?]", EVENT_CAP)   -- optional separate sound for a pass-out (blank = reuse the main death sound)
local vignettePtr     = im.BoolPtr(false) -- tinted edge vignette instead of flat black
local vignetteAfterPtr= im.BoolPtr(true)  -- true = vignette appears once the screen is black
local vigFadeInPtr    = im.BoolPtr(true)  -- fade the vignette in (vs snap on)
local vigFadeInDurPtr = im.FloatPtr(0.5)  -- vignette fade-in length (s)
local vigFadeOutPtr   = im.BoolPtr(true)  -- fade the vignette out (vs snap off)
local vigFadeOutDurPtr= im.FloatPtr(0.5)  -- vignette fade-out length (s)
local tintArr         = im.ArrayFloat(3)  -- vignette edge color (RGB 0..1)

-- Damage vignette: FPS-style. ANY crash (not just death-screen ones) flashes a
-- colored vignette at the screen edges whose strength scales with the hit, then
-- fades away on its own. Independent of the blackout.
-- Damage-vignette settings grouped in a table (keeps the file under LuaJIT's 200-locals cap)
local DVIG = {
    on    = im.BoolPtr(true),
    max   = im.FloatPtr(0.7),    -- peak opacity of the flash (0..1)
    cover = im.FloatPtr(0.7),    -- how far it reaches in from the edges at full strength (0..1)
    soft  = im.FloatPtr(0.6),    -- gradient softness: how wide/feathered the edge fade is (0..1)
    full  = im.FloatPtr(40000),  -- damage that pushes it to full strength
    fade  = im.FloatPtr(1.5),    -- seconds to fade back to nothing
    color = im.ArrayFloat(3),    -- edge color (RGB 0..1)
}

-- Crash blur: a full-screen gaussian blur on crash (the game's menu-background blur).
-- Crash-blur settings grouped in a table (LuaJIT 200-locals-per-chunk cap; same as SM/PASSOUT/INJ)
local BLUR = {
    on         = im.BoolPtr(true),
    amt        = im.FloatPtr(0.8),    -- how strong the blur is (0..1)
    dur        = im.FloatPtr(1.2),    -- how long it holds at full before easing off (s)
    trig       = im.FloatPtr(30000),  -- crash force needed to set the blur off (its own, lower threshold)
    fadeIn     = im.BoolPtr(true),    -- ease the blur in (vs snap on)
    fadeInDur  = im.FloatPtr(0.4),    -- blur fade-in length (s)
    fadeOut    = im.BoolPtr(true),    -- ease the blur out (vs snap off)
    fadeOutDur = im.FloatPtr(0.6),    -- blur fade-out length (s)
}
-- Recovery blur: after a blackout, blur the screen as it fades back in and clear it, as
-- if you're regaining your vision. Reuses the same full-screen blur as the crash blur.
local recoveryBlurPtr    = im.BoolPtr(true)   -- blur the screen as the blackout lifts
local recoveryBlurAmtPtr = im.FloatPtr(0.8)   -- how strong that blur starts (0..1)
local recoveryBlurDurPtr = im.FloatPtr(1.5)   -- how long it takes to clear (s)

local DEFAULT_COLOR   = {0.757, 0.071, 0.122}  -- #c1121f (GTA-ish red)
local DEFAULT_TINT    = {0.45, 0.02, 0.02}     -- dark-red vignette edges
local DEFAULT_DMGCOLOR= {0.75, 0.04, 0.04}     -- FPS damage red
local DEFAULT_SUBCOLOR= {0.874, 0.890, 0.902}  -- #dfe3e6 light grey subtitle
local DEFAULT_SHADOW  = {0.667, 0.0, 0.0}      -- #AA0000 dark-red glow (black is invisible on black)
local DEFAULT_INJCOLOR= {0.910, 0.706, 0.706}  -- #e8b4b4 pale clinical red for the injury report
-- Message fonts (CSS font-family stacks). Index 0 = default; stored by index
-- (textFontPtr) and applied to the overlay in the JS. The first group are fonts BeamNG
-- itself bundles + registers via @font-face in its UI (our overlay lives in the same
-- page, so these ALWAYS render) -- incl. "Digital" = the 7-segment display font
-- (Segment7Standard.otf). The rest are common system fonts (depend on the OS having them).
local FONTS = {
    { name = "Default",          css = "'Segoe UI',Roboto,Arial,sans-serif" },
    { name = "7-Segment",        css = "Digital,'Courier New',monospace" },
    { name = "Squada One",       css = "'Squada One',Impact,sans-serif" },
    { name = "Play",             css = "'Play','Segoe UI',sans-serif" },
    { name = "Roboto Condensed", css = "'Roboto Condensed',Arial,sans-serif" },
    { name = "News Cycle",       css = "'News Cycle',Arial,sans-serif" },
    { name = "Overpass",         css = "'Overpass',Arial,sans-serif" },
    { name = "Impact",           css = "Impact,'Arial Black',sans-serif" },
    { name = "Arial Black",      css = "'Arial Black',Gadget,sans-serif" },
    { name = "Arial",            css = "Arial,Helvetica,sans-serif" },
    { name = "Verdana",          css = "Verdana,Geneva,sans-serif" },
    { name = "Tahoma",           css = "Tahoma,Geneva,sans-serif" },
    { name = "Trebuchet MS",     css = "'Trebuchet MS',Helvetica,sans-serif" },
    { name = "Georgia",          css = "Georgia,'Times New Roman',serif" },
    { name = "Times New Roman",  css = "'Times New Roman',Times,serif" },
    { name = "Courier New",      css = "'Courier New',Courier,monospace" },
    { name = "Comic Sans MS",    css = "'Comic Sans MS',cursive" },
}

local windowOpen   = im.BoolPtr(true)     -- the settings window (open on first load so it's found)
local hideUIPtr    = im.BoolPtr(true)     -- hide this window while the death screen is showing

-- rolling damage window
-- Injury report (Tier 1: severity-based flavour). INJURIES[tone][tier] = a pool of lines;
-- tier (1..4) is picked from crash force. Deliberately structured so a REGION dimension
-- (directional injuries, Tier 2) and real part-damage (Tier 3) can slot in later without
-- reworking the picker. Pure roleplay flavour -- not medical, not serious.
local INJ = {
    on    = im.BoolPtr(false),   -- show an "injuries sustained" report on the death screen
    funny = im.BoolPtr(false),   -- tone: false = clinical, true = darkly funny
    size  = im.FloatPtr(26.0),   -- injury line font size (px)
    tough = im.FloatPtr(1.0),    -- survivability: multiplies the speed-tier thresholds (roll cage etc.)
    showFatal = im.BoolPtr(true),-- allow the "deceased" capstone on the worst crashes (off = always survive)
    deform = im.BoolPtr(true),   -- deformation-based detection (reads the real crush; off = impulse-only guess)
    color  = im.ArrayFloat(3),   -- injury text color (defaults set below)
    showDir = im.BoolPtr(true),  -- lead the report with the detected impact ("Frontal impact" etc.)
    delay   = im.FloatPtr(0.7),  -- seconds after the crash before the report fades in (auto-capped below the blackout)
    pos     = im.IntPtr(0),      -- 0 auto (bottom w/ message, centred without) / 1 top / 2 centre / 3 bottom
    -- pools[tone][region] = {minor=, major=} by impact direction; plus a per-tone `fatal`
    -- capstone for the worst crashes. Nested in INJ so it isn't a separate top-level local.
    pools = {
        clinical = {
            front    = { minor = { "Whiplash", "Bruised sternum", "Seatbelt abrasion", "Knee contusion", "Split lip" },
                         major = { "Fractured sternum", "Facial fractures", "Shattered kneecaps", "Femur fracture", "Flail chest", "Traumatic brain injury" } },
            rear     = { minor = { "Whiplash", "Strained neck", "Sore lower back", "Mild concussion" },
                         major = { "Cervical spine fracture", "Severe whiplash", "Herniated disc", "Fractured vertebra", "Concussion" } },
            side     = { minor = { "Bruised ribs", "Sore hip", "Shoulder strain", "Lateral bruising" },
                         major = { "Fractured ribs", "Pelvic fracture", "Ruptured spleen", "Collapsed lung", "Dislocated shoulder", "Fractured humerus" } },
            rollover = { minor = { "Neck strain", "Scalp laceration", "Bruised spine", "Sore shoulders" },
                         major = { "Cervical spine fracture", "Skull fracture", "Crush injuries", "Spinal cord damage", "Traumatic brain injury" } },
            fatal    = { "Cause of death: blunt force trauma", "Pronounced dead at the scene", "Non-survivable trauma" },
        },
        funny = {
            front    = { minor = { "Ate the steering wheel", "Airbag to the face, 0/10", "Dashboard kiss", "Knees to the chin" },
                         major = { "Became one with the dashboard", "Faceplant, professional grade", "Ribs: rearranged", "Kneecaps: gone", "Windshield speedrun" } },
            rear     = { minor = { "Whiplash (worth it)", "Neck went boing", "Rear-ended, respectfully", "Head, meet headrest" },
                         major = { "Neck folded backwards", "Spine went accordion", "Whiplash: legendary tier", "Head snapped like a Pez dispenser" } },
            side     = { minor = { "Ribs met the door", "Door-shaped bruise", "Shoulder check (literal)", "Hip took the hit" },
                         major = { "T-boned into oblivion", "Ribs now a xylophone", "Pelvis: rearranged", "Spleen has left the chat", "Door became interior decor" } },
            rollover = { minor = { "Bat impression: successful", "Dizzy but alive", "Rolled like a burrito", "Neck went sideways" },
                         major = { "Tumble dry: complete", "Became a human pretzel", "Roof, meet skull", "Ragdoll mode: permanent" } },
            fatal    = { "Deceased, respectfully", "Speedran to the afterlife", "Soul ejected at Mach 1", "Insurance fraud (successful)" },
        },
    },
    -- per-region impact-speed tiers {t2,t3,t4} km/h: front is most survivable (crumple zone +
    -- airbags), side/rollover the least. Injury tier = max(damage tier, this speed tier).
    sevSpeed = { front = { 55, 110, 175 }, rear = { 55, 120, 190 }, side = { 30, 65, 105 }, rollover = { 32, 68, 120 } },
    -- lead-in line atop the report so the detected impact direction/side is visible
    context = {
        clinical = { front = "Frontal impact", rear = "Rear impact", sideLeft = "Driver's-side impact", sideRight = "Passenger's-side impact", rollover = "Rollover" },
        funny    = { front = "Went in nose-first", rear = "Rear-ended", sideLeft = "Driver's side took it", sideRight = "Passenger got sacrificed", rollover = "Full tumble-dry" },
    },
}
pcall(function() math.randomseed(os.time()) end)   -- so the injury picks vary between sessions

local WINDOW_SEC   = 0.8

local function setBuf(buf, cap, s)
    s = tostring(s or "")
    if #s > cap - 1 then s = s:sub(1, cap - 1) end
    ffi.copy(buf, s)
end
setBuf(textBuf, TEXT_CAP, "WASTED")
setBuf(subBuf,  SUB_CAP,  "")
setBuf(presetNameBuf, PRESET_CAP, "")
colorArr[0] = im.Float(DEFAULT_COLOR[1])  -- default #c1121f (GTA-ish red)
colorArr[1] = im.Float(DEFAULT_COLOR[2])
colorArr[2] = im.Float(DEFAULT_COLOR[3])
setBuf(soundEventBuf, EVENT_CAP, "")   -- empty by default; user picks their own sound
tintArr[0] = im.Float(DEFAULT_TINT[1])   -- dark-red vignette edges
tintArr[1] = im.Float(DEFAULT_TINT[2])
tintArr[2] = im.Float(DEFAULT_TINT[3])
DVIG.color[0] = im.Float(DEFAULT_DMGCOLOR[1])
DVIG.color[1] = im.Float(DEFAULT_DMGCOLOR[2])
DVIG.color[2] = im.Float(DEFAULT_DMGCOLOR[3])
for i = 0, 2 do subColorArr[i]        = im.Float(DEFAULT_SUBCOLOR[i + 1]) end
for i = 0, 2 do INJ.color[i]          = im.Float(DEFAULT_INJCOLOR[i + 1]) end
for i = 0, 2 do textShadowColorArr[i] = im.Float(DEFAULT_SHADOW[i + 1]) end

-- which collapsible sections are expanded, remembered across restarts. Keyed by
-- the section label; `section()` fills in defaults on first run and flips
-- sectionDirty when the user opens/closes one so we persist it.
-- named presets: name -> a full settings snapshot (effect settings only). Each is now one
-- .json file in the Presets/ folder (shareable: hand someone a file / drop one in). `presets`
-- is the in-memory list, rebuilt from disk by refreshPresets().
local presets = {}
local presetPollT = 0   -- live-refresh countdown while the settings window is open
local function presetPath(name)
    local safe = tostring(name or ""):gsub('[\\/:*?"<>|]', "_"):match("^%s*(.-)%s*$")
    return PRESETS_DIR .. safe .. ".json"
end
local function ensurePresetDir()
    pcall(function() if FS and not FS:directoryExists(PRESETS_DIR) then FS:directoryCreate(PRESETS_DIR, true) end end)
end
local function refreshPresets()   -- rebuild the list from the folder (filename = preset name)
    local found = {}
    pcall(function()
        if not FS or not FS:directoryExists(PRESETS_DIR) then return end
        local files = FS:findFiles(PRESETS_DIR, "*.json", 0, false, true) or {}
        for _, path in ipairs(files) do
            local base = tostring(path):match("([^/\\]+)%.json$")
            local data = base and jsonReadFile(path)
            if base and type(data) == "table" then found[base] = data end
        end
    end)
    presets = found
end
local sectionOpen = {}
local sectionDirty = false

-- first-run keybind notice: shown once (until dismissed) so a fresh installer knows
-- how to reopen the window after closing it. Persisted so it never nags again.
local noticeSeen = false

-- transient: true while the "Reset all to defaults" button is waiting for confirmation
local resetConfirm = false

-- second half of the serialiser, split out to keep each function's upvalue count
-- under Lua's cap of 60 (each pointer referenced is an upvalue).
local function saveSettings2(t)
    t.vignette      = vignettePtr[0]
    t.vignetteAfter = vignetteAfterPtr[0]
    t.vigFadeIn     = vigFadeInPtr[0]
    t.vigFadeInDur  = vigFadeInDurPtr[0]
    t.vigFadeOut    = vigFadeOutPtr[0]
    t.vigFadeOutDur = vigFadeOutDurPtr[0]
    t.tint          = { tonumber(tintArr[0]), tonumber(tintArr[1]), tonumber(tintArr[2]) }
    t.dmgVig        = DVIG.on[0]
    t.dmgVigMax     = DVIG.max[0]
    t.dmgVigCover   = DVIG.cover[0]
    t.dmgVigSoft    = DVIG.soft[0]
    t.dmgVigFull    = DVIG.full[0]
    t.dmgVigFade    = DVIG.fade[0]
    t.dmgVigColor   = { tonumber(DVIG.color[0]), tonumber(DVIG.color[1]), tonumber(DVIG.color[2]) }
    t.blur          = BLUR.on[0]
    t.blurAmt       = BLUR.amt[0]
    t.blurDur       = BLUR.dur[0]
    t.blurTrig      = BLUR.trig[0]
    t.blurFadeIn    = BLUR.fadeIn[0]
    t.blurFadeInDur = BLUR.fadeInDur[0]
    t.blurFadeOut   = BLUR.fadeOut[0]
    t.blurFadeOutDur= BLUR.fadeOutDur[0]
    t.recoveryBlur    = recoveryBlurPtr[0]
    t.recoveryBlurAmt = recoveryBlurAmtPtr[0]
    t.recoveryBlurDur = recoveryBlurDurPtr[0]
    t.subColor      = { tonumber(subColorArr[0]), tonumber(subColorArr[1]), tonumber(subColorArr[2]) }
    t.subSize       = subSizePtr[0]
    t.textShadow    = textShadowPtr[0]
    t.textShadowStr = textShadowStrPtr[0]
    t.textShadowColor = { tonumber(textShadowColorArr[0]), tonumber(textShadowColorArr[1]), tonumber(textShadowColorArr[2]) }
    t.textPos       = textPosPtr[0]
    t.textBold      = textBoldPtr[0]
    t.textItalic    = textItalicPtr[0]
    t.textSpacing   = textSpacingPtr[0]
    t.textFont      = textFontPtr[0]
    t.windowOpen    = windowOpen[0]
    t.hideUI        = hideUIPtr[0]
    t.noticeSeen    = noticeSeen
end

local function buildSettings()
    local t = {
            enabled     = enabledPtr[0],
            blackout    = blackoutPtr[0],
            duration    = durationPtr[0],
            fadeIn      = fadeInPtr[0],
            fadeOut     = fadeOutPtr[0],
            threshold   = thresholdPtr[0],
            minSpeed    = minSpeedPtr[0],
            flip        = PASSOUT.on[0],
            flipTime    = PASSOUT.time[0],
            flipFadeIn  = PASSOUT.fadeIn[0],
            flipFadeOut = PASSOUT.fadeOut[0],
            flipPlaySound = PASSOUT.playSound[0],
            flipAngle   = PASSOUT.angle[0],
            injReport   = INJ.on[0],
            injFunny    = INJ.funny[0],
            injSize     = INJ.size[0],
            injTough    = INJ.tough[0],
            injFatal    = INJ.showFatal[0],
            injDeform   = INJ.deform[0],
            injShowDir  = INJ.showDir[0],
            injDelay    = INJ.delay[0],
            injPos      = INJ.pos[0],
            injColor    = { tonumber(INJ.color[0]), tonumber(INJ.color[1]), tonumber(INJ.color[2]) },
            opacity     = opacityPtr[0],
            scale       = scalePtr[0],
            scaleMin    = scaleMinPtr[0],
            scaleMinDark= scaleMinDarkPtr[0],
            scaleFull   = scaleFullPtr[0],
            soundCut    = soundCutPtr[0],
            soundBack   = soundBackPtr[0],
            soundBackAt = soundBackAtPtr[0],
            soundBackFade = soundBackFadePtr[0],
            showText    = showTextPtr[0],
            text        = ffi.string(textBuf),
            sub         = ffi.string(subBuf),
            textSize    = textSizePtr[0],
            textDelay   = textDelayPtr[0],
            color       = { tonumber(colorArr[0]), tonumber(colorArr[1]), tonumber(colorArr[2]) },
            slowmo      = SM.on[0],
            slowmoFactor= SM.factor[0],
            slowmoDur   = SM.dur[0],
            slowScale   = SM.scale[0],
            slowMinDur  = SM.minDur[0],
            slowMinFactor = SM.minFactor[0],
            slowFull    = SM.full[0],
            sound       = soundPtr[0],
            soundVol    = soundVolPtr[0],
            soundFade   = soundFadePtr[0],
            soundFadeDur= soundFadeDurPtr[0],
            soundEvent  = ffi.string(soundEventBuf),
            flipSound   = ffi.string(PASSOUT.soundBuf),
            flipSoundVol = PASSOUT.soundVol[0],
            sections    = sectionOpen,   -- which collapsible headers are expanded
    }
    saveSettings2(t)   -- vignette / damage-vignette / blur / window (split for the upvalue cap)
    return t
end

local function saveSettings()
    pcall(function() jsonWriteFile(SETTINGS_PATH, buildSettings(), true) end)
end

-- Snapshot the defaults NOW -- pointers still hold their declared defaults (no settings
-- file has been loaded yet), so "Reset all to defaults" is always exactly correct with
-- no duplicated literals to drift. We DON'T reset the window layout, section state, or
-- the first-run notice (those are UI prefs, not effect settings).
local DEFAULT_SETTINGS = {}
pcall(function() DEFAULT_SETTINGS = buildSettings() end)
DEFAULT_SETTINGS.windowOpen = nil
DEFAULT_SETTINGS.sections   = nil
DEFAULT_SETTINGS.noticeSeen = nil
DEFAULT_SETTINGS.presets    = nil    -- Reset-to-defaults must not wipe saved presets

-- second half of the loader, split out purely to keep each function's upvalue
-- count under Lua's hard cap of 60 (every setting pointer it touches is an upvalue).
local function loadSettings2(s)
    if s.vignette      ~= nil then vignettePtr[0]      = (s.vignette == true) end
    if s.vignetteAfter ~= nil then vignetteAfterPtr[0] = (s.vignetteAfter == true) end
    if s.vigFadeIn     ~= nil then vigFadeInPtr[0]     = (s.vigFadeIn == true) end
    if s.vigFadeInDur  ~= nil then vigFadeInDurPtr[0]  = math.max(0.0, math.min(5.0, tonumber(s.vigFadeInDur) or 0.5)) end
    if s.vigFadeOut    ~= nil then vigFadeOutPtr[0]    = (s.vigFadeOut == true) end
    if s.vigFadeOutDur ~= nil then vigFadeOutDurPtr[0] = math.max(0.0, math.min(5.0, tonumber(s.vigFadeOutDur) or 0.5)) end
    if type(s.tint) == "table" and #s.tint >= 3 then
        for i = 0, 2 do
            local v = tonumber(s.tint[i + 1]) or 0
            tintArr[i] = im.Float(math.max(0.0, math.min(1.0, v)))
        end
    end
    if s.dmgVig     ~= nil then DVIG.on[0]     = (s.dmgVig == true) end
    if s.dmgVigMax  ~= nil then DVIG.max[0]  = math.max(0.1, math.min(1.0, tonumber(s.dmgVigMax) or 0.7)) end
    if s.dmgVigCover~= nil then DVIG.cover[0]= math.max(0.0, math.min(1.0, tonumber(s.dmgVigCover) or 0.7)) end
    if s.dmgVigSoft ~= nil then DVIG.soft[0] = math.max(0.0, math.min(1.0, tonumber(s.dmgVigSoft) or 0.6)) end
    if s.dmgVigFull ~= nil then DVIG.full[0] = math.max(1000.0, math.min(300000.0, tonumber(s.dmgVigFull) or 40000)) end
    if s.dmgVigFade ~= nil then DVIG.fade[0] = math.max(0.2, math.min(5.0, tonumber(s.dmgVigFade) or 1.5)) end
    if type(s.dmgVigColor) == "table" and #s.dmgVigColor >= 3 then
        for i = 0, 2 do
            local v = tonumber(s.dmgVigColor[i + 1]) or 0
            DVIG.color[i] = im.Float(math.max(0.0, math.min(1.0, v)))
        end
    end
    if s.blur     ~= nil then BLUR.on[0]     = (s.blur == true) end
    if s.blurAmt  ~= nil then BLUR.amt[0]  = math.max(0.05, math.min(1.0, tonumber(s.blurAmt) or 0.8)) end
    if s.blurDur  ~= nil then BLUR.dur[0]  = math.max(0.1, math.min(8.0, tonumber(s.blurDur) or 1.2)) end
    if s.blurTrig ~= nil then BLUR.trig[0] = math.max(1000.0, math.min(300000.0, tonumber(s.blurTrig) or 30000)) end
    if s.blurFadeIn     ~= nil then BLUR.fadeIn[0]     = (s.blurFadeIn == true) end
    if s.blurFadeInDur  ~= nil then BLUR.fadeInDur[0]  = math.max(0.0, math.min(5.0, tonumber(s.blurFadeInDur) or 0.4)) end
    if s.blurFadeOut    ~= nil then BLUR.fadeOut[0]    = (s.blurFadeOut == true) end
    if s.blurFadeOutDur ~= nil then BLUR.fadeOutDur[0] = math.max(0.0, math.min(5.0, tonumber(s.blurFadeOutDur) or 0.6)) end
    if s.recoveryBlur    ~= nil then recoveryBlurPtr[0]    = (s.recoveryBlur == true) end
    if s.recoveryBlurAmt ~= nil then recoveryBlurAmtPtr[0] = math.max(0.05, math.min(1.0, tonumber(s.recoveryBlurAmt) or 0.8)) end
    if s.recoveryBlurDur ~= nil then recoveryBlurDurPtr[0] = math.max(0.1, math.min(8.0, tonumber(s.recoveryBlurDur) or 1.5)) end
    if type(s.subColor) == "table" and #s.subColor >= 3 then
        for i = 0, 2 do subColorArr[i] = im.Float(math.max(0.0, math.min(1.0, tonumber(s.subColor[i + 1]) or 0))) end
    end
    if s.subSize    ~= nil then subSizePtr[0]    = math.max(10.0, math.min(200.0, tonumber(s.subSize) or 36)) end
    if s.textShadow ~= nil then textShadowPtr[0] = (s.textShadow == true) end
    if s.textShadowStr ~= nil then textShadowStrPtr[0] = math.max(0.0, math.min(1.0, tonumber(s.textShadowStr) or 0.05)) end
    if type(s.textShadowColor) == "table" and #s.textShadowColor >= 3 then
        for i = 0, 2 do textShadowColorArr[i] = im.Float(math.max(0.0, math.min(1.0, tonumber(s.textShadowColor[i + 1]) or 0))) end
    end
    if s.textPos    ~= nil then textPosPtr[0]    = math.max(0, math.min(2, math.floor(tonumber(s.textPos) or 1))) end
    if s.textBold   ~= nil then textBoldPtr[0]   = (s.textBold == true) end
    if s.textItalic ~= nil then textItalicPtr[0] = (s.textItalic == true) end
    if s.textSpacing ~= nil then textSpacingPtr[0] = math.max(0.0, math.min(40.0, tonumber(s.textSpacing) or 8)) end
    if s.textFont   ~= nil then textFontPtr[0]   = math.max(0, math.min(#FONTS - 1, math.floor(tonumber(s.textFont) or 0))) end
    if s.windowOpen ~= nil then windowOpen[0]  = (s.windowOpen == true) end
    if s.hideUI     ~= nil then hideUIPtr[0]   = (s.hideUI == true) end
    if s.noticeSeen ~= nil then noticeSeen     = (s.noticeSeen == true) end
    -- one-time migration: presets used to live in settings.json; move each to its own file
    -- in Presets/, then re-save settings.json (buildSettings no longer includes them, so the
    -- old `presets` key is dropped). Guarded on fileExists so it never clobbers a newer file.
    if type(s.presets) == "table" and next(s.presets) then
        ensurePresetDir()
        for name, data in pairs(s.presets) do
            if type(name) == "string" and type(data) == "table" then
                pcall(function() if not (FS and FS:fileExists(presetPath(name))) then jsonWriteFile(presetPath(name), data, true) end end)
            end
        end
        pcall(function() jsonWriteFile(SETTINGS_PATH, buildSettings(), true) end)
    end
end

-- Loads settings from `sIn` if given (used by Reset-to-defaults), else from disk.
local function loadSettings(sIn)
    pcall(function()
        local s = sIn or jsonReadFile(SETTINGS_PATH)
        if type(s) ~= "table" then return end
        if s.enabled   ~= nil then enabledPtr[0]   = (s.enabled == true) end
        if s.blackout  ~= nil then blackoutPtr[0]  = (s.blackout == true) end
        if s.duration  ~= nil then durationPtr[0]  = math.max(0.5, math.min(15.0, tonumber(s.duration) or 4.0)) end
        if s.fadeIn    ~= nil then fadeInPtr[0]    = math.max(0.0, math.min(3.0,  tonumber(s.fadeIn)  or 0.12)) end
        if s.fadeOut   ~= nil then fadeOutPtr[0]   = math.max(0.0, math.min(5.0,  tonumber(s.fadeOut) or 0.9)) end
        if s.threshold ~= nil then thresholdPtr[0] = math.max(500.0, math.min(500000.0, tonumber(s.threshold) or 90000)) end
        if s.minSpeed  ~= nil then minSpeedPtr[0]  = math.max(0.0, math.min(150.0, tonumber(s.minSpeed) or 5.0)) end
        if s.flip      ~= nil then PASSOUT.on[0]      = (s.flip == true) end
        if s.flipTime  ~= nil then PASSOUT.time[0]  = math.max(1.0, math.min(30.0, tonumber(s.flipTime) or 13.5)) end
        if s.flipFadeIn  ~= nil then PASSOUT.fadeIn[0]  = math.max(0.0, math.min(5.0, tonumber(s.flipFadeIn)  or 1.5)) end
        if s.flipFadeOut ~= nil then PASSOUT.fadeOut[0] = math.max(0.0, math.min(5.0, tonumber(s.flipFadeOut) or 1.2)) end
        if s.flipPlaySound ~= nil then PASSOUT.playSound[0] = (s.flipPlaySound == true) end
        if s.flipAngle    ~= nil then PASSOUT.angle[0]     = math.max(90.0, math.min(170.0, tonumber(s.flipAngle) or 120.0)) end
        if s.injReport    ~= nil then INJ.on[0]    = (s.injReport == true) end
        if s.injFunny     ~= nil then INJ.funny[0] = (s.injFunny == true) end
        if s.injSize      ~= nil then INJ.size[0]  = math.max(10.0, math.min(60.0, tonumber(s.injSize) or 26.0)) end
        if s.injTough     ~= nil then INJ.tough[0] = math.max(0.5, math.min(2.0, tonumber(s.injTough) or 1.0)) end
        if s.injFatal     ~= nil then INJ.showFatal[0] = (s.injFatal == true) end
        if s.injDeform    ~= nil then INJ.deform[0] = (s.injDeform == true) end
        if s.injShowDir   ~= nil then INJ.showDir[0] = (s.injShowDir == true) end
        if s.injDelay     ~= nil then INJ.delay[0] = math.max(0.3, math.min(6.0, tonumber(s.injDelay) or 0.7)) end
        if s.injPos       ~= nil then INJ.pos[0]   = math.max(0, math.min(3, math.floor(tonumber(s.injPos) or 0))) end
        if type(s.injColor) == "table" and #s.injColor >= 3 then
            for i = 0, 2 do INJ.color[i] = im.Float(math.max(0.0, math.min(1.0, tonumber(s.injColor[i + 1]) or 0))) end
        end
        if s.opacity   ~= nil then opacityPtr[0]   = math.max(0.3, math.min(1.0,  tonumber(s.opacity)  or 1.0)) end
        if s.scale       ~= nil then scalePtr[0]        = (s.scale == true) end
        if s.scaleMin    ~= nil then scaleMinPtr[0]     = math.max(0.1, math.min(15.0, tonumber(s.scaleMin) or 1.5)) end
        if s.scaleMinDark~= nil then scaleMinDarkPtr[0] = math.max(0.1, math.min(1.0, tonumber(s.scaleMinDark) or 0.5)) end
        if s.scaleFull   ~= nil then scaleFullPtr[0]    = math.max(1000.0, math.min(500000.0, tonumber(s.scaleFull) or 200000)) end
        if s.soundCut  ~= nil then soundCutPtr[0]  = (s.soundCut == true) end
        if s.soundBack ~= nil then soundBackPtr[0] = (s.soundBack == true) end
        if s.soundBackAt ~= nil then soundBackAtPtr[0] = math.max(0.1, math.min(8.0, tonumber(s.soundBackAt) or 1.5)) end
        if s.soundBackFade ~= nil then soundBackFadePtr[0] = math.max(0.0, math.min(5.0, tonumber(s.soundBackFade) or 0.8)) end
        if s.showText  ~= nil then showTextPtr[0]  = (s.showText == true) end
        if s.text      ~= nil then setBuf(textBuf, TEXT_CAP, s.text) end
        if s.sub       ~= nil then setBuf(subBuf,  SUB_CAP,  s.sub)  end
        if s.textSize  ~= nil then textSizePtr[0]  = math.max(20.0, math.min(240.0, tonumber(s.textSize) or 88)) end
        if s.textDelay ~= nil then textDelayPtr[0] = math.max(0.0, math.min(3.0, tonumber(s.textDelay) or 0.26)) end
        if type(s.color) == "table" and #s.color >= 3 then
            for i = 0, 2 do
                local v = tonumber(s.color[i + 1]) or 0
                colorArr[i] = im.Float(math.max(0.0, math.min(1.0, v)))
            end
        end
        if s.slowmo       ~= nil then SM.on[0]        = (s.slowmo == true) end
        if s.slowmoFactor ~= nil then SM.factor[0]    = math.max(0.05, math.min(1.0, tonumber(s.slowmoFactor) or 0.3)) end
        if s.slowmoDur    ~= nil then SM.dur[0]       = math.max(0.0, math.min(10.0, tonumber(s.slowmoDur) or 2.0)) end
        if s.slowScale    ~= nil then SM.scale[0]     = (s.slowScale == true) end
        if s.slowMinDur   ~= nil then SM.minDur[0]    = math.max(0.0, math.min(10.0, tonumber(s.slowMinDur) or 0.5)) end
        if s.slowMinFactor~= nil then SM.minFactor[0] = math.max(0.05, math.min(1.0, tonumber(s.slowMinFactor) or 0.6)) end
        if s.slowFull     ~= nil then SM.full[0]      = math.max(1000.0, math.min(500000.0, tonumber(s.slowFull) or 200000)) end
        if s.sound        ~= nil then soundPtr[0]        = (s.sound == true) end
        if s.soundVol     ~= nil then soundVolPtr[0]     = math.max(0.0, math.min(3.0, tonumber(s.soundVol) or 1.0)) end
        if s.soundFade    ~= nil then soundFadePtr[0]    = (s.soundFade == true) end
        if s.soundFadeDur ~= nil then soundFadeDurPtr[0] = math.max(0.1, math.min(10.0, tonumber(s.soundFadeDur) or 1.0)) end
        if s.soundEvent   ~= nil then setBuf(soundEventBuf, EVENT_CAP, s.soundEvent) end
        if s.flipSound    ~= nil then setBuf(PASSOUT.soundBuf, EVENT_CAP, s.flipSound) end
        if s.flipSoundVol ~= nil then PASSOUT.soundVol[0] = math.max(0.0, math.min(3.0, tonumber(s.flipSoundVol) or 1.0)) end
        if type(s.sections) == "table" then
            for k, v in pairs(s.sections) do
                if type(k) == "string" then sectionOpen[k] = (v == true) end
            end
        end
        loadSettings2(s)   -- vignette / damage-vignette / blur / window (split for the upvalue cap)
    end)
end

-- Reset every effect/tuning setting to its default (routes the defaults snapshot back
-- through the same clamping load logic), then persist. Leaves window/section/notice as-is.
local function resetAllDefaults()
    loadSettings(DEFAULT_SETTINGS)
    saveSettings()
end

-- Presets: snapshot the current EFFECT settings (no window/section/notice/presets keys)
-- under a name, then load/switch between them.
local function capturePreset()
    local t = buildSettings()
    t.presets = nil; t.windowOpen = nil; t.sections = nil; t.noticeSeen = nil
    return t
end
local function savePreset(name)
    name = name and tostring(name):match("^%s*(.-)%s*$") or ""
    if name == "" then return end
    ensurePresetDir()
    pcall(function() jsonWriteFile(presetPath(name), capturePreset(), true) end)
    refreshPresets()
end
local function loadPreset(name)
    local p = presets[name]
    if type(p) ~= "table" then return end
    loadSettings(p)     -- applies the preset's effect settings; leaves window/etc. alone
    saveSettings()
end
local function deletePreset(name)
    pcall(function() if FS then FS:removeFile(presetPath(name)) end end)
    refreshPresets()
end

--------------------------------------------------------------------------------
-- BLACKOUT + TOAST OVERLAY  (injected once, then driven by JS calls)
--------------------------------------------------------------------------------
local uiInstalled = false

local OVERLAY_JS = [==[
(function(){
  if(window.__DeathScreen) return;
  var ds = window.__DeathScreen = {};
  var overlay=null, vig=null, txt=null, sub=null, inj=null, dmgVig=null, timers=[], toastEl=null, toastT=null, warmEl=null;
  function clearTimers(){ for(var i=0;i<timers.length;i++){clearTimeout(timers[i]);} timers=[]; }
  function hexRgba(h,a){ h=(''+h).replace('#',''); if(h.length===3){h=h[0]+h[0]+h[1]+h[1]+h[2]+h[2];} var n=parseInt(h,16)||0; return 'rgba('+((n>>16)&255)+','+((n>>8)&255)+','+(n&255)+','+a+')'; }
  function ensure(){
    /* damage vignette lives BELOW the blackout overlay and independent of it */
    if(!dmgVig || !document.body.contains(dmgVig)){
      dmgVig=document.createElement('div'); dmgVig.id='dsDmgVig';
      dmgVig.style.cssText='position:fixed;left:0;top:0;width:100vw;height:100vh;'
        +'pointer-events:none;opacity:0;z-index:2147483590;transition:opacity .1s linear;';
      document.body.appendChild(dmgVig);
    }
    if(overlay && document.body.contains(overlay)) return;
    overlay=document.createElement('div');
    overlay.id='dsOverlay';
    overlay.style.cssText='position:fixed;left:0;top:0;width:100vw;height:100vh;'
      +'background:#000;opacity:0;z-index:2147483600;pointer-events:none;'
      +'display:flex;flex-direction:column;align-items:center;justify-content:center;'
      +"font-family:'Segoe UI',Roboto,Arial,sans-serif;transition:opacity .12s linear;";
    /* separate vignette layer on top of the black, so it can fade in on its own beat */
    vig=document.createElement('div'); vig.id='dsVig';
    vig.style.cssText='position:absolute;left:0;top:0;right:0;bottom:0;'
      +'opacity:0;pointer-events:none;transition:opacity .5s ease;';
    txt=document.createElement('div'); txt.id='dsText';
    txt.style.cssText='color:#c9302c;font-size:88px;font-weight:800;letter-spacing:8px;'
      +'text-shadow:0 6px 30px rgba(0,0,0,.9);opacity:0;transition:opacity .45s ease;text-align:center;position:relative;';
    sub=document.createElement('div'); sub.id='dsSub';
    sub.style.cssText='color:#dfe3e6;font-size:24px;font-weight:600;margin-top:12px;'
      +'opacity:0;transition:opacity .45s ease;text-align:center;position:relative;';
    inj=document.createElement('div'); inj.id='dsInj';
    /* Anchored at the bottom and OUT of the message's flex flow (position:absolute), so the
       centered message NEVER shifts when the (async) injury report fades in a beat later.
       Subtle dark card keeps it readable when it floats over live gameplay (no blackout). */
    inj.style.cssText='position:absolute;left:50%;bottom:7vh;transform:translateX(-50%);max-width:90vw;'
      +'color:#e8b4b4;font-size:26px;font-weight:600;line-height:1.55;text-align:center;'
      +'opacity:0;transition:opacity .5s ease;'
      +'background:rgba(8,0,0,.55);padding:14px 30px;border-radius:12px;'
      +'border:1px solid rgba(255,110,110,.14);box-shadow:0 8px 40px rgba(0,0,0,.5);';
    overlay.appendChild(vig); overlay.appendChild(txt); overlay.appendChild(sub); overlay.appendChild(inj);
    document.body.appendChild(overlay);
    /* Force every custom message font to fully LOAD AND LAY OUT by rendering hidden
       sample text in each one, kept permanently offscreen. This is more reliable than
       document.fonts.load (whose promise can resolve before the font is usable for
       layout), so the visible message never renders in a fallback and then swaps/resizes. */
    try{
      if(!warmEl){
        warmEl=document.createElement('div'); warmEl.id='dsWarm';
        warmEl.style.cssText='position:fixed;left:-99999px;top:0;opacity:0;pointer-events:none;white-space:nowrap;';
        ['Digital','Squada One','Play','Roboto Condensed','News Cycle','Overpass','Impact','Arial Black'].forEach(function(f){
          var s=document.createElement('span');
          s.style.cssText="font-family:'"+f+"';font-size:120px;font-weight:800;font-style:italic;";
          s.textContent='WASTEDwasted 0123';
          warmEl.appendChild(s);
        });
        document.body.appendChild(warmEl);
      }
    }catch(e){}
  }
  ds.show=function(o){
    o=o||{}; ensure(); clearTimers();
    /* ==null (not ||) so an explicit 0 stays 0 -- 0||120 would be 120, breaking an instant blackout */
    var fadeIn=(o.fadeInMs==null?120:o.fadeInMs), hold=(o.holdMs==null?4000:o.holdMs), fadeOut=(o.fadeOutMs==null?900:o.fadeOutMs);
    var bg=(o.bg==null?1:o.bg);
    overlay.style.background='rgba(0,0,0,'+bg+')';
    overlay.style.transition='opacity '+(fadeIn/1000)+'s linear';
    /* vignette layer: tinted edges over the black; fades in on its own delay */
    if(o.vignette){
      vig.style.background='radial-gradient(ellipse at center, rgba(0,0,0,0) 38%, '+hexRgba(o.tint||'#5a0000',bg)+' 128%)';
      vig.style.transition='none'; vig.style.opacity='0';
    } else {
      vig.style.transition='none'; vig.style.opacity='0'; vig.style.background='';
    }
    /* prime the message hidden + slightly enlarged; revealed AFTER the screen is black */
    txt.textContent=o.text||''; sub.textContent=o.sub||'';
    txt.style.color=o.textColor||'#c1121f';
    if(o.textSize){ txt.style.fontSize=o.textSize+'px'; }
    if(o.font){ overlay.style.fontFamily=o.font; }   /* txt + sub inherit it (fonts are pre-warmed on level load) */
    sub.style.color=o.subColor||'#dfe3e6';
    if(o.subSize){ sub.style.fontSize=o.subSize+'px'; }
    /* font: title carries the weight + letter spacing, both share italic */
    var w=(o.bold===false)?'400':'800', st=o.italic?'italic':'normal';
    txt.style.fontWeight=w; txt.style.fontStyle=st;
    txt.style.letterSpacing=(o.spacing==null?8:o.spacing)+'px'; sub.style.fontStyle=st;
    /* shadow / glow (symmetric halo, doubles as a readability shadow) */
    var sh='none';
    if(o.shadow){ var sc=hexRgba(o.shadowColor||'#000000',0.92), b=Math.round(6+(o.shadowStr==null?0.6:o.shadowStr)*46); sh='0 0 '+b+'px '+sc+', 0 0 '+Math.round(b*0.5)+'px '+sc; }
    txt.style.textShadow=sh; sub.style.textShadow=sh;
    /* vertical position: 0 top, 1 centre, 2 bottom */
    var p=(o.pos==null?1:o.pos);
    overlay.style.justifyContent=(p===0?'flex-start':(p===2?'flex-end':'center'));
    overlay.style.paddingTop=(p===0?'12vh':'0'); overlay.style.paddingBottom=(p===2?'12vh':'0');
    txt.style.transition='none'; sub.style.transition='none';
    txt.style.opacity='0'; sub.style.opacity='0';
    txt.style.transform='none'; sub.style.transform='none';   /* no scale/slide = no resize/move; clean fade only */
    /* injury report is populated ASYNC (after the deform query) via ds.showInjuries; prime hidden.
       With a message: anchor it at the bottom (out of the message's way, so it can't shift it).
       Without a message: it's the only thing on screen, so centre it. */
    inj.style.transition='none'; inj.style.opacity='0'; inj.innerHTML='';
    /* injury report position: 0 auto, 1 top, 2 centre, 3 bottom.
       AUTO = put it wherever the MESSAGE isn't, resolved to a concrete spot below.
       No message -> centre it (it's the only thing on screen). Message at the bottom
       -> go to the TOP: the old rule always used bottom:7vh, which sits directly under
       a bottom-anchored message (12vh) and grows upward into it = guaranteed overlap.
       Message at top/centre -> the bottom is clear. Never MOVES the message (the report
       is position:absolute, out of the flex flow) so it can't shift it like it used to. */
    var ip=(o.injPos==null?0:o.injPos);
    if(ip===0){
      if(!(o.text||o.sub)) ip=2;
      else ip=((o.pos==null?1:o.pos)===2)?1:3;
    }
    if(ip===1){ inj.style.top='9vh'; inj.style.bottom=''; inj.style.transform='translateX(-50%)'; }
    else if(ip===2){ inj.style.top='50%'; inj.style.bottom=''; inj.style.transform='translate(-50%,-50%)'; }
    else { inj.style.top=''; inj.style.bottom='7vh'; inj.style.transform='translateX(-50%)'; }
    void overlay.offsetWidth;              /* force reflow so the fade-in + resets apply */
    overlay.style.opacity='1';
    if(o.vignette){
      var vdelay=(o.vignetteAfterMs==null?0:o.vignetteAfterMs);  /* 0 = with the black */
      var vfin=Math.min((o.vigFadeInMs==null?0:o.vigFadeInMs), hold)/1000;  /* 0 = snap on */
      timers.push(setTimeout(function(){ vig.style.transition='opacity '+vfin+'s ease'; vig.style.opacity='1'; }, vdelay));
      /* Fade the vignette out so it FINISHES exactly as the black hold ends -- it's
         a child of the black overlay, so it must fade while the overlay is still
         solid or the overlay's own fade would hide it. Length is capped to the
         visible window (i.e. the blackout length). 0 = snap off at the end. */
      var visStart=vdelay+(o.vigFadeInMs||0), visEnd=fadeIn+hold;
      var vfoutMs=Math.min((o.vigFadeOutMs==null?0:o.vigFadeOutMs), Math.max(0, visEnd-visStart));
      /* a held passout keeps the vignette up until ds.release(); only auto-fade it for a timed blackout */
      if(!o.hold){ timers.push(setTimeout(function(){ vig.style.transition='opacity '+(vfoutMs/1000)+'s ease'; vig.style.opacity='0'; }, visEnd-vfoutMs)); }
    }
    if(o.text||o.sub){
      var delay=fadeIn+(o.textDelayMs==null?260:o.textDelayMs);  /* GTA-style beat after black */
      timers.push(setTimeout(function(){
        txt.style.transition='opacity .45s ease';   /* opacity only -- text stays at its final size/position */
        sub.style.transition='opacity .5s ease .12s';
        if(o.text){ txt.style.opacity='1'; }
        if(o.sub){ sub.style.opacity='.9'; }
      }, delay));
    }
    /* o.hold = keep the black up indefinitely (passed-out upside down); ds.release()
       ends it. Otherwise schedule the normal auto fade-out. */
    if(!o.hold){
      timers.push(setTimeout(function(){
        overlay.style.transition='opacity '+(fadeOut/1000)+'s ease';
        overlay.style.opacity='0';   /* vignette already handled its own fade-out above */
        txt.style.opacity='0'; sub.style.opacity='0'; inj.style.opacity='0';
      }, fadeIn+hold));
    }
  };
  /* injuries arrive AFTER the deform query (async), so they get their own reveal call */
  ds.showInjuries=function(injuries, injSize, injColor, revealMs){
    if(!inj || !injuries || !injuries.length) return;
    inj.style.fontSize=(injSize||26)+'px';
    inj.style.color=injColor||'#e8b4b4';
    var ih='<div style="font-size:.62em;letter-spacing:4px;opacity:.7;font-weight:700;margin-bottom:8px">INJURY REPORT</div>';
    for(var i=0;i<injuries.length;i++){ ih+='<div>'+injuries[i]+'</div>'; }
    inj.innerHTML=ih;
    inj.style.transition='none'; inj.style.opacity='0';
    void inj.offsetWidth;
    /* Collision nudge. Measured HERE because this is the first moment the report's real
       height is known (content is in, layout is settled, opacity 0 doesn't affect layout).
       If the report would land on the message, slide it clear -- down if there's room,
       otherwise up. Only the REPORT moves: it's position:absolute and out of the flex
       flow, so the message can never be shifted by this (that was the 1.0.2 bug).
       Runs for every placement, not just the fixed ones, so even Auto stays clear when a
       huge message font makes the text taller than its lane. try/catch = worst case we
       simply keep the placement we already had. */
    try{
      var mTop=null, mBot=null;
      [txt,sub].forEach(function(el){
        if(!el || !el.textContent) return;
        var r=el.getBoundingClientRect();
        if(!r.height) return;
        mTop=(mTop===null)?r.top:Math.min(mTop,r.top);
        mBot=(mBot===null)?r.bottom:Math.max(mBot,r.bottom);
      });
      if(mTop!==null){
        var ir=inj.getBoundingClientRect(), gap=28, vh=window.innerHeight;
        if(ir.top < mBot+gap && ir.bottom+gap > mTop){          /* they collide */
          var below=mBot+gap;
          var y=(below+ir.height<=vh-16) ? below                /* prefer just under it */
                                         : Math.max(16, mTop-gap-ir.height);  /* else above */
          inj.style.top=y+'px'; inj.style.bottom=''; inj.style.transform='translateX(-50%)';
        }
      }
    }catch(e){}
    timers.push(setTimeout(function(){ inj.style.transition='opacity .5s ease'; inj.style.opacity='.92'; }, (revealMs==null?200:revealMs)));
  };
  /* release a held blackout: fade everything back out over fadeOutMs */
  ds.release=function(fadeOutMs){
    clearTimers();
    var fo=(fadeOutMs==null?900:fadeOutMs)/1000;
    if(overlay){ overlay.style.transition='opacity '+fo+'s ease'; overlay.style.opacity='0'; }
    if(vig){ vig.style.transition='opacity '+fo+'s ease'; vig.style.opacity='0'; }
    if(txt)txt.style.opacity='0'; if(sub)sub.style.opacity='0';
  };
  ds.hide=function(){ clearTimers(); if(overlay){ overlay.style.opacity='0';
    if(vig)vig.style.opacity='0'; if(txt)txt.style.opacity='0'; if(sub)sub.style.opacity='0'; } };
  /* Damage vignette animates entirely in the browser at 60fps so it never steps
     in chunks. Both the opacity and the reach (radius) ease in and out; because
     the radius grows from the edge inward and recedes back out, the OUTER edges
     start darkening first and finish clearing last -- the look Kyle described. */
  var D={op:0,opT:0,cov:0,covT:0,color:'#c00',fade:1500,cap:1,coverMax:0,soft:0.5,raf:0,last:0};
  function nowMs(){ return (window.performance&&performance.now)?performance.now():Date.now(); }
  function dmgRender(){
    var op=D.op<0?0:(D.op>1?1:D.op), cov=D.cov<0?0:(D.cov>1?1:D.cov);
    if(op<=0.003){ if(dmgVig) dmgVig.style.opacity='0'; return; }
    /* Smoothstep multi-stop ramp. The alpha eases from 0 at the inner edge up to
       full with ZERO slope at BOTH ends (smoothstep f*f*(3-2f)), so neither the
       onset nor the point where it reaches full is a visible line (a plain linear
       ramp leaves a Mach-band edge you can pick out -- RainlessSky's complaint).
       Softness pushes the "reaches full" radius outward: at soft=1 it only hits
       full red in the very corner, so there is NO solid plateau to see an edge on;
       at soft=0 the band collapses to a hard ring (kept as a deliberate option).
       clearEdge (from coverage) is where the tint begins. */
    var soft=(D.soft==null?0.5:D.soft);
    var clearEdge=(1-cov)*100;
    var t1=clearEdge+soft*(100-clearEdge);
    var span=t1-clearEdge, N=8;
    var parts=[hexRgba(D.color,0)+' '+clearEdge.toFixed(1)+'%'];
    for(var i=1;i<=N;i++){
      var f=i/N, a=f*f*(3-2*f);
      parts.push(hexRgba(D.color,a.toFixed(3))+' '+(clearEdge+f*span).toFixed(1)+'%');
    }
    if(t1<99.5){ parts.push(hexRgba(D.color,1)+' 100%'); }
    dmgVig.style.background='radial-gradient(ellipse at center, '+parts.join(', ')+')';
    dmgVig.style.opacity=''+op;
  }
  function dmgTick(t){
    t=t||nowMs();
    var dt=D.last?Math.min(0.05,(t-D.last)/1000):0.016; D.last=t;
    var fadeSec=Math.max(0.05, D.fade/1000);
    D.opT=Math.max(0, D.opT - dt/fadeSec);                 /* strength fades toward 0 */
    D.covT=(D.cap>0)?(D.coverMax*(D.opT/D.cap)):0;          /* reach tracks strength -> recedes, outer clears last */
    var k=1-Math.exp(-dt/0.06);                             /* ~60ms smoothing kills the chunks */
    D.op+=(D.opT-D.op)*k; D.cov+=(D.covT-D.cov)*k;
    dmgRender();
    if(D.op>0.003 || D.opT>0){ D.raf=requestAnimationFrame(dmgTick); }
    else { D.raf=0; D.op=0; D.cov=0; if(dmgVig) dmgVig.style.opacity='0'; }
  }
  /* Each hit ADDS to the strength (up to cap) and refreshes the fade, so hitting
     again mid-effect stacks/re-brightens instead of waiting for it to finish. */
  ds.damage=function(boost,coverMax,color,fadeMs,cap,soft){
    ensure();
    D.cap=cap||1; D.coverMax=coverMax||0; D.soft=(soft==null?D.soft:soft);
    if(boost>0){ D.opT=Math.min(D.cap, D.opT+boost); D.color=color||D.color; D.fade=fadeMs||1500; }
    if(!D.raf){ D.last=0; D.raf=requestAnimationFrame(dmgTick); }
  };
  ds.clearDamage=function(){ D.op=0;D.opT=0;D.cov=0;D.covT=0; if(dmgVig) dmgVig.style.opacity='0'; };
  ds.toast=function(msg,color,ms){
    if(!toastEl){
      toastEl=document.createElement('div'); toastEl.id='dsToast';
      toastEl.style.cssText='position:fixed;bottom:9%;left:50%;transform:translateX(-50%);'
        +'z-index:2147483601;pointer-events:none;padding:10px 20px;border-radius:10px;'
        +'background:rgba(12,13,16,.93);color:#eef;font-family:Segoe UI,Roboto,sans-serif;'
        +'font-size:16px;font-weight:600;opacity:0;transition:opacity .25s;'
        +'box-shadow:0 6px 22px rgba(0,0,0,.5);border-left:4px solid #c9302c';
      document.body.appendChild(toastEl);
    }
    toastEl.style.borderLeftColor=color||'#c9302c';
    toastEl.textContent=msg; toastEl.style.opacity='1';
    if(toastT)clearTimeout(toastT);
    toastT=setTimeout(function(){toastEl.style.opacity='0';},(ms||1600));
  };
  /* full cleanup when the mod is disabled/unloaded: stop the animation loop, remove
     every element we added, and drop the global so a re-enable re-injects cleanly */
  ds.teardown=function(){
    clearTimers();
    if(D.raf){ cancelAnimationFrame(D.raf); D.raf=0; }
    if(toastT){ clearTimeout(toastT); toastT=0; }
    [overlay,dmgVig,toastEl,warmEl].forEach(function(el){ if(el&&el.parentNode){ el.parentNode.removeChild(el); } });
    overlay=vig=txt=sub=inj=dmgVig=toastEl=warmEl=null;
    try{ delete window.__DeathScreen; }catch(e){ window.__DeathScreen=null; }
  };
})();
]==]

local function installUI()
    if uiInstalled then return end
    pcall(function()
        if be and be.executeJS then
            be:executeJS(OVERLAY_JS)
            uiInstalled = true
        end
    end)
end

-- Escape a Lua string into a JS single-quoted literal.
local function jsStr(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\r", ""):gsub("\n", "\\n")
    return "'" .. s .. "'"
end

-- An im.ArrayFloat(3) RGB as a "#rrggbb" string for the overlay.
local function hexOf(arr)
    local function to255(v)
        v = tonumber(v) or 0
        if v < 0 then v = 0 elseif v > 1 then v = 1 end
        return math.floor(v * 255 + 0.5)
    end
    return string.format("#%02x%02x%02x", to255(arr[0]), to255(arr[1]), to255(arr[2]))
end

local function showToast(msg, color)
    installUI()
    if not uiInstalled then return end
    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.toast(" .. jsStr(msg) .. "," .. jsStr(color or "#c9302c") .. ");")
    end)
end

--------------------------------------------------------------------------------
-- TRIGGERING
--------------------------------------------------------------------------------
local isShowing   = false
local heldActive  = false -- a passout blackout that HOLDS until righted/reset (no auto-fade)
local activeTimer = 0     -- real-time seconds left before we allow another trigger
local lastReason  = ""    -- for the debug line in the settings window
local uiHiddenByTrigger = false  -- did WE auto-close the window for this blackout?

-- damage-window detection state
local lastVid     = -1
local lastDamage  = 0
local dmgWindow   = {}     -- { {t=, d=}, ... } within WINDOW_SEC
local recentDamage = 0     -- running sum of the window
local peakDamage  = 0      -- highest recentDamage seen since last reset (for tuning)
local uiClock     = 0      -- ever-increasing real-time clock
local cooldownTimer = 0    -- brief lock after a blackout so a tumbling wreck can't re-fire
local RETRIGGER_COOLDOWN = 2.0
-- deform-direction state in one table (keeps the file under LuaJIT's 200-locals-per-chunk cap):
-- snapT = snapshot cadence, queryT = post-crash query countdown, speed = latest km/h (gates the
-- snapshot), pend = { force, spd, fb } awaiting the async deform-direction result.
local DEF = { snapT = 0.5, queryT = 0, speed = 0, pend = nil, blackMs = 0 }

-- damage-vignette state (the swell/fade animation itself runs in the browser)
local frameDamageDelta = 0 -- new damage this frame (set by updateDetection)
local dmgAccum = 0         -- damage gathered since the last hit was fed to the UI
local dmgVigThrottle = 0   -- rate-limit for feeding hits to the browser animation
local dmgVigWasOn = false  -- so we clear the effect once when it's turned off

-- Sound cutoff: mute the gameplay audio channels during the blackout and restore
-- the player's volumes after. We mute every GAME channel but deliberately DO NOT
-- touch 'Gui'/'Ui' or 'Master' (the parent) -- our death sound is an 'AudioGui'
-- playOnce, and muting Master would kill it too, so we mute the children.
--
-- 'Other' is special: a loose custom audio FILE (the "use your own .ogg" path)
-- STREAMS through AudioChannelOther, so muting Other silences the player's own
-- death sound -- the exact "custom sounds get cut" bug. The game's own comics.lua
-- keeps Gui + Master + Other unmuted for the same reason. So we mute Other only
-- when NO loose custom file is playing (kills the post-crash hazard-blinker tick
-- etc.), and skip it when a custom file IS the death sound so it can be heard.
local MUTE_CHANNELS = {
    "AudioChannelPower", "AudioChannelForcedInduction", "AudioChannelTransmission",
    "AudioChannelSuspension", "AudioChannelSurface", "AudioChannelCollision",
    "AudioChannelAero", "AudioChannelEnvironment", "AudioChannelMusic",
    "AudioChannelOther", "AudioChannelEffects", "AudioChannelIntercom", "AudioChannelLfe",
}
local soundCutActive = false
local savedVolumes = {}
local function muteGame(soundEv)
    if soundCutActive then return end
    pcall(function()
        if Engine and Engine.Audio then
            savedVolumes = {}
            -- keep AudioChannelOther alive when the sound about to play is a loose custom
            -- FILE (not an "event:" FMOD event), since those stream through Other. The
            -- caller passes the exact sound (main death sound, or the pass-out one).
            local ev = soundEv or (soundPtr[0] and ffi.string(soundEventBuf) or "")
            local keepOther = ev ~= "" and ev:sub(1, 6) ~= "event:"
            for _, ch in ipairs(MUTE_CHANNELS) do
                if not (keepOther and ch == "AudioChannelOther") then
                    savedVolumes[ch] = Engine.Audio.getChannelVolume(ch, false)
                    Engine.Audio.setChannelVolume(ch, 0.0)
                end
            end
            soundCutActive = true
        end
    end)
end
local function unmuteGame()
    if not soundCutActive then return end
    pcall(function()
        if Engine and Engine.Audio then
            for _, ch in ipairs(MUTE_CHANNELS) do
                if savedVolumes[ch] ~= nil then
                    Engine.Audio.setChannelVolume(ch, savedVolumes[ch])
                end
            end
        end
    end)
    soundCutActive = false
end
-- set the muted channels to `scale` (0..1) of their saved volume -- used to SWELL
-- the game audio back in over time instead of snapping it on. Keeps soundCutActive
-- true (still "cut") until the fade finishes and unmuteGame() finalises it.
local function setGameVolumeScale(scale)
    if not soundCutActive then return end
    pcall(function()
        if Engine and Engine.Audio then
            for _, ch in ipairs(MUTE_CHANNELS) do
                if savedVolumes[ch] ~= nil then
                    Engine.Audio.setChannelVolume(ch, savedVolumes[ch] * scale)
                end
            end
        end
    end)
end

-- Slow-motion (bullet-time) on crash, via the game's sim-time authority.
local slowmoActive = false
local slowmoTimer = 0
local function setSimSpeed(f)
    pcall(function() if simTimeAuthority then simTimeAuthority.set(f) end end)
end
local function restoreSpeed()
    if not slowmoActive then return end
    slowmoActive = false
    setSimSpeed(1)
end
-- Slow-mo game-speed + duration, optionally scaled by crash force ("Scale with crash
-- force" under slow-mo): at the trigger threshold -> "Min slow-mo length" + "Mildest
-- game speed"; at "Full-blast force" (and above) -> the full "Slow-mo length" + "Game
-- speed". No crashForce (a manual test) or scaling off -> the full set values.
local function slowmoParams(crashForce)
    local factor = SM.factor[0]
    local dur    = SM.dur[0]
    if SM.scale[0] and crashForce then
        local thr  = thresholdPtr[0]
        local full = math.max(thr + 1, SM.full[0])
        local t = (crashForce - thr) / (full - thr)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local minDur = math.min(SM.minDur[0], SM.dur[0])
        dur = minDur + (SM.dur[0] - minDur) * t
        -- game speed is inverted (lower = deeper): the "mild" end is the HIGHER value,
        -- deepening toward the set "Game speed" as the crash gets harder.
        local mild = math.max(SM.minFactor[0], SM.factor[0])
        factor = mild + (SM.factor[0] - mild) * t
    end
    return factor, dur
end
-- Kick off bullet-time. Shared by the full death screen AND the blackout-off
-- "slow-mo only" path, so slow-mo no longer depends on the black screen.
local function triggerSlowmo(crashForce)
    if slowmoActive then return end
    local factor, dur = slowmoParams(crashForce)
    setSimSpeed(factor)
    slowmoActive = true
    slowmoTimer  = dur
end

-- Crash blur: a full-screen gaussian blur via the game's ScreenBlurFX -- the SAME
-- effect that blurs the game behind menus. Each render frame we add a full-screen
-- "blur rect". The blend shader (simpleBlendP.hlsl) lerps sharp->blurred by the
-- mask's RED channel, NOT alpha -- so intensity must go in RGB. Passing alpha only
-- (as the flowgraph node does) pins red at 1 = always full blur, which is why the
-- strength slider did nothing and it popped on instantly. Driving RGB fixes both:
-- strength scales, and ramping RGB gives a real fade. It's per-frame, so when we
-- stop adding it the blur just stops -- nothing to restore, no stuck-blur risk.
local blurActive = false
local blurLevel  = 0                    -- 0..1 animation ramp
local blurPhase  = "in"
local blurHold   = 0

-- Recovery blur state: separate from the crash blur so both can coexist. It has no
-- ramp-in -- it snaps to full the moment the black starts lifting, then eases to 0.
local recoveryBlurLevel = 0             -- 0..1, eases down as vision "returns"
local recoveryBlurArmed = false         -- set when a blackout triggers; fires once when it lifts
local function armRecoveryBlur()  recoveryBlurArmed = recoveryBlurPtr[0]; recoveryBlurLevel = 0 end
local function fireRecoveryBlur() recoveryBlurArmed = false; recoveryBlurLevel = 1 end

local function triggerBlur()
    if blurActive then return end
    blurActive = true
    blurPhase  = "in"
    blurHold   = BLUR.dur[0]
    -- snap straight to full if fade-in is off (or zero-length)
    if BLUR.fadeIn[0] and BLUR.fadeInDur[0] > 0 then
        blurLevel = 0
    else
        blurLevel = 1; blurPhase = "hold"
    end
end

local function updateBlur(dt)
    dt = dt or 0
    -- recovery blur eases from full to nothing over its own duration (runs on its own,
    -- independent of the crash blur below)
    if recoveryBlurLevel > 0 then
        recoveryBlurLevel = recoveryBlurLevel - dt / math.max(0.01, recoveryBlurDurPtr[0])
        if recoveryBlurLevel < 0 then recoveryBlurLevel = 0 end
    end
    if not blurActive then return end
    if blurPhase == "in" then
        blurLevel = blurLevel + dt / math.max(0.01, BLUR.fadeInDur[0])
        if blurLevel >= 1 then blurLevel = 1; blurPhase = "hold" end
    elseif blurPhase == "hold" then
        blurHold = blurHold - dt
        if blurHold <= 0 then
            blurPhase = "out"
            -- snap straight off if fade-out is disabled (or zero-length)
            if not (BLUR.fadeOut[0] and BLUR.fadeOutDur[0] > 0) then
                blurLevel = 0; blurActive = false
            end
        end
    else -- "out"
        blurLevel = blurLevel - dt / math.max(0.01, BLUR.fadeOutDur[0])
        if blurLevel <= 0 then blurLevel = 0; blurActive = false end
    end
end

-- applied every render frame: blur the whole screen at (ramp * strength). Both the
-- crash blur and the recovery blur feed this; we draw whichever is currently stronger.
-- Intensity goes in RGB because the blend uses the mask's .r channel (see above).
local function renderBlur()
    local crashAmt = (blurLevel > 0)        and (blurLevel * BLUR.amt[0])                 or 0
    local recAmt   = (recoveryBlurLevel > 0) and (recoveryBlurLevel * recoveryBlurAmtPtr[0]) or 0
    local amt = math.max(crashAmt, recAmt)
    if amt <= 0 then return end
    pcall(function()
        local fx = scenetree and scenetree.ScreenBlurFX
        if fx and fx.obj then
            amt = math.min(1, amt)
            fx.obj:addFrameBlurRect(0, 0, 1, 1, ColorF(amt, amt, amt, 1))
        end
    end)
end

-- The GE-played sound (custom file / UI event) returns an SFX source; we keep
-- its id so we can cut it short -- e.g. when the player resets mid-playback.
local currentSoundId = nil
local soundFadeTimer = 0    -- >0: seconds until we start the end-of-sound fade
local soundFadeAmount = 0   -- how long that fade lasts
local soundBackTimer = 0    -- >0: seconds until game audio returns while still black (senses-before-vision)
local soundBackFadeTimer = 0 -- >0: seconds left in the swell-back-in of the game audio
local soundBackFadeDur = 0   -- total length of that swell (for the progress ratio)
local function stopDeathSound()
    soundFadeTimer = 0
    if not currentSoundId then return end
    pcall(function()
        local snd = scenetree.findObjectById(currentSoundId)
        if snd then snd:stop(0.05) end   -- tiny fade to avoid a click
    end)
    currentSoundId = nil
end

-- Death sting. The "Sound event" field accepts three things:
--   1. A custom audio FILE ("/settings/DeathScreen/mysound.ogg", .ogg/.wav) ->
--      played 2D via Engine.Audio.playOnce('AudioGui', ...). This is the way to
--      use your OWN sound. It STREAMS through AudioChannelOther, so it survives
--      "Cut game sound" only because muteGame() deliberately leaves Other unmuted
--      when the death sound is a loose file (see the MUTE_CHANNELS note).
--   2. A UI FMOD event ("event:>UI>...") -> same GE path, routes through the Gui
--      channel (never muted), so it survives the cut regardless.
--   3. Any other FMOD event ("event:>Vehicle>Failures>engine_explode",
--      "event:>Destruction>...") is a spatial VEHICLE sound -> the game plays it
--      inside the vehicle's Lua via sounds.playSoundOnceFollowNode; GE playOnce
--      does nothing for these. We route it to the vehicle's reference node (0).
--      (These are game sounds, so they DO get muted by the sound cut.)
local function playDeathSound(ev, vol)
    pcall(function()
        ev = ev or ffi.string(soundEventBuf)   -- caller can pass a specific sound (e.g. the pass-out one)
        if ev == "" then return end
        vol = vol or soundVolPtr[0]            -- ...and its own volume (0 stays 0)

        local isEvent   = ev:sub(1, 6) == "event:"
        local isUIEvent = ev:find("event:>UI>", 1, true) == 1 or ev:find("event:UI", 1, true) == 1

        if isEvent and not isUIEvent then
            -- spatial vehicle / destruction event: play it on the vehicle side
            local veh = be:getPlayerVehicle(0)
            if veh then
                veh:queueLuaCommand(
                    "if sounds and sounds.playSoundOnceFollowNode then sounds.playSoundOnceFollowNode([[" ..
                    ev .. "]], 0, " .. string.format("%.3f", vol) .. ") end")
            end
        else
            -- custom file OR UI event: 2D on the UI channel (survives the cut)
            local src = ev
            if not isEvent then
                -- A bare filename (no folder) resolves into our own settings
                -- folder, so users only type "mysound.ogg".
                if not src:find("/", 1, true) then
                    src = SOUND_DIR .. src
                end
                -- be forgiving about the leading slash: try both forms
                if FS and not FS:fileExists(src) then
                    local alt = (src:sub(1, 1) == "/") and src:sub(2) or ("/" .. src)
                    if FS:fileExists(alt) then
                        src = alt
                    else
                        log('W', "DeathScreen", "Death sound file not found: " .. src ..
                            "  (drop your .ogg in the BeamNG userfolder's settings/DeathScreen/)")
                    end
                end
            end
            if Engine and Engine.Audio then
                stopDeathSound()   -- cut any still-playing sting first
                local sfx = Engine.Audio.playOnce('AudioGui', src, { volume = vol })
                currentSoundId = sfx and sfx.sourceId or nil
                -- optional fade-out: schedule a faded :stop() near the sound's
                -- natural end so it eases out instead of cutting off. sfx.len is
                -- in seconds (same field ambientSound.lua uses).
                if currentSoundId and soundFadePtr[0] then
                    local len = sfx and tonumber(sfx.len)
                    local fadeDur = soundFadeDurPtr[0]
                    if len and len > 0 and len < 3600 and len > fadeDur + 0.05 then
                        soundFadeTimer  = len - fadeDur
                        soundFadeAmount = fadeDur
                    end
                end
            end
        end
    end)
end

-- force = ignore the enabled flag (used by the Test button/keybind)
-- Builds the message (text + styling) portion of the JS opts string. Split out so its
-- ~15 text pointers don't count against triggerDeathScreen's upvalues (Lua caps at 60).
local function buildMessageOpts()
    if not showTextPtr[0] then return "" end
    local opts = ",text:" .. jsStr(ffi.string(textBuf))
        .. ",textColor:" .. jsStr(hexOf(colorArr))
        .. ",textSize:" .. math.floor(textSizePtr[0] + 0.5)
        .. ",textDelayMs:" .. math.floor(textDelayPtr[0] * 1000 + 0.5)
        .. ",subColor:" .. jsStr(hexOf(subColorArr))
        .. ",subSize:" .. math.floor(subSizePtr[0] + 0.5)
        .. ",pos:" .. textPosPtr[0]
        .. ",bold:" .. (textBoldPtr[0] and "true" or "false")
        .. ",italic:" .. (textItalicPtr[0] and "true" or "false")
        .. ",spacing:" .. math.floor(textSpacingPtr[0] + 0.5)
        .. ",font:" .. jsStr((FONTS[textFontPtr[0] + 1] or FONTS[1]).css)
    local sub = ffi.string(subBuf)
    if sub ~= "" then opts = opts .. ",sub:" .. jsStr(sub) end
    if textShadowPtr[0] then
        opts = opts .. ",shadow:true,shadowColor:" .. jsStr(hexOf(textShadowColorArr))
            .. ",shadowStr:" .. string.format("%.3f", textShadowStrPtr[0])
    end
    return opts
end

-- Tier 2: which side of the car took the hit, from the vehicle's velocity in its own
-- local frame at the trigger frame. Approximates impact side by direction of travel --
-- good for the common "you drove into something" case. Falls back to "front".
local ROLLOVER_Z = 0.35   -- up.z below this at impact = a rollover (on its side / roof)
local function impactDirection()
    local dir
    pcall(function()
        local veh = be:getPlayerVehicle(0)
        if not veh then return end
        local up = vec3(veh:getDirectionVectorUp())
        if up.z < ROLLOVER_Z then dir = "rollover"; return end
        -- delta-v = how the car got SLAMMED (approach velocity -> now). It points at the part
        -- that actually HIT, regardless of which way you were travelling (spins, clips, slides).
        -- approach velocity = the fastest sample in the damage window (just before the crush).
        local curVel = vec3(veh:getVelocity())
        local approachV, maxS = nil, -1
        for i = 1, #dmgWindow do
            local w = dmgWindow[i]
            if w.v and w.s and w.s > maxS then maxS = w.s; approachV = w.v end
        end
        local dv = approachV and (curVel - approachV) or (curVel * -1)   -- fallback: travel dir
        if dv:length() < 0.5 then dir = "front"; return end
        local fwd   = vec3(veh:getDirectionVector())
        local right = fwd:cross(up)
        local f, r = dv:dot(fwd), dv:dot(right)   -- dv points AWAY from the impact
        if math.abs(f) >= math.abs(r) then dir = (f <= 0) and "front" or "rear"
        else dir = (r <= 0) and "sideRight" or "sideLeft" end   -- driver = left (LHD)
    end)
    return dir
end

-- Pick the injury lines. `crashForce` sets the severity tier (1..4) over the trigger
-- threshold..full-blast range (nil Test = mid tier). `dir` picks the body region
-- (nil = random region, for a Test). `parts` reserved for Tier 3 (real part damage).
local function buildInjuryReport(crashForce, dir, injSpeed, cabin)
    local tone    = INJ.funny[0] and INJ.pools.funny or INJ.pools.clinical
    local ctxTone = INJ.funny[0] and INJ.context.funny or INJ.context.clinical
    local region  = dir or ({ "front", "rear", "sideLeft", "sideRight", "rollover" })[math.random(5)]
    local poolRegion = (region == "sideLeft" or region == "sideRight") and "side" or region
    -- severity tier from crash force (over threshold..full-blast range)
    local tier
    if crashForce then
        local thr  = thresholdPtr[0]
        local full = math.max(thr + 1, scaleFullPtr[0])
        local t = (crashForce - thr) / (full - thr)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        tier = 1 + math.floor(t * 3.999)
    else
        tier = math.random(2, 4)
    end
    if tier < 1 then tier = 1 elseif tier > 4 then tier = 4 end
    -- Speed matters, and DIRECTION changes survivability: a frontal crash (crumple zone +
    -- airbags) is far more survivable than a side/rollover at the same speed. Per-region
    -- speed tiers; injury tier = the harsher of the damage tier and the speed tier.
    if injSpeed then
        local th = INJ.sevSpeed[poolRegion] or INJ.sevSpeed.front
        local sc = INJ.tough[0]   -- survivability: higher = need more speed to reach each tier
        local st = (injSpeed >= th[3] * sc and 4) or (injSpeed >= th[2] * sc and 3) or (injSpeed >= th[1] * sc and 2) or 1
        if st > tier then tier = st end
    end
    -- Cabin-intrusion modulation (real deformation in the SEAT band; crumple-only crashes read
    -- 0.03-0.08 there). Front/rear have crumple zones: cabin intact = you live -- up to the speed
    -- where the deceleration alone is lethal (~200 km/h, scaled by Survivability). Sides have NO
    -- crumple (the rigid door transmits the hit), so no such mercy there. And crush that actually
    -- reaches the seat is always at least serious.
    if cabin then
        if (poolRegion == "front" or poolRegion == "rear") and cabin < 0.12 and tier > 3
            and (not injSpeed or injSpeed < 200 * INJ.tough[0]) then tier = 3 end
        if cabin >= 0.22 and tier < 3 then tier = 3 end
    end
    local rp = tone[poolRegion] or tone.front
    local n = math.min(tier, 3)                          -- up to 3 region injuries
    local chosen = {}
    local function drawFrom(src, k)                       -- k distinct random picks appended to chosen
        local order = {}
        for i = 1, #src do order[i] = i end
        for i = 1, math.min(k, #src) do
            local j = math.random(i, #src)
            order[i], order[j] = order[j], order[i]
            chosen[#chosen + 1] = src[order[i]]
        end
    end
    local primary   = (tier >= 3) and rp.major or rp.minor
    local secondary = (tier >= 3) and rp.minor or rp.major
    drawFrom(primary, n)
    if #chosen < n then drawFrom(secondary, n - #chosen) end   -- backfill if the band was short
    if tier == 4 and INJ.showFatal[0] and tone.fatal then chosen[#chosen + 1] = tone.fatal[math.random(#tone.fatal)] end
    local ctx = ctxTone[region] or ctxTone[poolRegion]         -- lead with the detected impact
    if ctx and INJ.showDir[0] then table.insert(chosen, 1, ctx) end
    return chosen
end

-- Deformation-based impact direction (Tier 3). While driving we keep a rolling pre-crash node
-- snapshot (snapshotDeform -> VE globals _dsSnap/_dsSnapPrev, body nodes only). On a crash we
-- freeze it and queryDeform() diffs the crushed state against it -- the baseline cancels, leaving
-- only crash movement -> a deformation centroid. onDeformResult() turns cy (front/back) + cz
-- (rollover) into the direction. Left/right isn't separable (car is long+narrow), so side /
-- ambiguous hits fall back to the delta-v guess (which keeps the driver/passenger flavour).
local function showInjuriesFor(force, dir, spd, cabin, elapsedMs)
    local list = buildInjuryReport(force, dir, spd, cabin)
    if not list or #list == 0 then return end
    local parts = {}
    for i = 1, #list do parts[i] = jsStr(list[i]) end
    -- Absolute delay measured from the crash, capped to land INSIDE the death screen's real
    -- on-screen window (DEF.blackMs = fadeIn+hold, already crash-force-scaled). This applies
    -- with the blackout off too: the overlay is merely transparent then, and it still tears
    -- itself (and the report) down at fadeIn+hold -- so an uncapped delay would reveal the
    -- report into an already-hidden overlay and nobody would ever see it.
    -- elapsedMs = time already spent before this call (the deform read).
    local totalMs = math.floor(INJ.delay[0] * 1000 + 0.5)
    if DEF.blackMs > 0 then
        -- Reserve a READABLE window at the end, not just a sliver: the report has its own
        -- 0.5s fade-in, so a small margin meant it was still fading in when the overlay tore
        -- it down (it flashed and vanished). 500ms fade-in + ~1s to actually read it.
        local capMs = DEF.blackMs - 1500
        if capMs < 0 then capMs = 0 end
        if totalMs > capMs then totalMs = capMs end
    end
    local revealMs = totalMs - (elapsedMs or 0)
    if revealMs < 0 then revealMs = 0 end
    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.showInjuries([" ..
            table.concat(parts, ",") .. "]," .. math.floor(INJ.size[0] + 0.5) .. "," .. jsStr(hexOf(INJ.color)) .. "," .. revealMs .. ");")
    end)
end
local function onDeformResult(cx, cy, cz, tot, b1, b2, b3, b4, b5)
    if not DEF.pend then return end
    local p = DEF.pend; DEF.pend = nil
    local dir
    if tot and tot > 0.5 and cy then     -- clear deformation -> trust it for front / rear / rollover
        if cz and cz > 0.85 then dir = "rollover"
        elseif cy < -0.35 then dir = "front"
        elseif cy > 0.4 then
            -- door hits masquerade as "rear": doors are rigid (impact beams), so the soft rear
            -- quarter takes the visible crush. If the impulse was clearly LATERAL, it was a side hit.
            if p.fb == "sideLeft" or p.fb == "sideRight" then dir = p.fb else dir = "rear" end
        end
    end
    showInjuriesFor(p.force, dir or p.fb, p.spd, b3, 500)   -- b3 = seat-band crush -> cabin-intrusion severity; 500ms = the deform-read delay already spent
end
local function snapshotDeform()
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    pcall(function()
        veh:queueLuaCommand([[
            local nodes = v and v.data and v.data.nodes
            if not nodes then return end
            local fwd, up = obj:getDirectionVector(), obj:getDirectionVectorUp()
            local right = fwd:cross(up)
            _dsSnapPrev = _dsSnap
            _dsSnap = {}
            for _, n in pairs(nodes) do
                if n.cid and not n.wheelID then
                    local p = obj:getNodePosition(n.cid)
                    _dsSnap[n.cid] = { p:dot(right), p:dot(fwd), p:dot(up) }
                end
            end
        ]])
    end)
end
local function queryDeform()
    local veh = be:getPlayerVehicle(0)
    if not veh then onDeformResult(0, 0, 0, 0); return end
    pcall(function()
        veh:queueLuaCommand([[
            local snap = _dsSnapPrev or _dsSnap
            local nodes = v and v.data and v.data.nodes
            if not snap or not nodes then
                obj:queueGameEngineLua('if extensions.DeathScreen and extensions.DeathScreen.onDeformResult then extensions.DeathScreen.onDeformResult(0,0,0,0) end'); return
            end
            local fwd, up = obj:getDirectionVector(), obj:getDirectionVectorUp()
            local right = fwd:cross(up)
            -- longitudinal extent from rest positions (front = most-negative y per our probes)
            local minY, maxY = 1e9, -1e9
            for _, n in pairs(nodes) do
                if n.pos and n.cid and not n.wheelID then
                    if n.pos.y < minY then minY = n.pos.y end
                    if n.pos.y > maxY then maxY = n.pos.y end
                end
            end
            local len = maxY - minY
            if len < 0.01 then len = 0.01 end
            local cx, cy, cz, tot = 0, 0, 0, 0
            local b1, b2, b3, b4, b5 = 0, 0, 0, 0, 0   -- deformation by fifth of the car, nose->tail
            for _, n in pairs(nodes) do
                if n.cid and n.pos and not n.wheelID and snap[n.cid] then
                    local p = obj:getNodePosition(n.cid)
                    local s = snap[n.cid]
                    local dx, dy, dz = p:dot(right) - s[1], p:dot(fwd) - s[2], p:dot(up) - s[3]
                    local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
                    cx, cy, cz, tot = cx + n.pos.x * mag, cy + n.pos.y * mag, cz + n.pos.z * mag, tot + mag
                    local bi = math.floor(((n.pos.y - minY) / len) * 5) + 1
                    if bi < 1 then bi = 1 elseif bi > 5 then bi = 5 end
                    if bi == 1 then b1 = b1 + mag elseif bi == 2 then b2 = b2 + mag
                    elseif bi == 3 then b3 = b3 + mag elseif bi == 4 then b4 = b4 + mag
                    else b5 = b5 + mag end
                end
            end
            if tot < 0.001 then
                obj:queueGameEngineLua('if extensions.DeathScreen and extensions.DeathScreen.onDeformResult then extensions.DeathScreen.onDeformResult(0,0,0,0) end')
            else
                obj:queueGameEngineLua(string.format('if extensions.DeathScreen and extensions.DeathScreen.onDeformResult then extensions.DeathScreen.onDeformResult(%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f) end',
                    cx / tot, cy / tot, cz / tot, tot, b1 / tot, b2 / tot, b3 / tot, b4 / tot, b5 / tot))
            end
        ]])
    end)
end

local function triggerDeathScreen(force, crashForce, held, injSpeed)
    if isShowing then return end
    -- crash blackout is gated by 'Enable blackout'; a pass-out (held) is its own trigger
    -- and only needs the global 'Enabled', so it works even with the blackout turned off
    if not force and not enabledPtr[0] then return end
    if not force and not held and not (blackoutPtr[0] or showTextPtr[0] or INJ.on[0]) then return end   -- need black, message, or injury to show

    installUI()
    if not uiInstalled then return end

    -- Optionally scale the blackout with how hard the crash was (Kyle's idea):
    -- at the trigger threshold -> "Min blackout" length + "Min darkness"; at
    -- "Full-blast force" (and above) -> the full "Blackout length" + "Darkness".
    -- A manual test uses the full one.
    local holdSec = durationPtr[0]
    local darkVal = blackoutPtr[0] and opacityPtr[0] or 0   -- no blackout = transparent; message/injury still show over gameplay
    if blackoutPtr[0] and scalePtr[0] and crashForce then
        local thr  = thresholdPtr[0]
        local full = math.max(thr + 1, scaleFullPtr[0])
        local t = (crashForce - thr) / (full - thr)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local minDur = math.min(scaleMinPtr[0], durationPtr[0])
        holdSec = minDur + (durationPtr[0] - minDur) * t
        local minDark = math.min(scaleMinDarkPtr[0], opacityPtr[0])
        darkVal = minDark + (opacityPtr[0] - minDark) * t
    end

    -- A passout is a faint, not an impact: fade to black GRADUALLY (its own timer),
    -- instead of the crash's near-instant snap.
    local fadeInMs  = math.floor((held and PASSOUT.fadeIn[0] or fadeInPtr[0]) * 1000 + 0.5)
    local holdMs    = math.floor(holdSec * 1000 + 0.5)
    local fadeOutMs = math.floor(fadeOutPtr[0] * 1000 + 0.5)
    -- The overlay (and with it the injury report) is torn down at fadeIn+hold whether or not
    -- the blackout is on -- "blackout off" only makes it transparent, it still hosts the text.
    -- Stash the REAL visible window so the injury delay can be capped inside it (holdSec is
    -- already crash-force-scaled here, so this follows a shortened blackout too).
    DEF.blackMs = fadeInMs + holdMs

    local opts = "{fadeInMs:" .. fadeInMs
        .. ",holdMs:" .. holdMs
        .. ",fadeOutMs:" .. fadeOutMs
        .. ",bg:" .. string.format("%.3f", darkVal)
    if vignettePtr[0] then
        opts = opts .. ",vignette:true,tint:" .. jsStr(hexOf(tintArr))
        opts = opts .. ",vignetteAfterMs:" .. (vignetteAfterPtr[0] and (fadeInMs + 120) or 0)
        opts = opts .. ",vigFadeInMs:"  .. (vigFadeInPtr[0]  and math.floor(vigFadeInDurPtr[0]  * 1000 + 0.5) or 0)
        opts = opts .. ",vigFadeOutMs:" .. (vigFadeOutPtr[0] and math.floor(vigFadeOutDurPtr[0] * 1000 + 0.5) or 0)
    end
    if held then opts = opts .. ",hold:true" end   -- passout: hold the black until released
    if INJ.on[0] then opts = opts .. ",injPos:" .. INJ.pos[0] end   -- injury report position (0 auto)
    opts = opts .. buildMessageOpts()   -- message text/style opts (own fn: keeps triggerDeathScreen under the 60-upvalue cap)
    opts = opts .. "}"

    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.show(" .. opts .. ");")
    end)

    isShowing   = true
    heldActive  = held or false
    activeTimer = (fadeInMs + holdMs + fadeOutMs) / 1000 + 0.25   -- (ignored while heldActive)
    if hideUIPtr[0] and windowOpen[0] then   -- get the settings window out of the shot
        windowOpen[0] = false
        uiHiddenByTrigger = true
    end
    soundBackFadeTimer = 0
    -- Which sound this trigger plays: the main death sound on a crash; on a pass-out
    -- (only if opted in) the pass-out sound, or the main one if that field is blank.
    -- Resolved up front so the sound-cut's channel handling and the playback agree.
    local soundEv, soundVol = "", soundVolPtr[0]
    if soundPtr[0] and (not held or PASSOUT.playSound[0]) then
        soundEv = ffi.string(soundEventBuf)
        if held then
            local ps = ffi.string(PASSOUT.soundBuf)
            if ps ~= "" then soundEv = ps end
            soundVol = PASSOUT.soundVol[0]   -- pass-out has its own volume
        end
    end
    if soundCutPtr[0] then
        muteGame(soundEv)
        -- hear-before-you-see only for a timed blackout; a held passout stays cut until release
        soundBackTimer = (not held and soundBackPtr[0]) and math.max(0.05, soundBackAtPtr[0]) or 0
    else
        soundBackTimer = 0
    end
    if soundEv ~= "" then playDeathSound(soundEv, soundVol) end
    if SM.on[0] and not held then triggerSlowmo(crashForce) end   -- no indefinite slow-mo for a held passout
    armRecoveryBlur()   -- fires when the black starts lifting (handled in onUpdate / on release)
    -- Injury report: on a real crash, query deformation for the direction then show it async
    -- (onDeformResult); a manual Test has no crash, so show one immediately with a random region.
    if INJ.on[0] and not held then
        if crashForce and INJ.deform[0] then
            DEF.pend = { force = crashForce, spd = injSpeed, fb = impactDirection() }
            DEF.queryT = 0.5
        elseif crashForce then
            showInjuriesFor(crashForce, impactDirection(), injSpeed, 0)   -- impulse-only mode (deform detection off)
        else
            showInjuriesFor(nil, nil, injSpeed, 0)
        end
    end
    -- clear the window so the same crash can't re-trigger the instant the cooldown ends
    dmgWindow = {}
    recentDamage = 0
end

-- Slow-mo WITHOUT the blackout: a crash still triggers bullet-time even though the
-- death screen is off (Need for Speed Shift / GRID style). Mirrors the death-screen
-- cooldown + damage-window clear so a tumbling wreck can't re-fire it every frame.
local function triggerSlowmoOnly(crashForce)
    if isShowing or slowmoActive then return end
    triggerSlowmo(crashForce)
    cooldownTimer = RETRIGGER_COOLDOWN
    dmgWindow = {}
    recentDamage = 0
end

--------------------------------------------------------------------------------
-- DAMAGE VIGNETTE  (FPS-style edge flash on any crash; independent of blackout)
--------------------------------------------------------------------------------
-- feed a "hit" to the browser animation: it ADDS `boost` to the strength (up to
-- `cap`), reaching in up to `coverMax`, then fades on its own. Because it's
-- additive, hitting again mid-effect stacks like it used to.
local function sendDamageHit(boost, coverMax, cap)
    installUI()
    if not uiInstalled then return end
    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.damage(" ..
            string.format("%.3f", boost) .. "," .. string.format("%.3f", coverMax) .. "," ..
            jsStr(hexOf(DVIG.color)) .. "," .. math.floor(DVIG.fade[0] * 1000 + 0.5) .. "," ..
            string.format("%.3f", cap) .. "," .. string.format("%.3f", DVIG.soft[0]) .. ");")
    end)
end

local function dmgClear()
    if not uiInstalled then return end
    pcall(function() be:executeJS("window.__DeathScreen && window.__DeathScreen.clearDamage();") end)
end

local function updateDamageVignette(dt)
    if not (enabledPtr[0] and DVIG.on[0]) then   -- global master + own toggle
        if dmgVigWasOn then dmgClear(); dmgVigWasOn = false end
        dmgAccum = 0
        return
    end
    dmgVigWasOn = true
    dmgAccum = dmgAccum + (frameDamageDelta or 0)
    dmgVigThrottle = dmgVigThrottle - (dt or 0)
    if dmgVigThrottle <= 0 then
        dmgVigThrottle = 0.04
        -- only feed a hit when fresh damage arrived (and not under a blackout).
        -- boost is based on THIS batch of damage (dmgAccum) so repeated hits add up.
        if dmgAccum > 0 and not isShowing then
            local cap = DVIG.max[0]
            local hitP = math.min(1, dmgAccum / math.max(1, DVIG.full[0]))
            sendDamageHit(hitP * cap, DVIG.cover[0], cap)
        end
        dmgAccum = 0
    end
end

--------------------------------------------------------------------------------
-- DETECTION  (runs every frame in onUpdate)
--------------------------------------------------------------------------------
local function updateDetection(dtReal)
    uiClock = uiClock + (dtReal or 0)
    frameDamageDelta = 0     -- reset each frame; set below when new damage arrives

    local vid = be:getPlayerVehicleID(0)
    if vid == nil or vid < 0 then return end
    local mo = map and map.objects and map.objects[vid]
    if not mo then return end

    local dmg = mo.damage or 0

    -- (re)sync on vehicle switch / spawn so pre-existing damage isn't counted
    if vid ~= lastVid then
        lastVid = vid
        lastDamage = dmg
        dmgWindow = {}
        recentDamage = 0
        peakDamage = 0        -- fresh vehicle, fresh peak
        return
    end

    local delta = dmg - lastDamage
    lastDamage = dmg
    -- damage dropped => the car was repaired/reset; resync and clear the peak
    if delta < 0 then
        dmgWindow = {}
        recentDamage = 0
        peakDamage = 0
        return
    end

    local speed = (mo.vel and mo.vel:length() * 3.6) or 0
    DEF.speed = speed

    if delta > 0 then
        frameDamageDelta = delta     -- feed the damage vignette
        dmgWindow[#dmgWindow + 1] = { t = uiClock, d = delta, s = speed, v = mo.vel and vec3(mo.vel) or nil }
        recentDamage = recentDamage + delta
    end

    -- evict entries older than the window
    local cutoff = uiClock - WINDOW_SEC
    while dmgWindow[1] and dmgWindow[1].t < cutoff do
        recentDamage = recentDamage - dmgWindow[1].d
        table.remove(dmgWindow, 1)
    end
    if recentDamage < 0 then recentDamage = 0 end

    if recentDamage > peakDamage then peakDamage = recentDamage end

    if isShowing then return end

    -- Crash blur fires on its OWN (usually lower) threshold, so it triggers on
    -- ordinary crashes -- not just death-screen-level ones. Works with the blackout
    -- off (but still respects the global master); triggerBlur() self-guards so a
    -- sustained crash won't re-fire it.
    if enabledPtr[0] and BLUR.on[0] and recentDamage >= BLUR.trig[0] then
        triggerBlur()
    end

    if recentDamage >= thresholdPtr[0] then
        -- Use the fastest speed during the crash window (the approach speed) for
        -- BOTH the "min speed" gate and the readout: by the trigger frame the car
        -- has already crushed into the wall and slowed, so the current speed reads
        -- too low and could wrongly fail the gate on a hard, fast-stopping crash.
        local impactSpeed = speed
        for i = 1, #dmgWindow do
            if dmgWindow[i].s and dmgWindow[i].s > impactSpeed then impactSpeed = dmgWindow[i].s end
        end
        if impactSpeed >= minSpeedPtr[0] and enabledPtr[0] and cooldownTimer <= 0 then
            if blackoutPtr[0] or showTextPtr[0] or INJ.on[0] then   -- black screen, OR just the message/injury over gameplay
                lastReason = string.format("%.0f dmg @ %d km/h", recentDamage, math.floor(impactSpeed + 0.5))
                triggerDeathScreen(false, recentDamage, nil, impactSpeed)
            elseif SM.on[0] then                         -- no overlay content, only slow-mo: bullet-time alone
                lastReason = string.format("slow-mo: %.0f dmg @ %d km/h", recentDamage, math.floor(impactSpeed + 0.5))
                triggerSlowmoOnly(recentDamage)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- SETTINGS WINDOW  (imgui)
--------------------------------------------------------------------------------
local THEME = {
    { im.Col_WindowBg,         im.ImVec4(0.06, 0.03, 0.03, 0.97) },
    { im.Col_PopupBg,          im.ImVec4(0.09, 0.04, 0.04, 0.98) },  -- dropdown / tooltip background (match the window's dark red)
    { im.Col_TitleBg,          im.ImVec4(0.12, 0.04, 0.04, 0.95) },
    { im.Col_TitleBgActive,    im.ImVec4(0.35, 0.08, 0.08, 0.98) },
    { im.Col_Border,           im.ImVec4(0.70, 0.20, 0.20, 0.45) },
    { im.Col_Text,             im.ImVec4(0.94, 0.90, 0.90, 1.00) },
    { im.Col_TextDisabled,     im.ImVec4(0.60, 0.50, 0.50, 1.00) },
    { im.Col_FrameBg,          im.ImVec4(0.20, 0.07, 0.07, 0.60) },
    { im.Col_FrameBgHovered,   im.ImVec4(0.30, 0.10, 0.10, 0.70) },
    { im.Col_FrameBgActive,    im.ImVec4(0.40, 0.12, 0.12, 0.80) },
    { im.Col_Button,           im.ImVec4(0.45, 0.12, 0.12, 0.90) },
    { im.Col_ButtonHovered,    im.ImVec4(0.62, 0.16, 0.16, 0.95) },
    { im.Col_ButtonActive,     im.ImVec4(0.78, 0.20, 0.20, 1.00) },
    { im.Col_SliderGrab,       im.ImVec4(0.82, 0.25, 0.25, 0.90) },
    { im.Col_SliderGrabActive, im.ImVec4(0.96, 0.36, 0.36, 1.00) },
    { im.Col_CheckMark,        im.ImVec4(0.96, 0.36, 0.36, 1.00) },
    { im.Col_Header,           im.ImVec4(0.30, 0.09, 0.09, 0.85) },
    { im.Col_HeaderHovered,    im.ImVec4(0.45, 0.13, 0.13, 0.90) },
    { im.Col_HeaderActive,     im.ImVec4(0.55, 0.16, 0.16, 1.00) },
}

local function pushTheme()
    local nCol, nVar = 0, 0
    for _, c in ipairs(THEME) do
        if pcall(im.PushStyleColor2, c[1], c[2]) then nCol = nCol + 1 end
    end
    if pcall(im.PushStyleVar1, im.StyleVar_WindowRounding, 8) then nVar = nVar + 1 end
    if pcall(im.PushStyleVar1, im.StyleVar_FrameRounding,  5) then nVar = nVar + 1 end
    if pcall(im.PushStyleVar1, im.StyleVar_GrabRounding,   4) then nVar = nVar + 1 end
    return nCol, nVar
end

local function popTheme(nCol, nVar)
    if nVar > 0 then pcall(im.PopStyleVar, nVar) end
    if nCol > 0 then pcall(im.PopStyleColor, nCol) end
end

-- A small "(?)" you hover for an explanation, so the window isn't a wall of text.
local function helpMarker(tip)
    if not tip then return end
    im.SameLine()
    im.TextDisabled("(?)")
    if im.IsItemHovered() then
        im.BeginTooltip()
        im.PushTextWrapPos(im.GetFontSize() * 24)
        im.TextUnformatted(tip)          -- unformatted so '%' in tips is safe
        im.PopTextWrapPos()
        im.EndTooltip()
    end
end

-- Checkbox with an optional hover "(?)". Returns true when toggled.
local function checkbox(label, ptr, tip)
    local changed = im.Checkbox(label, ptr)
    helpMarker(tip)
    return changed
end

-- Collapsible section header. Returns true when the section is open, and REMEMBERS
-- the open/closed state across restarts: we force imgui to our stored state each
-- frame (Cond_Always) then read back the header's result, so a user click flips it
-- and we persist the change. `defaultOpen` only seeds the very first run.
local function section(label, defaultOpen)
    local cur = sectionOpen[label]
    if cur == nil then cur = (defaultOpen == true); sectionOpen[label] = cur end
    im.SetNextItemOpen(cur, im.Cond_Always)
    local open = im.CollapsingHeader1(label)
    if open ~= cur then
        sectionOpen[label] = open
        sectionDirty = true
    end
    return open
end

-- true once the user has bound a key to the settings-toggle action, so we can hide
-- the "bind a key" reminders the moment they do it. getControlForAction returns the
-- bound control (or nil); its cache is invalidated whenever bindings change, so this
-- updates live within a frame or two of binding in the controls menu.
local function settingsKeybindBound()
    local ok, ctrl = pcall(function()
        return core_input_bindings and core_input_bindings.getControlForAction
            and core_input_bindings.getControlForAction("toggleDeathScreenUI")
    end)
    return ok and ctrl ~= nil
end

-- A slider you can RIGHT-CLICK to type an exact value into (same as redline).
-- Right-click swaps it for an input box until it loses focus, then the typed
-- value is clamped back into [minv, maxv]. Optional hover "(?)". The bar is
-- narrowed so the label + marker have room. Returns true when the value changed.
local editField = nil
local function slider(id, label, ptr, minv, maxv, fmt, tip)
    im.PushItemWidth(im.GetContentRegionAvailWidth() * 0.52)
    local changed = false
    if editField == id then
        if im.InputFloat(label, ptr, 0, 0, "%.3f") then changed = true end
        if im.IsItemDeactivated() then
            ptr[0] = math.max(minv, math.min(maxv, ptr[0]))
            editField = nil
            changed = true
        end
    else
        if im.SliderFloat(label, ptr, minv, maxv, fmt) then changed = true end
        if im.IsItemHovered() and im.IsMouseClicked(1) then editField = id end
    end
    im.PopItemWidth()
    helpMarker(tip)
    return changed
end

-- The "Effects" + "Damage vignette" sections live in their own function so the
-- upvalues they reference don't count against drawSettingsWindow (Lua caps a
-- function at 60 upvalues, and the settings window was blowing past it).
local function drawEffects()
    local dirty = false
    --------------------------------------------------------------------------
    if section("Effects", true) then
        if checkbox("Slow-motion on crash", SM.on,
            "Briefly slows the game down when you crash, for a dramatic replay. Works even with the blackout turned off, if you just want the slow-mo (like Need for Speed Shift / RaceDriver GRID).") then dirty = true end
        if SM.on[0] then
            if slider("smf", "Game speed", SM.factor, 0.05, 1.0, "%.2f",
                "How slow it goes. 0.30 = 30 percent speed. Lower is more dramatic. (With 'Scale with crash force' on, this is the deepest, for a full-blast crash.)") then dirty = true end
            if slider("smd", "Slow-mo length", SM.dur, 0.0, 10.0, "%.1f s",
                "How long the slow-motion lasts (real seconds). (With 'Scale with crash force' on, this is the full length, for a full-blast crash.)") then dirty = true end
            if checkbox("Scale with crash force##slow", SM.scale,
                "Bigger crashes get longer and deeper slow-mo. 'Slow-mo length' and 'Game speed' above become the full-blast values; set a Min equal to its max to not scale that one. Works with the blackout off too.") then dirty = true end
            if SM.scale[0] then
                if slider("slmind", "Min slow-mo length", SM.minDur, 0.0, 10.0, "%.1f s",
                    "Shortest slow-mo, for a crash that just barely triggers.") then dirty = true end
                if slider("slminf", "Mildest game speed", SM.minFactor, 0.05, 1.0, "%.2f",
                    "Game speed for a barely-triggering crash. Higher = milder on small crashes; it deepens toward 'Game speed' as crashes get harder.") then dirty = true end
                if slider("slfull", "Full-blast force", SM.full, 1000.0, 500000.0, "%.0f",
                    "Crash force at or above which slow-mo hits its full length and depth. Watch 'Biggest so far' after a big crash to pick a value.") then dirty = true end
            end
        end

        if checkbox("Crash blur", BLUR.on,
            "Blurs the whole screen for a moment on a crash, like being dazed. Uses the game's own full-screen blur. Turn off the death screen to see it clearly, or use the Test button.") then dirty = true end
        if BLUR.on[0] then
            if slider("blura", "Blur strength", BLUR.amt, 0.05, 1.0, "%.2f",
                "How blurry it gets. Lower = subtler, 1.0 = full menu-grade blur.") then dirty = true end
            if slider("blurd", "Blur length", BLUR.dur, 0.1, 8.0, "%.1f s",
                "How long the blur holds at full before easing off (not counting the fades).") then dirty = true end
            if checkbox("Fade in##blur", BLUR.fadeIn,
                "Ease the blur in. Off = it snaps on instantly.") then dirty = true end
            if BLUR.fadeIn[0] then
                if slider("blurfin", "Fade in time", BLUR.fadeInDur, 0.0, 5.0, "%.1f s",
                    "How long the blur takes to ramp in.") then dirty = true end
            end
            if checkbox("Fade out##blur", BLUR.fadeOut,
                "Ease the blur out. Off = it snaps off instantly.") then dirty = true end
            if BLUR.fadeOut[0] then
                if slider("blurfout", "Fade out time", BLUR.fadeOutDur, 0.0, 5.0, "%.1f s",
                    "How long the blur takes to ramp out after the hold.") then dirty = true end
            end
            if slider("blurt", "Trigger at damage", BLUR.trig, 1000.0, 300000.0, "%.0f",
                "Crash force that sets the blur off. Lower = even small bumps blur. Watch 'Biggest so far' in the trigger section to pick a value. (Its own threshold, separate from the death screen.)") then dirty = true end
            if im.Button("Test blur") then triggerBlur() end
        end

        if checkbox("Blur on recovery (after blackout)", recoveryBlurPtr,
            "As the blackout fades back in, the screen starts blurry and sharpens -- like regaining your vision. Fires when the black lifts, so it needs the death screen. Use 'Test death screen' to preview.") then dirty = true end
        if recoveryBlurPtr[0] then
            if slider("rblura", "Recovery strength", recoveryBlurAmtPtr, 0.05, 1.0, "%.2f",
                "How blurry your vision is when it first comes back.") then dirty = true end
            if slider("rblurd", "Clear time", recoveryBlurDurPtr, 0.1, 8.0, "%.1f s",
                "How long the blur takes to clear as your vision returns.") then dirty = true end
        end

        if checkbox("Death sound", soundPtr,
            "Play a sound the moment it triggers.") then dirty = true end
        if soundPtr[0] then
            if im.InputText("Sound", soundEventBuf, EVENT_CAP) then dirty = true end
            helpMarker("Your OWN sound: drop a .ogg into the mod's settings/DeathScreen folder (use the button below) and type just its name, e.g.  hit.ogg  -- it plays even with 'Cut game sound' on.")
            if im.Button("Open sounds folder") then
                -- open the settings/DeathScreen folder in the OS file explorer so people
                -- know exactly where to drop their .ogg (create it first if it's not there)
                pcall(function()
                    if FS and not FS:directoryExists(SOUND_DIR) then FS:directoryCreate(SOUND_DIR, true) end
                    if Engine and Engine.Platform then Engine.Platform.exploreFolder(SOUND_DIR) end
                end)
            end
            helpMarker("Opens the folder where your custom sound files go, in Windows Explorer. Drop your .ogg here, then type its filename in the Sound box above.")
            if slider("svol", "Volume", soundVolPtr, 0.0, 3.0, "%.2f",
                "Sound volume. 1.0 = normal, higher = louder.") then dirty = true end
            if checkbox("Fade out sound", soundFadePtr,
                "Ease the sound out near its end instead of cutting off abruptly.") then dirty = true end
            if soundFadePtr[0] then
                if slider("sfade", "Fade length", soundFadeDurPtr, 0.1, 10.0, "%.1f s",
                    "How long the fade-out at the end takes.") then dirty = true end
            end
            if im.Button("Test sound") then playDeathSound() end
        end

        if checkbox("Edge vignette", vignettePtr,
            "Add a dark tint around the screen edges instead of flat black.") then dirty = true end
        if vignettePtr[0] then
            if im.ColorEdit3("Vignette color", tintArr) then dirty = true end
            im.SameLine()
            if im.Button("Reset##tint") then
                tintArr[0] = im.Float(DEFAULT_TINT[1])
                tintArr[1] = im.Float(DEFAULT_TINT[2])
                tintArr[2] = im.Float(DEFAULT_TINT[3])
                dirty = true
            end
            if checkbox("Appear after blackout", vignetteAfterPtr,
                "On: the vignette waits until the screen is fully black, then comes in. Off: it comes in together with the black.") then dirty = true end
            if checkbox("Fade in", vigFadeInPtr,
                "Fade the vignette in. Off = it snaps on instantly.") then dirty = true end
            if vigFadeInPtr[0] then
                if slider("vfin", "Fade in time", vigFadeInDurPtr, 0.0, 5.0, "%.1f s",
                    "How long the vignette takes to fade in.") then dirty = true end
            end
            if checkbox("Fade out", vigFadeOutPtr,
                "Fade the vignette out when the death screen ends. Off = it vanishes instantly.") then dirty = true end
            if vigFadeOutPtr[0] then
                if slider("vfout", "Fade out time", vigFadeOutDurPtr, 0.0, 5.0, "%.1f s",
                    "How long the vignette takes to fade out. It finishes right as the black hold ends, and is capped to the Blackout length.") then dirty = true end
            end
        end
    end

    --------------------------------------------------------------------------
    if section("Damage vignette (any crash)", true) then
        if checkbox("Enable damage vignette", DVIG.on,
            "FPS-style: ANY crash (even a light one, no death screen needed) flashes a colored vignette at the screen edges that fades away. The bigger the hit, the stronger it flashes.") then dirty = true end
        if DVIG.on[0] then
            if im.ColorEdit3("Color", DVIG.color) then dirty = true end
            im.SameLine()
            if im.Button("Reset##dmgcol") then
                DVIG.color[0] = im.Float(DEFAULT_DMGCOLOR[1])
                DVIG.color[1] = im.Float(DEFAULT_DMGCOLOR[2])
                DVIG.color[2] = im.Float(DEFAULT_DMGCOLOR[3])
                dirty = true
            end
            if slider("dvmax", "Max strength", DVIG.max, 0.1, 1.0, "%.2f",
                "How opaque the flash can get on the hardest hit. Lower = subtler. Set to 1.0 (with Coverage 1.0) so the biggest crashes reach fully solid.") then dirty = true end
            if slider("dvcover", "Coverage", DVIG.cover, 0.0, 1.0, "%.2f",
                "How far it reaches in from the edges on the hardest hit. 0 = a thin rim, 1 = closes right in to the centre. Smaller hits reach in proportionally less. For a 'knocked out' look, set Coverage AND Max strength to 1.0 with a black color -- hard crashes then close all the way to solid black, while light ones stay a partial rim.") then dirty = true end
            if slider("dvsoft", "Softness", DVIG.soft, 0.0, 1.0, "%.2f",
                "How gradual the edge fade is. Low = a tight, defined ring. High = the red keeps deepening all the way to the corners, reaching full only at the very edge, so there's NO visible line where it starts fading -- a smooth, edgeless tint. Push toward 1.0 if you can still see where the fade begins.") then dirty = true end
            if slider("dvfull", "Full at damage", DVIG.full, 1000.0, 300000.0, "%.0f",
                "Crash force that flashes it to full strength. Lower = even small hits flash strongly. (Uses the same 'crash force' as the readout above.)") then dirty = true end
            if slider("dvfade", "Fade time", DVIG.fade, 0.2, 5.0, "%.1f s",
                "How long the flash takes to fade away after a hit.") then dirty = true end
        end
    end
    return dirty
end

-- Injury report section (own fn: keeps drawSettingsWindow under the 60-upvalue cap).
local function drawInjury()
    local dirty = false
    if section("Injury report", false) then
        im.TextColored(im.ImVec4(0.95, 0.75, 0.35, 1.0), "Experimental")
        helpMarker("Injuries are estimated from the car's real crash deformation and impact physics. Most crashes read right, but odd multi-hit or corner crashes can misread. Pure roleplay flavour - not a medical sim.")
        if checkbox("Show injury report", INJ.on,
            "After a crash, lists the 'injuries' you sustained - where you got hit, how hard, and whether the crush reached your seat. Pure roleplay flavour. Off by default.") then dirty = true end
        if INJ.on[0] then
            if checkbox("Darkly funny", INJ.funny,
                "Tone of the report. Off = clinical (\"Fractured rib\"). On = dark humour (\"Spleen has left the chat\").") then dirty = true end
            if checkbox("Deformation-based detection", INJ.deform,
                "Reads the car's ACTUAL crush to tell where you got hit and whether the cabin was intruded (recommended). Tiny background cost while driving. Off = a lighter guess from the impact impulse only.") then dirty = true end
            if checkbox("Show impact direction", INJ.showDir,
                "Lead the report with the detected impact ('Frontal impact', 'Driver's-side impact', 'Rollover'...). Off = just the injuries.") then dirty = true end
            if slider("injsize", "Injury text size", INJ.size, 10.0, 60.0, "%.0f px",
                "Font size of the injury lines.") then dirty = true end
            if im.ColorEdit3("Injury text color", INJ.color) then dirty = true end
            im.SameLine()
            if im.Button("Reset##injcol") then
                INJ.color[0] = im.Float(DEFAULT_INJCOLOR[1]); INJ.color[1] = im.Float(DEFAULT_INJCOLOR[2]); INJ.color[2] = im.Float(DEFAULT_INJCOLOR[3])
                dirty = true
            end
            im.Text("Position:"); im.SameLine()
            if im.RadioButton2("Auto##injpos", INJ.pos, 0) then dirty = true end
            im.SameLine(); if im.RadioButton2("Top##injpos", INJ.pos, 1) then dirty = true end
            im.SameLine(); if im.RadioButton2("Center##injpos", INJ.pos, 2) then dirty = true end
            im.SameLine(); if im.RadioButton2("Bottom##injpos", INJ.pos, 3) then dirty = true end
            im.SameLine(); helpMarker("Where the report sits on screen. Auto = wherever the message isn't (the opposite end from your message position), or centred when there's no message. If a position would land on the message, the report slides just clear of it - the message itself never moves.")
            -- Picking the message's own spot is allowed; it just gets nudged clear when shown.
            -- Flag it here so "Center" not being exactly centred isn't a surprise.
            if showTextPtr[0] and INJ.pos[0] >= 1 and (INJ.pos[0] - 1) == textPosPtr[0] then
                im.TextColored(im.ImVec4(0.95, 0.75, 0.35, 1.0), "Shares the message's spot - will shift clear.")
            end
            if slider("injdelay", "Show after", INJ.delay, 0.3, 6.0, "%.1f s",
                "How long after the crash the report fades in. It's automatically capped so the report always has time to be READ before the screen clears - push this past your Blackout length and it just settles near the end instead of flashing by. Want a genuinely longer delay? Raise the Blackout length, that's what this is capped against. (With deformation detection on, it also can't beat the ~0.5s the game needs to read the crush first.)") then dirty = true end
            if slider("injtough", "Survivability", INJ.tough, 0.5, 2.0, "%.2fx",
                "How well you shrug off crashes. Higher = survive harder hits (e.g. with a roll cage), lower = fragile. 1.0 = default. Frontal crashes are always more survivable than side/rollover.") then dirty = true end
            if checkbox("Allow fatal injuries", INJ.showFatal,
                "On = the worst crashes can end with a 'deceased' line. Off = you always 'survive' (still lists the injuries, just no death).") then dirty = true end
        end
    end
    return dirty
end

-- "Cut game sound" and its audio-return sub-controls, split out so their pointers
-- don't count against drawSettingsWindow's upvalues (Lua caps a function at 60).
local function drawSoundCut()
    local dirty = false
    if checkbox("Cut game sound", soundCutPtr,
        "Mutes engine, tyres, crash, hazard-blinker and other game audio while the screen is black. A custom death sound still plays over it.") then dirty = true end
    if soundCutPtr[0] then
        if checkbox("Hear game before you recover", soundBackPtr,
            "Brings the game audio back BEFORE the screen clears -- you hear the world again while everything is still black, like your hearing returning before your sight.") then dirty = true end
        if soundBackPtr[0] then
            if slider("sback", "Audio returns after", soundBackAtPtr, 0.1, 8.0, "%.1f s",
                "How long after the crash the game audio comes back (while still black). Keep it shorter than the Blackout length, otherwise the audio just returns as the screen is already clearing.") then dirty = true end
            if slider("sbackfade", "Audio fade-in", soundBackFadePtr, 0.0, 5.0, "%.1f s",
                "How long the game audio takes to swell back in when it returns. 0 = snaps on instantly; higher = a gradual return, like your hearing easing back.") then dirty = true end
        end
    end
    return dirty
end

-- "Message" section, split out so its (many) text pointers don't count against
-- drawSettingsWindow's upvalues (Lua caps a function at 60).
local function drawMessage()
    local dirty = false
    if section("Message", false) then
        if checkbox("Show message", showTextPtr,
            "Show a big message (like GTA's WASTED) once the screen is black.") then dirty = true end
        if showTextPtr[0] then
            if im.InputText("Title", textBuf, TEXT_CAP) then dirty = true end
            if im.ColorEdit3("Title color", colorArr) then dirty = true end
            im.SameLine()
            if im.Button("Reset##color") then
                colorArr[0] = im.Float(DEFAULT_COLOR[1]); colorArr[1] = im.Float(DEFAULT_COLOR[2]); colorArr[2] = im.Float(DEFAULT_COLOR[3])
                dirty = true
            end
            if slider("tsize", "Title size", textSizePtr, 20.0, 240.0, "%.0f px",
                "Font size of the title.") then dirty = true end

            if im.InputText("Subtitle", subBuf, SUB_CAP) then dirty = true end
            if im.ColorEdit3("Subtitle color", subColorArr) then dirty = true end
            im.SameLine()
            if im.Button("Reset##subcolor") then
                subColorArr[0] = im.Float(DEFAULT_SUBCOLOR[1]); subColorArr[1] = im.Float(DEFAULT_SUBCOLOR[2]); subColorArr[2] = im.Float(DEFAULT_SUBCOLOR[3])
                dirty = true
            end
            if slider("ssize", "Subtitle size", subSizePtr, 10.0, 200.0, "%.0f px",
                "Font size of the subtitle.") then dirty = true end

            if im.BeginCombo("Font", (FONTS[textFontPtr[0] + 1] or FONTS[1]).name) then
                for i = 1, #FONTS do
                    if im.Selectable1(FONTS[i].name, textFontPtr[0] == i - 1) then
                        textFontPtr[0] = i - 1; dirty = true
                    end
                end
                im.EndCombo()
            end
            helpMarker("Font for the message. All are standard fonts your system has.")
            if checkbox("Bold", textBoldPtr, "Heavy weight vs normal for the message.") then dirty = true end
            im.SameLine()
            if checkbox("Italic", textItalicPtr, "Slant the message text.") then dirty = true end
            if slider("tspace", "Letter spacing", textSpacingPtr, 0.0, 40.0, "%.0f px",
                "Space between the title's letters.") then dirty = true end

            if checkbox("Shadow / glow", textShadowPtr, "A soft halo behind the text so it pops off the black.") then dirty = true end
            if textShadowPtr[0] then
                if im.ColorEdit3("Shadow color", textShadowColorArr) then dirty = true end
                im.SameLine()
                if im.Button("Reset##shcolor") then
                    textShadowColorArr[0] = im.Float(DEFAULT_SHADOW[1]); textShadowColorArr[1] = im.Float(DEFAULT_SHADOW[2]); textShadowColorArr[2] = im.Float(DEFAULT_SHADOW[3])
                    dirty = true
                end
                if slider("shstr", "Shadow spread", textShadowStrPtr, 0.0, 1.0, "%.2f",
                    "How far the halo/glow spreads. Higher = softer, wider.") then dirty = true end
            end

            im.Text("Position:"); im.SameLine()
            if im.RadioButton2("Top", textPosPtr, 0) then dirty = true end
            im.SameLine(); if im.RadioButton2("Center", textPosPtr, 1) then dirty = true end
            im.SameLine(); if im.RadioButton2("Bottom", textPosPtr, 2) then dirty = true end

            if slider("tdelay", "Text delay", textDelayPtr, 0.0, 3.0, "%.2f s",
                "Waits this long after the screen is black, then the text slams in (GTA-style).") then dirty = true end
        end
    end
    return dirty
end

-- Presets section: name + Save, and a list of saved presets with Load / delete.
-- (Load/Save/delete each persist on their own, so nothing to return.)
local function drawPresets()
    if section("Presets", false) then
        im.PushItemWidth(im.GetContentRegionAvailWidth() * 0.58)
        im.InputText("##presetname", presetNameBuf, PRESET_CAP)
        im.PopItemWidth()
        im.SameLine()
        if im.Button("Save preset") then
            savePreset(ffi.string(presetNameBuf):match("^%s*(.-)%s*$"))
        end
        helpMarker("Type a name and hit Save to store ALL your current settings as a preset. Load one below to switch to it instantly. Great for a 'cinematic' set vs a 'subtle' set, etc.")
        if im.Button("Open presets folder") then
            ensurePresetDir()
            pcall(function() if Engine and Engine.Platform then Engine.Platform.exploreFolder(PRESETS_DIR) end end)
        end
        helpMarker("Each preset is its own file in here. To SHARE one, send someone the file; to add someone else's, drop it in this folder - it shows up in the list live, no restart needed.")
        local names = {}
        for k in pairs(presets) do names[#names + 1] = k end
        table.sort(names)
        if #names == 0 then
            im.TextDisabled("No presets saved yet.")
        else
            for _, name in ipairs(names) do
                if im.Button("Load##p_" .. name) then loadPreset(name) end
                im.SameLine()
                if im.Button("X##p_" .. name) then deletePreset(name) end
                im.SameLine()
                im.Text(name)
            end
        end
    end
end

local function drawSettingsWindow()
    local nCol, nVar = pushTheme()
    -- Cap the window height to the screen so it never overflows small resolutions
    -- (e.g. 1366x768) -- with all the sections expanded the content is taller than the
    -- window, so imgui adds a vertical scrollbar instead of running off the bottom.
    local vp = im.GetMainViewport()
    if vp then
        im.SetNextWindowSizeConstraints(im.ImVec2(340, 120),
            im.ImVec2(100000, math.max(240, vp.Size.y * 0.92)))
    end
    im.SetNextWindowSize(im.ImVec2(430, 0), im.Cond_FirstUseEver)
    if im.Begin("Death Screen", windowOpen) then
        local dirty = false

        if checkbox("Enabled", enabledPtr,
            "Global master switch for the whole mod. When OFF, nothing happens on a crash at all -- no blackout, no crash blur, no damage vignette. Turn individual effects on/off in their own sections.") then dirty = true end
        if checkbox("Hide window during death screen", hideUIPtr,
            "Auto-hides this settings window while a death screen is playing (so it's not in your shot), then reopens it when the blackout ends.") then dirty = true end
        im.TextDisabled("Tip: right-click any slider to type an exact value.")
        if not settingsKeybindBound() then
            im.TextColored(im.ImVec4(1.00, 0.82, 0.40, 1.00),
                "Reopen via Options > Controls > Death Screen.")
        end

        --------------------------------------------------------------------------
        drawPresets()

        --------------------------------------------------------------------------
        if section("Blackout", true) then
            if checkbox("Enable blackout", blackoutPtr,
                "Black out the screen after a hard crash (the core death-screen effect). Turn this OFF to keep only the other effects -- e.g. crash blur and the damage vignette -- with no blackout. (The global 'Enabled' switch above still has to be on.)") then dirty = true end
            if slider("dur",  "Blackout length", durationPtr, 0.5, 15.0, "%.1f s",
                "How long the screen stays fully black. This also sets how long the message and the injury report stay on screen - including when 'Enable blackout' is OFF, where the screen isn't darkened but this still times the message/report.") then dirty = true end
            if slider("fin",  "Fade to black", fadeInPtr, 0.0, 3.0, "%.2f s",
                "How fast the screen goes black on impact. 0 = instant.") then dirty = true end
            if slider("fout", "Fade back in", fadeOutPtr, 0.0, 5.0, "%.2f s",
                "How gently the screen fades back to normal afterwards.") then dirty = true end
            if slider("dark", "Darkness", opacityPtr, 0.3, 1.0, "%.2f",
                "1.0 = fully black. Lower lets a bit of the game show through.") then dirty = true end
            if checkbox("Scale with crash force", scalePtr,
                "Bigger crashes get a longer and darker blackout. 'Blackout length' and 'Darkness' above become the maximums. Set a Min equal to its max to not scale that one.") then dirty = true end
            if scalePtr[0] then
                if slider("smin", "Min blackout", scaleMinPtr, 0.1, 15.0, "%.1f s",
                    "Shortest blackout, for a crash that just barely triggers.") then dirty = true end
                if slider("smindark", "Min darkness", scaleMinDarkPtr, 0.1, 1.0, "%.2f",
                    "Lightest darkness, for a crash that just barely triggers. Lower = greyer / more see-through on small crashes. Set equal to 'Darkness' to keep it fully black always.") then dirty = true end
                if slider("sfull", "Full-blast force", scaleFullPtr, 1000.0, 500000.0, "%.0f",
                    "Crash force at or above which you get the full 'Blackout length' and 'Darkness'. Watch 'Biggest so far' after a big crash to pick a good value.") then dirty = true end
            end
            if drawSoundCut() then dirty = true end   -- Cut game sound + audio-return (own function: keeps upvalues under Lua's 60 limit)
        end

        --------------------------------------------------------------------------
        if section("When it triggers", true) then
            if slider("sev", "Crash severity", thresholdPtr, 500.0, 500000.0, "%.0f",
                "How hard a crash has to be to trigger. Higher = only bigger crashes count. Use the readout below to tune it.") then dirty = true end
            if slider("spd", "Min speed", minSpeedPtr, 0.0, 60.0, "%.0f km/h",
                "Won't trigger unless you were going at least this fast. Blocks false alarms from fire or slow crushing.") then dirty = true end
            if checkbox("Pass out when upside down", PASSOUT.on,
                "A second way to trigger the blackout: if you're left upside down (on the roof) for long enough, the driver passes out. The black screen HOLDS until you're flipped back over or you reset. No crash needed. Works even with 'Enable blackout' OFF (pass-out blackouts without crash blackouts) - only the global 'Enabled' has to be on.") then dirty = true end
            if PASSOUT.on[0] then
                if slider("fliptime", "Upside-down time", PASSOUT.time, 1.0, 30.0, "%.1f s",
                    "How long you have to be upside down before you pass out. Righting the car resets the timer.") then dirty = true end
                if slider("flipang", "Upside-down angle", PASSOUT.angle, 90.0, 170.0, "%.0f deg",
                    "How far the car must tip before it counts as upside down. 90 = resting on its side, 170 = must be almost dead upside down. Default 120 = well onto the roof. Lower = passes out more easily.") then dirty = true end
                if slider("flipfin", "Pass-out fade", PASSOUT.fadeIn, 0.0, 5.0, "%.1f s",
                    "How slowly the screen fades to black as you pass out. Unlike a crash (a sudden snap), this is a gradual faint. 0 = instant.") then dirty = true end
                if slider("flipfout", "Come-to fade", PASSOUT.fadeOut, 0.0, 5.0, "%.1f s",
                    "How slowly your vision returns when you're flipped back over or reset. 0 = instant.") then dirty = true end
                if checkbox("Play death sound on pass-out", PASSOUT.playSound,
                    "When you pass out from being upside down, also play a sound (crashes still use the main Death sound). Off = stay silent on a pass-out. Needs 'Death sound' turned on under Effects.") then dirty = true end
                if PASSOUT.playSound[0] then
                    if im.InputText("Pass-out sound", PASSOUT.soundBuf, EVENT_CAP) then dirty = true end
                    helpMarker("Optional: a DIFFERENT sound for passing out, e.g. faint.ogg. Same folder as the Death sound (use its 'Open sounds folder' button under Effects). Leave blank to reuse your main Death sound.")
                    if slider("flipvol", "Pass-out volume", PASSOUT.soundVol, 0.0, 3.0, "%.2f",
                        "How loud the pass-out sound plays (1.0 = normal). Separate from the crash Death sound's volume.") then dirty = true end
                end
            end
            im.Dummy(im.ImVec2(0, 3))
            im.Text(string.format("Current crash force: %.0f", recentDamage))
            im.Text(string.format("Biggest so far: %.0f", peakDamage))
            im.SameLine()
            if im.Button("Reset##peak") then peakDamage = 0 end
            helpMarker("Do a light tap and note the biggest number, then a real crash and note that. Set 'Crash severity' between the two. Clears when you reset your vehicle.")
        end

        --------------------------------------------------------------------------
        if drawMessage() then dirty = true end   -- Message section (own function: keeps upvalues under Lua's 60 limit)
        if drawInjury() then dirty = true end    -- Injury report section (own function, same reason)

        --------------------------------------------------------------------------
        if drawEffects() then dirty = true end   -- Effects + Damage vignette (own function: keeps upvalues under Lua's 60 limit)

        --------------------------------------------------------------------------
        im.Separator()
        if im.Button("Test death screen", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
            lastReason = "manual test"
            triggerDeathScreen(true)
        end

        if lastReason ~= "" then
            im.Dummy(im.ImVec2(0, 2))
            im.TextDisabled("Last trigger: " .. lastReason)
        end

        --------------------------------------------------------------------------
        im.Dummy(im.ImVec2(0, 4))
        if not resetConfirm then
            if im.Button("Reset all to defaults") then resetConfirm = true end
        else
            im.TextColored(im.ImVec4(1.00, 0.82, 0.40, 1.00), "Reset every setting to its default?")
            if im.Button("Yes, reset") then
                resetAllDefaults()
                resetConfirm = false
            end
            im.SameLine()
            if im.Button("Cancel") then resetConfirm = false end
        end

        if dirty or sectionDirty then saveSettings(); sectionDirty = false end
    end
    im.End()
    popTheme(nCol, nVar)
end

-- First-run popup: a small separate window shown once (until dismissed) so a fresh
-- installer knows how to reopen the settings window after closing it. BeamNG only
-- binds keys in its own Controls menu, so we can't capture a key here -- the "Open
-- Options" button jumps to the game's Options menu (same call the game's own Options
-- keybind uses); the user then binds 'Death Screen: Settings' there.
local function drawFirstRunNotice()
    if noticeSeen or isShowing or settingsKeybindBound() then return end
    local nCol, nVar = pushTheme()                 -- match the death-screen window's red look
    local vp = im.GetMainViewport()                -- centre it on screen
    if vp then
        im.SetNextWindowPos(
            im.ImVec2(vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5),
            im.Cond_Always, im.ImVec2(0.5, 0.5))
    end
    im.SetNextWindowSize(im.ImVec2(360, 0), im.Cond_Always)
    if im.Begin("Death Screen - quick setup") then
        im.TextWrapped("This window opened automatically the first time. To reopen it after you close it, bind a key to 'Death Screen: Settings' under Options > Controls > Death Screen.")
        im.Dummy(im.ImVec2(0, 8))
        if im.Button("Open controls") then
            -- jump straight to the bindings page (the exact UI route); MenuOpenModule
            -- takes a {state=...} table, same as bigMapMode uses to open the bigmap.
            pcall(function() guihooks.trigger('MenuOpenModule', {state = 'menu.options.controls.bindings'}) end)
            noticeSeen = true
            saveSettings()
        end
        im.SameLine()
        if im.Button("Got it - don't show again") then
            noticeSeen = true
            saveSettings()
        end
    end
    im.End()
    popTheme(nCol, nVar)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------
local function hideOverlayJS()
    pcall(function()
        if uiInstalled and be and be.executeJS then
            be:executeJS("window.__DeathScreen && window.__DeathScreen.hide();")
        end
    end)
end

-- reopen the settings window if WE hid it for the blackout
local function restoreHiddenUI()
    if uiHiddenByTrigger then
        windowOpen[0] = true
        uiHiddenByTrigger = false
    end
end

-- fully tear down an active death screen: clear the black overlay, restore audio
-- and time scale, stop the sting, and bring the window back. Safe to call anytime
-- (each piece no-ops if it wasn't active). Used when the player resets/recovers.
local function cancelDeathScreen()
    hideOverlayJS()
    isShowing = false
    heldActive = false
    activeTimer = 0
    soundBackTimer = 0
    soundBackFadeTimer = 0
    unmuteGame()
    restoreSpeed()
    stopDeathSound()
    blurActive = false
    blurLevel = 0            -- stop the blur (it's per-frame, nothing else to undo)
    recoveryBlurLevel = 0
    recoveryBlurArmed = false
    restoreHiddenUI()
end

local wasWindowOpen = false
-- set true when OUR mod is disabled (detected in onModDeactivated); makes onUpdate a
-- no-op and then unloads us, since a "manual" mod extension isn't auto-unloaded on disable
local deactivated = false
-- Only draw our imgui when we're actually in gameplay -- NOT the main menu and NOT on a
-- loading screen. We QUERY this each frame (the onUiChangedState hook isn't broadcast to
-- arbitrary extensions, so relying on it left the window hidden forever). The game itself
-- treats the main menu as getMissionFilename()=="" (see core_gamestate.sendShowMainMenu),
-- and loadingScreenActive() is true during the load screens.
local function inGameplay()
    local ok, res = pcall(function()
        return getMissionFilename() ~= ""
           and not (core_gamestate and core_gamestate.loadingScreenActive and core_gamestate.loadingScreenActive())
    end)
    return ok and res == true
end

-- "Pass out" trigger: if the car is left upside down (roof-down) long enough, the
-- driver blacks out -- and unlike a crash blackout it HOLDS until you're flipped back
-- over or you reset. The vehicle's up-vector points to world-up (z near 1) when upright
-- and flips to z near -1 on its roof. The pass-out point is user-set as an ANGLE
-- (PASSOUT.angle, degrees from upright): up.z below cos(angle) means "upside down".
-- Come to once rolled back past that + a small hysteresis gap so it doesn't flicker.
local FLIP_HYST = 0.3         -- up.z gap between passing out and coming to (anti-flicker)
local flipTimer = 0
local function readUpZ()
    local z
    pcall(function()
        local veh = be:getPlayerVehicle(0)
        if veh then z = vec3(veh:getDirectionVectorUp()).z end
    end)
    return z
end

-- end a held passout blackout: fade the black back out, regain vision, return audio
local function releasePassout()
    if not heldActive then return end
    heldActive = false
    isShowing  = false
    flipTimer  = 0
    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.release(" ..
            math.floor(PASSOUT.fadeOut[0] * 1000 + 0.5) .. ");")
    end)
    if recoveryBlurPtr[0] then fireRecoveryBlur() end   -- vision returns as the black lifts
    if soundCutActive then                              -- bring the muted audio back (swell if set)
        local fade = soundBackFadePtr[0]
        if fade > 0 then soundBackFadeDur = fade; soundBackFadeTimer = fade else unmuteGame() end
    end
    restoreHiddenUI()
    cooldownTimer = RETRIGGER_COOLDOWN
end

local function updateFlipout(dt)
    local thr = math.cos(PASSOUT.angle[0] * math.pi / 180)   -- up.z below this = "upside down"
    -- holding a passout blackout: release the instant we're flipped back (or lose the vehicle)
    if heldActive then
        local z = readUpZ()
        if (not z) or z > thr + FLIP_HYST then releasePassout() end
        return
    end
    if not (enabledPtr[0] and PASSOUT.on[0]) or isShowing or cooldownTimer > 0 then   -- passout is independent of 'Enable blackout'
        flipTimer = 0
        return
    end
    local z = readUpZ()
    if z and z < thr then
        flipTimer = flipTimer + (dt or 0)
        if flipTimer >= PASSOUT.time[0] then
            flipTimer = 0
            lastReason = "passed out (upside down)"
            triggerDeathScreen(false, nil, true)   -- HELD full blackout until righted / reset
        end
    else
        flipTimer = 0                    -- righted itself (or only on its side): reset
    end
end

local function onUpdate(dtReal)
    if deactivated then
        -- our mod was disabled: stop everything and unload ourselves (deferred here so
        -- we're outside the onModDeactivated hook iteration). Once unloaded, onUpdate
        -- stops being called at all.
        pcall(function() extensions.unload("DeathScreen") end)
        return
    end
    updateDetection(dtReal)
    updateFlipout(dtReal)
    updateDamageVignette(dtReal)
    updateBlur(dtReal)
    -- keep a rolling pre-crash node snapshot while driving fast enough to crash (deform direction);
    -- free when the injury report is off, when parked/slow, or while a death screen is up
    if windowOpen[0] then   -- live-refresh the preset list from the Presets/ folder while the window is open
        presetPollT = presetPollT - (dtReal or 0)
        if presetPollT <= 0 then presetPollT = 1.0; refreshPresets() end
    end
    if INJ.on[0] and INJ.deform[0] and not isShowing and DEF.speed > 8 then   -- low gate: slow door-hit lineups still get a snapshot
        DEF.snapT = DEF.snapT - (dtReal or 0)
        if DEF.snapT <= 0 then DEF.snapT = 0.5; snapshotDeform() end
    end
    if DEF.queryT > 0 then   -- fire the deform query ~0.5s after a crash -> onDeformResult shows the report
        DEF.queryT = DEF.queryT - (dtReal or 0)
        if DEF.queryT <= 0 then DEF.queryT = 0; queryDeform() end
    end

    -- senses-before-vision: bring the game audio back while the screen is still black
    if soundBackTimer > 0 then
        soundBackTimer = soundBackTimer - (dtReal or 0)
        if soundBackTimer <= 0 then
            soundBackTimer = 0
            local fade = soundBackFadePtr[0]
            if fade > 0 then
                soundBackFadeDur = fade   -- swell it back in over this many seconds
                soundBackFadeTimer = fade
            else
                unmuteGame()              -- instant: hear the world again at once
            end
        end
    end
    -- swell the game audio back up from silence to the player's volume
    if soundBackFadeTimer > 0 then
        soundBackFadeTimer = soundBackFadeTimer - (dtReal or 0)
        if soundBackFadeTimer <= 0 then
            soundBackFadeTimer = 0
            unmuteGame()                  -- finished: snap to the exact saved volumes, clear the cut
        else
            setGameVolumeScale(1 - soundBackFadeTimer / soundBackFadeDur)
        end
    end

    if isShowing and not heldActive then   -- a held passout doesn't tick down; it's released by updateFlipout
        activeTimer = activeTimer - (dtReal or 0)
        -- fire the recovery blur right as the black starts lifting (the fade-back phase),
        -- so the world is blurry as it appears and then sharpens = regaining vision
        if recoveryBlurArmed and activeTimer <= fadeOutPtr[0] + 0.25 then
            fireRecoveryBlur()
        end
        if activeTimer <= 0 then
            isShowing = false
            soundBackTimer = 0
            soundBackFadeTimer = 0
            unmuteGame()          -- restore audio when the blackout ends
            cooldownTimer = RETRIGGER_COOLDOWN
            restoreHiddenUI()     -- bring the settings window back if we hid it
        end
    elseif cooldownTimer > 0 and not heldActive then
        cooldownTimer = cooldownTimer - (dtReal or 0)
    end

    if slowmoActive then
        slowmoTimer = slowmoTimer - (dtReal or 0)   -- real time, unaffected by the slow-mo itself
        if slowmoTimer <= 0 then restoreSpeed() end
    end

    if soundFadeTimer > 0 then
        soundFadeTimer = soundFadeTimer - (dtReal or 0)
        if soundFadeTimer <= 0 then
            soundFadeTimer = 0
            pcall(function()
                local snd = currentSoundId and scenetree.findObjectById(currentSoundId)
                if snd then snd:stop(soundFadeAmount) end   -- ease it out at the end
            end)
            currentSoundId = nil
        end
    end

    if inGameplay() then
        installUI()   -- inject the overlay + warm up the message fonts EARLY (self-guards),
                      -- so fonts are fully loaded well before any crash (no first-render swap)
        drawFirstRunNotice()   -- one-time keybind help for fresh installs (self-guards)

        if windowOpen[0] then
            drawSettingsWindow()
        elseif wasWindowOpen and not uiHiddenByTrigger then
            -- Genuine user close (not our auto-hide): flush settings so the window
            -- remembers being closed and any live text edits persist.
            saveSettings()
        end
        wasWindowOpen = windowOpen[0]
    end
end

local function onExtensionLoaded()
    loadSettings()
    refreshPresets()   -- load presets from the Presets/ folder (loadSettings migrated any legacy ones)
    log('I', "DeathScreen", "Death Screen loaded. Bind keys under Options > Controls > Bindings > Death Screen.")
end

local function onExtensionUnloaded()
    cancelDeathScreen()           -- never leave the game muted / slowed / blacked out
    -- remove the injected overlay/DOM + stop the browser animation loop so disabling
    -- the mod leaves no trace (and a re-enable re-injects cleanly)
    pcall(function()
        if be and be.executeJS then
            be:executeJS("window.__DeathScreen && window.__DeathScreen.teardown();")
        end
    end)
    uiInstalled = false
end

-- A "manual"-mode mod extension (required by the game for mod scripts) is NOT auto-
-- unloaded when the mod is disabled, so our effects would keep running with no way to
-- reach the settings. onModDeactivated fires for EVERY mod; our own files are unmounted
-- BEFORE it fires, so if OUR extension file is gone, WE were the one disabled -> stop
-- immediately and flag onUpdate to unload us.
-- true while our own extension file is still mounted. Checks BOTH slash forms because
-- FS:fileExists is inconsistent about the leading slash (see the sound-path code) -- if
-- we only checked one form and it returned false while mounted, we'd wrongly unload
-- ourselves whenever ANY other mod is disabled. If FS is unavailable we assume mounted.
local function ownFileMounted()
    if not FS or not FS.fileExists then return true end
    return FS:fileExists("/lua/ge/extensions/DeathScreen.lua")
        or FS:fileExists("lua/ge/extensions/DeathScreen.lua")
end

local function onModDeactivated()
    pcall(function()
        if not ownFileMounted() then       -- our files unmounted -> WE were disabled
            cancelDeathScreen()
            if be and be.executeJS then
                be:executeJS("window.__DeathScreen && window.__DeathScreen.teardown();")
            end
            uiInstalled = false
            deactivated = true
        end
    end)
end

-- Resetting/recovering the vehicle ends an active death screen: cut the sting,
-- bring the audio + time scale back, clear the black screen, and reopen the
-- window if we hid it. Also resets the tuning peak so the next run reads fresh.
local function onVehicleResetted(vid)
    if vid ~= be:getPlayerVehicleID(0) then return end
    cancelDeathScreen()
    peakDamage = 0
    dmgWindow = {}
    recentDamage = 0
    dmgAccum = 0
    dmgClear()   -- clear the damage flash on reset
    local mo = map and map.objects and map.objects[vid]
    lastDamage = (mo and mo.damage) or 0
end

-- keep the black screen from surviving a level change
local function onClientEndMission()
    cancelDeathScreen()
    lastVid = -1
    dmgWindow = {}
    recentDamage = 0
end

--------------------------------------------------------------------------------
-- PUBLIC API  (called from keybinds in DeathScreen.json)
--------------------------------------------------------------------------------
M.toggleUI = function() windowOpen[0] = not windowOpen[0]; saveSettings() end
M.test     = function() lastReason = "manual test"; triggerDeathScreen(true) end
M.testBlur = function() triggerBlur() end
M.trigger  = function() triggerDeathScreen(true) end   -- lets other mods force it
M.toggleEnabled = function()
    enabledPtr[0] = not enabledPtr[0]
    saveSettings()
    showToast(enabledPtr[0] and "Death Screen: ON" or "Death Screen: OFF",
              enabledPtr[0] and "#2fd94b" or "#c9302c")
end

M.onUpdate = onUpdate
M.onPreRender = renderBlur           -- applies the full-screen crash blur each render frame
M.onExtensionLoaded = onExtensionLoaded
M.onDeformResult = onDeformResult   -- async deform-direction result from the vehicle
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleResetted = onVehicleResetted
M.onClientEndMission = onClientEndMission
M.onModDeactivated = onModDeactivated   -- shut down cleanly when our mod is disabled
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
