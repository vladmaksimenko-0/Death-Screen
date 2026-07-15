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
local TEXT_CAP = 48
local SUB_CAP  = 64

-- imgui-backed setting pointers (these ARE the live settings)
local enabledPtr   = im.BoolPtr(true)     -- GLOBAL master: off = nothing fires at all
local blackoutPtr  = im.BoolPtr(true)     -- the blackout/death-screen itself (vs blur/vignette)
local durationPtr  = im.FloatPtr(4.0)     -- seconds held at full black (the "3-5s")
local fadeInPtr    = im.FloatPtr(0.12)    -- seconds to snap to black
local fadeOutPtr   = im.FloatPtr(0.9)     -- seconds to fade back in
local thresholdPtr = im.FloatPtr(90000)   -- windowed crash damage needed to trigger ("hardcore" gate)
local minSpeedPtr  = im.FloatPtr(5.0)     -- km/h floor (ignores fire/parked damage, slow crushes)
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
local textSizePtr  = im.FloatPtr(88)      -- title font size in px
local textDelayPtr = im.FloatPtr(0.26)    -- seconds after full-black before the message slams in
local colorArr     = im.ArrayFloat(3)     -- title color (RGB 0..1) for the imgui color picker

-- extras
local EVENT_CAP       = 96
local slowmoPtr       = im.BoolPtr(false) -- bullet-time on crash
local slowmoFactorPtr = im.FloatPtr(0.3)  -- time scale during slow-mo (1 = normal)
local slowmoDurPtr    = im.FloatPtr(2.0)  -- real seconds the slow-mo lasts
local soundPtr        = im.BoolPtr(false) -- play a death sting on trigger
local soundVolPtr     = im.FloatPtr(1.0)  -- sting volume
local soundFadePtr    = im.BoolPtr(false) -- fade the sting out near its end instead of a hard cut
local soundFadeDurPtr = im.FloatPtr(1.0)  -- fade-out length (seconds)
local soundEventBuf   = ffi.new("char[?]", EVENT_CAP)
local vignettePtr     = im.BoolPtr(false) -- tinted edge vignette instead of flat black
local vignetteAfterPtr= im.BoolPtr(true)  -- true = vignette appears once the screen is black
local vigFadeInPtr    = im.BoolPtr(true)  -- fade the vignette in (vs snap on)
local vigFadeInDurPtr = im.FloatPtr(0.5)  -- vignette fade-in length (s)
local vigFadeOutPtr   = im.BoolPtr(true)  -- fade the vignette out (vs snap off)
local vigFadeOutDurPtr= im.FloatPtr(0.5)  -- vignette fade-out length (s)
local tintArr         = im.ArrayFloat(3)  -- vignette edge color (RGB 0..1)

-- Damage vignette: FPS-style. ANY crash (not just death-screen ones) flashes a
-- coloured vignette at the screen edges whose strength scales with the hit, then
-- fades away on its own. Independent of the blackout.
local dmgVigPtr       = im.BoolPtr(true)
local dmgVigMaxPtr    = im.FloatPtr(0.7)   -- peak opacity of the flash (0..1)
local dmgVigCoverPtr  = im.FloatPtr(0.7)   -- how far it reaches in from the edges at full strength (0..1)
local dmgVigSoftPtr   = im.FloatPtr(0.6)   -- gradient softness: how wide/feathered the edge fade is (0..1)
local dmgVigFullPtr   = im.FloatPtr(40000) -- damage that pushes it to full strength
local dmgVigFadePtr   = im.FloatPtr(1.5)   -- seconds to fade back to nothing
local dmgVigColorArr  = im.ArrayFloat(3)   -- edge color (RGB 0..1)

