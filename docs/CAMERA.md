# A camera that hovers around you

> Status: required direction. The prop and the camera control this needs both
> exist and are already used elsewhere in this repository; the streaming half
> is the moq work in docs/MOQ.md, which carries no frames yet. Nothing here
> has been run.

The ask: a camera that floats near your character, Lakitu style, and is what a
call sees when you join it from inside the game.

## The constraint, and where it stops mattering

**FFXIV renders one view.** A plugin cannot ask the game for a second
viewpoint, so there is no way to watch from behind your own eyes while a
second camera watches your face at the same moment.

That bites a live second viewport. It does not bite a photograph.

A camera that takes a shot does not need its own viewport: it needs the view
to be in the right place at the moment the frame is captured. So the second
camera is real, and works like this:

1. it hovers where you put it, as an object in the world;
2. when a shot is asked for, the view swings to it;
3. the game renders a frame or two from there;
4. that frame is captured;
5. the view goes back exactly where it was.

From the outside -- from the MCP server asking for a picture of the character
from the front -- that is indistinguishable from a second camera, because what
comes back is a front-angle photograph that the person never had to line up.
The round trip is a handful of frames.

This is the difference between "the camera is the view" and "the camera
borrows the view for a moment", and only the second one is needed.

What it is built from:

* `get_camera_state` / `set_camera_state(dir_h, dir_v, distance)` move the
  real camera on its orbit around the character. `core/app/worldview.nelua`
  already takes the camera and gives it back (`host.cam_active`,
  `cam_restore`), so the borrow-and-restore problem is solved.
* `bg_create(model_path)` / `bg_ready` / `bg_set_transform` / `bg_destroy`
  place client-side objects in the world. `core/app/occluders.nelua` already
  does this for the boards behind world panels, with position, quaternion and
  scale.
* The composited frame -- the game plus every panel drawn over it -- is what
  a capture after Dalamud's draw sees. The plugin already streams frames to
  the agent for clips (`copen` / `cframe_rows`, core/app/capture.nelua).

## Three ways to use the same camera

**As a photographer.** The MCP server asks for a shot; the view goes there,
the frame is taken, the view comes back. Nobody has to hold the camera and the
person keeps playing. This is the one that wants front angles, and the one
that needs the least to be true.

**As the shot.** The view stays at the camera for as long as you like -- a
call, a scene, a screenshot you are composing by eye. You see what it sees.

**As a body only.** It hovers beside you and does nothing else, which is worth
having because other people's screenshots of you have a little camera in them.

## Front angles

`yaw` is measured from the way the character is facing, so `yaw = 0` is
directly in front of the face and `math.pi` is behind the head. A front angle
is therefore a small `yaw`, a `height` near eye level, and a short
`distance`; `lua/lakitu.lua` keeps these as named shots rather than numbers to
remember.

Straight-on is rarely the best picture of a character -- a little off the nose
(`yaw` around 0.3 to 0.6) and slightly above the eyeline reads better, which
is why `meeting` and `closeup` are set where they are rather than at zero.

## Orbit, not free flight

`set_camera_state` takes `dir_h`, `dir_v`, `distance`: an orbit around the
character, not an arbitrary point. So the camera can circle you, rise, fall
and pull in or out, and cannot fly off to film the scenery. Mario 64's Lakitu
is also on a leash to Mario, so this is the right shape anyway.

A "shot" is then three numbers plus how fast to move between them, which makes
presets cheap: over-the-shoulder, face-on, a slow circle while you talk.

## What makes it a webcam

The frames the call sees are the composited frame, captured the way a clip is
and sent to the agent, which writes them into a v4l2loopback device that Zoom
or any other program opens as an ordinary camera. That path is
`CLIP_KIND_CAM`, a continuous variant of the clip stream, and it is the first
real consumer of a moq track (docs/MOQ.md): a camera feed is video by
definition, which is exactly the case that must leave the lossless tile path.

Two things fall out of using the composited frame:

* your panels are in shot. The call sees your terminal if a terminal is on
  screen, which is either the best feature here or a hazard, and should be a
  setting rather than a surprise;
* it costs nothing extra to capture, because the game is already drawing it.

## Order, and what proves each step

1. The body: an object that follows the character on an orbit. Proof: it is
   visible in game and stays with you when you move.
2. The shot: `set_camera_state` driven to the body's orbit, borrowed and
   restored the way worldview already does. Proof: turning the camera on
   frames the character, and turning it off puts the view back exactly.
3. `cam.shoot`: place, let the game render, capture, restore -- the whole
   round trip behind one call, over `GhosttyDalamud.v1.Call` so the MCP server
   can ask for it. Proof: a front-angle picture of the character comes back,
   and the view afterwards is where it was before.
4. `CLIP_KIND_CAM`: the existing frame path, unbounded, for a call rather than
   a photograph. Proof: the agent receives frames at a steady rate with
   nothing recorded to a file.
5. The v4l2loopback sink. Proof: `zoom` (or `ffplay /dev/videoN`) shows the
   game.
6. moq for that track. Proof: the frame rate the tile path cannot reach --
   pixman caps a video-like window near 6 fps at 1280x720.

Steps 1 and 2 are done and covered by `tests/test_lakitu.nelua`, which is not
the same as seen in game. Step 3 is the one the MCP server is waiting for.

## Where it should live

Inside this plugin, not beside it. It needs the frame path, the agent
connection and the world placement code, all of which are here; a sibling mod
(the shape XivDesktop uses) would reach back through IPC for all three. If it
grows a UI of its own later, splitting it out is a smaller job than starting
it outside.
