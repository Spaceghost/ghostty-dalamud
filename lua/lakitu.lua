-- The hovering camera (docs/CAMERA.md): a camera that floats on an orbit
-- around your character. With the shot on it is the view, because FFXIV
-- renders one view and there is no second one to give a camera.
--
--   /term cam            -- the camera exists and follows you
--   /term cam shot       -- and the view becomes its view (again to give it back)
--   /term cam left|right|up|down|in|out|orbit|still|reset
--
-- From Lua:
--   ghostty.cam{ on = true, shot = true, distance = 2.2, height = 1.5, yaw = 0.5 }
--   ghostty.cam(false)
--   ghostty.cam_state() -> { on, shot, placed, steering, blocked, x, y, z, ... }
--
-- Not yet observed in game: the shot's framing against a real character, and
-- every model path below. `body` is empty on purpose -- a camera with no body
-- is the working default, and a wrong model path is a warning in the log.

local M = {}

-- Shots. Three numbers each, which is all a shot is here: how far out, how
-- high, and where around you. `yaw` is radians from the way you are facing,
-- so 0 is in front of your face and math.pi is behind your head.
M.shots = {
  -- The one a call wants: slightly above eye line, a little off-centre, close
  -- enough that you are the subject and not the scenery.
  meeting = { distance = 2.2, height = 1.5, yaw = 0.45, orbit = 0, ease = 6 },
  -- Over the shoulder: you in the corner, the world in front of you.
  shoulder = { distance = 1.6, height = 1.7, yaw = 2.6, orbit = 0, ease = 5 },
  -- Talking-head close-up.
  closeup = { distance = 1.2, height = 1.5, yaw = 0.2, orbit = 0, ease = 8 },
  -- A slow circle while you talk. Lovely for thirty seconds and nauseating
  -- for five minutes, so it is not a default.
  drift = { distance = 3.0, height = 1.8, yaw = 0.4, orbit = 0.12, ease = 4 },
  -- Up and back: the establishing shot.
  wide = { distance = 6.0, height = 3.0, yaw = 0.8, orbit = 0, ease = 3 },
}

-- The camera's body: a client-side object only you can see, which is what
-- makes this a Lakitu rather than a setting. It needs a model the game has;
-- none of these has been checked against the game's index yet, which is why
-- the default is none. Try one with `/term reload` after setting `body`.
M.body_candidates = {
  -- small floating housing props are the nearest thing to a camera drone
  { name = 'Aetheric Lantern', path = 'bgcommon/hou/indoor/general/0303/bgparts/fun_b0_m0303.mdl' },
  { name = 'Orchestrion',      path = 'bgcommon/hou/indoor/general/0231/bgparts/fun_b0_m0231.mdl' },
}
M.body = ''      -- a path from above, or any other .mdl
M.body_scale = 0.4

function M.apply(shot, extra)
  local s = type(shot) == 'table' and shot or M.shots[shot]
  if not s then return false, 'no such shot' end
  local t = {
    on = true,
    distance = s.distance, height = s.height, yaw = s.yaw,
    orbit = s.orbit or 0, ease = s.ease or 6,
    model = M.body, scale = M.body_scale,
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  return ghostty.cam(t)
end

-- Turn the camera on with a shot, and make it the view.
function M.roll(shot)
  return M.apply(shot or 'meeting', { shot = true })
end

-- Give the view back but leave the camera hovering.
function M.hold()
  return ghostty.cam{ shot = false }
end

function M.off()
  return ghostty.cam(false)
end

return M
