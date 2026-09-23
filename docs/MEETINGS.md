# Meetings

> Status: required direction. `/cam` and the camera behind it exist and pass
> their tests; the grid, the camera feed and the look-at do not exist yet.
> Nothing here has been seen in a game.

Taking a meeting from inside the game: the people you are talking to shown as
squares around you, a real camera feed among them if there is one, and your
character looking at the camera while you talk instead of staring through it.

`/cam` is its own command, not a verb under `/term`. It is about cameras and
meetings, and it has no more to do with terminals than the chat log does.

## What this is made of that already exists

* **The hovering camera** (docs/CAMERA.md). It orbits you, it can be the
  view, and it can take a photograph and give the view back. That is the
  camera half.
* **World panels.** Any Linux window the agent has can be a panel in the
  world, placed where you like, and the plugin already scales, pins and
  occludes them. That is the square half: a Brady Bunch grid is an
  arrangement of panels, not a new kind of surface.
* **`set_look_at(active, x, y, z)`** in the shim: the character's head and
  eyes turn toward a world point, and let go when `active` is 0. World panels
  already use it to follow a focused screen. That is the eye contact.

So the mod is mostly arrangement and attention, not new rendering. That is
deliberate -- the parts that would be hard are already here for other reasons.

## The camera feed, and what is actually on this machine

**There is no physical camera on this machine right now.** `uvcvideo` is not
loaded and the only `/dev/video0` is `v4l2loopback` presenting itself as "OBS
Virtual Camera". So the square that shows "your camera" has nothing to show
here until one is plugged in, and the mod has to be honest about that rather
than drawing an empty square.

Two directions, and only one of them is blocked:

* **A camera into the game** needs a camera. When one exists, it does not need
  new video code either: the agent can run any viewer on it and the existing
  remote-window path carries that window into the world as a panel. A feed is
  a window like any other.
* **The game out as a camera** is ready. `v4l2loopback` is already loaded
  here, which is exactly the sink docs/CAMERA.md's step 4 wants: the composited
  frame written into `/dev/videoN` so Zoom opens the game as an ordinary
  webcam. That is the direction that makes "taking a meeting in FFXIV" mean
  something to the other people on the call.

The second is worth building first because it works on the hardware that is
actually here.

## The grid

Squares around you, each a panel, laid out as a grid rather than the free
placement panels normally get: equal sizes, a fixed arc in front of you, and
the whole grid moving as one. A meeting is a group, so the layout is a
property of the group and not of each square.

Sizes follow the count the way a video call's do -- one person is large, nine
people are small -- and the grid sits far enough out to be read without
filling the screen.

## Looking at the camera

The point of the look-at is the thing video calls get wrong: people look at
the faces on their screen, so they never look at the camera, so nobody is ever
looked at. In the game this is fixable, because the character's head is under
our control and yours is not.

While you are talking, the character looks at the camera -- the square that is
the feed, or the hovering camera itself when there is no feed. When you are
not talking, it looks at whoever is. `set_look_at(0, ...)` gives the head back
when the meeting ends.

"While you are talking" has to come from somewhere real: the microphone level
the agent can read on Linux, or a push-to-talk key. Guessing from anything
else produces a character that stares at the wrong thing, which is worse than
one that does not move.

## Order

1. `/cam` answering in chat, so the camera can be told apart from a broken
   command. This is done.
2. The game out through `v4l2loopback`, because the hardware for it is here.
   Proof: `ffplay /dev/videoN` shows the game while the game is running.
3. A grid layout for panels, with one panel in it.
4. The look-at, driven by a push-to-talk key first, because a key is certain
   and a level is a guess.
5. A real camera in a square, when there is a real camera.

## Where it lives

Inside this plugin for now, with its own command, its own window and its own
config table -- the same shape the desk scene and the gallery have. Everything
it needs (panels, the agent, the capture path, the world placement) is here,
and a sibling plugin would reach back through `GhosttyDalamud.v1.Call` for all
four.

If it grows its own settings and its own release cadence, splitting it out
later is a smaller job than starting it outside and calling in.
