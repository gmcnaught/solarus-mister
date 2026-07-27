-- Fixture: a private input layer written in awkward but valid Lua formatting
-- -- two bindings sharing a line, a trailing comment, and a punctuation/keypad
-- key name -- that the line-anchored, single-binding-per-line scan used to
-- silently miss entirely.
local bindings = {
  attack = "s", action = "space", -- primary actions
  item_1 = "a", -- inventory slot 1
  item_2 = "kp +",
}

function bindings.mixin(game)
  function game:on_key_pressed(key, modifiers)
    return true
  end
end

return bindings
