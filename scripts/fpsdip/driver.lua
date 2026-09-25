-- fps-dip harness play driver (Mystery of Solarus DX). MEASUREMENT ONLY, never shipped.
--
-- Loaded through the engine's Lua console (run.sh writes `dofile(...)` into the
-- console FIFO). Starts save1.dat, makes the hero invincible with the sword, and
-- plays: random walking + sword swings via game:simulate_command_pressed (the same
-- path as a real controller press), dismisses dialogs, and every DWELL_MS teleports
-- to the next map of TOUR so a run covers overworld, town and dungeon maps.
-- Walking off a map edge is allowed: scrolling transitions are part of play.
-- The game is never saved.
--
-- Globals set by run.sh before dofile (all optional):
--   FPSDIP_STATE  state log path (default /tmp/fpsdip_state.txt)
--   FPSDIP_DWELL  ms per tour stop (default 40000)
--   FPSDIP_TOUR   space-separated map ids (default below)
--   FPSDIP_SEED   RNG seed (default 1)

local state_path = FPSDIP_STATE or "/tmp/fpsdip_state.txt"
local dwell = FPSDIP_DWELL or 40000
local tour = {}
for id in (FPSDIP_TOUR or "4 3 119 5 23 7 9 40 6 60 8 10 47 105"):gmatch("%S+") do
  tour[#tour + 1] = id
end
math.randomseed(FPSDIP_SEED or 1)

local log = io.open(state_path, "w")
local function note(fmt, ...)
  local s = string.format(fmt, ...)
  log:write(string.format("%d %s\n", sol.main.get_elapsed_time(), s))
  log:flush()
end

local dirs = { "right", "up", "left", "down" }
local held = {}
local function release_all(game)
  for c in pairs(held) do game:simulate_command_released(c) end
  held = {}
end
local function press(game, c)
  if not held[c] then game:simulate_command_pressed(c); held[c] = true end
end
local function release(game, c)
  if held[c] then game:simulate_command_released(c); held[c] = nil end
end

-- FPSDIP_TRACEFILL: log a traceback every 300th call of the surface methods that
-- run CPU software blending on the root (for attributing a per-frame Lua draw cost).
if FPSDIP_TRACEFILL then
  local mt = sol.main.get_metatable("surface")
  local tf = io.open("/tmp/fpsdip_fill.txt", "w")
  for _, name in ipairs({ "fill_color", "draw_region" }) do
    local orig, n = mt[name], 0
    mt[name] = function(surface, ...)
      n = n + 1
      if n % 300 == 1 then
        local w, h = surface:get_size()
        tf:write(string.format("%d %s #%d on %dx%d\n%s\n", sol.main.get_elapsed_time(), name, n, w, h, debug.traceback()))
        tf:flush()
      end
      return orig(surface, ...)
    end
  end
end

-- menus/title.lua:16 preloads every sound in on_started; the driver skips the title,
-- so do the same or each first play decodes an .ogg on the main thread (a harness-only
-- cost real play never sees).
sol.audio.preload_sounds()

local game = sol.game.load("save1.dat")
game:set_ability("sword", 1)
game:set_value("fpsdip_harness", true)
-- Set sol.main.game BEFORE stopping the menus: main.lua chains logo -> language ->
-- title -> savegames with `on_finished = function() if self.game == nil then start
-- the next menu`, so stopping them with game still nil starts the next one and the
-- title screen keeps drawing (full-screen fill_color) under the game. This is the
-- order the quest's own F1 debug key uses.
sol.main.game = game
sol.menu.stop_all(sol.main)
sol.main:start_savegame(game)
note("START save1.dat dwell=%d tour=%s", dwell, table.concat(tour, ","))

local tour_i = 0
local next_tour = sol.main.get_elapsed_time() + 8000   -- first teleport after the intro settles
local next_move = 0
local last_x, last_y, still_ms = 0, 0, 0
local TICK = 100

sol.timer.start(sol.main, TICK, function()
  if sol.main.game ~= game then return false end
  local now = sol.main.get_elapsed_time()
  local hero = game:get_hero()
  if hero ~= nil then
    hero:set_invincible(true)
    if game:get_life() < game:get_max_life() then game:set_life(game:get_max_life()) end
  end

  if game:is_paused() then
    release_all(game)
    game:simulate_command_pressed("pause"); game:simulate_command_released("pause")
    return true
  end
  if game:is_dialog_enabled() then
    -- advance / close dialogs; choose the first answer of any question
    release_all(game)
    game:simulate_command_pressed("action"); game:simulate_command_released("action")
    return true
  end
  if game:is_suspended() or game:get_map() == nil then return true end

  if now >= next_tour and #tour > 0 then
    tour_i = tour_i % #tour + 1
    release_all(game)
    note("TOUR %s", tour[tour_i])
    hero:teleport(tour[tour_i])
    next_tour = now + dwell
    return true
  end

  -- stuck detection: hero not moving while a direction is held -> pick another
  local x, y = hero:get_position()
  if x == last_x and y == last_y then still_ms = still_ms + TICK else still_ms = 0 end
  last_x, last_y = x, y

  if now >= next_move or still_ms >= 800 then
    for _, d in ipairs(dirs) do release(game, d) end
    local d1 = dirs[math.random(4)]
    press(game, d1)
    if math.random() < 0.35 then
      local d2 = dirs[math.random(4)]
      if d2 ~= d1 then press(game, d2) end
    end
    still_ms = 0
    next_move = now + math.random(400, 1500)
  end
  -- sword swings / charged attacks
  if math.random() < 0.08 then
    game:simulate_command_pressed("attack"); game:simulate_command_released("attack")
  end
  -- occasionally talk / lift / push
  if math.random() < 0.02 then
    game:simulate_command_pressed("action"); game:simulate_command_released("action")
  end
  return true
end)
