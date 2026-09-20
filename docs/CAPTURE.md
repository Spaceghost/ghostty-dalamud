# Screenshots and clips of the game, with the terminals in them

`/term shot` writes a PNG of the frame the game just drew — the world, the
game's own UI, and every ImGui window this plugin drew on top of it — into the
plugin's `screenshots` folder, and then offers it to the gallery prompt that
`/term share` already uses. `/term clip` records a few seconds the same way and
hands the frames to `ghostty-agent`, which runs `ffmpeg` on the host.

## Why the plugin takes its own pictures

The gallery's original flow asks you to press the game's screenshot key. That
file is written by the game, from the frame the game composed, and the
terminals are drawn by Dalamud on top of that frame — so whether they are in it
depends on where in the frame the game takes its copy, which differs between
Dalamud builds and rendering paths.

> **Nobody has checked this on this machine.** No screenshot taken with the
> game's key, with a terminal on screen, has been compared against one from
> `/term shot`; the game is not available where this branch was written. The
> README has said the same since the gallery landed. Treat "the game's
> screenshot may not have the terminal in it" as the reason this exists, not as
> a measurement.

`/term shot` removes the question: it copies the frame *after* every ImGui
window has been drawn into it, so the terminals are in the file by
construction. It can also crop to one panel, hide the game's UI, and hand the
file straight to the share prompt, none of which the game's key can do.

## How the frame is taken (core/capture.nelua)

1. At the very end of `gu_frame`, after everything has drawn,
   `core/app/capture.nelua` arms a capture and appends a draw-list callback to
   ImGui's **foreground** list.
2. The renderer draws that list last, so when the callback runs, render target 0
   holds the finished frame: game plus every ImGui window. The callback asks the
   device context what is bound (`OMGetRenderTargets`), checks the format, and
   `CopySubresourceRegion`s the whole frame — or one panel's rectangle — into a
   staging texture. Nothing is hooked; this is the same trick
   `core/depthpass.nelua` uses to bind its shader.
3. A **later** frame maps that staging texture with `D3D11_MAP_FLAG_DO_NOT_WAIT`.
   While the GPU has not caught up, `Map` says "still drawing" and the state
   machine simply comes back next frame rather than stalling the pipeline. A
   request made while one is in flight is refused and counted as a skip, so a
   clip drops frames instead of queueing them.
4. The readback is handed out as BGRA with opaque alpha, whatever the swap
   chain's byte order was (`DXGI_FORMAT_B8G8R8A8_*` and `R8G8B8A8_*` are read;
   a 10-bit HDR swap chain is refused with a line that says so).

The staging texture is kept between frames and only remade when the size,
format or device changes. If the renderer never runs draw-list callbacks, the
capture gives up after `CAPTURE_ARM_LIMIT` frames and says why rather than
staying armed for good.

## PNG (core/pngenc.nelua)

The encoder is ours: filtered rows (Sub, Up or Paeth, whichever predicts best)
through a single fixed-Huffman deflate block with greedy LZ77 matching. It runs
in steps — `png_step` encodes at most as many rows as it is given — so a
screenshot is spread over a few dozen frames and no single frame carries a whole
image. A synthetic 1080p frame with a terminal panel in it comes out around
50 KB in `tests/test_pngenc.nelua`; a real one is larger, and both are far
inside the gallery's 8 MB.

There is **no JPEG encoder**: the gallery takes PNG and JPEG, PNG is lossless
for text, and a baseline JPEG encoder (DCT, quantisation, Huffman tables) would
be a great deal of code for a worse picture of a terminal.

## Commands

    /term shot                  the whole frame
    /term shot panel            just the focused terminal's window
    /term shot clean            hide the game's own UI first
    /term shot panel clean      both

    /term shot status           what the frame grabs have been doing

    /term clip                  6 seconds, GIF
    /term clip 10 mp4           10 seconds, MP4
    /term clip 8 panel clean    the focused panel, no game UI

The camera button in the dropdown's tab bar still offers your latest
screenshot to the gallery (`/term share`); the shutter button beside it takes
one now (`/term shot`).

`panel` uses the dropdown's window while it is on screen, else the most recent
floating terminal window. A terminal pinned into the world has no ImGui window
of its own, so `panel` says so and you take the whole frame instead.

