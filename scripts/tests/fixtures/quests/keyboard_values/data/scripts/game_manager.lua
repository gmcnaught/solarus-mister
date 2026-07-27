-- Fixture: a quest using stock GameCommands PLUS quest-private keyboard values.
local game_manager = {}

function game_manager:initialize(game)
  game:set_value("keyboard_save", "escape")
  game:set_value("keyboard_run", "left shift")
  game:set_value("keyboard_map", "p")
  game:set_value("keyboard_monsters", "m")
  game:set_value("keyboard_look", "left control")
  game:set_value("keyboard_commands", "f1")
end

return game_manager
