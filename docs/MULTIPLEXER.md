# The MMO multiplexer (design)

**Status: design only. Nothing in this file is implemented or tested.** This is
the required direction, not a claim about the code. Statements about Dalamud and
FFXIVClientStructs were checked against the Dalamud 15.0.3.5 dev build's
`Dalamud.xml` and `FFXIVClientStructs.xml` (`~/.xlcore/dalamud/Hooks/dev`) and are
cited as `Dalamud:` / `FFXIVCS:` below. Everything marked **Assumption** has not
been checked at all.

Players who run these mods and stand in the same zone instance see each other's
summoned NPCs and the outlines of each other's panels. Nobody sees what an NPC
says or what a panel shows. An owner can invite a player to see some or all of
their windows and terminals, or to type into them. Players' AI agents can work
together through approval tickets, and players can pull each other's public
almanac notes. All coordination runs through ghostty-agent and a relay. None of it
goes through the game's packets or chat.

## Goals

1. **Presence.** Other mod users in the same zone instance see your summoned NPC
   (model, place, emote) and privacy-screened outlines of your world panels
   (place, size, kind). They never see dialogue, titles or pixels.
2. **Explicit sharing.** You grant a peer view or input on a window, a terminal or
   a named set of them. Grants expire by default and you can revoke them at any
   time. Without a grant, no frame, title, input path or protocol object reaches
   the peer.
3. **Pair work.** A guest has their own focus, pointer and keyboard state. A guest
   pressing `b` while the host holds Shift produces `b`.
4. **Agent collaboration.** Peers' MCP agents can ask each other for actions
   through tickets that a human approves. Peers can share almanac notes that the
   owner explicitly marked public.
5. **Safe defaults.** Presence reaches only peers you pinned face to face, and
   goes no wider unless you turn on open presence. Terminals take no direct
   input from anyone. The relay can't read payloads. No game packets are sent
   and nothing is typed into the chat automatically.

## Non-goals

* **Preventing capture by a legitimate viewer.** Anyone you grant view can
  screenshot, record or save every frame with a modified client. This can't be
  prevented, and the design doesn't try (see the threat model).
* **Anonymity from the relay operator's network view.** Cloudflare, and whoever
  runs the Worker, sees client IP addresses, connection times and message
  sizes. See "Room derivation" for what they can and can't learn about zones.
* **Players without the mods.** They see nothing, because everything is drawn on
  the client.
* **Sharing flat ImGui windows or the game UI.** Adopted plugin windows
  ([ADOPT.md](ADOPT.md)) and the chat pet live in the game process, not in the
  agent, so they're outside the enforcement point. They only ever show as
  outlines. The chat pet can never be shared, because it holds other people's
  tells and party chat.
* **Wayland protocol access for guests.** No guest ever gets a Wayland socket, a
  screencopy or capture protocol, or a portal. Guests get only encoded pixels
  and send only the WINPUT subset their grant allows.
* **Game-server state.** Nothing changes what the server or non-mod players see.

## Decisions reviewed

The brief's decisions stand, with these corrections. Items marked **unsafe as
stated** are changed in this design.

| # | Decision | Verdict |
|---|---|---|
| 1 | Visibility tiers: public presence, shared by grant | Kept. Presence goes out on two channels, both on by default: the zone room ("open presence", the weaker one, which is public to anyone running the code who can guess the zone) and a pairwise room per pinned peer (the stronger one). Presence therefore carries only data that is safe for anyone to see, and the first-run notice says so. |
| 2 | The agent enforces, and guests get their own `wlr_seat` | Kept. The agent also holds the identity key, so the key never enters the Wine/game process. Own seats only work for clients that bind a second `wl_seat`. Other clients (X11/Xwayland, some toolkits) fall back to floor control (see "Guest seats"). |
| 3 | An Ed25519 key per install, bound to a ContentId hash, TOFU plus a SAS | **Unsafe as stated:** a plain `H(ContentId)` is a stable cross-context identifier. ContentIds are 64-bit and sparse, so anyone who can list candidates can reverse the hash. It is replaced by a commitment keyed with the identity key, and it is sent only inside the encrypted handshake, never in presence. |
| 4 | Room id `H(zone-instance key ‖ epoch)`, with presence encrypted under a key from the same material | **Partly unsafe as stated, and it is still the default path.** "The relay can't learn which zone a room is" is false: the input has little entropy (worlds × territories × instances × housing ≈ 10⁶–10⁷ per epoch), so an operator can try every candidate. The scheme is kept for open presence, hardened with Argon2id, and **presence in a zone room must be treated as readable by a determined relay operator**. Pairwise rooms between pinned peers are added as the stronger channel and tell the relay nothing about location. |
| 4 | Shares E2E with Noise-style X25519 + ChaCha20-Poly1305 (Monocypher) | Kept: `Noise_XX_25519_ChaChaPoly_BLAKE2b`. Monocypher 4's default signature is EdDSA over BLAKE2b, which isn't Ed25519. Real Ed25519 needs its optional `monocypher-ed25519.c` (vendored, allowed). |
| 4 | Direct over Tailscale when both are on a tailnet | Kept, but opt-in per peer, because offering a path reveals your tailnet address. It's useful only between people who share a tailnet or a shared node. |
| 5 | Knowledge: public-marked items, pull-only, reviewed, data not instructions, tickets | Kept. The design adds that peers never reach almanac at all. They get a static, signed bundle that the owner built on purpose, and tickets go to a human, never to a model. |

### Answers to the open questions (owner, 2026-09-19)

These were the five questions this document first ended with. They are now
decided, and the rest of the file is written to them.

1. **Relay: public, on a paid Cloudflare plan, on the owner's account.** Sized,
   with retention, abuse controls and a kill switch, under "The relay".
2. **Rooms: pairwise room keys between pinned peers**, which is the stronger
   mode and the one to prefer. **Open presence (the zone room) still ships in
   P1 and is on by default**, with a first-run heads-up that says what it
   broadcasts and how to turn it off, so the zone-room hardening (Argon2id)
   stays on the default path.
3. **Terminal input: allowed, but as suggestions.** A guest types into a
   suggestion buffer. Nothing reaches the PTY until the host approves it, like
   sudo, with session and timed allowances, per-peer blocking and an audit log.
   App windows keep direct input under an input grant; only terminals work this
   way. See "Terminal suggestions".
4. **Presence: on by default**, both to pinned peers and, through open
   presence, to everyone in the zone room. What it broadcasts is listed in full
   under Tier 1 and summarised in "What others see by default", and every
   opt-out stays one command away.
5. **TLS: the agent does its own TLS and end-to-end crypto**, so shares never
   depend on the game client running. BearSSL is vendored for the agent.

Three follow-ups were answered the same day: the relay budget is **$10 a
month** (warn at $7, stop shares at $9); **open presence ships in P1, on by
default**, with the first-run notice; and **app-window input stays direct once
granted**, with no per-event approval — revoking the grant or kicking the peer
is the stop.

## What others see by default

In plain words, with the mod installed and set up as it ships:

* **Anyone in your zone who also has the mod** sees the NPC you have out (which
  minion, mount, pet or copy of yourself, where it stands, which way it faces,
  its emote, and whether it is talking) and a frosted rectangle for each of your
  world panels (where it is, how big, which way it faces, and whether it is a
  terminal, a window or another panel). They do **not** see what the NPC says,
  what any panel shows, its title, or what you type.
* **People you have pinned** (you exchanged an invite and compared the safety
  words) see the same thing through a private channel that no one else can read.
* **Nobody** sees your screens, your terminals, your clipboard or your input
  unless you grant it, per window, per person, with an expiry.
