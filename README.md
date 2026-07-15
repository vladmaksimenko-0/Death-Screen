# Death Screen

A client-side BeamNG.drive mod that blacks out your screen for a moment when you crash hard - a cinematic knockout, GTA "WASTED"-style - then brings you back to your senses. Purely visual, and every part is tunable in-game.

Works in singleplayer freeroam and in multiplayer (no server-side setup needed).

## Features

- **Severity-based blackout** on a hard crash - reads how much damage energy your car dumps in a split second, so brushing a wall at speed no longer sets it off.
- **Scales with the crash** (optional) - bigger hits get a longer, darker blackout.
- **Crash blur** - the whole screen goes blurry like being dazed.
- **Blur on recovery** - your vision comes back blurry and sharpens as the black lifts.
- **Damage vignette** - an FPS-style coloured edge flash on *any* crash, even light ones.
- **Cut game sound** during the blackout, with the world's audio returning *before* your vision does.
- Optional **slow-motion**, a **custom death sound**, and a **GTA-style on-screen message**.
- One **global master switch**, per-effect toggles, and a **reset all to defaults** button.
- Full in-game settings window with hover tooltips and right-click-to-type sliders.

## Install

**From the BeamNG repository (recommended):** search for **Death Screen** in-game under *Repository*, or on the BeamNG resources site, and install with one click.

**Manual:** drop the mod's `.zip` into `%localappdata%\BeamNG\BeamNG.drive\current\mods` It's client-side, so it also works in multiplayer - just install it as a client mod.

## Controls

Bind these under **Options > Controls > Bindings > Death Screen** (they ship unbound so they never clash with your existing keys):

| Action | What it does |
| --- | --- |
| Death Screen: Settings | Open/close the settings window |
| Death Screen: On/Off | Toggle the whole mod on or off (quick toast) |
| Death Screen: Test | Trigger the blackout to preview / tune it |
| Death Screen: Test Blur | Trigger the crash blur to preview it |

On a fresh install the settings window opens on its own, and a small centered popup explains how to bind a key to reopen it later (with an **Open controls** button that jumps straight to the bindings page). Both disappear the moment you bind a key. Once you close the window it stays closed and remembers that - so the keybind is how you get it back.

## Settings

The window is split into collapsible sections. Hover the **(?)** on any option for an explanation, right-click any slider to type an exact value, and use **Reset all to defaults** (bottom of the window) to undo your tuning. Section layout and window size are remembered across restarts.

### Top level

| Setting | Default | What it does |
| --- | --- | --- |
| Enabled | on | **Global master.** Off = nothing happens on a crash at all (no blackout, blur, or vignette). |
| Hide window during death screen | on | Auto-closes the settings window while the death screen plays, then reopens it after. |

### Blackout

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| Enable blackout | on | - | The blackout itself. Off = keep the other effects with no black screen. |
| Blackout length | 4.0 s | 0.5 - 15 | How long it stays fully black. |
| Fade to black | 0.12 s | 0 - 3 | How fast it goes black on impact (0 = instant). |
| Fade back in | 0.9 s | 0 - 5 | How gently it fades back afterwards. |
| Darkness | 1.0 | 0.3 - 1.0 | 1.0 = fully black; lower = tinted. |
| Scale with crash force | off | - | Bigger crashes get a longer and darker blackout (the values above become the maximums). |
| &nbsp;&nbsp;Min blackout | 1.5 s | 0.1 - 15 | Shortest blackout, for a crash that just barely triggers. |
| &nbsp;&nbsp;Min darkness | 0.5 | 0.1 - 1.0 | Lightest darkness for a barely-triggering crash. |
| &nbsp;&nbsp;Full-blast force | 200000 | 1000 - 500000 | Crash force at/above which you get the full blackout. |
| Cut game sound | on | - | Mutes all game audio (engine, tyres, crash, hazards) while black, then restores it. |
| &nbsp;&nbsp;Hear game before you recover | on | - | Brings the world's audio back before the screen clears - hearing returns before sight. |
| &nbsp;&nbsp;Audio returns after | 1.5 s | 0.1 - 8 | How long after the crash the audio comes back (while still black). |
| &nbsp;&nbsp;Audio fade-in | 0.8 s | 0 - 5 | How long the audio takes to swell back in (0 = snaps on). |

### When it triggers

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| Crash severity | 90000 | 500 - 200000 | How hard a crash must be to trigger - the "hardcore" gate. Use the live readout to tune it. |
| Min speed | 5 km/h | 0 - 60 | Won't trigger unless you were going at least this fast (blocks fire / slow-crush). |

The window shows a **live damage readout** and a **peak**. To dial the threshold in: do a light tap and note the peak, then a real crash and note that peak, and set **Crash severity** between the two. Hit **Reset peak** between tests.

