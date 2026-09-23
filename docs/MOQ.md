# Media over QUIC, as a second frame path

> Status: the transport half exists; the media half does not. What is
> implemented and observed is in "What exists" immediately below. Everything
> after it is still the required direction, and the media half remains the
> **largest and least certain** piece of docs/MULTI_AGENT.md. It is step 5 of that file's order, and it is the
> only step whose central mechanism — a video decoder inside the plugin core,
> which is a Windows PE DLL under Wine — does not exist anywhere in this
> repository today. Read "What is unproven" before treating any of it as a
> plan to start typing.

Today every remote window is the same thing: a tile diff, QOI or RAW
rectangles, a WFRAME per `seq`, a WACK back (docs/REMOTE_WINDOWS.md). That is
right for a window made of text and wrong for a window playing video. This
file says where a codec would branch off that path, and — as important — what
must never leave it.

## What exists

Implemented and observed, on the fedora build host:

* `crates/ghostty-iroh/src/moq.rs` presents iroh's `Connection`, `SendStream`
  and `RecvStream` as a `web_transport_trait::Session`. moq-net is generic
  over that trait rather than tied to an endpoint of its own, so **a moq
  session rides the QUIC connection the plugin and the agent already have**.
  One connection, one identity, one handshake, with media tracks alongside the
  existing protocol -- not a second transport with its own key and its own NAT
  traversal to get wrong.
* `crates/ghostty-iroh/tests/moq_loopback.rs` runs moq-net's own handshake
  across that adapter between two endpoints, over real QUIC streams, and then
  asserts the connection moved UDP bytes both ways and opened a stream. The
  test finishes in under a millisecond on loopback, and a green handshake that
  touched no wire would prove nothing.

Not implemented, and everything below this section is about it:

* no track carries a frame;
* no codec, and therefore none of "How a decoded frame reaches the D3D11
  texture" (the decoder inside a Windows PE DLL under Wine is still the piece
  that exists nowhere in this repository);
* the plugin's frame path is unchanged -- RAW and QOI tiles, a WFRAME per
  `seq`, a WACK back.

So the question this file was written to answer -- where a codec branches off
the tile path and what must never leave it -- is untouched. What has changed
is that the thing to carry it on is no longer hypothetical.

A note on the first consumer: a software camera (the game's composited frame
offered to a call as a webcam) is a better first track than a video in a
panel. It is video by definition, so it needs no damage-rate heuristic to
decide it belongs off the tile path, and the plugin already streams frames to
the agent for clips (`copen`/`cframe_rows` in core/app/capture.nelua) at a
chosen fps, which is the shape a camera feed wants.

## What this is for, and what it is not for

It is for one case: a window whose whole picture changes, often, and whose
pixels do not compress as text does. A video in a browser tab, a game, a
renderer's viewport, a video call.

It is **not** a fix for the frame rates measured in docs/REMOTE_WINDOWS.md
("Verified"). Those numbers are a compositor cost, not an encode cost:

| renderer | output | fps | compose ms | read back ms |
|---|---|---|---|---|
| pixman, scale 2 | 2560×1440 | 6.4 | 135.4 | 5.2 |
| pixman, scale 1 | 1280×720 | 34.2 | 12.0 | 1.2 |

135 ms of pixman compositing is spent before any encoder sees a pixel. A codec
cannot give that back; the GLES2 render-node path
(`--wayland-render-node`) is what gives that back, and it has to be the one in
use before a codec is worth anything for that window. What a codec buys is the
*wire and the encode*: a 1920×1200 key frame is 9 MB raw, and QOI on video
content saves little, so today a moving window is bounded by bytes long before
it is bounded by frames. Say the two problems separately or the measurement
will be misread.

## Where it branches

There are two branch points and they are at different heights. Keeping them
apart is the whole design.

### 1. The payload: a coded picture is a rectangle encoding

`core/wincodec.nelua` already has the seam. A WFRAME rectangle is

```
x u16, y u16, w u16, h u16, enc u8, len u32, bytes[len]
```

with `enc` 0 RAW and 1 QOI. A coded picture is **enc 2 CODEC**: one rectangle
covering the whole picture (`x=0, y=0, w=frame w, h=frame h`), whose bytes are
one access unit of the negotiated codec. Nothing else in the frame format
moves: `sid`, `seq`, `w`, `h`, KEY, END, WGEOM and WACK keep exactly the
meaning docs/REMOTE_WINDOWS.md gives them.

Concretely, on each side:

