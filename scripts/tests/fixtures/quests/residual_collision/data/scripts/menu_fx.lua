-- Fixture: KNOWN LIMITATION, not a regression to fix. An unrelated table's
-- keys collide with ACTION_VOCAB ("look", "map") AND its values happen to be
-- genuine SDL key names ("up", "m") -- not obviously-wrong English words like
-- the false_positive_words fixture. Two independent closed-vocabulary checks
-- (action membership + key-name membership) cannot tell this apart from a
-- real private binding, so it IS recorded. This fixture pins that accepted
-- residual behaviour; see scan_input_surface's docstring.
local fx = {
  look = "up",
  map = "m",
}

local menu = {}

function menu:on_key_pressed(key, modifiers)
  return false
end

return fx, menu