* **The relay** (a Cloudflare Worker on the mod author's account) sees your IP
  address and when you connect, never your content. With effort, it can work out
  which zone an open-presence room belongs to. Presence between pinned peers
  doesn't tell it even that.
* **Non-mod players and the game servers** see nothing at all. Everything is
  drawn on the clients that have the mod.

**Turning it off**, at any depth:

| You want | Command | Settings |
|---|---|---|
| Stop being visible to strangers, keep pinned peers | `/term mux presence pinned` | Settings → Multiplexer → Presence → *Pinned peers only* |
| See others, publish nothing | `/term mux presence invisible` | → *Invisible* |
| Off completely, no relay connection | `/term mux presence off` | → *Offline* |
| Just here | `/term mux zone off` | → *Disabled zones* |
| Everything, now | the panic chord (Ctrl+Alt+Shift+X) | revokes every grant and drops to Offline |

The same table is shown on first run and in the first-use notice.

## Visibility tiers: every field

### Tier 0: nothing

With the mux off, or in **Offline** mode, the agent makes no relay connection
and sends nothing. This is not the default: see Tier 1.

### Tier 1: presence (on by default, to pinned peers and the zone room)

**What is broadcast by default, and to whom.** Two channels, both on out of the
box:

* **The zone room (open presence).** Everyone in your zone instance who runs the
  mod sees your presence. This is how strangers meet, and it is the weaker mode:
  the room id comes from the zone, which has little entropy, so a determined
  relay operator can work out which zone a room is (see "Open presence").
* **Pairwise rooms.** Each peer you have pinned also gets the same presence
  through a room only the two of you can derive, which tells the relay nothing
  about where you are. This is the stronger mode, and it keeps working when you
  turn open presence off.

In both cases what goes out is: **your summoned NPC's model class and sheet row,
its place next to you, its facing, its emote and whether it is talking; and one
frosted outline per world panel with its place, facing, size, curvature and kind
(terminal, window or panel).** Nobody, pinned or not, sees dialogue, titles or
pixels.

This is the complete field list. The plaintext schema has no other fields, and
the agent rejects presence the plugin hands it that carries anything else.

| Field | Content | Why it is safe |
|---|---|---|
| `anchor` | your character's `EntityId` (Dalamud: `IGameObject.EntityId`) | every client in the zone already receives it |
| `pres_key` | Ed25519 public key made fresh for this epoch | not linked to your identity key |
| `inv_key` | X25519 public key made fresh for this epoch, used to seal invites to you | same |
| `seq`, `t` | message counter, and seconds into the epoch | ordering |
| `accepts_invites` | bool | your setting |
| `npc.kind` | none / minion / mount / pet / self-copy / allow-listed ENpc | a game model class |
| `npc.row` | row id in the Companion, Mount, Pet or ENpcBase sheet (self-copy: 0) | game data. A self-copy sends no appearance: the viewer clones the anchor character it already sees |
| `npc.offset` | dx, dy, dz from the anchor, cm, i16, capped at 10 yalms | relative to a character that is already visible |
| `npc.yaw` | u8, 1.4° steps | |
| `npc.emote` | Emote sheet row, from an allow-list | game data |
| `npc.talking` | bool, "the NPC is speaking now" (on by default, can be turned off) | tells people *that* it talks, never *what* it says |
| `outlines[]` | at most 16 | |
| `outline.kind` | terminal / window / panel | three values only |
| `outline.offset` | dx, dy, dz from the anchor, cm, i16, capped at 30 yalms | panels farther away aren't published, so a pin at your house doesn't reveal where you've been |
| `outline.yaw`, `outline.pitch` | i8, quantized | |
| `outline.w`, `outline.h` | cm, u16, quantized to 5 cm | |
| `outline.curve` | u8, the panel's curvature, quantized | so the screen matches the shape |

Never published: HUD panels (they're in camera space and would give away where
your camera points), full-screen and tab panels, focus, which panel is active,
titles, app ids, window keys, ContentId, character name, world, dialogue, typing
activity, and panels while hidden or asleep.

### Tier 2: shared (per grant)

Only while a valid grant holds, and only for the windows it names:

| Right | The grantee gets |
|---|---|
| `VIEW` | the window's pixels (WFRAME/WGEOM; popups belonging to that window only), its title (unless the grant has `REDACT_TITLE`), its size. For terminals: the output stream from the moment of the grant (see "Terminals") |
| `POINTER` | MOVE, BUTTON and WHEEL into that window, on the guest seat. **App windows only** |
| `KEYBOARD` | KEY and TEXT into that window, on the guest seat. **App windows only.** A grant that names a terminal with `KEYBOARD` is refused when it is issued |
| `SUGGEST` | **terminals only.** The guest's keystrokes go into a suggestion buffer that the host approves line by line. Nothing reaches the PTY unapproved. See "Terminal suggestions" |
| `CLIP_IN` | the guest may set the text of the guest seat's selection (paste their own text). **Never** the host clipboard |
| `DIALOGS` | new child windows of a granted window (`parent:WID`) are shared on the same terms. Without it, they show as outlines only |
| `CURSORS` | participants' pointer positions over the shared window, for pair work |

No right gives: the owner's window list, other windows' titles, WLIST `apps`,
launching (`run:`, `app:`, `desktop:`, match text), FOCUS, resizing or closing
the window (a guest's WCLOSE ends only the guest's stream), the host clipboard
(CLIP_GET/CLIP_SET), terminal creation, or anything from the Wayland socket.

## Components

```
 Player A (owner)                                            Player B (guest)
 ┌──────────── FFXIV ────────────┐                           ┌──────────── FFXIV ────────────┐
 │ GhosttyDalamud core           │                           │ GhosttyDalamud core           │
 │  presence out (poses)         │                           │  outlines/NPCs of peers drawn │
 │  sharing UI, SAS, grant UI    │                           │  shared panels (agent=peer:…) │
  │ XivDesktop: NPC state, no text│                          │ XivDesktop: peer NPC clones   │
 │ xiv-mcp: ticket approvals     │                           │ xiv-mcp: tickets, board       │
 └───────┬───────────────────────┘                           └────────────────┬──────────────┘
         │ TCP + token (loopback)                                              │
 ┌───────▼────────────────────────┐   WSS    ┌──────────────┐   WSS   ┌──────▼─────────────────┐
 │ ghostty-agent A                │◄────────►│ CF Worker +  │◄───────►│ ghostty-agent B        │
 │  identity key, grants table    │          │ Durable Obj. │         │  identity key          │
 │  ENFORCEMENT: filters every    │          │ rooms: sealed│         │  proxies B's plugin to │
 │  stream by grant; guest seats  │          │ presence;    │         │  A over Noise          │
 │  Noise sessions                │◄── direct over tailnet (opt-in) ──►│                        │
 │  static knowledge bundle       │          │ pipes: Noise │         │                        │
 └───────┬────────────────────────┘          │ ciphertext   │         └────────────────────────┘
         │ reads a file almanac wrote        └──────────────┘
 ┌───────▼──────────┐
 │ almanac (local)  │  export-public → signed bundle; incoming notes quarantined
 └──────────────────┘
```

| Component | Lives in | Role in the mux | Never does |
|---|---|---|---|
| **ghostty-agent** | `agent/mux_*.nelua` (new): `mux_relay` (WSS client), `mux_noise`, `mux_grants`, `mux_presence`, `mux_seat` (in `capture_wayland`) | holds the identity key (`~/.config/ghostty-agent/identity`, 0600; `%APPDATA%` with an owner-only DACL on Windows). Derives rooms, seals and opens presence, runs handshakes, issues and checks grants, filters every stream, runs guest seats, serves the knowledge bundle, tunnels a guest plugin's v3 protocol to the peer | forward any stream or input without a grant table hit. Expose its Wayland socket, WLIST, apps or clipboard to peers |
| **GhosttyDalamud plugin** (core + Lua) | `core/app/mux.nelua`, `lua/mux.lua`; shim stays a forwarder | reads the zone key and your poses. Hands presence to the agent. Draws peers' outlines. Owns the in-game UI (invite, SAS, grant list, revoke, panic chord). Opens shared panels as `agent = "peer:<fp>"` | hold the identity key. Talk to the relay. Send chat or packets |
| **XivDesktop** | new provider over `GhosttyDalamud.v1.Call` (`mux.npc.publish`, `mux.peers`) | publishes its ask-an-NPC state (kind, row, offset, yaw, emote, talking). Spawns client-side clones of peers' NPCs | send dialogue: the IPC schema has no text field and strict parsing rejects extra fields. The ask-an-NPC feature isn't on the `ask-npc` branch yet (it equals `main`), so this interface is **Assumption**-level |
| **Relay** | a Cloudflare Worker plus Durable Object classes (SQLite-backed) on the owner's **paid** account, open to the public (see "The relay") | `GET /r/<room_id>` WebSocket: fans sealed presence out within a room (a pairwise room by default, a zone room under open presence). `GET /p/<pipe_id>`: joins two sockets and passes Noise ciphertext through. Enforces caps, the budget guard and the kill switch | decrypt anything (it has no keys). Keep a roster peers can read. Log payloads or keep identifiers |
| **almanac** | `almanac export-public` (new CLI verb), `knowledge/foreign/` | builds the public bundle on the owner's command. Imports reviewed foreign notes as data | accept connections from peers. Execute anything found in foreign notes |
| **xiv-mcp** | additive IPC `XivMcp.PeerTicket`, a peer section in `ConfirmWindow`, and `peer:` posts on `AgentBoard` | shows peer tickets for Allow/Deny once, and shows peers' shared board posts read-only | grant timed approvals ("allow for 10 min") to peers. Feed ticket text to a model |

**Assumption:** both players run ghostty-dalamud and ghostty-agent. Someone
with only XivDesktop can't publish or see presence in v1.

### The agent does its own TLS (decided)

Workers are reached over HTTPS/WSS, and the agent has no TLS today. **BearSSL is
vendored** (C, pinned in `toolchain.env`, vendored code only, no new project
`.c` files) for the agent's outbound connections, with a pinned root set and the
Worker's hostname checked. The end-to-end crypto is the agent's too. Nothing in
the relay path runs in the game process.

The point is independence from the game client: sessions, grants, presence
publishing and knowledge pulls keep working while FFXIV is closed, crashed,
reloading the plugin, or in a loading screen. The plugin is only a renderer and
a UI. A guest can keep watching a build finish after the host alt-tabs out, and
the host's grant list and revocations are the agent's state, not the plugin's.
When the game is closed the plugin publishes no poses, so presence falls back to
"no NPC, no outlines" while the session stays up.

## Protocols

All integers are little endian. Crypto comes from Monocypher 4:
`crypto_blake2b_keyed`, `crypto_argon2` (Argon2id), `crypto_x25519`,
`crypto_aead_lock` (XChaCha20-Poly1305), and the IETF ChaCha20-Poly1305 from
`crypto_aead_init_ietf` for Noise. Ed25519 comes from the optional
`crypto_ed25519_*`. `KDF(k, label)` means `crypto_blake2b_keyed(out32, key=k, msg=label)`.
Noise and the framing are Nelua, checked against the Noise test vectors
(cacophony) in the host tests.

### Rooms: pairwise by default

Presence rides in a room per **pair of pinned peers**. Both sides know the
other's static keys from the handshake, so both can derive the same room without
any help from the relay.

```
pair_dh    = x25519(my_static_sk, peer_static_pk)              (same on both sides)
lo‖hi      = the two static X25519 public keys, sorted bytewise
epoch      = floor(unix_seconds / 600)                          (10 minutes)
pair_seed  = KDF(pair_dh, "xivmux-pair-v2" ‖ lo ‖ hi ‖ epoch u64)
room_id    = KDF(pair_seed, "room")[0..16]      the relay sees this, and it rotates every epoch
room_key   = KDF(pair_seed, "presence")         the relay never sees this
```

* A room holds exactly two agents. The DO refuses a third socket, so a peer who
  guessed a room id still can't join, and there is no fan-out to strangers.
* The room id changes every epoch and has full entropy, so the relay can't
  enumerate it, can't tell which zone anyone is in, and can't link a room across
  epochs by its id alone. It still sees the two IPs and their timing, so it can
  link the same pair session by address.
* Each side publishes only while both are in the same zone instance. The zone
  tuple below is compared *inside* the sealed payload (a 16-byte
  `KDF(pair_seed, "zone" ‖ zone_tuple)` tag), so the relay never learns it and a
  peer learns only "we are in the same place", which they can already see.
* One socket per online pinned peer, capped at 32. Beyond that, peers are
  watched in the order they were last seen. Presence is published at most once
  every 2 s, and only when something changed.
* `pair_dh` is static-static, so presence has **no forward secrecy**: someone who
  later steals both identity keys can decrypt recorded presence. Given what
  presence holds (see Tier 1) that is accepted. Shares, which do have forward
  secrecy, use Noise.
* Losing a pin (unpin, block) stops the room at once, from both directions.

### Open presence: zone rooms (on by default)

Meeting strangers needs a room that people who have never met can both find, so
the zone-derived room ships in P1 and is **on by default**. It is the weaker of
the two channels, so the cost is stated wherever it appears, not hidden behind a
shorter label: **Settings → Multiplexer → Presence → "Open presence (anyone in
this zone with the mod can see my NPC and my panel outlines, and a determined
relay operator can work out which zone I am in)"**.

