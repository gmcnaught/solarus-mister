-- Fixture: a quest that requires a shader and has private key bindings.
local bindings = {
  attack = "s",
  action = "space",
  item_1 = "a",
  item_2 = "d",
}

function sol.main:on_key_pressed(key)
  -- Handler installed
end

function sol.main:on_started()
  local shader = sol.shader.create("scanlines")
  sol.video.set_shader(shader)
end
