# iroh under the transport

> Status: this is the required direction, not a claim that it works. Nothing
> here is built. One thing has been measured and is marked as such; everything
> else is design, and the parts most likely to be wrong are named.

`docs/MULTI_AGENT.md` step 3 says "iroh backend behind `net.nelua`, both ends,
still one stream". This is that step written out, plus step 4 at the end
because the shape of step 3 has to leave room for it.

## What is already known

* **The seam is real.** `core/sys/net.nelua` is the whole transport surface:
  `init`, `shutdown`, `invalid`, `is_valid`, `close`, `connect`,
  `connect_poll`, `listen`, `accept`, `recv`, `send`, `socket_fd`.
  `core/agent_client.nelua` only ever holds a `NetSocket`; the agent only ever
  holds one in `Client.sock` (`agent/agent.nelua:74-81`). The subsystems
  (`agent/windows.nelua`, `agent/jobs.nelua`, `agent/clips.nelua`) are handed
  `queue_of: function(ci: usize): *ByteQueue` and never see a handle at all.
* **UDP out of Wine works, both directions.** Measured on this machine: a PE32+
  binary built by `zig cc -target x86_64-windows-gnu`, run under the game's own
  Wine build and prefix, against a UDP echo server on the fedora tailnet host.
  That is the one fact that makes QUIC from the PE core viable. It is *not*
  evidence that iroh's socket setup, hole punching, or relay fallback work
  under Wine — those are the next things to prove, in that order.
* **Nothing builds on this machine while the game is up.** `tools/build.sh`
  execs `tools/run-placed.sh`; `tools/where-build.sh` defaults to remote and
  `tools/build-remote.sh` runs the build in an Incus container on the fedora
  host. Every build step below happens there.

## The shape: one crate, two targets, one C ABI

A Rust `staticlib` called `ghostty-iroh`, built twice — host glibc for
`ghostty-agent`, `x86_64-pc-windows-gnu` for `ghostty_core.dll` and
`ghostty-agent.exe` — exposing a C ABI that `net.nelua` binds with a
`## linklib`, exactly the way `core/ghostty.nelua:11-12` binds libghostty-vt
and `core/sys/net.nelua:5-7` binds ws2_32.

The crate owns an iroh `Endpoint` and a Tokio runtime on threads of its own.
Nelua never sees a Rust type, never blocks, and never calls from more than one
thread. Everything crossing the boundary is a scalar or a `const uint8_t*`.

### Handles

```c
typedef uint32_t gi_handle;        /* 0 is always invalid */
```

A handle is a 1-based generation-tagged index into a slot table inside the
crate: low 16 bits slot, high 16 bits generation, so a stale handle from a
closed connection is rejected rather than aliasing a new one. `0` is invalid on
both platforms, which matters because `net.invalid()` is `-1` on POSIX (where
`0` is a valid fd) and `INVALID_SOCKET` on Windows. The backend switch in
`net.nelua` must therefore be a *type* choice at comptime, not a value test —
see "Two backends" below.

### The functions

```c
/* lifecycle */
int32_t    gi_init(const char *secret_key_path);   /* 0 ok, <0 gi_error */
void      gi_shutdown(void);                      /* joins the runtime */

/* identity */
int32_t    gi_node_id(char *out, size_t cap);      /* z-base-32, >=64 bytes; bytes written or <0 */

/* client */
gi_handle gi_connect(const char *node_id);        /* returns immediately, 0 on bad addr */
int32_t    gi_connect_poll(gi_handle h);           /* 1 connected, 0 pending, <0 gi_error */

/* server */
gi_handle gi_listen(const char *allowlist_path);  /* one endpoint, accepts inbound */
gi_handle gi_accept(gi_handle listener);          /* 0 when nothing pending */
int32_t    gi_peer_id(gi_handle h, char *out, size_t cap);

/* data */
int32_t    gi_recv(gi_handle h, void *buf, size_t cap);   /* >0 n, 0 again, <0 gi_error */
int32_t    gi_send(gi_handle h, const void *buf, size_t len); /* >=0 n, 0 again, <0 gi_error */
void      gi_close(gi_handle h);                  /* no-op on 0 or stale */

/* readiness — see "No fd" */
int32_t    gi_wakeup_fd(void);                    /* POSIX: read end of a pipe/eventfd, -1 if none */
void      *gi_wakeup_handle(void);                /* Windows: manual-reset event HANDLE, NULL if none */
void      gi_wakeup_drain(void);                  /* clear the readiness signal */
int32_t    gi_wait_ms(int32_t cap_ms);            /* how long the caller may sleep, <= cap_ms */
```

