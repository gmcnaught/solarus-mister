-- Fixture: a quest with only commented-out shader references.
-- This should NOT be marked as requiring shaders.

function sol.main:on_started()
  -- local shader = sol.shader.create("scanlines")
  -- sol.video.set_shader(shader)
  --[[
  Experimented with sol.shader but decided against it.
  ]]
  print("No shader used in this quest")
end
