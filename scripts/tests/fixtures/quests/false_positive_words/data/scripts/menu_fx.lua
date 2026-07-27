-- Fixture: a menu script that installs its own on_key_pressed handler for UI
-- navigation, but also has an unrelated table whose keys happen to collide
-- with ACTION_VOCAB entries ("attack", "action") that are ordinary English
-- words. Neither should be recorded as a key binding.
local fx = {
  attack = "hit",
  action = "idle",
}

local menu = {}

function menu:on_key_pressed(key, modifiers)
  return false
end

return fx, menu