Twelve functions for the ten `net.nelua` ones plus identity and readiness.

### Ownership and lifetime

* **Every buffer is caller-owned and borrowed for the duration of the call.**
  `gi_send` copies into the stream's outgoing buffer before returning; `gi_recv`
  copies out. No pointer given to Rust is retained, and no pointer returned by
  Rust is owned by Nelua — `gi_node_id` and `gi_peer_id` write into a
  caller-supplied array. There is no `gi_free`, deliberately: nothing the
  crate allocates ever crosses the boundary.
* **No callbacks into Nelua, ever.** This is not a style preference. The
  Wine loader unloads `ghostty_core.dll` while the process lives on
  (`core/host.nelua:307` calls `net.shutdown` on core unload), and a surviving
  Rust thread holding a function pointer into the unloaded module is the crash
  to design against. Readiness is a signal the caller polls, never a call
  inward.
* **The endpoint is a singleton owned by `gi_init`, not by a connection.**
  `net_started` (`core/sys/net.nelua:77`) is per-loaded-copy of the core and
  sized for `WSAStartup`; an iroh endpoint is a runtime, a UDP socket, a relay
  connection and a key. `gi_init` refcounts; `gi_shutdown` on the last
  reference must actually stop the runtime, close the endpoint, and *join* the
  threads before returning. If it cannot join within a bounded time it must say
  so rather than return and let the DLL unmap underneath.
* **Handles are thread-confined to the caller's thread.** The runtime lives on
  its own threads; the slot table is behind a mutex the caller never contends
  for more than a slot lookup. The game thread is the only caller in the core
  (`core/agent_client.nelua` has no locking anywhere), and the agent's main
  loop is the only caller there.
* **`gi_close` is synchronous and void, and must not leak.** The reconnect path
  runs forever when an agent is down: `core/agent_client.nelua:87-91` closes and
  `core/app/agent.nelua:417-422` reconnects 3 seconds later. A graceful QUIC
  close is asynchronous; `gi_close` hands the connection to the runtime to
  drain and frees the slot immediately. Per cycle it must leak no slot, no task
  and no socket. **Unproven: this is the thing to run under valgrind and under a
  multi-hour agent-down loop before believing it.**

### Error model

Negative returns only, one enum, no errno, no strings crossing the boundary
except on demand:

```c
#define GI_EAGAIN       0   /* not an error: "again next frame" */
#define GI_ECLOSED     -1   /* peer closed cleanly (FIN) */
#define GI_ERESET      -2   /* RESET_STREAM */
#define GI_ETIMEOUT    -3   /* idle timeout / connection lost */
#define GI_EREFUSED    -4   /* peer reachable, refused (not allowlisted) */
#define GI_EUNREACH    -5   /* no path, relay included */
#define GI_EADDR       -6   /* unparseable NodeId */
#define GI_EHANDLE     -7   /* stale or unknown handle */
#define GI_EINTERNAL   -8
int32_t gi_last_error(char *out, size_t cap);  /* human text for the log line only */
```

The contract `net.nelua` must preserve is narrower than this enum, and getting
it wrong tears down connections:

* **`recv` returns `0` for "nothing right now" and `-1` for EOF *or* error.**
  `core/sys/net.nelua:229-235` collapses them deliberately, and
  `core/agent_client.nelua:680-685` maps `-1` to `AgentState.Failed` plus
  "connection closed". The iroh backend keeps that collapse: every `GI_E*`
  becomes `-1` at the `net.recv` boundary, and the distinction survives only in
  the log line from `gi_last_error`. This is lossy — a `RESET_STREAM` on one
  window stream will look identical to the agent dying — and it is the right
  trade only while there is one stream. Step 4 below changes it.
