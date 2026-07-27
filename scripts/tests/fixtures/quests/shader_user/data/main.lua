-- Fixture: a quest that requires a shader, which this port cannot provide.
function sol.main:on_started()
  local shader = sol.shader.create("scanlines")
  sol.video.set_shader(shader)
end
