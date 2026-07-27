-- Fixture: every "binding" in this file is commented out, in each shape the
-- scanner recognises and each Lua comment form (line comment, block comment,
-- long-bracket block comment). Every one of these would pass BOTH closed
-- vocabulary checks (ACTION_VOCAB action name, SDL_KEY_NAMES value) if left
-- in the scanned text, so this only stays green if comments are stripped
-- before scanning, not after.
local bindings = {}

-- attack = "s"

--[[
action = "space"
]]

--[==[
item_1 = "a"
]==]

function bindings.mixin(game)
  function game:on_key_pressed(key, modifiers)
    return true
  end

  function game:on_started()
    -- game:set_value("keyboard_run", "left shift")
  end
end

return bindings