* **`send` must return `0`, not an error, when flow control is blocked.**
  `flush` at `core/agent_client.nelua:631-637` treats `-1` as "connection lost"
  and tears down; `0` is "stop, retry next frame". A full QUIC stream window is
  `GI_EAGAIN` → `0`. Partial writes are fine — `flush` already handles them.
* **`connect` signals failure by handle, not return code.** `net.connect`
  returns a `NetConn` whose failure is `net.is_valid(conn.sock) == false`
  (checked at `core/agent_client.nelua:104` and `agent/agent.nelua:607`), so
  `gi_connect` returning `0` is exactly the existing shape.

### Non-blocking connect without a socket

`net.connect_poll` (`core/sys/net.nelua:188-201`) works today by re-issuing
`connect()` against the stored `sockaddr_in` and reading `EISCONN`/`EALREADY`/
`EINPROGRESS`. That trick has no QUIC analogue, and a 32-byte NodeId does not
fit a `sockaddr_in`.

So `NetConn` stops being a struct with a public `addr` and becomes opaque:

```
NetConn = @record{
  sock: NetSocket,
  connected: boolean,
  backend: <comptime-selected state>,   -- sockaddr_in, or nothing
}
```

`.sock` and `.connected` stay, because those are the two fields
`core/agent_client.nelua:103-111` reads. `.addr` becomes backend-private. Every
other access has to be audited; there are few.

`gi_connect` spawns the connect task and returns a handle in the `Connecting`
state immediately. `gi_connect_poll` is a slot-table lookup and an atomic read —
no syscall, no lock beyond the slot mutex, cheap enough for ~60 calls a second,
and idempotent after success because the state latches. It must reach a
terminal state within 5 seconds or the client fails it anyway
(`core/agent_client.nelua:657`). iroh's own connect can take longer than that
when it falls back to a relay, so **the crate sets its own connect deadline
below 5 s and reports `GI_ETIMEOUT`**, rather than letting the client's timer
fire against a handle still doing work. Unproven: whether a relay-only path
routinely completes inside that budget. Measure before picking the number.

### No fd — this is the hard part

Say it plainly: **a QUIC stream is not a file descriptor, and the honest answer
is that the caller's wait loop has to change on both ends.** `net.socket_fd`
(`core/sys/net.nelua:246`) has no iroh equivalent. The best a backend can offer
is the endpoint's own UDP socket, which is one fd for the whole endpoint and
tells you nothing about any particular stream.

The two ends are in very different shape.

**The client: no problem at all.** `net.socket_fd` has zero call sites in
`core/`. The plugin core never polls; it spins once per rendered frame —
`agent_pump(now)` at `core/app/agent.nelua:413` calls `AgentClient:pump`, which
polls connect, flushes, does a bounded read (`read_chunks` × 16 KiB, 8 by
default, 64 while window streams are live, `core/agent_client.nelua:673` and
`core/app/remotewin.nelua:1597`) and dispatches. A frame-clocked poll of
`gi_recv`/`gi_send` is exactly what the backend wants. Step 3 is a genuine
drop-in at the client.

**The agent: needs a wakeup, and it already has the fallback.** The POSIX loop
(`agent/agent.nelua:810-857`) rebuilds a flat `fds: [512]pollfd` each pass and
calls `poll(&fds, n, windows_cap(250))` at `:841` — and then *never reads
`revents`*. Lines 843-856 unconditionally accept, pump every client, session,
window, job and clip. `poll` is a sleep with wakeups, not a dispatcher.

That gives two things:

1. **Correctness does not depend on an fd.** An iroh connection with nothing in
   the `fds` array is still pumped every pass. What suffers is latency, bounded
   by the 250 ms `windows_cap` (`agent/agent.nelua:570-576`, already shortened
   by `windows:wait_ms` and `jobs:wait_ms`).
2. **The tidy fix is small and matches the existing pattern.** The crate owns
   an eventfd (or pipe) that the runtime writes when any connection has data or
   a listener has a pending accept; `gi_wakeup_fd()` hands the read end to the
   agent, which pushes it into the same heterogeneous `fds` array that already
   holds sockets, PTYs, D-Bus, PipeWire and job pipes. `gi_wakeup_drain()` is
   called once per pass. Additionally `gi_wait_ms(cap)` plugs into
   `windows_cap` the way `windows:wait_ms` does, so a backend that *cannot*
   produce an fd still shortens the sleep.

