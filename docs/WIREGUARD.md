# Embedded WireGuard (design)

**Status: designed here, built in the pull requests listed under
"Delivery".** Verified with host tests, against kernel WireGuard, and (the
Windows build) under Wine. Nothing here has been seen in game.

## The problem

The agent protocol is authenticated by a token but **not encrypted**
([packaging/README-agent.md](../packaging/README-agent.md)). Today a player
whose game runs on another machine is told to keep the agent on loopback and
use `ssh -L`, or to use a private network. The owner's own setup reaches the
agent over Tailscale. As the owner put it on 2026-09-23:

> Others may not have tailscale, we can use wireguard in our code though.
> Only if tailscale isn't detected.
> Bake the wireguard embedded into the agent or something very clean and
> robust for cross-platform.

## What it is

The agent becomes a **real WireGuard peer**, in-process. It needs no root, no
TUN device and no kernel module on any OS (Linux, Windows, macOS). The other
end runs the **stock WireGuard app** (the official clients for Windows,
macOS, Linux, iOS and Android) with a config the agent prints, QR code
included. The plugin does not change: it connects to the agent's address
inside the tunnel, exactly as it connects to `127.0.0.1` today.

```
 game PC (Windows, or Linux + Wine)                 agent host (any OS, no root)
┌─────────────────────────────┐               ┌──────────────────────────────────────────────┐
│ FFXIV + plugin              │               │ ghostty-agent (one process, one event loop)  │
│   agent = 10.77.12.1:7777   │               │                                              │
│        │                    │               │  UDP :51820 ──► wg device (Nelua)            │
│ stock WireGuard app (TUN)   │  UDP, Noise   │     Noise_IKpsk2, counters, timers, cookies  │
│   10.77.12.2 ───────────────┼──────────────►│     │ decrypted IP packets                   │
│   Moonlight / mstsc / VNC   │               │  lwIP netstack (vendored), tunnel 10.77.12.1 │
└─────────────────────────────┘               │     │ TCP/UDP to allow-listed ports          │
                                              │  forwards over loopback                      │
                                              │     ├─► 127.0.0.1:7777  the agent's listener │
                                              │     ├─► 127.0.0.1:3389  RDP  (if allowed)    │
                                              │     └─► 127.0.0.1:47984… Sunshine (if allowed)│
                                              └──────────────────────────────────────────────┘
```

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | WireGuard or our own protocol | **Real WireGuard**, byte for byte per the whitepaper, so the stock apps on every OS are the client. No client of our own to install or maintain, and a protocol with a published analysis. |
| 2 | Kernel, TUN, or in-process | **In-process, userspace.** The agent terminates the tunnel itself: no root, no driver, no TUN, the same on Linux, Windows and macOS. This is how `wireguard-go`'s netstack mode, `wireproxy` and `onetun` work. |
| 3 | Crypto | **Vendored Monocypher 4** for X25519, IETF ChaCha20-Poly1305 and XChaCha20-Poly1305 (cookies), as [MULTIPLEXER.md](MULTIPLEXER.md) already decided for the agent. **BLAKE2s, HMAC-BLAKE2s and the HKDF are Nelua**, because Monocypher has BLAKE2b only. Each is checked against published vectors (below). |
| 4 | TCP/IP inside the tunnel | **Vendored lwIP 2.2.1** (BSD-3-Clause), raw API with `NO_SYS=1`, driven from the agent's own loop. See "Why lwIP". |
| 5 | How the tunnel reaches the agent | **Loopback forwards.** A TCP connection to `tunnel_ip:7777` becomes a connection from the agent to its own listener on `127.0.0.1:7777`, which still wants the token. The same mechanism forwards allow-listed local ports (RDP 3389, VNC 5900, Sunshine), so remote desktop needs no OS-level VPN on the agent host. |
| 6 | When it runs | **Only when Tailscale is not detected**, unless forced (see "Selection"). |
| 7 | Plaintext on the network | **Refused.** The agent no longer listens on a non-loopback address unless that address is a tailnet address and Tailscale is running. `--allow-insecure-listen` forces it and logs a warning at start and on every connection. |
| 8 | Keys | `wireguard.conf` in the agent's config directory, 0600 on POSIX and an owner-only DACL on Windows (the token's convention, and the identity key's in MULTIPLEXER.md). **Client private keys are printed once and never stored.** Every peer gets a preshared key. |
| 9 | NAT | One side must be reachable: normally a UDP port forward to the agent. The agent can also dial a reachable peer (`Endpoint` on the agent's side). The carrier is behind a seam so "WireGuard over the relay's WebSocket pipe" can be added later. It is not built now. |

### Where this pushes back on the brief

* **"Only if Tailscale isn't detected" is decided on the agent host only.** The
  agent cannot tell whether the *game PC* has Tailscale, and `100.64.0.0/10`
  is also the carrier-grade NAT range, so a host behind CGNAT looks like a
  tailnet node. The default follows the owner: Tailscale present means no
  WireGuard, and the log says why. `--wireguard always` overrides it, for a
  friend whose game PC is not on your tailnet. The log names what was
  detected (the socket or the address and interface), so a false positive is
  visible.
* **Loopback forwarding, not a new in-process transport.** The agent's
  protocol code does not change, and the token check still applies inside
  the tunnel (defence in depth: a peer key alone is not a shell). The cost is
  that every tunnelled connection looks like `127.0.0.1` to the agent, so the
  forwarder logs each one with its tunnel source address, which `wg list`
  maps to a peer. If per-peer policy is needed later (MULTIPLEXER's grants),
  the forwarder is where the peer identity is known.
* **lwIP needs two configuration headers** (`lwipopts.h`, `arch/cc.h`). The
  rule is "no hand-written `.c`/`.h`", so they are **generated at compile
  time** by the Nelua module's preprocessor from a Lua table of options
  (`agent/wg_netstack.nelua`) into the Nelua cache. The configuration is Lua,
  and the header is a build product like the C that Nelua generates.
* **The listen refusal breaks existing setups on upgrade.**
  `tools/agent-container.sh` ran `--listen 0.0.0.0:7777` inside its
  container, and the owner's `fedora:ghostty-agent` runs exactly that. Its
  Incus proxy already connects to `127.0.0.1` inside the container, so the
  script now makes the agent listen on loopback. **The owner's running
  container needs its unit changed the same way before it takes an agent
  with this rule** (`ExecStart=… --listen 127.0.0.1:7777`). The refusal
  message says what to do. The proxy still listens on the Incus host's
  addresses, which is outside the agent's view: the script now takes
  `GHOSTTY_AGENT_PROXY_ADDR` (the host's tailnet address, say) and says so.

## Selection

At start the agent works out, in order:

1. **Tailscale.** It is detected when any of these holds:
   * `tailscaled`'s socket or pipe is there: `/run/tailscale/tailscaled.sock`
     or `/var/run/tailscale/tailscaled.sock` on Linux,
     `/var/run/tailscaled.socket` on macOS, or
     `\\.\pipe\ProtectedPrefix\LocalService\tailscaled` on Windows;
   * an interface has an address in `fd7a:115c:a1e0::/48` (Tailscale's own
     ULA range);
   * an interface has an address in `100.64.0.0/10`. This is the weak signal
     (CGNAT), and the log says so.
2. **WireGuard.** `--wireguard auto|on|off|always` (default `auto`):

   | Mode | Starts WireGuard when |
   |---|---|
   | `auto` | `wireguard.conf` exists, has at least one peer, and Tailscale was not detected. Having added a peer *is* the opt-in. |
   | `on` | Tailscale was not detected. It makes the key and file if they are missing. |
   | `always` | Always, and it logs that Tailscale is present. |
   | `off` | Never. |

   `--wireguard-config PATH` names another file, and naming it counts as `on`.

   With Tailscale detected and WireGuard not started, the log says:
   `Tailscale detected (<why>): WireGuard not started. To reach this agent
   from another machine, listen on your tailnet address: --listen
   100.x.y.z:7777`, with the address it found.
3. **The listen address.** Loopback (`127.0.0.0/8`, `::1`, `localhost`) is
   always allowed. A tailnet address is allowed when Tailscale was detected.
   Anything else, `0.0.0.0` included, is refused with exit code 2 and a
   message naming the three ways out (loopback plus WireGuard, a tailnet
   address, `ssh -L`), unless `--allow-insecure-listen` is given. Then it
   warns at start and logs every connection it accepts, with its address.

## The protocol

Exactly the WireGuard whitepaper (Donenfeld, "WireGuard: Next Generation
Kernel Network Tunnel", NDSS 2017) and the protocol page on wireguard.com. The constants are the protocol's:
`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`, `WireGuard v1 zx2c4 Jason@zx2c4.com`,
the labels `mac1----` and `cookie--`, and message types 1 to 4 with their
fixed sizes (148, 92, 64, and 32 plus the padded payload).

* **Handshake.** Initiation and response exactly as specified, with
  `Noise_IKpsk2`. The responder checks the initiator's static key against its
  peers, and requires a TAI64N timestamp newer than the last one it accepted
  from that peer (replay of a captured initiation does nothing). It rejects an
  all-zero X25519 result. At most one initiation per peer is processed every
  20 ms (50 a second).
* **Transport.** 64-bit counters with a sliding replay window of 8192
  messages. Payloads are padded to 16 bytes. Keys rotate: `REKEY_AFTER_MESSAGES`
  2⁶⁰, `REJECT_AFTER_MESSAGES` 2⁶⁴ − 2¹³ − 1, `REKEY_AFTER_TIME` 120 s,
  `REJECT_AFTER_TIME` 180 s, `REKEY_ATTEMPT_TIME` 90 s, `REKEY_TIMEOUT` 5 s
  with jitter, `KEEPALIVE_TIMEOUT` 10 s. The responder sends no data on a new
  session until the initiator's first data message confirms it. Current,
  previous and next keypairs are kept as the whitepaper describes. Key
  material is wiped after `REJECT_AFTER_TIME × 3` with no new handshake.
* **Timers.** The whitepaper's set: handshake retransmission with jitter,
  passive keepalive 10 s after receiving with nothing sent, a new handshake
  when data was sent and nothing came back for 15 s, persistent keepalive
  when configured, and rekey on age and on message count.
* **Cookies.** MAC1 is required on every handshake message (keyed with
  `HASH("mac1----" ‖ our public key)`). Under load (more than 64 handshake
  messages in the last second, a threshold chosen for a one-thread agent) a message
  without a valid MAC2 gets a cookie reply instead of a DH. Cookies are
  XChaCha20-Poly1305 under `HASH("cookie--" ‖ public key)`, the secret rotates
  every 120 s, and the cookie binds the sender's IP and port.
* **Roaming.** The peer's endpoint becomes the source address of the latest
  authenticated message (a handshake whose MAC and AEAD verified, or a data
  message that decrypted).
* **Silence.** Nothing that fails MAC1 or AEAD gets an answer. There is no
  ICMP, no error and no cookie before MAC1. To a scanner without a peer's key
  the port looks closed.
* **Cryptokey routing.** A decrypted packet is accepted only if its source
  address is inside that peer's `AllowedIPs`. Outbound packets go to the peer
  whose `AllowedIPs` contain the destination. A peer cannot speak for another
  peer's tunnel address.

### Crypto and its vectors

| Primitive | From | Checked against |
|---|---|---|
| X25519 | Monocypher `crypto_x25519` | RFC 7748 §5.2 and §6.1 |
| ChaCha20-Poly1305 (IETF) | Monocypher `crypto_aead_init_ietf` + `crypto_aead_write`/`read`, a fresh context per message (Monocypher ratchets a context's key after each message; WireGuard must not) | RFC 8439 §2.8.2 |
| XChaCha20-Poly1305 | Monocypher `crypto_aead_lock`/`unlock` | draft-irtf-cfrg-xchacha-03 §A.3.1 |
| BLAKE2s (keyed, 16 and 32 bytes out) | `agent/blake2s.nelua` | RFC 7693 Appendix B (`abc`) and the Appendix E self-test over every length and key size |
| HMAC-BLAKE2s, HKDF (`KDF1/2/3`) | `agent/blake2s.nelua` | vectors from Python's `hmac` + `hashlib.blake2s` (an independent implementation), written into the test with the command that made them |
| The whole handshake | all of the above | the interop test against kernel WireGuard |

Randomness: `getrandom`/`getentropy` on Linux and macOS, `BCryptGenRandom` on
Windows. If there is no random source the agent refuses to start WireGuard. It
never falls back to a weak one.

## Why lwIP

| Stack | Licence | Language | For this job |
|---|---|---|---|
| **lwIP 2.2.1** | BSD-3 | C | Mature (since 2001), IPv4 and IPv6, TCP with window scaling and SACK, a raw callback API that runs in one thread with `NO_SYS=1`, used by `tun2socks`-style userspace VPN code on all three OSes. **Chosen.** |
| smoltcp | 0BSD | Rust | Good, and what `onetun` uses, but it brings a Rust toolchain into an agent whose build promise is "a C compiler and make". |
| gVisor netstack | Apache-2 | Go | What `wireguard-go` and `wireproxy` use. Needs Go and a runtime. |
| picoTCP | GPL-2/3 | C | The licence cannot go into an MIT agent. |
| uIP | BSD | C | One packet buffer, stop-and-wait TCP. Too slow for window streams and remote desktop. |
| our own TCP in Nelua | | | The owner's rule is the real tool over a reimplementation, and a TCP stack is where reimplementations hurt. |

lwIP runs with `NO_SYS=1` (no threads, no OS layer), `MEM_LIBC_MALLOC` and
`MEMP_MEM_MALLOC` (the heap, no fixed pools), `LWIP_RAW=0`, no sockets or
netconn API, no DHCP, ARP or ND on the tunnel interface. IPv4 and IPv6 are on.
The MTU is 1420 (WireGuard's default) and the MSS 1360, so a segment fits
under either family. `TCP_WND` is 256 KiB with window scaling, and the send
buffer 256 KiB, enough to keep a window stream or a desktop moving at
tunnelled line rate. `sys_now()` comes from Nelua, and `sys_check_timeouts()`
runs from the agent's loop, which also caps its sleep at lwIP's next timer.

### Forwards

Each allowed port is a listener on the tunnel address inside lwIP. An accepted
tunnel connection opens a non-blocking TCP connection to `127.0.0.1:<port>`
and copies both ways, with **back-pressure both ways**: tunnel data is
acknowledged into the TCP window only once the local socket has taken it, and
the local socket is read only while lwIP has send buffer. Half-close carries
over both ways, and an error or reset on either side aborts the other. UDP
forwards (Sunshine's video, audio and control ports) keep one local socket
per tunnel source address and port, dropped after 60 s idle.

The agent's own port is always forwarded. Others are off until added:

```
ghostty-agent wg forward tcp 3389          # RDP
ghostty-agent wg forward tcp 5900          # VNC
ghostty-agent wg forward sunshine          # tcp 47984 47989 48010, udp 47998-48000 48002 48010
ghostty-agent wg unforward tcp 3389
```

Forwards only ever reach **loopback on the agent host**: no LAN, no other
host, no routing. A tunnel peer cannot use the agent as a way into the rest
of the network.

## Addressing

`wg` picks a random `10.x.y.0/24` and a random RFC 4193 ULA `/64` when it
first makes `wireguard.conf`. Random prefixes make a clash with the player's
own LAN unlikely, and both are in the file to change. The agent is `.1` and
`::1` of these. Peers get the next free address. A client's `AllowedIPs` is
the agent's `/32` and `/128` only, so installing the tunnel on the game PC
routes nothing else through it.

## Files and the CLI

`~/.config/ghostty-agent/wireguard.conf` (`%APPDATA%\ghostty-agent\` on
Windows). It is 0600 on POSIX and has an owner-only DACL on Windows, and it
is rewritten through a temporary file and an atomic rename. It is in
wg-quick's format (`[Interface]`, `[Peer]`, `Key = value`) so it reads like
every other WireGuard config. It has two keys of our own, `Name` (a peer's
name) and `Forward`, so wg-quick itself will not load it:

```ini
[Interface]
PrivateKey = <agent private key>
ListenPort = 51820
Address = 10.77.12.1/24, fd4e:2b1c:9a07:1::1/64
Forward = tcp 3389

[Peer]
Name = laptop
PublicKey = <laptop public key>
PresharedKey = <psk>
AllowedIPs = 10.77.12.2/32, fd4e:2b1c:9a07:1::2/128
```

The parser is strict: an unknown key or a malformed value stops the agent
with the line number, instead of being ignored.

```
ghostty-agent wg add NAME [--endpoint HOST[:PORT]] [--no-qr] [--agent-port N] [--token-file PATH]
    new keys for NAME. Prints the client's config once (and a QR code for the
    phone and tablet apps), plus the plugin's `agent = { host, port, token }`
    line. The client's private key is not kept anywhere. The file and the
    agent's key are made on first use.
ghostty-agent wg list          peers: name, tunnel address, last handshake, endpoint, public key
ghostty-agent wg remove NAME   drops the peer; a running agent wipes its keys within 2 s
ghostty-agent wg show          public key, port, addresses, forwards, Tailscale status
ghostty-agent wg forward … / unforward …
ghostty-agent wg init [--port N]
(every command takes --config PATH for another file)
```

The running agent reads the file again every two seconds and applies what
changed (it compares a BLAKE2s of the text, so an edit within the same
second counts). Unchanged peers keep their sessions, a removed peer's keys are
wiped at once, and a change of `PrivateKey`, `ListenPort` or `Address`
restarts the device. A file that does not parse is reported once and changes
nothing. `wg list` reads the handshake times from a small status file the
running agent writes beside it (`wireguard.conf.status`, 0600).

The QR code comes from Nayuki's QR Code generator (MIT, vendored C), drawn
with half-block characters so a 300-byte config fits an 80-column terminal.

## NAT and reachability

WireGuard needs one side to be reachable by UDP:

* **The agent is reachable** (the usual case): forward UDP 51820 on the
  router to the agent host. The client config carries
  `Endpoint = <host>:51820` and `PersistentKeepalive = 25`, so the agent's
  replies get through the client's NAT.
* **The game PC is reachable:** give the peer an `Endpoint` (an IP address
  and port) and, if it sits behind NAT, a `PersistentKeepalive` in
  `wireguard.conf`; the agent initiates the handshake and keeps the path open.
* **Neither is reachable:** not solved here. The seam for it is the
  device's carrier. `agent/wg_device.nelua` takes datagrams through
  `WgDevice:receive` and hands them out through its `send` callback (the UDP
  socket today), and a `WgEndpoint` has a `carrier` field beside the address. MULTIPLEXER.md's relay already has `GET /p/<pipe_id>` joining
  two sockets. WireGuard messages are self-contained datagrams, so a later
  carrier can frame them over that pipe (`len u16 ‖ message`), with the
  endpoint being the pipe. Roaming then moves a peer between the pipe and UDP
  by the same rule as any other roam. This is left for later and not built.

## Threat model

Assets: the shells and windows behind the agent (a shell on the agent host);
the agent token; the WireGuard private key and the peers' preshared keys;
which devices talk to the agent, and when.

| Adversary | Can | Cannot | Mitigations, and what is left |
|---|---|---|---|
| **Network attacker on path** (café Wi-Fi, ISP) | see UDP to port 51820: sizes, timing, both IPs; drop, delay, replay or reorder datagrams | read or change anything; replay a handshake or data (TAI64N, counters, replay window); learn the token | WireGuard's AEAD and handshake. The token, which used to cross the network in the clear, now only crosses loopback. **Left:** traffic analysis (sizes and timing of a window stream), and blocking UDP. |
| **Off-path scanner** | send anything to the UDP port | get any answer without a valid MAC1, which needs the agent's public key | Silence before MAC1. With the public key: cookies under load, 50 initiations a second per peer. **Left:** knowing the public key (it is in every client config) lets someone make the agent do MAC checks, but not DH work under load. |
| **Handshake flood (DoS)** | burn CPU on DH | keep the agent from serving authenticated peers | Cookie replies bind work to a source address. Per-peer initiation rate limit. The threshold is small because the agent is one thread. **Left:** a flood from many addresses can still slow handshakes. |
| **Stolen or lost client device** | use its private key and PSK: the same access the device had, the tunnel address, the forwarded ports | reach the agent's shells without also having the token | `wg remove NAME` wipes the peer at the next reload (≤ 2 s). The token is still required inside the tunnel. **Left:** a stolen device usually holds the plugin's token too; rotate it (delete the token file and restart). |
| **Malicious or compromised peer** (one of your own devices) | reach the agent's port and the forwards you allowed, on loopback | spoof another peer's tunnel address (cryptokey routing); reach the LAN or another host (forwards go to loopback only); reach ports you did not forward | Allow-listed forwards, loopback only. The token. **Left:** what it can do with the ports you forwarded (RDP, VNC and Sunshine have their own logins; do not forward a port that has none). |
| **Other local users on the agent host** | connect to `127.0.0.1:7777` as today | read `wireguard.conf` or the token | 0600 files and the owner-only DACL; the token check. **Left:** as today, root or an administrator on the agent host owns everything. |
| **Key compromise later** | decrypt recorded traffic | decrypt it with only the static keys: sessions use ephemeral keys (forward secrecy), and the PSK must be stolen too | Noise IK's ephemeral DH, the per-peer PSK (which also hedges a future quantum attacker who records traffic now), keys wiped after 540 s idle. |
| **Tailscale mis-detection** | a CGNAT address makes the agent skip WireGuard | expose anything: a mistake leaves WireGuard off, and the listener on loopback | The log names the reason. `--wireguard always`. |
| **A user forcing plaintext** | `--allow-insecure-listen` on `0.0.0.0` | do it quietly | A warning at start and a log line per non-loopback connection. The README says what it costs. |
| **Implementation bugs** (parsers, lwIP) | attack the handshake parser without a key; attack lwIP only after a handshake | reach lwIP without a valid peer key | Fixed-size parsers with length checks first; lwIP is behind WireGuard's authentication, so only your peers can send it packets; fuzz targets for message parsing (tests/fuzz.nelua), and ASan/UBSan in the quality battery. **Left:** lwIP is a large C dependency, pinned and updated deliberately. |

## How this relates to MULTIPLEXER.md

The multiplexer connects **other players' agents** through a relay, with
grants, SAS and Noise XX over BLAKE2b. WireGuard connects **your own devices**
to your agent. The trust relationship is different (a WireGuard peer is you,
and already holds the token), so they stay separate protocols. They share
ground:

* **One vendored Monocypher**, pinned in `toolchain.env`, used by both. The
  crypto bindings (`agent/crypto.nelua`: X25519, both AEADs, random, wipe,
  constant-time compare) are written once for both. BLAKE2s is WireGuard's
  alone; the multiplexer keeps BLAKE2b from Monocypher.
* **Key files** follow the identity key's convention: the agent's config
  directory, 0600, and the owner-only DACL on Windows. The WireGuard static key
  is **not** the multiplexer identity key. A key is used by one protocol only.
* **Direct paths.** MULTIPLEXER.md's "direct over tailnet" offer
  (`tailnet_addr:port` on channel 0) generalises to "an address inside a
  private tunnel": a WireGuard tunnel address qualifies the same way a tailnet
  address does, and it is opt-in per peer for the same reason (offering it
  reveals the address).
* **The relay.** The later "WireGuard over the relay pipe" carrier uses
  MULTIPLEXER.md's `/p/<pipe_id>` as it is. The relay passes ciphertext it
  cannot read, which is already the relay's contract.
* **P5 (UDP state sync)** plans its own datagram crypto with a 2048-entry
  replay window. When it is built it should reuse this code's replay window
  and roaming rule rather than write them twice.

## Platforms

| | Linux | Windows | macOS |
|---|---|---|---|
| UDP socket | dual-stack `[::]:port`, non-blocking, in the `poll` set | dual-stack, `WSAEventSelect` in the winloop | as Linux |
| Randomness | `getrandom` | `BCryptGenRandom` | `getentropy` |
| Tailscale | socket in `/run` or `/var/run`, `getifaddrs` | the pipe, `GetAdaptersAddresses` | `/var/run/tailscaled.socket`, `getifaddrs` |
| Private files | 0600 | owner-only DACL | 0600 |
| Built and tested | host tests, interop against kernel WireGuard in Incus | cross-built with Zig (`x86_64-windows-gnu`); run under Wine 11 against kernel WireGuard (handshake, a peer swapped in the running file, the agent answering through the tunnel); not yet on Windows itself | not built here |

## Tests

* **Vectors:** every row of the crypto table, in `tests/test_wg_crypto.nelua`.
* **Protocol, in-process:** two devices on a fake network and a fake clock
  (`tests/test_wg.nelua`): the handshake started by data, data both ways,
  replays and the window, tampering and silence (garbage, a wrong MAC1, the
  all-zero DH result), cryptokey routing, keepalives, rekey on time and on
  count, roaming, a replayed initiation, the 20 ms initiation rate, cookies
  under load, retransmission and giving up, key wiping after 540 s, the
  agent dialling a peer, removing a peer. `tests/fuzz.nelua` throws random
  datagrams at a device, half of them with a valid MAC1.
* **Netstack:** TCP through two netstacks and two devices to a real loopback
  echo server: 32 MB each way with the reader paused (the agent side holds
  at most the TCP window), half-close both ways, a refused local port, a port
  not forwarded, a spoofed source, a UDP forward (`tests/test_wg_netstack.nelua`).
* **Interop** (`tools/wg-interop.sh`): our side in the build container,
  **kernel WireGuard** in another Incus container
  (`fedora:ghostty-wgpeer`, keys from `wg genkey`). It checks the handshake
  and ping; roaming (the peer's listen port changes mid-session); a rekey
  (pings for 130 s: the kernel makes a new handshake and none is lost); and
  then the real agent: its netstack answering ping, and
  `tests/test_agent.nelua` (the plugin's `core/agent_client.nelua`) passing
  through the tunnel, with a 4.5 MB flood and a 1 MB paste.
* **Config and CLI:** the parser's accepted and rejected lines, round trips,
  the file's mode, a running service following the file
  (`tests/test_wg_config.nelua`); `ghostty-agent wg` end to end on the built
  agent, the QR code, Tailscale's ranges and the listen rule
  (`tests/test_wg_cli.nelua`).
* All of these run clean under ASan, UBSan and LeakSanitizer.

## Delivery

1. This document.
2. Vendoring (Monocypher, lwIP, the QR generator: `toolchain.env` pins with
   sha256, `tools/fetch-vendor.sh`, the agent source tarball) and the crypto
   primitives with their vectors.
3. The WireGuard protocol with its unit tests, then the interop test against
   kernel WireGuard.
4. The netstack, the agent listener over the tunnel, and the port forwards.
5. The CLI, Tailscale detection, the listen rule, README-agent.md, and the
   Windows build.