* Agent, `stream_send` in `agent/windows.nelua`. Today: `wincodec_downscale`,
  then `wincodec_diff` against `s.prev`, then `wincodec_write_frames`. With a
  codec on, the diff is skipped — the encoder's own inter-frame prediction
  replaces the tile diff, and `s.prev` stops being maintained (it exists to
  answer "what does the client have", which for a codec is "whatever the
  decoder says"). The branch is one `if s.codec ~= 0 then` around the
  diff-and-encode pair, calling a new `wincodec_write_coded` that emits the
  same WFRAME head with one enc 2 rectangle. `send_geom` is unchanged and
  still goes first.
* Plugin, `on_frame` in `core/app/remotewin.nelua`. `wincodec_parse` and
  `wincodec_next_rect` are unchanged. `wincodec_apply_rect` gains an
  `enc == WINCODEC_ENC_CODEC` arm, which is the only place that calls the
  decoder. It writes BGRA into the same `rw.pixels` at the same stride, and
  then the existing code path — `note_dirty`, END, `rw.ack_seq`, `ack(rw)`,
  `policy_windows_size` on the first frame — runs without knowing a codec was
  involved. A coded picture always sets `rw.dirty_all`, since a decoder gives
  a whole picture and does not tell you which tiles moved.

The point of this shape: **enc 2 works over the existing TCP connection**, with
no moq, no QUIC and no iroh. It is testable on the host the day it is written
(`tests/test_wincodec.nelua` with a stub codec that is raw bytes in a codec
wrapper), it is the only part that touches the decoder, and it is where all of
the risk is. moq can then be added under a payload format that already works,
instead of two new things at once.

### 2. The carriage: a moq track instead of a WFRAME on the control stream

The second branch is a transport decision and comes after steps 3 and 4 of
docs/MULTI_AGENT.md (iroh under `core/sys/net.nelua`, then one QUIC stream per
window stream). Once each window stream has its own QUIC stream, a window
whose payload is coded pictures is exactly what moq-transport is shaped for,
and the enc 2 bytes are carried as track objects rather than inside PROTO
frames.

The mapping:

| moq | here |
|---|---|
| broadcast | one per agent link (`AgentLink.name` names it) |
| track | one per `sid`: `win/<sid>`; the control messages stay on the connection's own stream |
| group | one GoP: begins at each key frame (each WFRAME KEY) |
| object | one coded picture, object id = the WFRAME `seq` of that picture |
| object payload | the enc 2 bytes, byte for byte |

`seq` keeps its current meaning, so WACK keeps its current meaning: the client
still sends `WACK sid, seq` on the control stream naming the picture it
presented, and the agent still refuses to run ahead. That is deliberate and it
is where moq's instincts and ours disagree.

**Flow control, honestly.** The moq way is that a subscriber falls behind and
the relay drops whole groups; the newest group wins and nobody counts frames.
Our way is `WINDOWS_UNACKED_MAX = 2`, which exists to bound memory on both
sides and to stop a panel nobody is looking at from producing anything at all
(`ack()` in `core/app/remotewin.nelua` holds the WACK while the panel sleeps
or has not been drawn for 2 s, and the agent then stops). That second property
is not optional — it is what keeps twenty pinned panels from costing twenty
encoders — so WACK stays. The reconciliation:

* WACK is the *encoder's* permission to continue, unchanged in meaning, and
  a stream with no WACK still goes quiet. Sleeping panels are the common
  case, not the exceptional one.
* The unacked bound rises for a coded stream (a GoP's worth rather than 2),
  because coded pictures are small and the 2-frame rule was sized against
  multi-megabyte key frames.
* Within that window, dropping is the transport's business: a subscriber that
  joined late or fell behind starts at the newest group, which is a key frame
  by construction. The plugin does not need to ask for one; joining a group
  boundary is what asking for one means here.

## How a decoded frame reaches the D3D11 texture

The target is unchanged: the single `DXGI_FORMAT_B8G8R8A8_UNORM`
`D3D11_USAGE_DEFAULT` texture per stream in `core/wintex.nelua`, on Dalamud's
device, whose shader resource view is the `ImTextureID`. Everything about the
panel — the 24 × 16 quad grid, the curve, the depth test, WGEOM boxes and
popups, input mapping — is downstream of that texture and must not learn that
a codec exists.

Three ways to fill it, in increasing order of both performance and risk:

**(a) Decode to BGRA on the CPU, upload the whole texture.** The decoder
outputs NV12 or I420; a colour conversion writes BGRA into `rw.pixels`;
`rw.dirty_all` is set; the existing `wintex_upload` of one full-window
rectangle runs on the render thread exactly as a KEY frame does today.
Nothing in `core/wintex.nelua` changes at all — this is the reason to build it
first. The cost is a full `UpdateSubresource` per frame: 9 MB at 1920×1200, at
30 fps 270 MB/s of staging traffic, plus the conversion. The tile path exists
precisely because whole-window uploads were judged expensive
(`core/wintex.nelua`'s own header argues this against `WRITE_DISCARD`), so
this is the one place the design knowingly does the thing the rest of the file
avoids. It has not been measured.

**(b) Upload NV12, convert on the GPU.** Two textures (a `R8_UNORM` luma and a
`R8G8_UNORM` chroma, or one `NV12` texture where the driver allows it), a
small pixel shader writing into the existing BGRA texture through a render
target view. Uploads drop to 1.5 bytes a pixel and the conversion stops
costing CPU. The cost: `core/wintex.nelua` gains a render target, a shader and
a draw call on Dalamud's immediate context, in the middle of Dalamud's own
ImGui rendering, which means saving and restoring device state that ImGui
assumes. The `wintex_fake` split keeps it host-testable in shape, not in
behaviour.

**(c) Hardware decode straight into a D3D11 texture.** `ID3D11VideoDevice` /
`ID3D11VideoContext`, the decoder writing an NV12 texture, then (b)'s shader.
No CPU touches a pixel. This is the right answer on a native Windows machine
and it is the least likely to work under Wine; see below.

The order is (a), then (b), and (c) only with a measurement in hand. Each is a
change inside `wincodec_apply_rect` and `core/wintex.nelua` and nowhere else.

## Codec

**H.264, 8-bit 4:2:0, High profile, no B-frames.** Reasons, in the order they
decide it:

* Latency. B-frames reorder output; a panel is interactive, so the encoder
  runs with none and the decoder never holds a picture back. A coded picture
  arrives, decodes, and is presented in the same `on_frame` that a QOI
  rectangle would have been.
* Decoders. H.264 is the one codec with a plausible decoder on every path we
  might take: a small permissive software decoder exists (openh264, BSD), and
  it is the codec Wine's D3D11/DXVA support is most likely to have been
  exercised against. AV1 is better per bit and worse on every other axis here:
  bigger decoders, thinner Wine coverage, and an encoder the agent host may
  not have.
* Encoders the agent already has. `agent/clips.nelua` already requires ffmpeg
  and already encodes MP4 with libx264 and `yuv420p` (docs/CAPTURE.md). The
  same binary, the same pixel format, piped instead of batched, is the
  shortest first encoder: raw BGRA in on stdin, Annex B out on stdout, one
  process per coded stream. That is a deliberately unambitious start — it
  costs a process and a copy per stream and it is not how this should end —
  but it means the agent side needs no new dependency and no new build, and
  a host with no ffmpeg simply never offers a codec, the same way it already
  refuses a clip before the first frame is taken.
* Licensing is a real constraint, not a footnote. libx264 is GPL; that is
  tolerable for a thing the agent shells out to and intolerable for something
  linked into a distributed DLL. The decoder in the plugin must therefore be
  permissive (openh264, or the platform's own decoder through D3D11), and the
  encoder stays behind a subprocess boundary.

4:2:0 is the whole reason the next section exists.

## Deciding a window is video-like

The agent already computes everything the decision needs, once a frame, for
free. In `stream_send` it has: `#s.rects` and their total area from
`wincodec_diff`, the encoded size `wincodec_write_frames` returned, the
picture area, and `s.interval` and `s.due`, which say whether the stream is
running at its cap or idling.

Two signals, both required:

1. **Damage area.** The changed area over a sliding window of about two
   seconds, as a fraction of the picture. Video is near 1.0 every frame.
2. **QOI ratio.** Encoded bytes per changed pixel. Text is cheap under QOI —
   long runs, index hits, flat backgrounds — and photographic or dithered
   content is not. Something near or above 1.5 bytes a pixel is not text.

Damage area alone is not enough and this is the interesting failure: a
terminal scrolling `cat` of a large file changes the whole picture every frame
and would be classified as video by area alone. The QOI ratio is what
separates them, and it costs nothing because the tile path already produced
the number.

The rule, then: enter the codec when both signals hold continuously for
**about three seconds**, at a frame rate at or near the stream's cap. Leave it
when either fails for **about ten seconds**. The asymmetry is hysteresis and
the constants come from the cost of a switch: every switch in either direction
is a key frame, which is the most expensive thing either path produces, so a
browser window that alternates between a video and a page of text must be
allowed to settle rather than flip.

### Renegotiation on the wire

The choice is per stream and belongs to the agent, which is the side with the
numbers. The client's part is to say what it can decode and to be able to
refuse.

* **Capability.** The plugin advertises its decoders when it opens a stream: a
  codec mask in WOPEN (the existing head is `req, wid, max_w, max_h, fps`; a
  byte after `fps`, absent in older clients, reads as 0 = tiles only). An
  agent that sees 0 never offers a codec, so an old plugin and a new agent
  behave exactly as today. Protocol version becomes 5; the negotiation is
  additive in both directions, as versions 3 and 4 were.
* **Switching.** A new agent → client message, `WCODEC sid, codec u8,
  params…`: codec 0 means "tiles from here on", non-zero names the codec and
  carries its out-of-band parameters (for H.264, the SPS/PPS, so the decoder
  can be created before the first picture arrives). It comes immediately
  before the first WFRAME of the `seq` it applies to, in the same place and
  with the same "holds from this seq on" rule WGEOM already uses.
* **Every switch is a key frame.** Into the codec: an IDR, flagged KEY.
  Out of it: a full-picture QOI KEY frame, and `s.prev` is rebuilt from the
  frame just sent. The client's `rw.pixels` is correct across the switch
  either way, so the panel shows no discontinuity and `rw.dirty_all` handles
  the upload.
* **Refusal and failure.** If the decoder cannot be created, or a picture
  fails to decode, the plugin sends `WCODEC sid, 0` upward — the one
  client → agent use of the message — and the agent returns to tiles with a
  KEY frame. A stream that has failed a codec once does not get offered one
  again. A panel must degrade to the path that has always worked, never to a
  black rectangle.
* **A size change resets everything.** The picture size is the decoder's
  configuration; a WGEOM-driven resize (a popup opening widens the picture)
  tears the decoder down and starts a new one at a key frame. This is
  frequent on the Linux compositor path — every menu opening changes the
  picture size — and is a real argument for the hysteresis being generous.

### The configuration escape

`lua/windows.lua` gains `codec = 'auto' | 'never'`, per window default and per
`/window` call, defaulting to `'auto'` for pulled desktop windows. The
detector is advisory and the config wins. Anyone who does not want a lossy
picture, for any reason, should not have to argue with a heuristic.

## What must keep using lossless QOI tiles

**Terminal text, always, with no automatic path to a codec.**

This is not a preference. The reasons, in order:

* **4:2:0 destroys coloured text.** Chroma is at half resolution in both
  directions; a red glyph on a black background, or syntax highlighting at
  small point sizes, is exactly the content that subsampling was designed to
  throw away. Antialiased glyph edges become coloured mush at precisely the
  scale a reader is reading at.
* **DCT ringing sits on glyph edges.** A codec's error is distributed around
  high-contrast edges, and a page of text is nothing but high-contrast edges.
  The artefact lands on the letterforms.
* **A terminal must not lie about characters.** QOI is lossless, so the
  picture on the panel is the picture the agent has. A plugin that shows a
  shell should not be capable of rendering a `0` that decodes as an `O`. This
  is the one that decides it even if the first two were tolerable.
* **The tile path is already better for text.** A blinking caret is one 32×32
  tile; under a codec it is a whole coded picture every time it blinks, at the
  stream's frame rate, forever. The codec is worse on bytes *and* worse on
  quality for this content.

Practically:

* A terminal panel never reaches this code at all — terminals are PTY sessions
  (PROTO_DATA), not window streams, so there is no path from a `/term` to a
  codec. That is a property worth keeping rather than an accident to rely on.
* A remote window that *is* a terminal (a terminal emulator opened into the
  agent's compositor by `run:`, `app:` or `desktop:`) is a window stream, and
  the detector is what protects it. It protects it correctly: a terminal fails
  the QOI-ratio signal even while scrolling, which is why that signal is
  required and not merely contributory.
* `codec = 'never'` exists for everything the heuristic gets wrong, and the
  detector's thresholds should be tuned to prefer tiles when uncertain. The
  failure mode of staying on tiles is a slow video. The failure mode of
  switching wrongly is unreadable text, which is worse.

## What is unproven

This is the section that matters most, and it is long on purpose.

* **No video decoder has ever run in the plugin core.** The core is a PE DLL
  under Wine, and it links nothing of this kind today. Decoder in the core is
  new surface area in the process that also renders the game's UI: new
  allocation behaviour, new threading, and a new class of crash in a place
  where a crash takes the game with it. Nothing about it has been tried.
* **D3D11 video decode under Wine is unknown here.** Path (c) assumes
  `ID3D11VideoDevice` works in the game's Wine build against this host's
  NVIDIA open drivers, through whatever Wine maps it onto. Not tested, not
  even probed. Assume it does not work until a PE binary says otherwise, the
  way the UDP question was settled.
* **Software decode cost in the game's frame budget is unmeasured.** A
  software H.264 decode of 1920×1200 at 30 fps is not free, and it would run
  in the same process, under Wine, beside a game. Whether it belongs on the
  render thread, a worker, or a thread at all is undecided.
* **The full-texture upload of path (a) is unmeasured.** 270 MB/s through
  `UpdateSubresource` on Dalamud's immediate context, every frame, is exactly
  what the tile design set out to avoid. It may be fine. It may be the reason
  path (a) is only a stepping stone. There is no number.
* **No moq implementation is linked, and moq-transport is a moving draft.**
  The carriage half depends entirely on steps 3 and 4 of
  docs/MULTI_AGENT.md landing first: iroh behind `core/sys/net.nelua`, then
  per-window QUIC streams. Neither exists.
* **What the UDP measurement does and does not prove.** A PE32+ binary built
  by `zig cc -target x86_64-windows-gnu`, run under the game's own Wine build
  and prefix, exchanged UDP with a server on the fedora tailnet host in both
  directions. That is real and it is the reason QUIC from the PE core is worth
  pursuing at all. It proves UDP reaches the network. It does not prove QUIC,
  iroh, moq, a codec, or anything about throughput or jitter under a running
  game.
* **The encoder side is sketched, not designed.** One ffmpeg process per coded
  stream, piped, is a starting point with obvious costs: process count,
  a full BGRA copy per frame into a pipe, no control over rate adaptation,
  and latency behaviour nobody has looked at. Whether it should become a
  linked encoder or a VA-API/NVENC path on the render node the compositor
  already selects (`--wayland-render-node`, which already finds each GPU's
  driver and free VRAM) is open.
* **The detector's constants are guesses.** 1.5 bytes a pixel, three seconds
  in, ten seconds out, "near the cap" — none of these came from a measurement.
  They are starting values to be replaced by numbers from real windows.

## Order, and what would prove each step

Each step is useful alone, and the early ones do not need moq, QUIC or iroh.

1. **enc 2 in `core/wincodec.nelua`**, with a stub codec, over TCP. Proof:
   `tests/test_wincodec.nelua` round-trips a coded rectangle and
   `tests/test_remotewin.nelua` presents it; no decoder yet.
2. **A real decoder behind `wincodec_apply_rect`, path (a).** Proof: a coded
   picture decoded to the right pixels on the host, under valgrind, before
   anything is asked of Wine.
3. **The decoder in a PE binary under the game's Wine prefix**, standalone,
   decoding a file — the same shape of experiment that settled the UDP
   question, and the one that says whether any of this is possible.
4. **WCODEC and the detector**, agent side, still over TCP. Proof: a video
   window switching to the codec and a terminal window beside it never
   switching, in a log.
5. **The moq track**, after per-window QUIC streams exist. Proof: a video in a
   panel at a frame rate the tile path cannot reach, with a terminal panel
   beside it still lossless and still responsive to typing.

Steps 1 to 4 are worth doing whether or not moq ever lands, because they are
the codec. Step 5 is the transport it deserves.

## Where the work would go

| file | change |
|---|---|
| `core/wincodec.nelua` | `WINCODEC_ENC_CODEC = 2`, `wincodec_write_coded`, the enc 2 arm of `wincodec_apply_rect`; still pure and host-tested |
| `core/wintex.nelua` | unchanged for path (a); NV12 textures, a shader and a render target for (b) |
| `core/app/remotewin.nelua` | decoder lifetime per `RemoteWin` (created on WCODEC, torn down on size change, close and failure), the WCODEC handler, the refusal path back to tiles |
| `core/protocol.nelua` | `PROTO_WCODEC`, the WOPEN codec byte, `PROTO_VERSION` 5 |
| `agent/windows.nelua` | the detector in `stream_send`, `s.codec`, the encoder's lifetime, the branch around diff-and-encode |
| `lua/windows.lua` | `codec = 'auto' \| 'never'` |
| `docs/REMOTE_WINDOWS.md` | enc 2, WCODEC and the version 5 negotiation, once they exist |

Builds do not run on the machine the game is on: `tools/build-remote.sh`
builds in an Incus container on the fedora host and `tools/where-build.sh`
enforces it. The host-side work here — the codec seam, the detector, the
decoder before it goes near Wine — is the part that can be checked with tests
and valgrind rather than by staring at a panel, and it should be pushed as far
as it goes before anything is asked of the game.