### Message (off by default)

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| Show message | off | - | GTA-style text that slams in after the screen goes black. |
| Title / Subtitle | "WASTED" / - | - | The message text. |
| Text color | red (#c1121f) | - | Full colour picker for the title (with a Reset). |
| Text size | 88 px | 20 - 240 | Title font size. |
| Text delay | 0.26 s | 0 - 3 | How long after full-black before the message slams in. |

### Effects

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| Crash blur | on | - | Blurs the **whole screen** for a moment on a crash, like being dazed (uses the game's own full-screen blur). Fires on its own damage threshold, so it works even with the blackout off. |
| &nbsp;&nbsp;Blur strength | 0.8 | 0.05 - 1.0 | How blurry it gets. |
| &nbsp;&nbsp;Blur length | 1.2 s | 0.1 - 8 | How long it holds at full before easing off. |
| &nbsp;&nbsp;Fade in / Fade in time | on / 0.4 s | 0 - 5 | Ease the blur in (vs snap on). |
| &nbsp;&nbsp;Fade out / Fade out time | on / 0.6 s | 0 - 5 | Ease the blur out (vs snap off). |
| &nbsp;&nbsp;Trigger at damage | 30000 | 1000 - 300000 | Crash force that sets the blur off (its own, lower threshold). |
| Blur on recovery | on | - | After a blackout, the screen fades back in blurry and then sharpens, like regaining your vision. Fires as the black lifts. |
| &nbsp;&nbsp;Recovery strength | 0.8 | 0.05 - 1.0 | How blurry your vision is when it first comes back. |
| &nbsp;&nbsp;Clear time | 1.5 s | 0.1 - 8 | How long it takes to sharpen. |
| Slow-motion on crash | off | - | Bullet-time: slows the game, then eases back. (May be overridden by the server in multiplayer.) |
| &nbsp;&nbsp;Game speed | 0.3 | 0.05 - 1.0 | Time scale during slow-mo (0.30 = 30% speed). |
| &nbsp;&nbsp;Slow-mo length | 2.0 s | 0 - 10 | How long it lasts (real seconds). |
| Death sound | off | - | Plays a one-shot sting the instant it triggers (see below). Stops if you reset mid-playback. |
| &nbsp;&nbsp;Volume | 1.0 | 0 - 3 | Sting volume (1.0 = normal). |
| &nbsp;&nbsp;Fade out sound / Fade length | off / 1.0 s | 0.1 - 10 | Ease the sting out near its end instead of a hard cut. |
| Edge vignette | off | - | Tints the blackout's edges (default dark red) instead of flat black. Its own layer with independent timing. |
| &nbsp;&nbsp;Appear after blackout | on | - | Wait for full black before it comes in (vs come in with it). |
| &nbsp;&nbsp;Fade in / Fade in time | on / 0.5 s | 0 - 5 | Fade the vignette in (vs snap on). |
| &nbsp;&nbsp;Fade out / Fade out time | on / 0.5 s | 0 - 5 | Fade the vignette out (vs snap off). |

**Adding your own death sound:** drop a `.ogg` (or `.wav`) into `.../BeamNG.drive/<version>/settings/DeathScreen/` and type just the filename, e.g. `hit.ogg`. It plays on the UI channel, so it's **not** muted by "Cut game sound" - you can cut all game audio and hear only your sting. `.ogg` is the safest format; the file must live inside the BeamNG userfolder (arbitrary paths like `C:\Music\...` won't load).

### Damage vignette (any crash)

Separate from the death screen: an FPS-style damage indicator. *Any* crash flashes a coloured vignette at the screen edges that fades away on its own - the harder the hit, the stronger it flashes. It works even with the blackout disabled.

| Setting | Default | Range | What it does |
| --- | --- | --- | --- |
| Enable damage vignette | on | - | Turns it on. |
| Colour | red | - | Edge colour (with a Reset). |
| Max strength | 0.70 | 0.1 - 1.0 | How opaque it gets on the hardest hit. |
| Coverage | 0.70 | 0 - 1.0 | How far it reaches in from the edges - 0 = a thin rim, 1 = closes in toward the centre. |
| Softness | 0.60 | 0 - 1.0 | How gradual the edge fade is. High = no visible line where it starts (smoothstep, edgeless). |
| Full at damage | 40000 | 1000 - 300000 | Crash force that flashes it to full strength. |
| Fade time | 1.5 s | 0.2 - 5.0 | How long the flash takes to fade away. |

**"Knocked out" look:** set **Coverage** and **Max strength** both to 1.0 with a black **Colour** - hard crashes then close all the way to solid black, while light ones stay a partial rim.

## How it works

BeamNG reports every vehicle's cumulative crash damage (dissipated energy) to the game engine each frame. The mod watches **your** vehicle and sums the *new* damage it takes inside a short rolling window (~0.8 s). A gentle bump adds almost nothing; a real crash dumps a huge amount of energy in a fraction of a second. When that windowed damage crosses **Crash severity** (and you're above **Min speed**), the blackout fires.

Because it keys off damage rather than speed, it triggers on genuine wrecks and ignores brushing a wall at speed. The blackout is a full-screen overlay drawn over the game's UI (so it covers the HUD too), with `pointer-events: none` so the game keeps running underneath - your car keeps tumbling for the replay.

Settings are saved to `settings/DeathScreen/settings.json` in your BeamNG userfolder and persist across restarts.

## Tips

- If it fires too easily, raise **Crash severity**; if it never fires on the crashes you care about, lower it - use the live readout to pick a value.
- Crashing again while the screen is still black is ignored until the current blackout finishes (plus a short cooldown so a tumbling wreck can't strobe the screen).
- **Resetting or recovering your vehicle** while the death screen is up cancels it instantly: the black clears, audio and time scale come back, the sting stops, and the window reopens if it was hidden.

## Files

```
lua/ge/extensions/
  DeathScreen.lua                       # detection + blackout + settings UI
  core/input/actions/DeathScreen.json   # keybinds
scripts/DeathScreen/modScript.lua       # bootstrap (loads the extension, registers keybinds)
```

BeamNG loads `lua/` and `scripts/` from the root of the mod zip, so the repo is laid out the same way - just zip those two folders.
