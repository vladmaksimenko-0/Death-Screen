-- Death Screen (CLIENT)
-- Runs automatically when the mod is loaded by BeamNG / BeamMP. Loads the
-- runtime extension and registers a keybind category so the actions in
-- lua/ge/extensions/core/input/actions/DeathScreen.json show up in
-- Options > Controls > Bindings.

load('DeathScreen')

-- "manual" means the game won't unload the extension on level change etc.
setExtensionUnloadMode('DeathScreen', 'manual')

-- Adds a "Death Screen" group in the Controls > Bindings menu.
extensions.core_input_categories.DeathScreen = {
    order = 99999,
    icon = "warning",
    title = "Death Screen",
    desc = "Death Screen blackout controls"
}

-- If the mod is installed while the game is ALREADY running, the input system won't
-- re-scan the actions folder on its own (filesystem change notifications are unreliable
-- -- the game's own bindings code notes this), so our binds wouldn't show under
-- Options > Controls until a restart. Clear the action cache so our newly-mounted
-- DeathScreen.json is picked up, then refresh the controls UI. Guarded, and harmless at
-- normal startup (the input system does its own scan then anyway).
pcall(function()
    if core_input_actions and core_input_actions.onFileChanged then
        core_input_actions.onFileChanged("/lua/ge/extensions/core/input/actions/DeathScreen.json")
    end
    if core_input_bindings and core_input_bindings.notifyUI then
        core_input_bindings.notifyUI()
    end
end)