Scroll Lock (the game's own "hide the HUD" key) does a more complete job than
`clean` and the plugin's windows stay visible through it
(`CONFIG.host.keep_visible`); `clean` is there for the times a macro or a
button has to do it without a key press.

`clean` hides a fixed list of game UI elements (action bars, party list,
parameter widget, target info, minimap, chat log and so on) through the shim's
`addon_show`, waits three frames, takes the shot and puts them back. It comes
back after four seconds whatever happens, and on shutdown, so a failed capture
can never leave you without your action bars. It needs a shim that has
`addon_show`; older ones say so and take the shot as it is.

## Where files go

Screenshots: `<config>/screenshots/ghostty_<date>_<time>.png`, where `<config>`
is the plugin's config folder (`GHOSTTY_HOME` when set). The gallery prompt
appears as soon as the file is written — the same prompt, the same one-click
upload, the same review on the site.

`lua/gallery.lua` does not watch this folder, on purpose: the shot is offered
the moment it is written, and watching would offer it a second time. `/term
share` still finds the game's own screenshots.

## Clips (agent/clips.nelua)

Nothing is encoded in the game process. The plugin captures frames at a reduced
rate and size, QOI-encodes each one (the same codec remote windows use) and
sends it to the agent as a `CFRAME`; the agent decodes it, appends it to one
raw BGRA file, and on `CEND` runs ffmpeg over that file:

* GIF — `palettegen`/`paletteuse`
* MP4 — libx264, `yuv420p`, even dimensions

The plugin asks first (`COPEN`) and only starts capturing once the agent
answers with a clip id, so a host without ffmpeg refuses **before** a single
frame is taken and the chat says so. Point `GHOSTTY_FFMPEG` at a binary to
choose one; `GHOSTTY_CLIP_DIR` chooses where clips are written (a
`ghostty-clips` folder in the system temp folder otherwise). The raw frames are
deleted as soon as the encoder is done with them.

Caps, on both sides: at most 20 seconds, 10 frames a second (15 maximum),
1280x720, 300 frames and 192 MB in the plugin; the agent independently refuses
anything over 1920x1080, 30 fps, 600 frames or a gigabyte, and records at most
two clips at once.

**GIF and MP4 are never uploaded to the gallery.** The site at
`spacegho.st/mods/ffxiv/term/gallery/` sniffs the bytes and takes PNG and JPEG
only (`src/image.js`: `IMAGE_TYPES = ['image/png', 'image/jpeg']`), at most
8 MB, each side between 64 and 16384 pixels. A GIF or MP4 body is answered
`415 bad_type`. Clips are for the owner's own media; `docs/media/shot-quests.json`
lists what they are for.

## Protocol

Added to the agent protocol (docs/REMOTE_WINDOWS.md describes the window
frames these follow):

| Frame | Payload |
| --- | --- |
| `COPEN` 37 | req u32, kind u8 (0 gif, 1 mp4), w u16, h u16, fps u8 |
| `CFRAME` 38 | cid u32, seq u32, enc u8 (0 raw, 1 QOI), pixels |
| `CEND` 39 | cid u32, flags u8 (1: cancel, write nothing) |
| `COPENED` 40 | req u32, cid u32, text (cid 0: refused, text says why) |
| `CDONE` 41 | cid u32, status i32 (0 ok), the file's path or why not |

The protocol version is unchanged: an agent that does not know these frames
answers `ERR unknown frame`, and the plugin gives up on the clip after five
seconds with "the agent is probably too old for clips".

## What is tested, and what is not

Tested on the host (`tests/run.sh`):

* `tests/test_pngenc.nelua` — the file's structure and chunk CRCs, the pixels
  round-tripping through an inflater written for the test, stepping in small
  budgets giving the same picture, and a 1080p frame fitting the gallery.
* `tests/test_capture.nelua` — the crop maths, the whole state machine against
  a fake D3D11 (padded row pitch, BGRA and RGBA, crops clamped to the frame,
  staging reuse, skips while one is in flight, a renderer that runs no
  callbacks, a map that fails, a format that cannot be read).
* `tests/test_clips.nelua` — the agent side end to end against a stand-in
  encoder: refusals, frames accepted and dropped, the frame budget, `CDONE`
  with the file, a failing encoder's message, cancelling, and a client going
  away.
* `tests/test_chrome.nelua` — the new shutter button and icon.

**Not tested, because it needs the game:** every D3D11 call in
`core/capture.nelua` (they are compiled only on Windows and stubbed on the
host), whether Dalamud's renderer runs a callback appended to the foreground
draw list at the point this assumes, the `addon_show` HUD list, the ImGui
window lookup `panel` uses, and the Windows half of `agent/clip_run.nelua`
(`CreateProcessA`), which has been written but never run — the host tests are
POSIX. Nothing in this branch has been run in the game.