The Windows agent loop (`agent/agent.nelua:755-808`) waits on HANDLEs via
`winloop_wait`, so there `gi_wakeup_handle()` returns a manual-reset event. It
matters less: `ghostty-agent` is the native Linux binary, and the PE side is the
plugin core, which does not poll. `agent/agent.nelua:780-784` already logs and
degrades to 50 ms polling on handle overflow — the same fallback an fd-less
transport uses.

Two hazards to keep in view rather than fix here:

* The `fds[512]` cap silently drops entries past 512, with no log (guards at
  `agent/agent.nelua:818, 825, 831, 838`), unlike the Windows path which logs at
  `:780-783`. Harmless only because `revents` are ignored. The moment anything
  dispatches on `revents` — which per-stream readiness would want — it is a
  starvation bug.
* One wakeup fd for the whole endpoint means a level-triggered readiness signal
  that says "something, somewhere". That is fine for a loop that pumps
  everything anyway, and useless for a loop that dispatches. Step 4 has to
  decide which loop it wants.

## Two backends in net.nelua, protocol untouched

`net.nelua` grows a comptime backend selection, not a runtime one, because
`NetSocket` is a type:

```
## local NET_BACKEND = NET_BACKEND or 'bsd'
## if NET_BACKEND == 'iroh' then
  ## linklib 'ghostty_iroh'
  global NetSocket = @uint32
## else
  -- existing Windows/POSIX split, unchanged
## end
```

Rules this has to obey:

* **The TCP path stays compiled in, always.** `tests/test_agent.nelua`,
  `tests/smoke_windows_win32.nelua:115` and `tests/test_agent_windows.nelua:101`
  bind real loopback sockets. A backend switch that *replaces* BSD sockets
  breaks the suite. And `agent/agent.nelua:745` `capture_wayland_set_agent` has
  the Wayland capture helper connecting *back* to the agent over the TCP listen
  spec with the token file — the loopback listener cannot go away.
* **Therefore the real shape is a tagged handle, not a compile-time swap.**
  `NetSocket` becomes a small record `{ kind: uint8, h: uint64 }`, or the
  handle carries a tag bit; `net.close`/`recv`/`send` dispatch on it. There is
  no backend tag anywhere in `NetSocket` today, and `net.is_valid` is literally
  `s ~= net.invalid()` (`core/sys/net.nelua:107-109`). Both have to be revisited
  together, and the cost is a branch per call on a path that already does a
  syscall. On the agent, `Client.sock` gains the same tag; it is read at exactly
  `agent/agent.nelua:432, 449, 521, 818` (plus `:791` for `ev`), so the blast
  radius is five lines.
* **`setsockopt` moves behind the backend.** `TCP_NODELAY`
  (`core/sys/net.nelua:176, :223`) and `SO_REUSEADDR` (`:211`) are meaningless
  for QUIC and must not stay in shared code.
* **The protocol does not change.** `core/protocol.nelua:223-235` reads a u8
  type and u32 LE length off the head of *one* contiguous byte stream and waits
  for `PROTO_HEADER + len` contiguous bytes. One iroh bidirectional stream per
  connection carries exactly that, and `inq`/`outq` stay single. Feeding more
  than one QUIC stream into one `inq` produces garbage — which is why step 4 is
  a protocol change, not a transport change.
* **Backpressure changes character, quietly.** `read_chunks` bounds the client
  to 8 or 64 × 16 KiB per frame (`core/agent_client.nelua:673`), and the design
  assumes unread bytes sit in the *kernel* socket buffer so the agent stalls.
  QUIC flow control bounds bytes per stream, but iroh may buffer received data
  in userspace whether or not the game called `recv`. That turns kernel
  backpressure into userspace memory growth. **Unproven and worth measuring
  early**: a large KEY frame burst with the client deliberately reading slowly,
  watching the crate's RSS. If it grows without bound, the crate needs its own
  receive cap that stops reading the stream.
  The agent side survives unchanged: `session_blocked`
  (`agent/agent.nelua:211-217`) and `OUTQ_HIGH` (`:96`) are expressed purely in
  `outq` length, which is transport-independent.