**First-run notice.** The first time the mux would publish anything, the plugin
stops and shows a notice that must be dismissed: what is broadcast (the list
above, in plain words), who sees it, that content and dialogue are never
included, and the "Turning it off" table with both the command and the settings
path. It offers three buttons — *Keep open presence on*, *Pinned peers only*
and *Offline* — and publishes nothing until one is pressed. The same summary is
repeated in the first-use notice the plugin already shows after an update, and
`/term mux` prints it on demand.

Because this is the default path, the zone-room hardening matters and stays:
Argon2id, 10-minute epochs, quantized and relative poses, per-epoch keys, and
the field list of Tier 1 as the whole of what is exposed.

```
zone_tuple = "xivmux-zone-v1" ‖ world u16 ‖ territory u16 ‖ instance u8
             ‖ ward i16 ‖ plot i16 ‖ room i16 ‖ division i8
epoch      = floor(unix_seconds / 600)                     (10 minutes)
zone_seed  = Argon2id(password = zone_tuple ‖ epoch u64,
                      salt = "xivmux-v1-salt!!", m = 64 MiB, t = 3, p = 1)
room_id    = KDF(zone_seed, "room")[0..16]                 relay sees this (in the URL)
room_key   = KDF(zone_seed, "presence")                    relay never sees this
```