-- Crash blur: a full-screen gaussian blur on crash (the game's menu-background blur).
local blurPtr         = im.BoolPtr(true)
local blurAmtPtr      = im.FloatPtr(0.8)   -- how strong the blur is (0..1)
local blurDurPtr      = im.FloatPtr(1.2)   -- how long it holds at full before easing off (s)
local blurTrigPtr     = im.FloatPtr(30000) -- crash force needed to set the blur off (its own, lower threshold)
local blurFadeInPtr   = im.BoolPtr(true)   -- ease the blur in (vs snap on)
local blurFadeInDurPtr= im.FloatPtr(0.4)   -- blur fade-in length (s)
local blurFadeOutPtr  = im.BoolPtr(true)   -- ease the blur out (vs snap off)
local blurFadeOutDurPtr=im.FloatPtr(0.6)   -- blur fade-out length (s)
-- Recovery blur: after a blackout, blur the screen as it fades back in and clear it, as
-- if you're regaining your vision. Reuses the same full-screen blur as the crash blur.
local recoveryBlurPtr    = im.BoolPtr(true)   -- blur the screen as the blackout lifts
local recoveryBlurAmtPtr = im.FloatPtr(0.8)   -- how strong that blur starts (0..1)
local recoveryBlurDurPtr = im.FloatPtr(1.5)   -- how long it takes to clear (s)

local DEFAULT_COLOR   = {0.757, 0.071, 0.122}  -- #c1121f (GTA-ish red)
local DEFAULT_TINT    = {0.45, 0.02, 0.02}     -- dark-red vignette edges
local DEFAULT_DMGCOLOR= {0.75, 0.04, 0.04}     -- FPS damage red

local windowOpen   = im.BoolPtr(true)     -- the settings window (open on first load so it's found)
local hideUIPtr    = im.BoolPtr(true)     -- hide this window while the death screen is showing

-- rolling damage window
local WINDOW_SEC   = 0.8

local function setBuf(buf, cap, s)
    s = tostring(s or "")
    if #s > cap - 1 then s = s:sub(1, cap - 1) end
    ffi.copy(buf, s)
end
setBuf(textBuf, TEXT_CAP, "WASTED")
setBuf(subBuf,  SUB_CAP,  "")
colorArr[0] = im.Float(DEFAULT_COLOR[1])  -- default #c1121f (GTA-ish red)
colorArr[1] = im.Float(DEFAULT_COLOR[2])
colorArr[2] = im.Float(DEFAULT_COLOR[3])
setBuf(soundEventBuf, EVENT_CAP, "")   -- empty by default; user picks their own sound
tintArr[0] = im.Float(DEFAULT_TINT[1])   -- dark-red vignette edges
tintArr[1] = im.Float(DEFAULT_TINT[2])
tintArr[2] = im.Float(DEFAULT_TINT[3])
dmgVigColorArr[0] = im.Float(DEFAULT_DMGCOLOR[1])
dmgVigColorArr[1] = im.Float(DEFAULT_DMGCOLOR[2])
dmgVigColorArr[2] = im.Float(DEFAULT_DMGCOLOR[3])

-- which collapsible sections are expanded, remembered across restarts. Keyed by
-- the section label; `section()` fills in defaults on first run and flips
-- sectionDirty when the user opens/closes one so we persist it.
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
    t.dmgVig        = dmgVigPtr[0]
    t.dmgVigMax     = dmgVigMaxPtr[0]
    t.dmgVigCover   = dmgVigCoverPtr[0]
    t.dmgVigSoft    = dmgVigSoftPtr[0]
    t.dmgVigFull    = dmgVigFullPtr[0]
    t.dmgVigFade    = dmgVigFadePtr[0]
    t.dmgVigColor   = { tonumber(dmgVigColorArr[0]), tonumber(dmgVigColorArr[1]), tonumber(dmgVigColorArr[2]) }
    t.blur          = blurPtr[0]
    t.blurAmt       = blurAmtPtr[0]
    t.blurDur       = blurDurPtr[0]
    t.blurTrig      = blurTrigPtr[0]
    t.blurFadeIn    = blurFadeInPtr[0]
    t.blurFadeInDur = blurFadeInDurPtr[0]
    t.blurFadeOut   = blurFadeOutPtr[0]
    t.blurFadeOutDur= blurFadeOutDurPtr[0]
    t.recoveryBlur    = recoveryBlurPtr[0]
    t.recoveryBlurAmt = recoveryBlurAmtPtr[0]
    t.recoveryBlurDur = recoveryBlurDurPtr[0]
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
            slowmo      = slowmoPtr[0],
            slowmoFactor= slowmoFactorPtr[0],
            slowmoDur   = slowmoDurPtr[0],
            sound       = soundPtr[0],
            soundVol    = soundVolPtr[0],
            soundFade   = soundFadePtr[0],
            soundFadeDur= soundFadeDurPtr[0],
            soundEvent  = ffi.string(soundEventBuf),
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
    if s.dmgVig     ~= nil then dmgVigPtr[0]     = (s.dmgVig == true) end
    if s.dmgVigMax  ~= nil then dmgVigMaxPtr[0]  = math.max(0.1, math.min(1.0, tonumber(s.dmgVigMax) or 0.7)) end
    if s.dmgVigCover~= nil then dmgVigCoverPtr[0]= math.max(0.0, math.min(1.0, tonumber(s.dmgVigCover) or 0.7)) end
    if s.dmgVigSoft ~= nil then dmgVigSoftPtr[0] = math.max(0.0, math.min(1.0, tonumber(s.dmgVigSoft) or 0.6)) end
    if s.dmgVigFull ~= nil then dmgVigFullPtr[0] = math.max(1000.0, math.min(300000.0, tonumber(s.dmgVigFull) or 40000)) end
    if s.dmgVigFade ~= nil then dmgVigFadePtr[0] = math.max(0.2, math.min(5.0, tonumber(s.dmgVigFade) or 1.5)) end
    if type(s.dmgVigColor) == "table" and #s.dmgVigColor >= 3 then
        for i = 0, 2 do
            local v = tonumber(s.dmgVigColor[i + 1]) or 0
            dmgVigColorArr[i] = im.Float(math.max(0.0, math.min(1.0, v)))
        end
    end
    if s.blur     ~= nil then blurPtr[0]     = (s.blur == true) end
    if s.blurAmt  ~= nil then blurAmtPtr[0]  = math.max(0.05, math.min(1.0, tonumber(s.blurAmt) or 0.8)) end
    if s.blurDur  ~= nil then blurDurPtr[0]  = math.max(0.1, math.min(8.0, tonumber(s.blurDur) or 1.2)) end
    if s.blurTrig ~= nil then blurTrigPtr[0] = math.max(1000.0, math.min(300000.0, tonumber(s.blurTrig) or 30000)) end
    if s.blurFadeIn     ~= nil then blurFadeInPtr[0]     = (s.blurFadeIn == true) end
    if s.blurFadeInDur  ~= nil then blurFadeInDurPtr[0]  = math.max(0.0, math.min(5.0, tonumber(s.blurFadeInDur) or 0.4)) end
    if s.blurFadeOut    ~= nil then blurFadeOutPtr[0]    = (s.blurFadeOut == true) end
    if s.blurFadeOutDur ~= nil then blurFadeOutDurPtr[0] = math.max(0.0, math.min(5.0, tonumber(s.blurFadeOutDur) or 0.6)) end
    if s.recoveryBlur    ~= nil then recoveryBlurPtr[0]    = (s.recoveryBlur == true) end
    if s.recoveryBlurAmt ~= nil then recoveryBlurAmtPtr[0] = math.max(0.05, math.min(1.0, tonumber(s.recoveryBlurAmt) or 0.8)) end
    if s.recoveryBlurDur ~= nil then recoveryBlurDurPtr[0] = math.max(0.1, math.min(8.0, tonumber(s.recoveryBlurDur) or 1.5)) end
    if s.windowOpen ~= nil then windowOpen[0]  = (s.windowOpen == true) end
    if s.hideUI     ~= nil then hideUIPtr[0]   = (s.hideUI == true) end
    if s.noticeSeen ~= nil then noticeSeen     = (s.noticeSeen == true) end
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
        if s.threshold ~= nil then thresholdPtr[0] = math.max(500.0, math.min(300000.0, tonumber(s.threshold) or 90000)) end
        if s.minSpeed  ~= nil then minSpeedPtr[0]  = math.max(0.0, math.min(150.0, tonumber(s.minSpeed) or 5.0)) end
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
        if s.slowmo       ~= nil then slowmoPtr[0]       = (s.slowmo == true) end
        if s.slowmoFactor ~= nil then slowmoFactorPtr[0] = math.max(0.05, math.min(1.0, tonumber(s.slowmoFactor) or 0.3)) end
        if s.slowmoDur    ~= nil then slowmoDurPtr[0]    = math.max(0.0, math.min(10.0, tonumber(s.slowmoDur) or 2.0)) end
        if s.sound        ~= nil then soundPtr[0]        = (s.sound == true) end
        if s.soundVol     ~= nil then soundVolPtr[0]     = math.max(0.0, math.min(3.0, tonumber(s.soundVol) or 1.0)) end
        if s.soundFade    ~= nil then soundFadePtr[0]    = (s.soundFade == true) end
        if s.soundFadeDur ~= nil then soundFadeDurPtr[0] = math.max(0.1, math.min(10.0, tonumber(s.soundFadeDur) or 1.0)) end
        if s.soundEvent   ~= nil then setBuf(soundEventBuf, EVENT_CAP, s.soundEvent) end
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

--------------------------------------------------------------------------------
-- BLACKOUT + TOAST OVERLAY  (injected once, then driven by JS calls)
--------------------------------------------------------------------------------
local uiInstalled = false

local OVERLAY_JS = [==[
(function(){
  if(window.__DeathScreen) return;
  var ds = window.__DeathScreen = {};
  var overlay=null, vig=null, txt=null, sub=null, dmgVig=null, timers=[], toastEl=null, toastT=null;
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
    overlay.appendChild(vig); overlay.appendChild(txt); overlay.appendChild(sub);
    document.body.appendChild(overlay);
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
    txt.textContent=o.text||''; txt.style.color=o.textColor||'#c1121f';
    if(o.textSize){ txt.style.fontSize=o.textSize+'px'; }
    sub.textContent=o.sub||'';
    txt.style.transition='none'; sub.style.transition='none';
    txt.style.opacity='0'; sub.style.opacity='0';
    txt.style.transform='scale(1.18)'; sub.style.transform='translateY(8px)';
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
      timers.push(setTimeout(function(){ vig.style.transition='opacity '+(vfoutMs/1000)+'s ease'; vig.style.opacity='0'; }, visEnd-vfoutMs));
    }
    if(o.text||o.sub){
      var delay=fadeIn+(o.textDelayMs==null?260:o.textDelayMs);  /* GTA-style beat after black */
      timers.push(setTimeout(function(){
        txt.style.transition='opacity .45s ease, transform .6s cubic-bezier(.16,.9,.24,1)';
        sub.style.transition='opacity .5s ease .12s, transform .5s ease .12s';
        if(o.text){ txt.style.opacity='1'; txt.style.transform='scale(1)'; }
        if(o.sub){ sub.style.opacity='.9'; sub.style.transform='translateY(0)'; }
      }, delay));
    }
    timers.push(setTimeout(function(){
      overlay.style.transition='opacity '+(fadeOut/1000)+'s ease';
      overlay.style.opacity='0';   /* vignette already handled its own fade-out above */
      txt.style.opacity='0'; sub.style.opacity='0';
    }, fadeIn+hold));
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
    [overlay,dmgVig,toastEl].forEach(function(el){ if(el&&el.parentNode){ el.parentNode.removeChild(el); } });
    overlay=vig=txt=sub=dmgVig=toastEl=null;
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

-- damage-vignette state (the swell/fade animation itself runs in the browser)
local frameDamageDelta = 0 -- new damage this frame (set by updateDetection)
local dmgAccum = 0         -- damage gathered since the last hit was fed to the UI
local dmgVigThrottle = 0   -- rate-limit for feeding hits to the browser animation
local dmgVigWasOn = false  -- so we clear the effect once when it's turned off

-- Sound cutoff: mute the gameplay audio channels during the blackout and
-- restore the player's volumes after. We mute every GAME channel -- including
-- 'Other', where misc vehicle sounds like the post-crash hazard-blinker tick
-- route (that was leaking through before) -- but deliberately DO NOT touch
-- 'Gui'/'Ui', because our death sting ('AudioGui' playOnce) routes there; that
-- lets the sting be heard over the silence. ('Master' is the parent -- muting it
-- would kill the sting too, so we mute the children individually instead.)
local MUTE_CHANNELS = {
    "AudioChannelPower", "AudioChannelForcedInduction", "AudioChannelTransmission",
    "AudioChannelSuspension", "AudioChannelSurface", "AudioChannelCollision",
    "AudioChannelAero", "AudioChannelEnvironment", "AudioChannelMusic",
    "AudioChannelOther", "AudioChannelEffects", "AudioChannelIntercom", "AudioChannelLfe",
}
local soundCutActive = false
local savedVolumes = {}
local function muteGame()
    if soundCutActive then return end
    pcall(function()
        if Engine and Engine.Audio then
            for _, ch in ipairs(MUTE_CHANNELS) do
                savedVolumes[ch] = Engine.Audio.getChannelVolume(ch, false)
                Engine.Audio.setChannelVolume(ch, 0.0)
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
    blurHold   = blurDurPtr[0]
    -- snap straight to full if fade-in is off (or zero-length)
    if blurFadeInPtr[0] and blurFadeInDurPtr[0] > 0 then
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
        blurLevel = blurLevel + dt / math.max(0.01, blurFadeInDurPtr[0])
        if blurLevel >= 1 then blurLevel = 1; blurPhase = "hold" end
    elseif blurPhase == "hold" then
        blurHold = blurHold - dt
        if blurHold <= 0 then
            blurPhase = "out"
            -- snap straight off if fade-out is disabled (or zero-length)
            if not (blurFadeOutPtr[0] and blurFadeOutDurPtr[0] > 0) then
                blurLevel = 0; blurActive = false
            end
        end
    else -- "out"
        blurLevel = blurLevel - dt / math.max(0.01, blurFadeOutDurPtr[0])
        if blurLevel <= 0 then blurLevel = 0; blurActive = false end
    end
end

-- applied every render frame: blur the whole screen at (ramp * strength). Both the
-- crash blur and the recovery blur feed this; we draw whichever is currently stronger.
-- Intensity goes in RGB because the blend uses the mask's .r channel (see above).
local function renderBlur()
    local crashAmt = (blurLevel > 0)        and (blurLevel * blurAmtPtr[0])                 or 0
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
--      played 2D via Engine.Audio.playOnce on the UI channel. This is the way to
--      use your OWN sound, and it also plays THROUGH "Cut game sound" (the UI
--      channel isn't muted).
--   2. A UI FMOD event ("event:>UI>...") -> same GE path, also survives the cut.
--   3. Any other FMOD event ("event:>Vehicle>Failures>engine_explode",
--      "event:>Destruction>...") is a spatial VEHICLE sound -> the game plays it
--      inside the vehicle's Lua via sounds.playSoundOnceFollowNode; GE playOnce
--      does nothing for these. We route it to the vehicle's reference node (0).
--      (These are game sounds, so they DO get muted by the sound cut.)
local function playDeathSound()
    pcall(function()
        local ev = ffi.string(soundEventBuf)
        if ev == "" then return end
        local vol = soundVolPtr[0]

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
local function triggerDeathScreen(force, crashForce)
    if isShowing then return end
    if not force and (not enabledPtr[0] or not blackoutPtr[0]) then return end

    installUI()
    if not uiInstalled then return end

    -- Optionally scale the blackout with how hard the crash was (Kyle's idea):
    -- at the trigger threshold -> "Min blackout" length + "Min darkness"; at
    -- "Full-blast force" (and above) -> the full "Blackout length" + "Darkness".
    -- A manual test uses the full one.
    local holdSec = durationPtr[0]
    local darkVal = opacityPtr[0]
    if scalePtr[0] and crashForce then
        local thr  = thresholdPtr[0]
        local full = math.max(thr + 1, scaleFullPtr[0])
        local t = (crashForce - thr) / (full - thr)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local minDur = math.min(scaleMinPtr[0], durationPtr[0])
        holdSec = minDur + (durationPtr[0] - minDur) * t
        local minDark = math.min(scaleMinDarkPtr[0], opacityPtr[0])
        darkVal = minDark + (opacityPtr[0] - minDark) * t
    end

    local fadeInMs  = math.floor(fadeInPtr[0]  * 1000 + 0.5)
    local holdMs    = math.floor(holdSec * 1000 + 0.5)
    local fadeOutMs = math.floor(fadeOutPtr[0] * 1000 + 0.5)

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
    if showTextPtr[0] then
        opts = opts .. ",text:" .. jsStr(ffi.string(textBuf))
        opts = opts .. ",textColor:" .. jsStr(hexOf(colorArr))
        opts = opts .. ",textSize:" .. math.floor(textSizePtr[0] + 0.5)
        opts = opts .. ",textDelayMs:" .. math.floor(textDelayPtr[0] * 1000 + 0.5)
        local sub = ffi.string(subBuf)
        if sub ~= "" then opts = opts .. ",sub:" .. jsStr(sub) end
    end
    opts = opts .. "}"

    pcall(function()
        be:executeJS("window.__DeathScreen && window.__DeathScreen.show(" .. opts .. ");")
    end)

    isShowing   = true
    activeTimer = (fadeInMs + holdMs + fadeOutMs) / 1000 + 0.25
    if hideUIPtr[0] and windowOpen[0] then   -- get the settings window out of the shot
        windowOpen[0] = false
        uiHiddenByTrigger = true
    end
    soundBackFadeTimer = 0
    if soundCutPtr[0] then
        muteGame()
        -- optionally bring the world back before the screen clears (hear before you see)
        soundBackTimer = soundBackPtr[0] and math.max(0.05, soundBackAtPtr[0]) or 0
    else
        soundBackTimer = 0
    end
    if soundPtr[0] then playDeathSound() end
    if slowmoPtr[0] then
        setSimSpeed(slowmoFactorPtr[0])
        slowmoActive = true
        slowmoTimer  = slowmoDurPtr[0]
    end
    armRecoveryBlur()   -- fires when the black starts lifting (handled in onUpdate)
    -- clear the window so the same crash can't re-trigger the instant the cooldown ends
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
            jsStr(hexOf(dmgVigColorArr)) .. "," .. math.floor(dmgVigFadePtr[0] * 1000 + 0.5) .. "," ..
            string.format("%.3f", cap) .. "," .. string.format("%.3f", dmgVigSoftPtr[0]) .. ");")
    end)
end

local function dmgClear()
    if not uiInstalled then return end
    pcall(function() be:executeJS("window.__DeathScreen && window.__DeathScreen.clearDamage();") end)
end

local function updateDamageVignette(dt)
    if not (enabledPtr[0] and dmgVigPtr[0]) then   -- global master + own toggle
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
            local cap = dmgVigMaxPtr[0]
            local hitP = math.min(1, dmgAccum / math.max(1, dmgVigFullPtr[0]))
            sendDamageHit(hitP * cap, dmgVigCoverPtr[0], cap)
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

    if delta > 0 then
        frameDamageDelta = delta     -- feed the damage vignette
        dmgWindow[#dmgWindow + 1] = { t = uiClock, d = delta, s = speed }
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
    if enabledPtr[0] and blurPtr[0] and recentDamage >= blurTrigPtr[0] then
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
        if impactSpeed >= minSpeedPtr[0] then
            -- global master + the blackout's own toggle + re-trigger cooldown
            if enabledPtr[0] and blackoutPtr[0] and cooldownTimer <= 0 then
                lastReason = string.format("%.0f dmg @ %d km/h", recentDamage, math.floor(impactSpeed + 0.5))
                triggerDeathScreen(false, recentDamage)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- SETTINGS WINDOW  (imgui)
--------------------------------------------------------------------------------
local THEME = {
    { im.Col_WindowBg,         im.ImVec4(0.06, 0.03, 0.03, 0.97) },
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
        if checkbox("Slow-motion on crash", slowmoPtr,
            "Briefly slows the game down when you crash, for a dramatic replay.") then dirty = true end
        if slowmoPtr[0] then
            if slider("smf", "Game speed", slowmoFactorPtr, 0.05, 1.0, "%.2f",
                "How slow it goes. 0.30 = 30 percent speed. Lower is more dramatic.") then dirty = true end
            if slider("smd", "Slow-mo length", slowmoDurPtr, 0.0, 10.0, "%.1f s",
                "How long the slow-motion lasts (real seconds).") then dirty = true end
        end

        if checkbox("Crash blur", blurPtr,
            "Blurs the whole screen for a moment on a crash, like being dazed. Uses the game's own full-screen blur. Turn off the death screen to see it clearly, or use the Test button.") then dirty = true end
        if blurPtr[0] then
            if slider("blura", "Blur strength", blurAmtPtr, 0.05, 1.0, "%.2f",
                "How blurry it gets. Lower = subtler, 1.0 = full menu-grade blur.") then dirty = true end
            if slider("blurd", "Blur length", blurDurPtr, 0.1, 8.0, "%.1f s",
                "How long the blur holds at full before easing off (not counting the fades).") then dirty = true end
            if checkbox("Fade in##blur", blurFadeInPtr,
                "Ease the blur in. Off = it snaps on instantly.") then dirty = true end
            if blurFadeInPtr[0] then
                if slider("blurfin", "Fade in time", blurFadeInDurPtr, 0.0, 5.0, "%.1f s",
                    "How long the blur takes to ramp in.") then dirty = true end
            end
            if checkbox("Fade out##blur", blurFadeOutPtr,
                "Ease the blur out. Off = it snaps off instantly.") then dirty = true end
            if blurFadeOutPtr[0] then
                if slider("blurfout", "Fade out time", blurFadeOutDurPtr, 0.0, 5.0, "%.1f s",
                    "How long the blur takes to ramp out after the hold.") then dirty = true end
            end
            if slider("blurt", "Trigger at damage", blurTrigPtr, 1000.0, 300000.0, "%.0f",
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
            helpMarker("Your OWN sound: drop a .ogg into the mod's settings/DeathScreen folder and type just its name, e.g.  hit.ogg  -- it plays even with 'Cut game sound' on.")
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
        if checkbox("Enable damage vignette", dmgVigPtr,
            "FPS-style: ANY crash (even a light one, no death screen needed) flashes a coloured vignette at the screen edges that fades away. The bigger the hit, the stronger it flashes.") then dirty = true end
        if dmgVigPtr[0] then
            if im.ColorEdit3("Colour", dmgVigColorArr) then dirty = true end
            im.SameLine()
            if im.Button("Reset##dmgcol") then
                dmgVigColorArr[0] = im.Float(DEFAULT_DMGCOLOR[1])
                dmgVigColorArr[1] = im.Float(DEFAULT_DMGCOLOR[2])
                dmgVigColorArr[2] = im.Float(DEFAULT_DMGCOLOR[3])
                dirty = true
            end
            if slider("dvmax", "Max strength", dmgVigMaxPtr, 0.1, 1.0, "%.2f",
                "How opaque the flash can get on the hardest hit. Lower = subtler. Set to 1.0 (with Coverage 1.0) so the biggest crashes reach fully solid.") then dirty = true end
            if slider("dvcover", "Coverage", dmgVigCoverPtr, 0.0, 1.0, "%.2f",
                "How far it reaches in from the edges on the hardest hit. 0 = a thin rim, 1 = closes right in to the centre. Smaller hits reach in proportionally less. For a 'knocked out' look, set Coverage AND Max strength to 1.0 with a black colour -- hard crashes then close all the way to solid black, while light ones stay a partial rim.") then dirty = true end
            if slider("dvsoft", "Softness", dmgVigSoftPtr, 0.0, 1.0, "%.2f",
                "How gradual the edge fade is. Low = a tight, defined ring. High = the red keeps deepening all the way to the corners, reaching full only at the very edge, so there's NO visible line where it starts fading -- a smooth, edgeless tint. Push toward 1.0 if you can still see where the fade begins.") then dirty = true end
            if slider("dvfull", "Full at damage", dmgVigFullPtr, 1000.0, 300000.0, "%.0f",
                "Crash force that flashes it to full strength. Lower = even small hits flash strongly. (Uses the same 'crash force' as the readout above.)") then dirty = true end
            if slider("dvfade", "Fade time", dmgVigFadePtr, 0.2, 5.0, "%.1f s",
                "How long the flash takes to fade away after a hit.") then dirty = true end
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
        if section("Blackout", true) then
            if checkbox("Enable blackout", blackoutPtr,
                "Black out the screen after a hard crash (the core death-screen effect). Turn this OFF to keep only the other effects -- e.g. crash blur and the damage vignette -- with no blackout. (The global 'Enabled' switch above still has to be on.)") then dirty = true end
            if slider("dur",  "Blackout length", durationPtr, 0.5, 15.0, "%.1f s",
                "How long the screen stays fully black.") then dirty = true end
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
            if slider("sev", "Crash severity", thresholdPtr, 500.0, 200000.0, "%.0f",
                "How hard a crash has to be to trigger. Higher = only bigger crashes count. Use the readout below to tune it.") then dirty = true end
            if slider("spd", "Min speed", minSpeedPtr, 0.0, 60.0, "%.0f km/h",
                "Won't trigger unless you were going at least this fast. Blocks false alarms from fire or slow crushing.") then dirty = true end
            im.Dummy(im.ImVec2(0, 3))
            im.Text(string.format("Current crash force: %.0f", recentDamage))
            im.Text(string.format("Biggest so far: %.0f", peakDamage))
            im.SameLine()
            if im.Button("Reset##peak") then peakDamage = 0 end
            helpMarker("Do a light tap and note the biggest number, then a real crash and note that. Set 'Crash severity' between the two. Clears when you reset your vehicle.")
        end

        --------------------------------------------------------------------------
        if section("Message", false) then
            if checkbox("Show message", showTextPtr,
                "Show a big centered message (like GTA's WASTED) once the screen is black.") then dirty = true end
            if showTextPtr[0] then
                if im.InputText("Title", textBuf, TEXT_CAP) then dirty = true end
                if im.InputText("Subtitle", subBuf, SUB_CAP) then dirty = true end
                if im.ColorEdit3("Text color", colorArr) then dirty = true end
                im.SameLine()
                if im.Button("Reset##color") then
                    colorArr[0] = im.Float(DEFAULT_COLOR[1])
                    colorArr[1] = im.Float(DEFAULT_COLOR[2])
                    colorArr[2] = im.Float(DEFAULT_COLOR[3])
                    dirty = true
                end
                if slider("tsize", "Text size", textSizePtr, 20.0, 240.0, "%.0f px",
                    "Font size of the title.") then dirty = true end
                if slider("tdelay", "Text delay", textDelayPtr, 0.0, 3.0, "%.2f s",
                    "Waits this long after the screen is black, then the text slams in (GTA-style).") then dirty = true end
            end
        end

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
local function onUpdate(dtReal)
    if deactivated then
        -- our mod was disabled: stop everything and unload ourselves (deferred here so
        -- we're outside the onModDeactivated hook iteration). Once unloaded, onUpdate
        -- stops being called at all.
        pcall(function() extensions.unload("DeathScreen") end)
        return
    end
    updateDetection(dtReal)
    updateDamageVignette(dtReal)
    updateBlur(dtReal)

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

    if isShowing then
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
    elseif cooldownTimer > 0 then
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
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleResetted = onVehicleResetted
M.onClientEndMission = onClientEndMission
M.onModDeactivated = onModDeactivated   -- shut down cleanly when our mod is disabled
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
