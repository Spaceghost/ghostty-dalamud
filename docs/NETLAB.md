# Netlab: iroh and moq, live, in game

A panel that shows two networking libraries doing real work: **iroh** (QUIC
between endpoints named by public keys, holepunched where it can be, relayed
where it cannot) and **moq**, Media over QUIC (a publisher's broadcast, split
into tracks, groups and objects, fanned out to subscribers, each of which
skips what it is too late for instead of queueing it). The payload is a window
from the agent's host, published as a moq broadcast over iroh and played back
into the game beside the view of how it got there.

Status: design. Nothing here has been seen in game yet.

## What the panel shows

```
 ┌ Netlab ─────────────────────────────────────────────────────────────────┐
 │  you  k4t2…9q  relay euw1 ● connected   ticket [copy]                   │
 │                                                                         │
 │  ┌ publisher ┐  broadcast netlab · track frames            ┌ fast ┐      │
 │  │ window:   │══ g41 ▪▪▪▪▪ ═══════ direct 192.0.2.4 0.4ms ═▶│ 38ms │ ▣    │
 │  │ foot      │   g42 ▪▪                                    └──────┘      │
 │  │ 30 fps    │══════════ relay → direct (holepunched 1.2s) ▶┌ slow ┐      │
 │  └───────────┘               ✕ g38 ✕ g39 skipped            │ 2 behind │ │
 │                                                             └──────────┘ │
 │  paths  ● direct 192.0.2.4:4433  rtt 0.4 ms  selected                   │
 │         ○ relay  https://euw1…   rtt 31 ms                              │
 │  timeline  0.0 relay opened · 0.2 relay selected · 1.2 direct opened    │
 │            · 1.3 direct selected                                        │
 │  ┌ what the fast subscriber sees ┐                                      │
 │  │   (the window, live)          │                                      │
 │  └───────────────────────────────┘                                      │
 └─────────────────────────────────────────────────────────────────────────┘
```

* **iroh:** this node's endpoint id (short form, the ticket to copy), its home
  relay and whether it is connected, every connection with every network path
  (relay or direct, which one carries the data, the round-trip time of each),
  and a timeline of path events: a connection starts on the relay, direct
  paths open as holepunching succeeds, and the selected path switches, live.
* **moq:** the publisher (broadcast, track, the group and object at its live
  edge), each subscriber drawn as the end of a pipe along which objects fly,
  grouped by colour per group; per subscriber its latency (publisher's clock to
  ours), where it is against the live edge, and the groups moq **skipped** or
  **cut** for it. A slow subscriber (one that reads slowly on purpose) shows
  what moq does when you fall behind: whole groups disappear, the next one
  starts with a key frame, nothing queues up.
* **The payload:** the fast subscriber's frames, decoded and drawn in the
  panel.

## Data path

```
 host A (publisher)                                       host B, or A again
 ┌──────────────────────────────┐   iroh (QUIC, UDP)   ┌───────────────────────────┐
 │ ghostty-agent                │   direct or relayed  │ ghostty-agent             │
 │  capture backend ─▶ netlab   │═════════════════════▶│  netlab: subscription     │
 │  (a window)        publisher │   moq-lite session   │   objects ─▶ NLFRAME      │
 │  wincodec: KEY + deltas      │                      │   stats   ─▶ NLSTAT       │
 │  moq_iroh (Rust, static lib) │                      │  moq_iroh                 │
 └──────────────────────────────┘                      └───────────┬───────────────┘
                                                                   │ agent protocol (TCP, token)
                                                       ┌───────────▼───────────────┐
                                                       │ plugin core               │
                                                       │  core/app/netlab.nelua    │
                                                       │   NLFRAME ─▶ wincodec ─▶  │
                                                       │   texture (wintex)        │
                                                       │   NLSTAT ─▶ lua/netlab.lua│
                                                       │  lua/netlab.lua: layout,  │
                                                       │   animation, ghostty.ui   │
                                                       └───────────────────────────┘
```

* **The network belongs to the agent** (as in MULTIPLEXER.md, "The agent does
  its own TLS"): the iroh endpoint and the moq sessions keep running while the
  game reloads the plugin or sits in a loading screen, and nothing in the game
  process opens a socket to a peer. The plugin renders what the agent reports.
* **One agent can be both ends.** `netlab demo` makes the agent's main node
  publish, and two more nodes in the same agent (separate iroh endpoints,
  separate UDP sockets) subscribe to it over real iroh connections: one at full
  speed whose frames are shown, one throttled to show skipping. A second agent
  on another machine subscribes with the first one's ticket; the panel of
  whichever agent the game talks to shows that agent's side.
* **Objects are window frames.** The publisher reads a capture backend
  (`agent/capture.nelua`: the Linux compositor, Win32, macOS, or `--windows
  test`), downscales, diffs and encodes exactly as a window stream does
  (`core/wincodec.nelua`: QOI tiles in WFRAME frames). A moq group starts with
  a KEY frame (every second, or on a size change) and its objects are the
  deltas after it, so a subscriber that joins or loses a group recovers at the
  next group: the moq model and the codec agree.
* **Latency** is the subscriber's wall clock minus the publisher's, carried in
  each object: exact on one host, as good as clock sync between two.

## The moq and iroh side: `moq_iroh`

moq and iroh are Rust. The owner's moq fork (Spaceghost/moq, branch
`spaceghost`) gains `rs/moq-iroh-c`: a static library and a cbindgen header
built on the fork's `moq-tokio` (its iroh transport, iroh 1.0) and `moq-net`.
The existing `moq_ffi` is UniFFI (RustBuffer and foreign-future calls meant for
generated wrappers) and `libmoq` delivers through callbacks on its runtime
thread, cannot accept sessions and cannot reach iroh, so neither fits a C
`poll()` loop. `moq_iroh` never calls back: results are queued, a descriptor
becomes readable, the agent drains.