Sources: `world` is Dalamud `IPlayerCharacter.CurrentWorld`. `territory` is
Dalamud `IClientState.TerritoryType`. `instance` is Dalamud
`IClientState.Instance` ("the instance number of the current zone, used when
multiple copies of an area are active"). Housing uses FFXIVCS `HousingManager`
`GetCurrentWard/Plot/Room/Division` (−1 outside housing). Zone changes arrive
through Dalamud `IClientState.ZoneInit` (`ZoneInitEventArgs.TerritoryType`,
`.Instance`, `.ContentFinderCondition`).

* **Duties.** Two parties running the same duty share a tuple, so they meet in
  one room. They never see each other's content anyway, and their anchors are in
  different instances, so the viewer finds no matching character and draws
  nothing. Duties are also on the default per-zone disable list.
* **Rotation.** On a zone change, and in the last 30 s of each epoch, the agent
  derives the next room (Argon2 runs on a worker thread, ~0.3 s: **Assumption**,
  to be measured). It stays in both rooms until 30 s into the new epoch. Clocks
  may be ±30 s apart. A peer further off drops out until its clock is fixed, and
  the plugin says so.
* **What the relay learns.** Each epoch the operator can compute `room_id` for
  every candidate tuple. With about 10⁶ open-world tuples at ~0.3 s each, that's
  roughly 80 CPU-hours per 10-minute epoch, or ~500 cores running all the time.
  That's expensive but possible for someone determined, and much cheaper for a
  few targeted zones such as one housing ward. Without doing that, it still sees
  IPs and timing, so it can link the same client across rooms. **Presence is
  hidden from a casual or lazy relay, not from a determined one.** For this
  reason presence carries only the fields above.
* **Scope.** Open presence is what discovery costs. Everything else — invites,
  shares, knowledge, tickets — works from pinned keys and never needs it. A
  player who never turns it on can still be invited by anyone who can target
  them, as long as that player is themselves in open presence, or by an out-of-
  band pin (below).
* **Out-of-band pinning**, so open presence is never the only way to meet: a
  player can show a short pairing code (their static key's fingerprint plus a
  one-time pipe id, as text or a screenshot). The other side types it in, and
  the two agents run the same handshake and SAS. No zone room is involved.

### Relay envelopes

What the relay handles:

```
room socket  WSS /r/<room_id hex32>         client ⇄ DO("room:" ‖ room_id)
  client → relay: blob (≤ 2 KiB)            relay → each other socket: blob
  pairwise room: 2 sockets max              open-presence zone room: 64 sockets max
pipe socket  WSS /p/<pipe_id hex32>         two sockets max; bytes passed through
  frames ≤ 256 KiB
```

The first frame on a room socket says which kind it is, and the DO caps the room
accordingly (2 or 64). The relay can't tell the kinds apart by itself, so a
client that lies raises only the cap; it still has to know the room id, which
for a pairwise room is 128 bits nobody else can derive, and it still can't
decrypt anything. Mixed claims on one room are refused after the first socket.

The relay adds nothing and keeps no roster. Hibernatable WebSockets
(`acceptWebSocket`) keep duration charges to handler time.

### Presence message (sealed, inside a room blob)

```
blob       = nonce[24] ‖ XChaCha20-Poly1305(room_key, nonce, ad = room_id ‖ "xivmux-pres-v1", pt)
pt         = ver u8 (1) ‖ type u8 ‖ pres_key[32] ‖ seq u32 ‖ t u16 ‖ body ‖ sig[64]
sig        = Ed25519(pres_key_secret, "xivmux-pres-sig-v1" ‖ room_id ‖ pt-without-sig)

type 1 PRESENCE body:
  anchor u32, inv_key[32], zone_tag[16] (pairwise rooms only; 0 in a zone room),
  flags u8 (bit0 accepts_invites, bit1 npc.talking),
  npc_kind u8, npc_row u32, npc_dx i16, npc_dy i16, npc_dz i16, npc_yaw u8, npc_emote u16,
  n u8 (≤ 16), n × { kind u8, dx i16, dy i16, dz i16, yaw i8, pitch i8, w u16, h u16, curve u8 }
type 2 BYE        body: empty
type 3 INVITE     body: to_hint u8[4] ‖ sealed        (see handshake)
type 4 INVITE_ANS body: to_hint u8[4] ‖ sealed
```

Receivers drop a blob that fails decryption, has the wrong version, is over size
or out of range, is stale (`seq` not increasing per `pres_key`), claims an
`anchor` that isn't a player character in their object table, puts the NPC more
than 10 yalms or an outline more than 30 yalms from where that anchor actually
stands, or names a row outside the allow-lists. The signature ties updates to one
publisher within an epoch. It doesn't prove who the publisher is (see Spoofing).
If two `pres_key`s claim the same anchor in an epoch, both are ignored for that
anchor.

Rendering notes: FFXIVCS `ClientObjectManager.CreateBattleCharacter` is the
client-side spawn path. Clones' emotes use the `Emote` sheet and FFXIVCS
`Character.EmoteController`. **Assumption:** this is how XivDesktop's ask-an-NPC
spawns its NPC (its code doesn't exist yet), and it's safe to call from the
framework thread for other players' clones too.

### Invite and handshake

An invite starts in game: target a player (Dalamud `ITargetManager.Target`) or
right-click one. The context-menu entry comes from Dalamud `IContextMenu`. Its
`MenuTargetDefault` gives `TargetObjectId`, `TargetContentId`, `TargetName` and
`TargetHomeWorld`.

1. The owner's plugin finds the target's presence by `anchor == EntityId`, in a
   pairwise room when the peer is already pinned, or in the zone room when both
   sides have open presence on. With neither (not a mod user, invisible, offline
   or not in open presence), it says "they aren't reachable here; ask them for a
   pairing code" and stops. The pairing-code path (above) goes straight to
   step 4 with the `pipe_id` from the code.
2. The owner's agent picks a random `pipe_id` (16 bytes) and sends a room
   INVITE. `sealed` = X25519 sealed box to the target's `inv_key`: ephemeral
   pk, then XChaCha20-Poly1305 under `KDF(x25519(e, inv_key), "xivmux-invite-v1")`.
   The plaintext holds `pipe_id`, an offer summary ("2 windows, view"), and an
   expiry of now + 120 s. `to_hint` is the first 4 bytes of
   `BLAKE2b(inv_key)`, so recipients skip most trial decryptions. The relay
   only sees that some room member sent something.
3. The target sees "Jack wants to show you 2 windows (view). Accept / Decline /
   Block". Nothing is fetched first. Accepting connects both agents to
   `/p/<pipe_id>`.
4. `Noise_XX_25519_ChaChaPoly_BLAKE2b`, prologue `"xivmux-share-v1" ‖ pipe_id`.
   The invitee is the initiator:
   ```
   → e
   ← e, ee, s, es, payload(cert_owner)
   → s, se, payload(cert_guest)
   cert = ed25519_pk[32] ‖ sig(ed25519, "xivmux-static-v1" ‖ x25519_static_pk)[64]
        ‖ cid_commit[32] ‖ label (≤ 64 bytes UTF-8, the name@world the user chose to show)
   cid_commit = BLAKE2b-256(key = ed25519_pk, "xivmux-cid-v1" ‖ ContentId u64)
   ```
   Each side checks the signature. It then checks `cid_commit` against the
   ContentId of the character it targeted or was invited by. That value comes
   from Dalamud `MenuTargetDefault.TargetContentId` or FFXIVCS
   `Character.ContentId`; your own from Dalamud `IPlayerState.ContentId`. The
   commitment shows which character the key *claims*. It isn't proof, because
   anyone near you can read your ContentId.
5. **SAS:** `KDF(h, "xivmux-sas-v1")`, 41 bits turned into 4 words from the EFF
   short word list (1296 words, vendored as data). Both screens show the words.
   The two people compare them out loud or type them into /say **themselves**:
   the plugin never sends chat. Both click "They match". A mismatch ends the
   session and flags it as a possible interception.
6. **TOFU pin:** `ed25519_pk ↔ label ↔ cid_commit` is stored in the agent
   (`peers.lua`). Later sessions with a pinned key skip step 5. A new key for a
   pinned character, or a pinned key under another character, requires the SAS
   again, with a warning.
7. Transport: Noise CipherStates. Frames are
   `len u32 ‖ ChaChaPoly(k, n, channel u16 ‖ type u8 ‖ payload)`. Both sides rekey
   (Noise `Rekey`) every 2²⁰ frames or 60 min. Channel 0 is control. Channel 1
   carries grants and lists. Channels 2 and up carry the existing protocol v3
   messages (WOPEN/WFRAME/WACK/WGEOM/WINPUT/WCLOSE and terminal OPEN/DATA),
   filtered by the owner's agent, so the guest's plugin reuses `remotewin` and
   `session` as they are.
8. **Direct path (opt-in):** on channel 0 each side may offer
   `tailnet_addr:port`. When both offered and a TCP connection succeeds, the
   session moves to it with the same keys (a fresh `Rekey` first). The pipe stays
   open as a fallback until the direct path has carried 5 s of traffic.

### Share grant

A grant is a capability that **the issuer's own agent** checks. Its grant table
is the authority. The signature lets the guest show exactly what they hold, and
lets tickets and audits refer to it. Revocation is a local delete: the issuer's
agent closes the matching streams at once and refuses the grant from then on. No
revocation list is needed, because no third party ever checks a grant.

```
grant = "XMG1" ‖ ver u8 (1) ‖ rights u8 ‖ flags u8
      ‖ issuer_pk[32] ‖ grantee_pk[32]
      ‖ grant_id[16]            (random; doubles as the nonce)
      ‖ issued_at u64 ‖ not_before u64 ‖ expires_at u64   (unix seconds)
      ‖ max_w u16 ‖ max_h u16 ‖ max_fps u8
      ‖ n u16 ‖ n × { sel_kind u8, len u8, bytes[len] }
      ‖ sig[64]    Ed25519(issuer, "xivmux-grant-v1\0" ‖ everything above)

rights: 1 VIEW, 2 POINTER, 4 KEYBOARD (app windows only), 8 CLIP_IN,
        16 DIALOGS, 32 CURSORS, 64 SUGGEST (terminals only)
flags:  1 REDACT_TITLE, 2 WATERMARK (agent burns the grantee's label into frames)
sel_kind: 1 window key (launch id "<run>.<n>", REMOTE_WINDOWS.md "Window keys"),
          2 terminal session id, 3 named set (resolved when used; members listed in the UI)
```

* Default length is 60 minutes. The UI offers 15 min, 1 h, 4 h and "until I
  leave the zone", and caps any grant at 24 h. A pinned key under an explicit
  "trusted friend" setting may get up to 30 days.
* Input rights require VIEW. `KEYBOARD` or `POINTER` on a terminal selector, and
  `SUGGEST` on a window selector, are refused when the grant is issued: the two
  input models don't cross. Direct keyboard on an app window is still real input
  into a program running as you, and the UI says so.
* A window key from an earlier agent run never matches, so grants die with the
  agent's windows.
* A named set is resolved each time it is used. Adding a window to a shared set
  therefore shares it. The owner sees a banner "Set *pairing* is shared with B"
  while the grant is live.
* Every shared panel on the owner's side gets a coloured border and an eye badge
  listing its viewers. A panic chord (`CONFIG.mux.panic`, default Ctrl+Alt+Shift+X)
  revokes every grant and leaves every room.

### Terminals

Today the agent has only the raw byte ring (256 KiB replay). Replaying it would
show a guest output from before the grant, such as a secret that scrolled past.
Shared terminals therefore **never get replay**. A new viewer gets a clear
screen, and the agent sends the PTY a SIGWINCH so full-screen programs redraw.
Later, libghostty-vt linked into the agent (it already builds for the host) could
send a screen-only snapshot. That isn't planned for P2.

### Terminal suggestions (the sudo model)

A guest never types into a PTY. With `SUGGEST`, their keystrokes go into a
**suggestion buffer** that lives in the owner's agent. The host approves or
rejects it, line by line. This is the whole of terminal input; there is no
"direct mode" to fall back to.

* **Guest side.** Their panel shows a suggestion line under the terminal, in a
  different colour, marked "suggestion — waiting for host". Their editing keys
  work inside the buffer (characters, Backspace, arrows, Home/End). Enter closes
  a line and queues it. Nothing they type is echoed by the shell, because the
  shell never sees it. Control characters are refused outright, apart from
  Enter and Tab-as-text; a guest cannot send Ctrl+C, Ctrl+D, Ctrl+Z or any
  escape sequence. At most 16 lines queue per guest, at most 4 KiB each.
* **Host side.** Pending lines are drawn on the panel above the prompt, oldest
  first, each with its author's label and age, with control and bidi characters
  shown escaped as `\uXXXX` (as xiv-mcp already does for tool arguments) so a
  line can't disguise itself. The keybind (`CONFIG.mux.suggest_keys`, default
  Ctrl+Enter approve, Ctrl+Backspace reject, Alt+E edit-then-approve) acts on
  the top line. Approving writes exactly the displayed bytes, plus `\n`, into
  the PTY. Editing first is normal terminal editing on the host's own input
  line. Rejecting drops it and tells the guest.
* **Allowances,** all per (peer, terminal session), all revocable from the same
  list as grants: **ask every time** (the default), **allow for this session**
  (until the terminal closes, the grant expires or the agent restarts), **allow
  for N minutes** (15 / 60 / custom, capped at the grant's expiry), and **always
  for this peer** (only for a peer marked a trusted friend; it still stops at
  the grant's expiry). An allowance auto-approves a queued line after a 2 s
  cancel window, during which the host can still stop it with the reject key.
* **Blocking.** Per-peer block stops suggestions at once and rejects everything
  queued; it can be set from the panel and from the peer list. Blocking is
  separate from revoking the grant, so a host can keep showing the terminal
  while refusing input.
* **Never auto-approved, whatever the allowance:**
  * while the PTY's line discipline has `ECHO` off, which is how password and
    passphrase prompts read their input (`tcgetattr` on the master; the agent
    already owns the PTY). Suggestions are refused, and the buffer is cleared,
    so a guest cannot type into a password prompt or see one being answered;
  * when the last 2 KiB of output matches a prompt pattern (`[sudo] password
    for`, `Password:`, `Enter passphrase`, `Verification code`, `2FA`, and the
    same in the other client languages);
  * when the line itself starts a privilege escalation or a remote login
    (`sudo`, `doas`, `su`, `pkexec`, `ssh`, `scp`, `rsync` to a host),
    or contains a token-like string. Those always need a keypress, and the UI
    says why.
* **Audit.** Every decision appends one line to
  `~/.config/ghostty-agent/suggest-audit.log` (0600, JSON per line): time, peer
  fingerprint and label, session id, terminal title, the bytes as sent, whether
  it was approved, rejected, auto-approved under which allowance, or refused by
  a rule, and whether the host edited it first. The file is append-only for the
  agent, is never sent to a peer, and rotates at 8 MiB. `/term mux audit` shows
  the tail in game.
* A terminal with a live `SUGGEST` grant draws a badge with the number of
  pending lines, and the panic chord clears every queue.
* **What this does not fix.** An approved line runs as you. A host who approves
  without reading is in the same place as one who handed over the keyboard, and
  the patterns above are a speed bump, not a sandbox: a line can be `bash
  script.sh` where the script does anything. The defence is that every line is
  seen and approved by a person, and that the log says who asked for what.

### Enforcement in the agent (for every message from a peer)

1. Is the session authenticated, and is the grantee key pinned or confirmed
   by SAS?
2. Does the grant table hold a grant that is live, unexpired and unrevoked for
   this key, covering the named window or session with the needed right?
3. The message kind must be on the peer allow-list: WLIST (answered with
   granted windows only), WOPEN by key only, WACK, WCLOSE of own streams,
   WINPUT MOVE/BUTTON/WHEEL/KEY/TEXT/MODS within rights **for app windows
   only**, and WSUGGEST for a terminal. Everything else is refused and logged:
   `run:`, `app:`, `desktop:`, match text, wid, FOCUS, CLIP_*, terminal OPEN of
   new sessions, LIST, and any byte aimed at a PTY.
   Terminal streams have no input path at all: a peer's bytes can only enter
   through the suggestion queue, which the host's own agent writes after the
   host's approval.
4. Caps from the grant and the rate limits apply.

Frames for a guest come from the same per-window render. Each viewer has its own
stream, its own flow control (WACK) and its own scaling.

### P0: two pixel leaks in today's code

Both are in code that already runs. Each can put pixels of a window the owner
never shared into a stream a guest watches, so **both must land, with their
test, before any view share ships** (phase P0 below). They are worth fixing
even if the mux is never built, because they also mean a panel can show pixels
its owner didn't ask for.

1. **The X11 menu owner fallback (Linux).** An override-redirect window (a menu
   or tooltip) is drawn into the output of "its transient-for parent's, else the
   X11 window of its process it lies over, else one of its process, else **the
   focused X11 window**" ([REMOTE_WINDOWS.md](REMOTE_WINDOWS.md), "X11 apps").
   That last fallback can attach one app's menu to a different app's stream.
   **Fix:** drop the focused-window fallback. Only transient-for and
   same-process owners may claim a popup; an unclaimed override-redirect window
   is drawn nowhere and logged once. **Test** (`test_wayland_compositor`): two
   X11 clients, A shared and B focused; B opens a menu; A's picture and its
   WGEOM boxes are unchanged, and the menu's pixels appear in no frame of A.
2. **The Win32 BitBlt fallback (Windows).** Frames come from
   `PrintWindow(PW_CLIENTONLY | PW_RENDERFULLCONTENT)`, and when that fails or
   comes back black, from `BitBlt` of the window DC and then of the screen. Both
   fallbacks copy whatever is covering the window. Under Wine, `PrintWindow`
   drew nothing for another process's window, so **every observed frame came
   from a fallback**. **Fix:** a stream marked shareable uses `PrintWindow`
   only. If it fails or is blank, the stream sends no frame and, when the grant
   is what wants it, sharing that window is refused with "this window can't be
   captured safely on Windows". Local-only panels keep the fallbacks, with the
   panel showing which path it is on. **Test** (`test_capture_win32` plus a Wine
   smoke): a fallback capture on a shareable stream produces no frame and the
   documented refusal; the local path still produces one.

macOS: ScreenCaptureKit's `desktopIndependentWindow` filter captures only the
window, so it is fine as designed. It has never been run.

### Rate limits

| Where | Limit | Enforced by |
|---|---|---|
| Room socket | ≤ 2 KiB a blob. ≤ 2 blobs/s, burst 6. At most 34 room sockets per client (32 pinned peers, 1 zone room, 1 spare during rotation) | DO (per socket), agent (own sending) |
| Room size | 2 sockets for a pairwise room, 64 for a zone room. Past that the DO refuses new joins with `room full` | DO |
| Presence publish | at most 1 per 2 s. A change is sent at once but at most 2/s | agent |
| Invites sent | 3 a minute, 1 pending per target, 10 min quiet after a decline | agent (the relay can't read them) |
| Invites received | ≥ 5 from one `pres_key` in 10 min mutes it for the epoch. Blocked keys and characters are dropped silently. Setting: invites only from party, friends or pinned keys | agent + plugin |
| Pipe | 2 sockets. Frames ≤ 256 KiB. ≤ 60 frames/s. Idle 120 s closes it. ≤ 4 pipes per client IP | DO |
| Connections | ≤ 8 WebSocket upgrades a minute per IP (`CF-Connecting-IP`) | Worker |
| Account budget | the Worker counts billed requests and pipe-seconds in a counter DO and estimates the spend against a $10 month: warn at $7, refuse new pipes at $9 while presence keeps running, plus a daily pace check (see "The relay") | Worker |
| Handshakes | 5 a minute per peer, 20 in total. A failed SAS blocks that pipe | agent |
| Guest input | 200 events/s and 4 KiB TEXT/s per guest, app windows only | owner agent |
| Suggestions | 16 queued lines and 4 KiB a line per guest per terminal, 1 line/s, dropped while the buffer is full | owner agent |
| Guest streams | 4 guests, 4 streams each. Over the relay: ≤ 15 fps, ≤ 1280×800 | owner agent |

## The relay: public, paid, on the owner's account

The relay is open to anyone running the mod and runs on Jack's Cloudflare
account on the **Workers Paid** plan. That makes him the operator of a public
service, so the sizing, what he holds, retention, abuse handling and the way to
turn it off all belong in the design.

### Sizing and what it costs

Workers Paid starts at **$5 a month**, which includes the Workers requests and
the Durable Objects allowances (1 million DO requests and 400,000 GB-s a month;
above that, $0.15 per million requests and $12.50 per million GB-s; **Cloudflare
docs, Durable Objects pricing**). Incoming WebSocket messages bill at 20:1,
outgoing are free, and hibernatable sockets are billed for handler time rather
than wall clock.

A worked estimate, all of it **unverified arithmetic on documented rates**, for
**50 players who average 2 hours in game a day, each with 10 pinned peers and
open presence on**:

| Item | Working | Month |
|---|---|---|
| Presence messages, pairwise | 50 × 10 peers × 1 msg/2 s × 2 h/day × 30 = 54 M messages → ÷20 | 2.7 M billed requests |
| Presence messages, zone room (fan-out is outgoing, so free) | 50 × 1 msg/2 s × 2 h/day × 30 = 5.4 M → ÷20 | 0.27 M requests |
| Presence duration (hibernating, ~0.3 ms a message) | 59 M × 0.3 ms × 0.125 GB | ~2,200 GB-s |
| View shares, 100 stream-hours at 15 fps | 5.4 M messages → ÷20 | 0.27 M requests |
| Pipe duration, 100 stream-hours (a busy pipe doesn't hibernate) | 360,000 s × 0.125 GB | 45,000 GB-s |
| **Total over the included allowances** | ~2.2 M requests, 0 GB-s over | **~$0.33 + the $5 minimum** |

So at this size the plan costs its $5 floor. The shape of the bill matters more
than the total: presence is cheap and grows with users, while **pipe duration is
the expensive part**, at about $0.0056 an hour of one live share past the
included 400,000 GB-s (≈ 890 pipe-hours). A thousand extra share-hours in a
month is about $6.

**The budget is $10 a month, all in.** That is the $5 plan floor plus about $5
of usage, which at the rates above is roughly **5,700 share-hours a month, or
190 a day**, with presence costing well under a dollar of it. The guard below
works in those terms: a warning at **$7** and a hard stop at **$9** that ends
sharing but keeps presence running.

### What the operator holds, and for how long

* **By design, nothing durable that identifies anyone.** The Worker and the DOs
  keep no user records, no roster, no room history and no payload. Room and
  pipe ids rotate; a pairwise room id is meaningless after its epoch. Payloads
  are end-to-end encrypted and the relay has no key.
* **Transiently, in memory:** the sockets in a room, their IP addresses as
  Cloudflare provides them (`CF-Connecting-IP`), and per-socket counters. These
  die with the DO.
* **Durably, on purpose:** aggregate counters only — requests and pipe-seconds
  per day and per month, counts of rooms and pipes, and counts of rejections by
  reason. No identifiers, no IPs, no room ids. That is what the budget guard and
  the status page read.
* **Logging minimisation:** no `console.log` of payloads, room ids, pipe ids or
  IPs; Workers Logs and Logpush off; no Analytics Engine writes carrying an
  identifier; exceptions logged with a code, not a request body. What stays is
  what Cloudflare keeps for its own edge (request metadata, per their retention
  policy), which is outside the operator's control and should be said so in the
  published note.
* **A published privacy note** in the repo and on the status page, saying the
  above, saying that a determined operator of any relay can see IPs and timing,
  and saying that open presence additionally lets a determined operator work
  out which zone a room is in.
* **Retention:** aggregate counters are kept 90 days, rolled up to monthly
  totals, and nothing else is written at all.

### Abuse controls

The relay can't read anything, so it can only act on shape and volume:

* Per-IP caps: 8 upgrades a minute, 4 pipes, 34 room sockets; per-socket message
  and byte rates as in the table above; rooms capped at 2 or 64.
* A pipe is a capability: a stranger can't join one without the 128-bit id, and
  the second socket closes it to anyone else.
* A minimum client version and a required `User-Agent`-style build tag on the
  upgrade, so an old or obviously fake client can be refused and told why.
* Optional hashcash (2¹⁶ BLAKE2b, ~ms for a client) on room joins, off until
  scrapers show up, switchable without a deploy.
* An IP and ASN deny list for floods, and a global concurrency cap.
* **Reports** are weak by construction, and the note says so: the operator can't
  see who did what inside a session. In-game reporting produces evidence on the
  *reporter's* machine (the peer's fingerprint, label, the audit log). The
  operator can only ban an IP or refuse a build. Peer-level blocking is the
  users' own tool and works without the relay.
* **Abuse between players** (harassment, unwanted invites) is handled at the
  ends: mute, block by key, invite filters, Offline mode. The operator never
  needs to arbitrate, because he can't see the content.

### Budget guard and kill switch

* A counter DO holds the day's and the month's usage: billed requests and
  pipe-seconds. It turns them into an **estimated spend** with the published
  rates plus the $5 floor, and compares that with the **$10 monthly budget**.
  Both thresholds are configurable without a deploy:
  * **$7 — warn.** A banner on the status page, a line in the operator's
    notification, and a flag clients show as "the relay is near its budget;
    sharing may pause this month". Nothing is refused yet.
  * **$9 — stop shares, keep presence.** New pipes are refused with "sharing is
    paused until the month rolls over; presence still works", and live pipes are
    closed after their current stream idles for 60 s. Room sockets are
    untouched, because presence is the cheap part and the part people notice
    losing. Shares come back at the start of the next billing month, or when the
    operator raises the budget.
  * A **daily pace check** on top: a day may spend at most the month's remaining
    budget divided by the days left, doubled to allow a busy evening. Past that,
    new pipes wait until the next day, again with presence untouched.
  Cloudflare has no hard spend cap, so this counter is what stands between a
  busy month and a surprise bill, and the numbers above are estimates from
  documented rates, not a promise from the bill.
* **Kill switch:** a single flag read on every upgrade. Flipping it
  (`wrangler kv key put mux:state off`, or the dashboard) refuses all new
  connections with a reason, and a broadcast closes existing ones with a code
  the client shows as "the relay is off: <reason>". Degraded modes are the same
  flag with other values: `presence-only` (what the $9 stop sets),
  `pinned-only` (pairwise rooms only, which also ends zone-room fan-out if open
  presence ever turns into a flood), and `read-only` (no new pipes).
* Clients treat any refusal as "back off and tell the user": exponential
  backoff from 5 s to 5 min with jitter, the reason shown in the plugin, and no
  automatic retries past the hard cap.
* A tiny static status page (static-first, no framework) shows the flag, the
  day's aggregate counters and the published privacy note.
* Nothing in the design assumes the relay exists: a pinned pair on one tailnet
  connects directly, and losing the relay costs discovery and NAT traversal, not
  the mux.

## Guest seats and input on Wayland

The Linux compositor (`agent/capture_wayland.nelua`) has one seat, `seat0`,
today. Planned:

* `--guest-seats N` (default 2) creates `wlr_seat`s `guest-1`…`guest-N` **at
  startup**. Clients bind seats from registry globals, so apps started later see
  them. Apps that were already running see them only if they handle a
  global-added event.
* Each seat has its own `wlr_keyboard` (xkb keymap and `xkb_state`), its own
  pointer and keyboard focus, its own `wl_data_device` selection and primary
  selection, and its own text-input-v3. A guest's KEY goes through
  `wlr_seat_keyboard_notify_key` on *their* seat, so the modifiers sent with
  it are that seat's. With the host holding Shift on `seat0`, the guest's `b`
  arrives at the client with an empty modifier mask on `guest-1`: `b`.
* The protocol needs modifier **hold** semantics. Today KEY presses `mods` around
  the key and lone modifier keys aren't played, so a held Shift with a click
  can't be expressed. KEY gains a flag for "a modifier down/up that persists on
  this participant's seat". It is additive (a new WINPUT kind 7, MODS).
* A guest's clipboard stays in the guest seat. It is never bridged to the host
  clipboard, and host pastes never reach it. `CLIP_IN` lets a guest put their
  own text into their seat's selection.
* **Whether a client really takes the second seat:**
  `wlr_seat_client_for_wl_client(guest_seat, client)` is NULL when the client
  never bound that seat. Then the window falls back to **floor control**.
  **Assumption, to be tested in P3:** GTK3/4 and Qt handle several seats
  (GdkSeat / QWaylandInputDevice per `wl_seat`). Chromium/Electron and many
  others bind only one. Xwayland binds one, and X11 has one core keyboard, so X11
  apps always use floor control.
* **Floor control:** one participant at a time drives a window's input on
  `seat0`. When the floor passes, every held key and button of the old holder is
  released and the modifiers are reset (`wlr_seat_keyboard_notify_modifiers`
  with 0) before the new holder's state applies. The host can take the floor at
  any time. A guest asks for it (the host approves, or approves once for the
  session). It returns to the host after 10 s of guest idle. Modifier isolation
  holds because only one person types at a time. It isn't concurrent.
* Guests can't resize windows (the size is shared), send FOCUS, or close them.
* **Input on an app window is direct once granted.** There is no per-event
  approval: an editor or a browser is unusable that way, and the guest already
  had to be pinned, SAS-confirmed and granted. The stop is coarse and immediate:
  **Revoke** (the grant goes, streams close) or **Kick** (`/term mux kick
  <peer>`, or the button on the panel and in the peer list), which drops that
  peer's session, closes every stream and clears their queues while leaving the
  grant to expire on its own. The panic chord does both for everyone. Terminals
  are the exception and never take direct input: see "Terminal suggestions".
* `CURSORS`: the agent sends every viewer each participant's pointer position
  (≤ 30/s) as a new message, WCURSOR. Panels draw labelled carets.
* The agent's compositor must never advertise to its clients the protocols that
  would let one app capture or type into another: wlr-screencopy,
  ext-image-copy-capture, wlr-data-control, virtual-keyboard and
  input-method. This is a local defence, but it keeps a shared window from
  seeing unshared ones. Xwayland is weaker: X11 clients can read each other's
  windows and keys (XGetImage, XQueryKeymap). A guest who can type into an X11
  app can therefore reach other X11 windows. The UI warns on input grants for
  X11 windows.

### Windows and macOS backends: limits

* **Windows** (`capture_win32`): there is one system input state. The FOCUS path
  (`SendInput`) mixes with the host's physical keyboard: host Shift plus guest
  `b` gives `B`. So guests are **never** given the SendInput path. Guest input
  uses only window messages (`SendMessageTimeout`). That keeps the `WM_CHAR` text
  right, but apps reading `GetKeyState` see the host's real modifiers, and
  accelerators, menus and dialog navigation don't work. Guest input into a real
  desktop window can open dialogs on the host's actual screen, outside any
  grant. **Default: view-only on Windows.** Input needs a per-grant override with
  this warning. Frames: `PrintWindow` only (see above).
* **macOS** (`capture_mac`, never run on a Mac): pid-posted events carry the
  flags the agent sets per event. Apps that read the hardware modifier state
  (`CGEventSourceFlagsState`, `NSEvent.modifierFlags`) see the host's keys.
  FOCUS posts to the HID tap and is shared with the host, so guests never get it.
  **Default: view-only.** Screen Recording and Accessibility permissions belong
  to the agent, which gives guests no extra reach.

## Privacy-screen rendering

Peers' outlines are drawn by a new content-less world panel kind in
`core/app/worldview.nelua`. They use the same projection, curvature and depth
test, so walls hide them like real panels.

* Frosted glass: a neutral tint with procedural noise that moves a little, a
  1 px rim, the panel's curvature, and a small kind glyph in a corner
  (terminal, window or panel). No title strip, text, colour sampling or
  content-dependent brightness. Every outline of a kind looks the same apart
  from its size and pose.
* The NPC clone stands at its offset and plays its emote. When `talking` is set
  it plays a talk loop, with a speech bubble showing only "…". No text is ever
  drawn.
* No hover detail. A right-click offers "Ask to see" (a knock: an INVITE
  request going the other way, under the same rate limits, off when the owner
  sets "no knocks"), plus Mute and Block.
* Viewer-side toggles: hide peers' outlines, hide peers' NPCs, and a maximum of
  N clones in total (default 8) and per peer (1). Everything is hidden in gpose
  and cutscenes, and whenever `desk_block`'s scene flags say so
  ([ARCHITECTURE.md](ARCHITECTURE.md)).

### Opt-outs

| Mode | Connects to relay | Publishes | Sees others | Can be invited | Can invite |
|---|---|---|---|---|---|
| **Offline** (hide presence entirely) | no | no | no | no | no |
| **Invisible** | yes (the relay sees your IP and room ids) | no | yes | no | yes (you reveal yourself only to that invitee, on acceptance) |
| **Visible to pinned peers** | yes | to pinned peers only | yes | by pinned peers, per the invite filter | yes |
| **Visible + open presence** (the default) | yes | to everyone in the zone room, and to pinned peers | yes | by anyone in the zone room, per the filter | yes |

Presence is **on by default in the open-presence mode**, because otherwise
nobody can ever meet anybody. The first-run notice says exactly that, lists what
goes out, and offers *Pinned peers only* and *Offline* as one-press
alternatives; `/term mux presence pinned|invisible|off` does the same later, as
does Settings → Multiplexer → Presence. The panic chord drops straight to
Offline.

**Per-zone disable:** a list of territory ids plus categories, checked on every
`ZoneInit`. Entering a disabled zone leaves the room and hides peers' content.
Default categories: duties (`ContentFinderCondition` ≠ 0), PvP, and housing
interiors other than your own. Your own publishing can also be disabled per zone
("don't show my outlines at the Aetheryte Plaza"). Live grants aren't cut by a
zone change unless the grant says "until I leave the zone".

## Threat model

Assets, most to least sensitive: window and terminal contents and input (a
shell); the identity key; ContentId and character-to-key links; knowledge
notes; positions and presence; the relay budget.

| Adversary | S (spoofing) | T (tampering) | R (repudiation) | I (info disclosure) | D (denial of service) | E (elevation) | Mitigations and what is left |
|---|---|---|---|---|---|---|---|
| **Relay operator** (the account owner, Cloudflare, or whoever gets the account) | can pose as a peer only through MITM of the handshake | can drop, delay, reorder or replay blobs | none | IPs, timing and sizes. Room ids, and with work the zones (decision 4). Social graph: who opened a pipe with whom | can refuse service | none | Noise XX + SAS defeats MITM. AEAD + signatures + `seq` catch tampering and replay. **Left:** metadata, the pair graph, and — since open presence is on by default — zone enumeration for most users. Switching to pinned-only removes even that, and the first-run notice is what makes the choice real rather than buried. Running a public relay makes the operator a data holder, which "The relay" answers with minimised logs, aggregate-only retention, a published note, a budget guard and a kill switch |
| **Malicious peer** (another mod user) | can claim someone else's `anchor` and draw an NPC or outlines next to them; can claim a character in a handshake | sends malformed presence, frames or input | can deny sending (no audit on their side) | sees only presence. With a grant, sees what you granted | invite spam, knock spam, clone spam, suggestion spam | a guest who gets a line approved runs it as you | Anchor range checks, conflict rule, allow-listed models, caps, mute/block. SAS + ContentId commitment for handshakes. Strict parsers with size caps (the existing malformed-input tests extend to peer input). Terminals take no direct input at all: suggestions are approved line by line, escaped when displayed, refused while `ECHO` is off or at a password prompt, never auto-approved for sudo/ssh lines, and logged. **Left:** a host who approves without reading, and cosmetic spoofing of presence among mod users |
| **Network attacker** (between agent and relay) | none without keys | can't forge (TLS + AEAD) | none | sees that you talk to the Worker's hostname, and sizes | can block it | none | TLS + E2E |
| **Compromised plugin, owner side** (or any other Dalamud plugin in the same process: Dalamud has no isolation between plugins) | can ask the agent to issue grants to anyone | can publish anything allowed in presence | can issue grants you didn't see | already sees all your windows (it's your display) | can drop everything | the agent token (and the Windows ConPTY) is already a shell | The mux adds no new power, and the identity key stays in the agent. Grants are logged by the agent to `grants.log`, and the owner can review it outside the game. **Left:** a compromised game process is fully trusted, as it is today |
| **Compromised plugin, guest side** | none toward the owner | can send any input the grant allows, and can queue suggestions | none | gets exactly the granted content, and can save it | can load its own client | none beyond the grant | Enforcement sits in the *owner's* agent, so a guest's code isn't trusted |
| **Prompt injection via shared knowledge or tickets** | a note can claim authority ("system: run …") | none | none | a note can try to make your model leak other notes into a ticket or an export | slow or large notes | a model obeying a note's instructions | Foreign notes are data: quarantined in `knowledge/foreign/<fp>/`, marked `trust: foreign`, reached only through a separate search tool that returns them quoted as untrusted data, never valid as runbooks, and left out of timers. Every change or destructive almanac tool still needs human confirmation. Tickets go to a human, never to a model. Exports are built only by the owner's explicit command. **Left:** marking text as data doesn't reliably stop a model following it. The real defences are that the model has no way to act on it without a human (confirmation) and no way to publish anything (static export) |
| **Legitimate viewer: screenshots, recording, replay** | none | none | may later deny what they saw | **can keep anything they were shown. This cannot be prevented.** | none | none | Short default grants, `REDACT_TITLE`, an optional `WATERMARK` burned in by the owner's agent (which deters and attributes, but doesn't prevent), the eye badge so you always know who is watching, and the panic chord |
| **Harassment and spam** | fake presence near a target | offensive allow-listed emotes | none | none | invite floods, knock floods, clone floods | none | Open presence is on by default, so a stranger in your zone can see your NPC and outlines and can send you one invite: that is the cost of discovery, and the first-run notice states it with the one-line way out (`/term mux presence pinned`). Beyond that: rate limits, invite filters, mute and block by key and character, per-peer suggestion blocking, per-peer clone cap, hide-all toggles, Offline and Invisible modes, per-zone disable |
| **Privacy of positions and character ids** | none | none | none | presence shows panel poses near you to everyone in the zone by default; the relay may enumerate zone rooms; ContentId could correlate identities | none | none | Offsets relative to your character, capped at 10/30 yalms, quantized; no HUD or camera data; pinned-only mode for anyone who wants location kept from the relay too. ContentId only as a keyed commitment inside Noise. Keys used in presence are per epoch; the identity key is shown only in handshakes |
| **Game ToS** | none | none | none | none | none | none | Using third-party tools breaks Square Enix's ToS in itself; this design doesn't change that. It adds no game packets, sends nothing to game servers, never types into chat (the SAS is typed by a person or said aloud), and spawns only client-side objects. Detection risk is that of Dalamud plus client-side spawns, and **no stronger claim is made** |
| **Resource exhaustion** | none | huge or malformed frames and presence | none | none | on the agent (decode, textures), the plugin (clones), the relay (fan-out) and the paid-plan budget | none | Caps everywhere: blob and frame sizes, `max_w`/`max_h` in grants, QOI decoded length bound, ≤ 16 outlines, 2 or 64 sockets per room, texture memory per peer, suggestion queue caps, plus the relay's per-IP caps, budget guard and kill switch. **Left:** on a paid plan the budget is money, not just an outage, so the counter DO and its soft and hard caps are the control, and Cloudflare offers no hard spend cap |

Replay protection: presence is bound to its epoch through `room_id` in the AD and
rejects stale `seq`. Noise transport nonces are counters. INVITE expiries are
120 s. Grants carry `not_before` and `expires_at`, and live in a table.

## Knowledge exchange (P4)

* **Marking.** almanac notes get an additive front-matter key `share: public`.
  The default is private, and the existing parser stays strict about
  `key: value` lines. Notes with `safety` other than `read`, and runbooks, can't
  be public.
* **Export.** The owner runs `almanac export-public`. It lints each note and
  refuses to export one that matches home paths, IPs, tailnet names, hostnames
  from the config, e-mail addresses or token-like strings. It writes a bundle
  (notes, manifest, time) and asks ghostty-agent to sign it with the identity
  key. The lint is a safety net, not a guarantee, so the owner is shown the
  bundle's full list before it's signed.
* **Pull.** A peer with a session asks for the catalogue on channel 1, gets the
  manifest, and pulls the bundle. Nothing is pushed.
* **Review.** Incoming bundles are staged. `almanac review-incoming` (or an
  in-game window) shows every note in full. Accepted notes land in
  `knowledge/foreign/<fingerprint>/` with `trust: foreign`, `source_peer` and
  `received`, in a separate FTS index.
* **Use.** The local model reaches them only through `search_foreign`. Its
  results are wrapped as quoted untrusted data with the peer's label. Nothing
  foreign can be a runbook, a tool or config.

### Agent tickets

A peer's agent (through their almanac or xiv-mcp) can send a ticket on channel
1:

`{ticket_id, from_key, tool, args (JSON ≤ 4 KiB), reason (≤ 500 chars), expires}`

* `tool` must be on the owner's peer allow-list, which is empty by default.
  Examples: `post_status` to my board, opening a URL through my browser, or a
  `read`-safety almanac tool.
* My agent passes it to my plugin, which passes it to xiv-mcp's
  `XivMcp.PeerTicket` IPC. `ConfirmWindow` shows the peer's pinned label, the
  tool and the arguments, escaped as xiv-mcp already escapes them (format, bidi
  and line-separator characters as `\uXXXX`). The choices are **Allow once** and
  **Deny**. There are no timed grants for peers.
* An allowed ticket runs the tool deterministically with those arguments. It is
  never handed to a model as a prompt. The result goes back on the same channel.
* Board sharing: with opt-in, a peer's `post_status` entries show on my
  `AgentBoard` as `peer:<label>/<agent>`, read-only, with the same limits
  (64-character names, 200-character status).

## P5: UDP state-sync transport

This works like mosh's SSP. The sender keeps a numbered state for each object
and sends diffs from the last state the receiver acknowledged, so a lost packet
is overtaken rather than resent. Window streams are already close to this (tile
diffs plus WACK). Terminals need a screen state, so libghostty-vt goes into the
agent.

* Datagrams: `session_id u32 ‖ nonce u64 ‖ ChaChaPoly(k, nonce, …)`, with keys
  derived from the Noise session. The nonce is explicit, with a 2048-entry replay
  window. Roaming follows mosh: the last address that sent an authenticated
  packet wins.
* Paths: the tailnet or the LAN only. Workers can't carry UDP. The Worker could
  report `CF-Connecting-IP`, but not the UDP port the NAT maps, so hole punching
  would need STUN, meaning third-party metadata. That is deferred.
* The same state-sync layer also runs over the WebSocket pipe, so there's one
  code path, and UDP is just a faster carrier.

## Phased delivery

Estimates are focused engineering days for the code and host tests, based on the
size of comparable work in this repo. **In-game observation is extra**, and
nothing counts as done until it has been seen in game on the build claimed.

| Phase | Contents | Host tests | Estimate |
|---|---|---|---|
| **P0: the two pixel leaks** (blocks every later phase) | drop the focused-X11-window fallback for override-redirect windows; shareable Win32 streams use `PrintWindow` only, with the refusal path and the panel telling you which capture path it is on | the two tests written out under "P0": an unclaimed X11 menu appears in no other stream, and a fallback capture on a shareable stream yields no frame | 2–4 |
| **P1: presence of NPCs and outlines** | vendor Monocypher + optional Ed25519 + BearSSL (pinned). Relay Worker + DOs: rooms (pairwise and open), counter DO, the $10 budget guard ($7 warn, $9 shares-off) and daily pace check, kill switch, status page, privacy note. Agent: TLS client, `mux_relay`, pairwise and zone room derivation and rotation, sealing and opening, limits. Plugin: zone tuple, presence out, privacy-screen panels, Offline/Invisible/open-presence switches, per-zone disable, mute/block, pairing codes, and the first-run notice with the turn-it-off table. XivDesktop: `mux.npc.publish` / `mux.peers` and clones | BLAKE2/X25519/Argon2 vectors, envelope round trip and every rejection, epoch rotation, a room refusing a third socket, a fake relay in the harness, the outline panel through fake ImGui, nothing published before the first-run notice is answered and each button landing in the right mode, Miniflare tests for the caps, the budget thresholds (warn, shares-off with presence still flowing, daily pace) and the kill switch | 18–26 |
| **P2: view-only shares** | identity key, Noise XX (cacophony vectors), SAS words, TOFU pins, invite by target and context menu, pairing-code path, grants and table, revoke, panic, eye badge. Agent enforcement and filtered WLIST. Guest plugin panels for `peer:`. Terminals without replay. Watermark | handshake with MITM and bad-SAS cases, grant parsing and expiry, every refused message kind, two agents over a fake relay (test_agent_windows extended), no pixels of an unshared window in a shared stream | 15–20 |
| **P3: input: guest seats and terminal suggestions** | app windows: guest `wlr_seat`s, MODS hold, per-seat clipboard, floor control and handoff, WCURSOR, Windows/macOS view-only defaults. Terminals: the suggestion buffer and queue, WSUGGEST, the host's approve/reject/edit keybinds and panel UI, allowances (session, N minutes, always-for-peer), per-peer blocking, the `ECHO`-off and prompt-pattern refusals, the audit log and `/term mux audit` | test_wayland_compositor: host Shift held on seat0 while guest `b` gives `b` (GTK3 yad); seat binding detection; floor handoff releasing keys; no host clipboard in the guest seat. Suggestions: nothing reaches a PTY unapproved, control characters refused, queue caps, every allowance including its cancel window, refusals while `ECHO` is off and at each prompt pattern, audit lines for approve/reject/edit/auto/refuse | 16–26 |
| **P4: almanac exchange and agent tickets** | `share: public`, export lint, signing, pull, staging, review, foreign index, `search_foreign`. Ticket channel, `XivMcp.PeerTicket`, allow-list, board sharing | almanac unit tests for lint and quarantine, injection fixtures (notes that give instructions) that never reach a tool call, xiv-mcp approval tests for peer tickets | 10–14 |
| **P5: UDP state sync** | libghostty-vt in the agent, SSP-style state objects, datagram crypto, replay window, roaming, WebSocket carrier parity | loss, reorder and duplication harness, roaming, replay rejection | 12–18 |

Total: 73–108 focused days before in-game verification.

## Nothing open

All eight questions this document raised are answered and folded in:

| Question | Answer |
|---|---|
| Who runs the relay | Public, paid, on the owner's account, with the duties that brings |
| Room privacy | Pairwise rooms for pinned peers, zone rooms for discovery |
| Terminal input | Suggestions, approved line by line |
| Presence default | On |
| TLS | In the agent, so shares outlive the game client |
| Monthly budget | $10: warn at $7, shares stop at $9, presence keeps running |
| Open presence in P1 | Yes, on by default, behind a first-run notice that says how to turn it off |
| Per-event approval for app windows | No. Direct input once granted; revoke or kick is the stop |

What remains is not a question but a warning: **none of this is implemented, and
nothing in it has been observed in game.** The first thing to build is P0, the
two capture leaks, because they are live in today's code.