## Addressing a link

`CONFIG.agents` gains `node` beside `host`/`port`, as `docs/MULTI_AGENT.md:100`
says:

```lua
agents = {
  fedora = { node = 'k51q…', token_file = … },      -- iroh
  nuc    = { host = '100.100.1.10', port = 7788 }, -- TCP, unchanged
}
```

A link with `node` uses the iroh backend; a link with `host`/`port` uses BSD
sockets; both is an error, not a fallback, because a silent fallback hides
exactly the failure step 3 is meant to prove ("a panel from a machine with no
tailnet route and no port forward").

This is not free at the seam. Addressing is `host: string` + `port: uint16` all
the way up: `parse_ipv4` (`core/sys/net.nelua:151-161`) accepts only an IPv4
literal — there is no DNS anywhere, `getaddrinfo` is imported at `:52-65` and
never called — and `AgentClient` stores host and port as fields
(`core/agent_client.nelua:37-38`, set in `:init` at `:63-64`, used at `:103`).
A NodeId can be smuggled through `host` with `port` ignored, and that is the
smallest change, but `AgentClient:init`'s signature, the config mapping that
logs `host:port` (`core/app/agent.nelua:275`) and the error strings all encode
the assumption. Prefer an explicit `addr` variant over the smuggle; it is a
handful of lines and it keeps the log readable.

The plugin pins each link's agent key on first use and refuses a changed key —
`known_hosts` but not optional (`docs/MULTI_AGENT.md:164`).

## The token, after public-key auth

**The token stays.** iroh authenticates the machine; the token authorises the
connection. Dropping it makes a NodeId a bearer credential, and NodeIds are
not secret.

More importantly the *handshake frame* stays regardless of what authenticates
it, because it carries more than authentication. `agent.hello` is
`"ghostty-agent <PROTO_VERSION> <nonce>"`, built at `agent/agent.nelua:732-739`,
and the nonce is what tells a reconnecting client whether its session ids still
mean the same shells. A key-authenticated transport that skips `PROTO_HELLO`
silently breaks reattach.

The seam is one boolean. `handle_frame` (`agent/agent.nelua:287-305`) accepts
only `PROTO_HELLO` until `c.authed`, compares the whole payload to
`agent.token` by string equality at `:292`, replies `PROTO_OK` with
`agent.hello`, and drops the client otherwise. So:

* an iroh connection whose peer key is on the allowlist may have `c.authed`
  pre-granted at accept time;
* `:290` then accepts a `PROTO_HELLO` with an empty payload when `authed` was
  pre-granted, and still replies with `agent.hello`;
* `--iroh` without an allowlist entry for the peer is `GI_EREFUSED` at the
  transport, before any frame.

Whether the token is *also* required on iroh links is a policy flag, not a
protocol question, and the same one-boolean seam serves both readings.

What this does **not** give: `c.authed` is binary and grants the entire frame
table below `agent/agent.nelua:306`, including `OPEN` with arbitrary argv
(`:306-345`). The per-peer capabilities in `docs/MULTI_AGENT.md:169-188` have no
representation in the agent today, and they belong on the same `Client` record
the transport work modifies. **Sequence them so they do not collide** — and
note that capabilities are independent of iroh and could land first.

One more thing that should land before the transport, for the same reason:
`ci` is a bare index into `agent.clients`, renumbered on every disconnect
(`reap()` at `agent/agent.nelua:497-541`, hand-decrementing at `:511, :515`),
and it is stored durably in `WinStream.client` (`agent/windows.nelua:31`),
`Job.client` (`agent/jobs.nelua:41`), `Clip.client` (`agent/clips.nelua:38`),
`Session.attached`/`detached` (`agent/agent.nelua:68-69`). It is already not
uniformly correct: `AgentClips:client_gone` (`agent/clips.nelua:481-493`) does
**not** decrement indexes above `ci`, while `AgentWindows:client_gone`
(`agent/windows.nelua:468-480`) and `AgentJobs:client_gone`
(`agent/jobs.nelua:408-423`) both do — so after a disconnect a surviving clip
can point at the wrong client and `client_queue` (`agent/agent.nelua:564`) will
hand its frames to someone else. Read-only finding, not reproduced at runtime;
pre-existing, not caused by this work. Two listeners interleaving connects and
disconnects makes it far more reachable. A monotonic `Client.id` resolved by
`client_queue` removes the class, is independent of iroh, and is testable with
the suites that exist.

## The agent's --iroh mode

`--listen` keeps working and stays on by default. `--iroh` is additive.

Three edits, all in `main()` and the loop:

1. `agent/agent.nelua:725` — `agent.listen_sock = net.listen(host, port)`
   becomes one entry of a small listener set. Add `--iroh` beside `--listen` in
   the arg loop at `:697-720`, and print the NodeId next to the
   `listening on …` line at `:731`. The key is persisted (an ed25519 secret in
   the agent's state dir, mode 0600) so the NodeId survives restarts — a
   NodeId that changes on restart is unusable in `CONFIG.agents`.
2. `agent/agent.nelua:813` / `:756` — add `gi_wakeup_fd()` / `gi_wakeup_handle()`
   to the wait array, and `gi_wait_ms` into `windows_cap`.
3. `agent/agent.nelua:843-848` (POSIX) / `:789-799` (Windows) — the accept loop
   gains a second `gi_accept` drain alongside `net.accept`, pushing a `Client`
   whose `sock` carries the iroh tag. Both drains terminate the same way: on an
   invalid/zero handle.

`--iroh` does not remove the loopback TCP listener, because
`capture_wayland_set_agent` (`agent/agent.nelua:745`) connects back over it.

## Cross-compilation

Both facts here were measured; the plan after them is not.

**Measured, in the build container (`incus exec fedora:ghostty-build`):**
`cargo`, `rustc` and `rustup` are all MISSING. `zig` is 0.16.0. `dnf` offers
`rust` and `cargo` 1.98.1-1.fc44, `rust-std-static-x86_64-pc-windows-gnu`
1.98.1-1.fc44, and `mingw64-gcc` 16.1.1-1.fc44 — so Fedora ships the
windows-gnu std and no rustup is needed. Nothing installs them today:
`BUILD_PKGS` / `BUILD_PKGS_PINNED` in `toolchain.env` (installed at
`tools/build-container.sh:165` and `:152`) contain no Rust entry.

### Pinning, to the standard the repo already holds

`tools/fetch-vendor.sh` has exactly four idioms — git checkout at a full commit
SHA (`clone_pin`, `:9-19`), tarball + sha256 (`:26-34`), raw file + sha256
re-verified every run (`:37-42`), and RPM by exact NVR with `name:sha256` pairs
plus a `.pinned` stamp (`:47-67`). Zig is gated on exact version equality
(`tools/build.sh:62-63`). A bare `cargo build` against crates.io matches none of
them and would be the only dependency in this repo that reaches the network at
build time. So:

* `RUST_VERSION=` in `toolchain.env`, and the toolchain pinned as NEVRs in
  `BUILD_PKGS_PINNED`
  (`rust-1.98.1-1.fc44 cargo-1.98.1-1.fc44 rust-std-static-x86_64-pc-windows-gnu-1.98.1-1.fc44`),
  or as a pinned tarball the way Zig is at `tools/build-container.sh:168-184`;
* `Cargo.lock` committed, the tree `cargo vendor`-ed with a `.cargo/config.toml`
  replace-with stanza, built `--offline --locked`. Note `vendor/` inside the
  container is a symlink into the shared Incus cache volume
  (`tools/build-remote.sh:145-149`) and is *not* part of the rsynced source
  (`:134-141`), so a committed vendor tree and a fetched one need different
  handling — pick one and say which.

### Linking

Nelua compiles *and* links in one invocation, so every linker flag is a string
inside `--cflags`. There is no single place to add a library. Five shell lines
plus a pragma:

1. `core/sys/net.nelua` — `## linklib 'ghostty_iroh'` beside the existing
   `## linklib 'ws2_32'` (`:7`), under the backend guard.
2. `tools/build.sh:123` and `:128` — core and loader. `-L"$ROOT/build/win/lib"`
   is already on those lines, so dropping `libghostty_iroh.a` there is the
   smallest change.
3. `tools/build.sh:115` — the host agent passes *no* `--cflags` today; one must
   be added (`-L"$ROOT/build/lib"`).
4. `tools/build.sh:131` — `ghostty-agent.exe` needs the same `-L` as the core.
5. `tools/build-agent.sh:35` and `tests/run.sh:69, :94, :98, :156, :191`, which
   build their own `$LIBS` strings. Miss one and it surfaces as an
   undefined-symbol failure in a different stage than the one you edited.

The staticlib is built as a new `== ghostty-iroh` step inside the `SKIP_DEPS`
block (`tools/build.sh:65-91`), beside libghostty-vt and Lua, emitting host and
windows-gnu `.a` into `build/lib` and `build/win/lib`. It must respect
`SKIP_WIN=1` (`tools/ci/run.sh:172, :176`) and `SKIP_DEPS=1`.

### The two risks

* **MinGW single-pass linking.** A Rust staticlib's Windows system deps must be
  named *after* it on the `zig cc` line. For an iroh-shaped tree expect at
  least `ws2_32` (already there), `bcrypt`, `ntdll`, `userenv`, `advapi32`,
  `iphlpapi`, `secur32`, `crypt32`. Order matters.
* **Two mingw-w64 copies.** `rust-std-static-x86_64-pc-windows-gnu` ships its
  own mingw import libs and `libgcc_eh` objects; `zig cc -target
  x86_64-windows-gnu` (`tools/zig-cc-win.sh:8`) bundles a different mingw-w64.
  Mixing them is the concrete failure mode — duplicate or missing
  `__chkstk_ms`/`___chkstk_ms`, unwind symbols. Unverified; nothing has been
  built. The arrangement to try first is `CARGO_BUILD_TARGET=x86_64-pc-windows-gnu`
  with `CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER` pointed at
  `tools/zig-cc-win.sh`, which keeps one toolchain. Also untested.

The host side is the easy half: the agent is linked by `zig cc` against glibc,
and a Fedora-packaged rustc produces objects for the same Fedora 44 glibc the
agent already inherits.

### Two gaps in coverage, stated rather than papered over

* `tests/static-budget.txt` counts come from Fedora gcc/clang/cppcheck via
  `tools/ci/in-fedora.sh:10`. A Rust crate is invisible to that gate. Either
  `clippy -D warnings` joins the Fedora CI step or the new code has no
  static-analysis coverage at all — say which, in `docs/CI.md`.
* `sccache` today only wraps plain `-c` compiles (`GHOSTTY_SCCACHE` via
  `tools/zig-cc*.sh`). Caching rustc needs `RUSTC_WRAPPER=sccache` in the
  container profile written at `tools/build-container.sh:204-232`, and a new
  cache dir in the list at `:186-197`. iroh's tree is large (QUIC + TLS +
  crypto) and the container is 8 CPU / 32 GiB. Absolute paths inside the
  container are part of every sccache key, so the Rust build directory needs a
  fixed container path for the same reason everything else does.

## After the drop-in: one QUIC stream per window stream

Step 3 changes the transport and nothing else. Step 4 is the point of the
exercise and it is a **protocol change**, as `docs/MULTI_AGENT.md:107-110`
already says. It cannot be reached by swapping `net.nelua`.

### What has to move

* **One `inq`/`outq` per stream.** `proto.read_frame`
  (`core/protocol.nelua:223-235`) reassembles from one contiguous byte stream.
  Several QUIC streams into one `inq` is garbage. On the agent,
  `client_queue`'s `function(ci: usize): *ByteQueue`
  (`agent/agent.nelua:564-567`) — the only handle `windows`, `jobs` and `clips`
  ever get (`agent/windows.nelua:64,74`, `agent/jobs.nelua:59,63`,
  `agent/clips.nelua:57`) — has to become per-stream. That signature is the
  whole interface between the transport and the subsystems, which is good news:
  it is one signature.
* **A control stream, explicitly.** Handshake ordering is connection-scoped
  today: `pump` rebuilds `outq` so `PROTO_HELLO` is the first bytes on the wire
  (`core/agent_client.nelua:651-656`) and the agent drops a client whose first
  frame is not HELLO. With several streams, "first" is per-stream.
  Authentication binds to the QUIC *connection*, or to one designated control
  stream, and it has to be written down rather than inherited.
* **Reply matching by arrival order has to go.** `attach_fifo` and `clip_fifo`
  (`core/agent_client.nelua:48-49`) match replies to requests by order, not by
  id — for `CLIP_SET`/`CLIP_GET` and version-1 `ATTACH`. QUIC gives no ordering
  *between* streams, so either those exchanges stay pinned to the control
  stream, or they gain ids. Silent mismatch is the failure mode, which is the
  worst kind.
* **`sid` stops multiplexing.** Today `sid` identifies a stream inside one byte
  stream. With one QUIC stream per window stream the QUIC stream id *is* the
  demultiplexer, and `sid` becomes the name of the thing, not the channel. It
  still has to exist on the wire — it is what a reattach refers to, and what
  the control stream uses to open and close a window stream — but it stops
  being read on every frame to route it. The mapping (QUIC stream id → `sid`)
  is established when the stream opens, on the control stream, before any frame
  flows on it.
* **Error granularity comes back.** Once streams are separate, collapsing
  `GI_ERESET` and `GI_ECLOSED` into `-1` is no longer acceptable: a reset on one
  window stream must close that window, not fail the link. `net.recv`'s
  EOF/error collapse is a step-3 simplification with a step-4 expiry date.
* **The corrupt-stream hack becomes dangerous.** `core/protocol.nelua:228-232`
  drops the *entire* queue when a length exceeds `PROTO_MAX_PAYLOAD` (4 MiB,
  `:117`). That is a byte-stream resync for a single stream. Per-QUIC-stream it
  is fine — and catastrophic if any two streams ever share a queue. Another
  reason the queue split has to be complete, not partial.

### Why WACK still exists

Because **QUIC's flow control bounds bytes, not frames.**

A QUIC stream window says "you may have N unread bytes outstanding". It says
nothing about how many *window frames* are in flight, and the thing that
bounds the agent's memory today is the 2-unacknowledged-`seq` rule: the agent
will not encode and queue a third frame for a stream until the client
acknowledges. Remove WACK and a client that reads slowly gets a QUIC window
that fills — but the *agent* has already spent the CPU encoding frames and the
memory holding them, because its own `outq` is what stalls it
(`session_blocked` at `agent/agent.nelua:211-217`, `OUTQ_HIGH` at `:96`), and
`outq` growth is the symptom, not the brake.

WACK is the brake, and it is a frame-level, application-level brake. QUIC
cannot express it: the transport does not know that frame N+2 for a window
supersedes frame N+1, or that encoding it at all was wasted work. Keep it,
unchanged, per stream.

The one thing QUIC *does* fix here is head-of-line blocking between streams,
which is exactly what step 4 is for and exactly what step 4's proof measures:
a KEY frame on one panel not stalling typing on another.

## What would prove each part

Cheap and non-token-consuming first, in this order:

1. A hello-world Rust staticlib with two exported functions, cross-compiled to
   `x86_64-pc-windows-gnu` in the build container and linked into
   `ghostty_core.dll`. Proves the mingw-w64 mixing question, which is the
   single most likely thing to stop this design, and costs one build.
2. The same crate with iroh in it, connecting to a listener on the fedora host
   from the PE core under Wine. Proves iroh's socket setup under Wine — UDP
   itself is already proven, iroh's use of it is not.
3. `valgrind` on the native agent across an hours-long connect/disconnect loop
   with the peer down, watching for slot, task and socket leaks in `gi_close`.
4. A slow-reading client against a KEY frame burst, watching the crate's RSS.
   Proves or disproves the userspace-buffering concern above.
5. Only then the step-4 proof from `docs/MULTI_AGENT.md:198`: a KEY frame on
   one panel not stalling typing on another.

Nothing in this document has been run. It is the required direction.
