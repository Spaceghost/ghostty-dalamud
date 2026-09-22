# Many agents, and the transport under them

> Status: this is the required direction. Nothing here is implemented yet, and
> nothing has been observed in game. What is true today is in the first section.

Today the plugin talks to exactly one `ghostty-agent`, over one TCP connection,
and everything that says "agent" means that one. `lua/windows.lua:22` says so
outright, and `core/app/state.nelua:135-145` is the shape of it: a single
`agent: AgentClient` with nine sibling scalars tracking that connection.

The consequence the owner hit: pointing `CONFIG.agent` at another machine to
get its GPU moved the *terminals* there too, because a profile with
`transport = 'agent'` means "the agent", and there is only one.

Three changes, in this order. Each is useful on its own.

## 1. An agent is a named link, not the connection

`core/app/state.nelua` gets a record and a sequence:

```
AgentLink = @record{
  name: string,           -- 'local', 'fedora', … ; 'local' always exists
  client: AgentClient,
  enabled: boolean,
  last_try: float64,
  listed: boolean,
  prev_state: AgentState,
  seen: boolean,
  nonce: uint64,          -- the agent process last seen Ready
  error_shown: string,
  down: boolean,
}
```

`host.agents: sequence(AgentLink)`, index 0 named `local`. `host.agent` stays
as an alias for `host.agents[0]` so the call sites that mean "the default one"
do not move; the 45 references in `core/app/agent.nelua` are read once and
split into "this link" (most) and "the default link" (few).

Sessions need no change: `core/session.nelua` already holds `agent` as a
pointer and `core/app/agent.nelua:186` already passes `&host.agent` in. The
pump, the reconnect logic and `agent_on_ready`'s nonce comparison become
per-link loops.

Config:

```lua
agent = { host = '127.0.0.1', port = 7777, token_file = … }   -- still works: the 'local' link
agents = {
  fedora = { host = '100.100.1.10', port = 7788, token_file = … },
}
```

## 2. Shells are local unless they say otherwise

A terminal profile gains `agent`:

```lua
{ name = 'shell', transport = 'agent', agent = 'local', command = { '/bin/bash', '-l' } },
```

**`agent` defaults to `'local'`.** That is the rule the owner asked for: where
window panels come from must never decide where a shell runs. A profile that
wants a remote shell names the link, which is clearer than the ssh profiles
that do it by hand today.

`M.agent` in `lua/windows.lua` becomes the *window* default, and
`/window run --agent NAME CMD`, `/window pull --agent NAME` pick per call.
`window.list` already carries an `agent` field per panel; it stops being
always `"default"`.

What this does not do: two agents are two sources of panels, not two GPUs on
one panel. A window streams from the machine it runs on.

## 3. iroh under the transport, moq for the pixels

### Why

`core/sys/net.nelua` is eight functions — `connect`, `connect_poll`, `listen`,
`accept`, `recv`, `send`, `close`, `socket_fd` — and `AgentClient` only ever
holds a `NetSocket`. So the transport can be replaced without touching the
protocol.

TCP costs us two things that matter once there is more than one agent:

* **Head-of-line blocking.** Every window stream shares one connection, so a
  large KEY frame for one panel delays every other panel's frames and every
  keystroke on every shell.
* **Addressing.** `host:port` means a tailnet, a LAN, or port forwarding. A
  node identity does not.

### iroh

A Rust `staticlib`, `ghostty-iroh`, exposing the same eight-function C ABI, so
`net.nelua` gains a second backend rather than a rewrite. iroh gives direct
QUIC with hole punching, a relay fallback, and TLS identity by public key.

* The agent gets `--iroh` and prints its NodeId; `--listen` keeps working.
* Config: `agents = { fedora = { node = 'k51q…' } }` beside `host`/`port`.
* The token stays. iroh authenticates the *machine*; the token authorises the
  connection, and dropping it would make a NodeId a bearer credential.
* Under Wine: the plugin core is a PE DLL, so the crate cross-compiles to
  `x86_64-pc-windows-gnu` and links with the rest. UDP out of Wine works; that
  is the one thing to prove before building anything else.