| Call | Does |
|---|---|
| `moqi_node_new(&{secret_path, relay, port})` | bind an iroh endpoint serving a moq origin; `relay` is `default` (n0's relays and address lookup), `off`, or a relay URL |
| `moqi_node_ticket(node, buf, cap)` | `iroh://<endpoint id>?relay=…&addr=…`, what a peer dials |
| `moqi_publish(node, broadcast, track)`, `moqi_publish_object(pub, data, len, new_group)`, `moqi_publish_close` | a broadcast with one track; objects, a new group on demand |
| `moqi_subscribe(node, ticket, broadcast, track, max_age_ms)`, `moqi_subscribe_throttle(sub, ms)`, `moqi_subscribe_close` | dial and subscribe; moq skips groups older than `max_age_ms` |
| `moqi_read(sub, &object, buf, cap)` | the next object: group, index, sent and received time, flags (group start, gap) |
| `moqi_wake_fd()`, `moqi_wake_clear()` | the descriptor the agent's `poll()` watches |
| `moqi_stats(node, buf, cap)` | JSON: id, ticket, relays, connections and their paths with rtt, the path timeline, moq-net's traffic counters, publishers, subscriptions |
| `moqi_last_error(buf, cap)` | why the last call failed |

The agent links it statically (`agent/moqi.nelua`, `<cimport>` of
`moq_iroh.h`). `tools/fetch-vendor.sh` builds it from the commit pinned in
`toolchain.env` with cargo into `vendor/moq-iroh`; without it (no cargo, or
`SKIP_NETLAB=1`) the agent builds without netlab and says so when asked.

## Agent protocol (additive)

Numbers 48 to 51, clear of what exists (up to 41) with room between. Clients
send NLCTL only to agents greeting with version 4 or later; an agent that
does not know it answers ERR "unknown frame", which the plugin shows as "this
agent has no netlab".

client → agent

| type | name | payload |
|---|---|---|
| 48 | NLCTL | req u32, UTF-8 command line (below) |

agent → client

| type | name | payload |
|---|---|---|
| 49 | NLREPLY | req u32, ok u8, UTF-8 text (a subscription id, a ticket, or why not) |
| 50 | NLSTAT | UTF-8 JSON: `{"t_ms", "built", "nodes": [{"role", "name", …moqi_stats…}], "pubs": […], "subs": […]}`, pushed to connections that asked with `watch` |
| 51 | NLFRAME | sub u32, group u64, index u32, flags u8, lat_us u32, then WFRAME frames (header and payload each) making one picture |

Commands:

| Command | Does |
|---|---|
| `start [relay=default\|off\|URL] [port=N]` | bind the main node (key in the agent's config directory, so the id stays) |
| `publish NAME [window=MATCH] [fps=N] [size=WxH] [group=MS]` | publish a window as broadcast NAME, track `frames` |
| `subscribe TICKET NAME [age=MS] [slow=MS] [view]` | a new local node subscribes; `view` sends its frames here as NLFRAME |
| `slow SUB MS`, `view SUB on\|off`, `unsubscribe SUB`, `unpublish NAME`, `stop` | as named |
| `demo [window=MATCH]` | start, publish `netlab`, subscribe a fast viewed and a slow node to it |
| `watch MS` | NLSTAT every MS milliseconds to this connection (0 stops) |
| `ticket` | the main node's ticket |

NLFRAME goes to one connection and never piles up: while that connection's
output queue is over 4 MiB the agent drops objects until the next group
start and counts them (`dropped_to_client`).

## The plugin side

* `core/app/netlab.nelua`: NLCTL out, NLREPLY / NLSTAT to Lua, NLFRAME decoded
  (wincodec) into a pixel buffer per subscription and uploaded to a texture
  (`core/wintex.nelua`) once per frame; the glass window, drawn like the /ask
  panel.
* `core/uidraw.nelua`: a few more `ghostty.ui` calls for drawing, in their own
  file: `canvas(w, h)`, `line`, `rect`, `circle`, `text_at`, `color(name, a)`
  from the theme, `netlab_image(sub, w, h)`.
* `lua/netlab.lua`: everything the panel decides: layout, the pipeline
  animation (objects are dots that leave the publisher when NLFRAME says they
  were sent and arrive after their measured latency), colours from the theme,
  the commands. `/term netlab [demo|sub TICKET|slow N|ticket|stop]`.
* `/term selftest netlab` checks the panel against a live agent.

## Tests

| Where | What |
|---|---|
| Spaceghost/moq `rs/moq-iroh-c` | direct and relayed-then-direct connections, publish/subscribe with stats on both ends, a throttled subscriber skipping groups, errors, the header |
| `tests/test_netlab.nelua` | the agent's netlab against `--windows test`: publish, two local subscribers, frames decoded back to the test picture, the slow one skipping |
| `tests/test_netlab_agent.nelua` | the protocol over TCP against a real agent: NLCTL, NLREPLY, NLSTAT, NLFRAME; an agent without netlab |
| `tools/netlab-containers.sh` | two agents in two Incus containers (plus `iroh-relay --dev` in a third): B subscribes to A over iroh, starting on the relay, and the probe checks the stats the panel reads on both |
| `tests/test_netlab_panel.nelua`, `tests/test_netlab.lua` | the panel through fake ImGui: layout, animation, video quads, commands |

## Not covered

* The Windows agent: `moq_iroh` is only built for Linux so far; the Windows
  and macOS agents answer "netlab not built".
* No access control: anyone with the ticket can subscribe to a netlab
  broadcast. It is a demo of the transport; sharing real windows with peers
  is the multiplexer's job, with its grants (MULTIPLEXER.md).
