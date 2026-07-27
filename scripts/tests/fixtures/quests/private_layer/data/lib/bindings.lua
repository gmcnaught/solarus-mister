-- Fixture: a quest that runs its own input layer instead of GameCommands.
local bindings = {}

bindings.keys = {
  attack = "s",
  action = "space",
  item_1 = "a",
  item_2 = "d",
  inventory = "w",
  map = "tab",
  escape = "escape",
}

function bindings.mixin(game)
  function game:on_key_pressed(key, modifiers)
    return true
  end
end

return bindings