**One QUIC stream per window stream** is the point of the exercise, and it is a
protocol change, not a transport swap: `sid` stops multiplexing inside one byte
stream. WACK-based flow control stays — QUIC's flow control bounds bytes, not
frames, and the 2-unacknowledged-`seq` rule is what bounds memory.

### moq

Media over QUIC replaces the *frame path* for windows that behave like video,
and only those.

* Today every rectangle is RAW BGRA or QOI: lossless, cheap for text, and
  hopeless for a video playing in a panel — `docs/REMOTE_WINDOWS.md` measures
  pixman capping such a window near 6 fps at 1280×720.
* A moq track carrying h264 or av1 for those windows costs a codec dependency
  and gives back full frame rate. Text panels keep QOI tiles: a lossy codec on
  a terminal is worse than what we have, not better.
* The choice is per stream and can be renegotiated: the agent already knows a
  window's damage rate, which is the signal for "this is video".

So: iroh is a transport swap with a protocol change on top, moq is a codec for
the streams that want one. They are separable and should land separately.

## Other people's machines

Everything above assumes the agents are the owner's. Once a friend runs one,
the security model has to change, and this is the part that should not be
built casually.

### What an agent grants today

One shared bearer token, and holding it gives: `run:CMD` (any command),
PTY shells through `transport = 'agent'` profiles, clipboard in both
directions, and capture of every window in the agent's compositor. That is a
remote shell service. It is the right amount of trust for loopback and a
tailnet of one's own machines, and the wrong amount for anything a friend
installs — one leaked token is a shell on every machine that accepts it.

### Trust runs both ways

* **Agent → plugin.** Whoever holds the token has a shell on the agent's
  machine. This is the one that matters for a friend running an agent for you.
* **Plugin → agent.** A panel is a window the agent's owner controls, and
  `WINPUT` sends your keystrokes and clipboard into it. A hostile agent reads
  everything you type into that panel. Anyone typing a password into a remote
  terminal panel is handing it to that machine's owner.

One good property already holds and should be defended: on Linux the agent's
compositor is not the host desktop (`docs/REMOTE_WINDOWS.md`, "the agent is the
compositor"). A friend showing you a browser does not expose their desktop, and
input you send reaches only the windows in that compositor.

### What iroh changes, beyond the transport

An iroh NodeId *is* an ed25519 public key, so identity stops being a shared
secret. Each side knows the other by key:

* the agent keeps an allowlist of client keys instead of one token;
* the plugin pins each link's agent key, like `known_hosts` but not optional.

Nothing has to be copied between machines except public keys, and a leak
reveals nothing.

### Capabilities, per peer

Identity alone is not enough: the friend needs to say what a known key may do.
Per peer, defaulting to **nothing** until granted:

```toml
[peer.k51q…]
name      = "jack"
windows   = ["org.mozilla.firefox"]  # may open only these
run       = false                    # no arbitrary run:
shell     = false                    # no PTY profiles
clipboard = "read"                   # none | read | write
```

`run = false, shell = false` is the setting that turns an agent from a remote
shell service into a window server, which is what a friend should be able to
offer without thinking hard about it.

This is independent of iroh and could land first: the agent has no per-peer
anything today, and adding it does not need a new transport.

## Order, and what proves each step

1. `AgentLink` + `host.agents`, one link, no behaviour change. Green tests.
2. A second link from config; `/window --agent`; profiles default to `local`.
   Proof: a shell on `local` while a panel streams from `fedora`.
3. iroh backend behind `net.nelua`, both ends, still one stream. Proof: a panel
   from a machine with no tailnet route and no port forward.
4. Per-window QUIC streams. Proof: a KEY frame on one panel not stalling typing
   on another — measurable, unlike the rest of this list.
5. moq for video-like streams. Proof: a video in a panel at more than 6 fps.

Steps 1 and 2 are the owner's actual complaint. Steps 3 to 5 are the interesting
part and should not be allowed to delay them.
