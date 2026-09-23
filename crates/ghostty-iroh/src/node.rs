//! The transport itself, as a plain Rust object.
//!
//! `Node` owns a tokio runtime, one iroh `Endpoint`, the slot table and the
//! wakeup signal. Every method is non-blocking and mirrors one C ABI function,
//! so `lib.rs` is a thin singleton + pointer-validation layer over this, and
//! the loopback test in `tests/` can hold two `Node`s in one process — which
//! the singleton ABI cannot express.
//!
//! Threading: the runtime has its own threads; every `Node` method is meant to
//! be called from exactly one caller thread (the game thread in the core, the
//! agent main loop in the agent). Shared state is behind short-held mutexes and
//! atomics; nothing here calls back into the caller.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering, AtomicU32};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::endpoint::{Connection, RecvStream, SendStream};
use iroh::{Endpoint, NodeAddr, NodeId, RelayMode, SecretKey};
use tokio::sync::{mpsc, Notify};

use crate::wakeup::Wakeup;

/// Single ALPN. Step 4 (one QUIC stream per window stream) stays inside this
/// ALPN; a protocol change bumps the suffix.
pub const ALPN: &[u8] = b"ghostty/agent/0";

/// Error codes. Kept byte-identical to `include/ghostty_iroh.h`.
pub const GI_EAGAIN: i32 = 0;
pub const GI_ECLOSED: i32 = -1;
pub const GI_ERESET: i32 = -2;
pub const GI_ETIMEOUT: i32 = -3;
pub const GI_EREFUSED: i32 = -4;
pub const GI_EUNREACH: i32 = -5;
pub const GI_EADDR: i32 = -6;
pub const GI_EHANDLE: i32 = -7;
pub const GI_EINTERNAL: i32 = -8;

/// Userspace receive cap. iroh may buffer a stream's received bytes whether or
/// not the caller ever calls recv (docs/IROH.md, "Backpressure changes
/// character"), so the reader task stops reading the stream above this and lets
/// QUIC flow control do its job. UNMEASURED: the right number is whatever a
/// large KEY-frame burst with a slow reader shows.
const RX_CAP: usize = 4 * 1024 * 1024;
/// Queued-but-unwritten bytes above which `send` returns GI_EAGAIN (0).
const TX_CAP: usize = 4 * 1024 * 1024;
/// Largest chunk copied per send call.
const SEND_CHUNK: usize = 64 * 1024;
/// Below the client's own 5 s connect timer (core/agent_client.nelua:657) so a
/// stuck connect is reported by the crate, not raced by the caller.
/// UNMEASURED: whether a relay-only path routinely completes inside this.
const CONNECT_DEADLINE: Duration = Duration::from_millis(4_500);

// ---------------------------------------------------------------------------
// slot table
// ---------------------------------------------------------------------------

/// `gi_handle`: low 16 bits are a 1-based slot index, high 16 bits a
/// generation, so 0 is never valid and a stale handle is rejected instead of
/// aliasing a reused slot.
pub type Handle = u32;

fn pack(slot: usize, generation: u16) -> Handle {
    ((generation as u32) << 16) | ((slot as u32 + 1) & 0xffff)
}

fn unpack(h: Handle) -> Option<(usize, u16)> {
    let idx = (h & 0xffff) as usize;
    if idx == 0 {
        return None;
    }
    Some((idx - 1, (h >> 16) as u16))
}

enum Entry {
    Conn(Arc<ConnState>),
    Listener(Arc<ListenerState>),
}

#[derive(Default)]
struct Slots {
    entries: Vec<Option<Entry>>,
    gens: Vec<u16>,
}

impl Slots {
    fn insert(&mut self, e: Entry) -> Handle {
        let slot = match self.entries.iter().position(|s| s.is_none()) {
            Some(i) => i,
            None => {
                if self.entries.len() >= 0xffff {
                    return 0;
                }
                self.entries.push(None);
                self.gens.push(0);
                self.entries.len() - 1
            }
        };
        self.gens[slot] = self.gens[slot].wrapping_add(1);
        self.entries[slot] = Some(e);
        pack(slot, self.gens[slot])
    }

    fn get(&self, h: Handle) -> Option<&Entry> {
        let (slot, generation) = unpack(h)?;
        if self.gens.get(slot).copied()? != generation {
            return None;
        }
        self.entries.get(slot)?.as_ref()
    }

    fn take(&mut self, h: Handle) -> Option<Entry> {
        let (slot, generation) = unpack(h)?;
        if self.gens.get(slot).copied()? != generation {
            return None;
        }
        self.entries.get_mut(slot)?.take()
    }
}

// ---------------------------------------------------------------------------
// per-connection state
// ---------------------------------------------------------------------------

struct ConnState {
    /// 0 pending, 1 connected, <0 one of GI_E*. Latches once terminal.
    status: AtomicI32,
    rx: Mutex<VecDeque<u8>>,
    rx_len: AtomicUsize,
    /// 0 while the stream is live, else the GI_E* that ended it. Only reported
    /// to the caller once `rx` has drained.
    rx_end: AtomicI32,
    /// Signalled when the caller drained below RX_CAP, so the reader resumes.
    rx_room: Notify,
    tx: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
    tx_len: AtomicUsize,
    peer: Mutex<Option<String>>,
    /// What the allowlist grants this peer (GI_CAP_*). Everything for a
    /// connection we opened, and for an accepted one with no allowlist -- a
    /// file that does not exist cannot restrict anybody.
    caps: AtomicU32,
    closing: AtomicBool,
    closed: Notify,
    wake: Arc<Wakeup>,
}

impl ConnState {
    fn new(wake: Arc<Wakeup>, status: i32) -> Arc<Self> {
        Arc::new(Self {
            status: AtomicI32::new(status),
            rx: Mutex::new(VecDeque::new()),
            rx_len: AtomicUsize::new(0),
            rx_end: AtomicI32::new(0),
            rx_room: Notify::new(),
            tx: Mutex::new(None),
            tx_len: AtomicUsize::new(0),
            peer: Mutex::new(None),
            caps: AtomicU32::new(GI_CAP_ALL),
            closing: AtomicBool::new(false),
            closed: Notify::new(),
            wake,
        })
    }

    fn fail(&self, code: i32) {
        let _ = self.status.compare_exchange(0, code, Ordering::SeqCst, Ordering::SeqCst);
        let _ = self.rx_end.compare_exchange(0, code, Ordering::SeqCst, Ordering::SeqCst);
        self.wake.signal();
    }

    /// True when the caller has something to look at without blocking.
    fn pollable(&self) -> bool {
        self.rx_len.load(Ordering::SeqCst) > 0
            || self.rx_end.load(Ordering::SeqCst) != 0
            || self.status.load(Ordering::SeqCst) != 0
    }
}

struct ListenerState {
    pending: Mutex<VecDeque<Arc<ConnState>>>,
    closing: AtomicBool,
    closed: Notify,
}

// ---------------------------------------------------------------------------
// node
// ---------------------------------------------------------------------------

pub struct NodeConfig<'a> {
    /// ed25519 secret, 32 raw bytes. Created with mode 0600 if absent, so the
    /// NodeId survives an agent restart. `None` generates an ephemeral key.
    pub secret_key_path: Option<&'a Path>,
    /// n0 discovery + relays. Off in the loopback test, which addresses the
    /// peer by its direct socket address.
    pub relays: bool,
}

impl Default for NodeConfig<'_> {
    fn default() -> Self {
        Self { secret_key_path: None, relays: true }
    }
}

pub struct Node {
    rt: Option<tokio::runtime::Runtime>,
    endpoint: Endpoint,
    slots: Mutex<Slots>,
    wake: Arc<Wakeup>,
    last_error: Mutex<String>,
}

impl Node {
    pub fn new(cfg: NodeConfig<'_>) -> Result<Self, String> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("ghostty-iroh")
            .build()
            .map_err(|e| format!("runtime: {e:#}"))?;

        let secret = load_or_create_key(cfg.secret_key_path)?;
        let relays = cfg.relays;
        let endpoint = rt
            .block_on(async move {
                let mut b = Endpoint::builder().secret_key(secret).alpns(vec![ALPN.to_vec()]);
                b = if relays { b.discovery_n0() } else { b.relay_mode(RelayMode::Disabled) };
                b.bind().await
            })
            .map_err(|e| format!("bind: {e:#}"))?;

        Ok(Self {
            rt: Some(rt),
            endpoint,
            slots: Mutex::new(Slots::default()),
            wake: Arc::new(Wakeup::new()),
            last_error: Mutex::new(String::new()),
        })
    }

    fn rt(&self) -> &tokio::runtime::Runtime {
        self.rt.as_ref().expect("runtime dropped")
    }

    fn set_err(&self, msg: impl Into<String>) {
        if let Ok(mut s) = self.last_error.lock() {
            *s = msg.into();
        }
    }

    pub fn last_error(&self) -> String {
        self.last_error.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn node_id(&self) -> NodeId {
        self.endpoint.node_id()
    }

    /// Direct socket addresses this endpoint is reachable on. Used by the
    /// loopback test to build a `NodeAddr` without discovery or a relay.
    pub fn direct_addrs(&self) -> Vec<SocketAddr> {
        self.rt()
            .block_on(self.endpoint.direct_addresses().initialized())
            .map(|set| set.into_iter().map(|d| d.addr).collect())
            .unwrap_or_default()
    }

    pub fn node_addr(&self) -> NodeAddr {
        NodeAddr::from_parts(self.node_id(), None, self.direct_addrs())
    }

    // -- client ------------------------------------------------------------

    /// Returns immediately with a handle in the pending state, or 0.
    pub fn connect(&self, addr: NodeAddr) -> Handle {
        let st = ConnState::new(self.wake.clone(), 0);
        let h = self.slots.lock().unwrap().insert(Entry::Conn(st.clone()));
        if h == 0 {
            self.set_err("slot table full");
            return 0;
        }
        let ep = self.endpoint.clone();
        let peer = addr.node_id;
        let state = st.clone();
        self.rt().spawn(async move {
            let res = tokio::time::timeout(CONNECT_DEADLINE, ep.connect(addr, ALPN)).await;
            let conn: Connection = match res {
                Err(_) => return state.fail(GI_ETIMEOUT),
                Ok(Err(e)) => return state.fail(map_connect_error(&e.to_string())),
                Ok(Ok(c)) => c,
            };
            // One bidirectional stream per connection: core/protocol.nelua
            // reassembles from one contiguous byte stream, and feeding more
            // than one QUIC stream into one inq is garbage (step 4 changes
            // that, as a protocol change).
            let (send, recv) = match conn.open_bi().await {
                Ok(pair) => pair,
                Err(e) => return state.fail(map_stream_error(&e.to_string())),
            };
            *state.peer.lock().unwrap() = Some(peer.to_string());
            spawn_io(state.clone(), conn, send, recv);
            state.status.store(1, Ordering::SeqCst);
            state.wake.signal();
        });
        h
    }

    /// 1 connected, 0 pending, <0 GI_E*. Slot lookup plus an atomic read; safe
    /// to call once per rendered frame, idempotent after it latches.
    pub fn connect_poll(&self, h: Handle) -> i32 {
        match self.conn(h) {
            Some(st) => st.status.load(Ordering::SeqCst),
            None => GI_EHANDLE,
        }
    }

    // -- server ------------------------------------------------------------

    /// One endpoint-wide accept pump. `allowlist` is a file of z-base-32 node
    /// ids, one per line, `#` comments; `None` accepts any peer (the token in
    /// PROTO_HELLO is then the only authorisation — see docs/IROH.md).
    pub fn listen(&self, allowlist: Option<&Path>) -> Handle {
        let allowed = match allowlist {
            None => None,
            Some(p) => match read_allowlist(p) {
                Ok(v) => Some(v),
                Err(e) => {
                    self.set_err(format!("allowlist {}: {e}", p.display()));
                    return 0;
                }
            },
        };
        let ls = Arc::new(ListenerState {
            pending: Mutex::new(VecDeque::new()),
            closing: AtomicBool::new(false),
            closed: Notify::new(),
        });
        let h = self.slots.lock().unwrap().insert(Entry::Listener(ls.clone()));
        if h == 0 {
            self.set_err("slot table full");
            return 0;
        }
        let ep = self.endpoint.clone();
        let wake = self.wake.clone();
        self.rt().spawn(async move {
            loop {
                if ls.closing.load(Ordering::SeqCst) {
                    break;
                }
                let incoming = tokio::select! {
                    _ = ls.closed.notified() => break,
                    inc = ep.accept() => match inc { Some(i) => i, None => break },
                };
                let ls2 = ls.clone();
                let wake2 = wake.clone();
                let allowed2 = allowed.clone();
                tokio::spawn(async move {
                    let conn = match incoming.await {
                        Ok(c) => c,
                        Err(_) => return,
                    };
                    let peer = match conn.remote_node_id() {
                        Ok(id) => id,
                        Err(_) => {
                            conn.close(4u32.into(), b"no peer id");
                            return;
                        }
                    };
                    let mut caps = GI_CAP_ALL;
                    if let Some(list) = &allowed2 {
                        match list.iter().find(|(a, _)| *a == peer) {
                            Some((_, c)) => caps = *c,
                            None => {
                                // GI_EREFUSED at the transport, before any frame.
                                conn.close(4u32.into(), b"not allowlisted");
                                return;
                            }
                        }
                    }
                    let (send, recv) = match conn.accept_bi().await {
                        Ok(pair) => pair,
                        Err(_) => return,
                    };
                    let st = ConnState::new(wake2.clone(), 1);
                    *st.peer.lock().unwrap() = Some(peer.to_string());
                    st.caps.store(caps, Ordering::Relaxed);
                    spawn_io(st.clone(), conn, send, recv);
                    ls2.pending.lock().unwrap().push_back(st);
                    wake2.signal();
                });
            }
        });
        h
    }

    /// 0 when nothing is pending. Same termination shape as `net.accept`.
    pub fn accept(&self, listener: Handle) -> Handle {
        let ls = match self.slots.lock().unwrap().get(listener) {
            Some(Entry::Listener(l)) => l.clone(),
            Some(_) => {
                self.set_err("accept on a connection handle");
                return 0;
            }
            None => {
                self.set_err("accept on a stale handle");
                return 0;
            }
        };
        let st = match ls.pending.lock().unwrap().pop_front() {
            Some(s) => s,
            None => return 0,
        };
        self.slots.lock().unwrap().insert(Entry::Conn(st))
    }

    pub fn peer_id(&self, h: Handle) -> Option<String> {
        self.conn(h)?.peer.lock().unwrap().clone()
    }

    /// GI_CAP_* for this connection, or None for a stale handle. A caller that
    /// cannot tell must not assume: the agent refuses rather than granting.
    pub fn peer_caps(&self, h: Handle) -> Option<u32> {
        Some(self.conn(h)?.caps.load(Ordering::Relaxed))
    }

    // -- data --------------------------------------------------------------

    /// >0 bytes copied, 0 "again next frame", <0 GI_E*.
    ///
    /// Buffered bytes are handed over before any end-of-stream code, so a peer
    /// that writes then closes does not lose its last frame.
    pub fn recv(&self, h: Handle, buf: &mut [u8]) -> i32 {
        let st = match self.conn(h) {
            Some(s) => s,
            None => return GI_EHANDLE,
        };
        if buf.is_empty() {
            return 0;
        }
        let mut n = 0usize;
        {
            let mut rx = st.rx.lock().unwrap();
            while n < buf.len() {
                match rx.pop_front() {
                    Some(b) => {
                        buf[n] = b;
                        n += 1;
                    }
                    None => break,
                }
            }
        }
        if n > 0 {
            st.rx_len.fetch_sub(n, Ordering::SeqCst);
            st.rx_room.notify_waiters();
            return n as i32;
        }
        let end = st.rx_end.load(Ordering::SeqCst);
        if end != 0 {
            return end;
        }
        let status = st.status.load(Ordering::SeqCst);
        if status < 0 {
            return status;
        }
        GI_EAGAIN
    }

    /// >=0 bytes accepted, <0 GI_E*. A blocked stream window is 0, never an
    /// error: core/agent_client.nelua:631-637 tears the link down on -1.
    pub fn send(&self, h: Handle, buf: &[u8]) -> i32 {
        let st = match self.conn(h) {
            Some(s) => s,
            None => return GI_EHANDLE,
        };
        let status = st.status.load(Ordering::SeqCst);
        if status < 0 {
            return status;
        }
        if status == 0 {
            return GI_EAGAIN; // still connecting
        }
        if buf.is_empty() {
            return 0;
        }
        if st.tx_len.load(Ordering::SeqCst) >= TX_CAP {
            return GI_EAGAIN;
        }
        let n = buf.len().min(SEND_CHUNK);
        let tx = st.tx.lock().unwrap();
        let tx = match tx.as_ref() {
            Some(t) => t,
            None => return GI_ECLOSED,
        };
        match tx.send(buf[..n].to_vec()) {
            Ok(()) => {
                st.tx_len.fetch_add(n, Ordering::SeqCst);
                n as i32
            }
            Err(_) => GI_ECLOSED,
        }
    }

    /// Synchronous, void, and must not leak: the reconnect path runs this
    /// forever while an agent is down. The slot goes away now; the graceful
    /// QUIC close drains on the runtime.
    pub fn close(&self, h: Handle) {
        let entry = self.slots.lock().unwrap().take(h);
        match entry {
            Some(Entry::Conn(st)) => {
                st.closing.store(true, Ordering::SeqCst);
                // Dropping the sender is what tells the writer task to finish
                // the stream rather than abort it.
                st.tx.lock().unwrap().take();
                st.closed.notify_waiters();
                st.rx_room.notify_waiters();
            }
            Some(Entry::Listener(ls)) => {
                ls.closing.store(true, Ordering::SeqCst);
                ls.closed.notify_waiters();
                // Anything accepted but never handed out is closed too.
                for st in ls.pending.lock().unwrap().drain(..) {
                    st.closing.store(true, Ordering::SeqCst);
                    st.tx.lock().unwrap().take();
                    st.closed.notify_waiters();
                }
            }
            None => {} // 0 or stale: no-op, by contract
        }
    }

    // -- readiness ---------------------------------------------------------

    pub fn wakeup_fd(&self) -> i32 {
        self.wake.raw_fd()
    }

    pub fn wakeup_handle(&self) -> *mut std::ffi::c_void {
        self.wake.raw_handle()
    }

    pub fn wakeup_drain(&self) {
        self.wake.drain();
    }

    /// How long the caller may sleep, never more than `cap_ms`.
    pub fn wait_ms(&self, cap_ms: i32) -> i32 {
        if self.wake.armed() {
            return 0;
        }
        let slots = self.slots.lock().unwrap();
        for e in slots.entries.iter().flatten() {
            match e {
                Entry::Conn(st) if st.pollable() => return 0,
                Entry::Listener(ls) if !ls.pending.lock().unwrap().is_empty() => return 0,
                _ => {}
            }
        }
        cap_ms.max(0)
    }

    fn conn(&self, h: Handle) -> Option<Arc<ConnState>> {
        match self.slots.lock().unwrap().get(h) {
            Some(Entry::Conn(st)) => Some(st.clone()),
            _ => None,
        }
    }

    /// Stops the runtime, closes the endpoint and joins the threads. Blocking,
    /// bounded: the DLL must not unmap while a runtime thread is still alive.
    pub fn shutdown(mut self) {
        let handles: Vec<Handle> = {
            let slots = self.slots.lock().unwrap();
            (0..slots.entries.len())
                .filter(|i| slots.entries[*i].is_some())
                .map(|i| pack(i, slots.gens[i]))
                .collect()
        };
        for h in handles {
            self.close(h);
        }
        if let Some(rt) = self.rt.take() {
            rt.block_on(async {
                let _ = tokio::time::timeout(Duration::from_secs(2), self.endpoint.close()).await;
            });
            // Bounded join: shutdown_timeout returns once the threads are gone
            // or the deadline passes, and the deadline passing is a bug to log,
            // not a reason to unmap under a live thread.
            rt.shutdown_timeout(Duration::from_secs(2));
        }
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        if let Some(rt) = self.rt.take() {
            rt.shutdown_timeout(Duration::from_secs(2));
        }
    }
}

// ---------------------------------------------------------------------------
// per-connection io tasks
// ---------------------------------------------------------------------------

fn spawn_io(st: Arc<ConnState>, conn: Connection, mut send: SendStream, mut recv: RecvStream) {
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    *st.tx.lock().unwrap() = Some(tx);

    // writer
    let w = st.clone();
    tokio::spawn(async move {
        while let Some(chunk) = rx.recv().await {
            let n = chunk.len();
            if send.write_all(&chunk).await.is_err() {
                w.tx_len.fetch_sub(n, Ordering::SeqCst);
                w.fail(GI_ERESET);
                return;
            }
            w.tx_len.fetch_sub(n, Ordering::SeqCst);
        }
        // Sender dropped by close(): drain what QUIC still owes, then FIN.
        let _ = send.finish();
        let _ = tokio::time::timeout(Duration::from_secs(2), send.stopped()).await;
        conn.close(0u32.into(), b"bye");
    });

    // reader
    let r = st.clone();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            if r.closing.load(Ordering::SeqCst) {
                return;
            }
            // Stop reading the stream while the caller is behind, so the
            // backpressure lands in QUIC flow control instead of our heap.
            while r.rx_len.load(Ordering::SeqCst) >= RX_CAP {
                tokio::select! {
                    _ = r.rx_room.notified() => {}
                    _ = r.closed.notified() => return,
                }
            }
            let read = tokio::select! {
                _ = r.closed.notified() => return,
                res = recv.read(&mut buf) => res,
            };
            match read {
                Ok(Some(0)) => continue,
                Ok(Some(n)) => {
                    r.rx.lock().unwrap().extend(buf[..n].iter().copied());
                    r.rx_len.fetch_add(n, Ordering::SeqCst);
                    r.wake.signal();
                }
                Ok(None) => {
                    // Clean FIN. net.recv collapses this to -1 at the seam.
                    let _ = r.rx_end.compare_exchange(
                        0,
                        GI_ECLOSED,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                    r.wake.signal();
                    return;
                }
                Err(e) => {
                    r.fail(map_stream_error(&e.to_string()));
                    return;
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// Error mapping is by message text because the iroh/quinn error enums are not
/// stable across releases and the caller collapses every negative code to -1
/// anyway; the distinction survives only in the gi_last_error log line.
fn map_connect_error(msg: &str) -> i32 {
    let m = msg.to_ascii_lowercase();
    if m.contains("timed out") || m.contains("timeout") {
        GI_ETIMEOUT
    } else if m.contains("refused") || m.contains("closed by peer") || m.contains("forbidden") {
        GI_EREFUSED
    } else if m.contains("no addr") || m.contains("unreachable") || m.contains("no path") {
        GI_EUNREACH
    } else {
        GI_EINTERNAL
    }
}

fn map_stream_error(msg: &str) -> i32 {
    let m = msg.to_ascii_lowercase();
    if m.contains("reset") {
        GI_ERESET
    } else if m.contains("timed out") || m.contains("timeout") {
        GI_ETIMEOUT
    } else if m.contains("closed") || m.contains("finished") {
        GI_ECLOSED
    } else {
        GI_EINTERNAL
    }
}

pub fn parse_node_id(s: &str) -> Option<NodeId> {
    s.trim().parse::<NodeId>().ok()
}

/// What one allowlisted peer may do. Bits, so the agent can carry them on a
/// client and the ABI can pass them as one integer.
///
/// Default is everything, because that is what an allowlist entry meant before
/// grants existed and a file written then must keep working. A peer that
/// should only be shown windows is written `run=no shell=no`, which is the
/// setting docs/MULTI_AGENT.md calls the difference between a window server
/// and a remote shell service.
pub const GI_CAP_RUN: u32 = 1 << 0; // start a program (run:, app:, desktop:)
pub const GI_CAP_SHELL: u32 = 1 << 1; // open a PTY session
pub const GI_CAP_CLIP_READ: u32 = 1 << 2; // read the host clipboard
pub const GI_CAP_CLIP_WRITE: u32 = 1 << 3; // write it
pub const GI_CAP_WINDOWS: u32 = 1 << 4; // list and stream windows
pub const GI_CAP_ALL: u32 = GI_CAP_RUN | GI_CAP_SHELL | GI_CAP_CLIP_READ | GI_CAP_CLIP_WRITE | GI_CAP_WINDOWS;

fn truthy(v: &str) -> bool {
    matches!(v, "1" | "yes" | "true" | "on")
}

/// `<node id> [key=value ...]`, `#` comments. Keys: run, shell, windows
/// (yes/no) and clipboard (none/read/write/both). An unknown key is an error
/// rather than a silent grant: a typo in a security file must not read as
/// permission.
fn parse_caps(rest: &str) -> Result<u32, String> {
    let mut caps = GI_CAP_ALL;
    for word in rest.split_whitespace() {
        let (k, v) = match word.split_once('=') {
            Some(kv) => kv,
            None => return Err(format!("want key=value, got {word}")),
        };
        let on = truthy(v);
        match k {
            "run" => caps = if on { caps | GI_CAP_RUN } else { caps & !GI_CAP_RUN },
            "shell" => caps = if on { caps | GI_CAP_SHELL } else { caps & !GI_CAP_SHELL },
            "windows" => caps = if on { caps | GI_CAP_WINDOWS } else { caps & !GI_CAP_WINDOWS },
            "clipboard" => {
                caps &= !(GI_CAP_CLIP_READ | GI_CAP_CLIP_WRITE);
                match v {
                    "none" | "no" => {}
                    "read" => caps |= GI_CAP_CLIP_READ,
                    "write" => caps |= GI_CAP_CLIP_WRITE,
                    "both" | "yes" => caps |= GI_CAP_CLIP_READ | GI_CAP_CLIP_WRITE,
                    _ => return Err(format!("clipboard: want none|read|write|both, got {v}")),
                }
            }
            "name" => {} // for whoever reads the file
            _ => return Err(format!("unknown key {k}")),
        }
    }
    Ok(caps)
}

fn read_allowlist(p: &Path) -> std::io::Result<Vec<(NodeId, u32)>> {
    let text = std::fs::read_to_string(p)?;
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let (id_text, rest) = match line.split_once(char::is_whitespace) {
            Some((a, b)) => (a, b),
            None => (line, ""),
        };
        let id = match parse_node_id(id_text) {
            Some(id) => id,
            None => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("bad node id: {id_text}"),
                ))
            }
        };
        let caps = parse_caps(rest).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{id_text}: {e}"))
        })?;
        out.push((id, caps));
    }
    Ok(out)
}

fn load_or_create_key(path: Option<&Path>) -> Result<SecretKey, String> {
    let path = match path {
        None => return Ok(SecretKey::generate(rand::rngs::OsRng)),
        Some(p) => p,
    };
    if path.exists() {
        let raw = std::fs::read(path).map_err(|e| format!("read key: {e}"))?;
        let bytes: [u8; 32] = raw
            .as_slice()
            .try_into()
            .map_err(|_| format!("key {}: want 32 raw bytes, got {}", path.display(), raw.len()))?;
        return Ok(SecretKey::from_bytes(&bytes));
    }
    let key = SecretKey::generate(rand::rngs::OsRng);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    std::fs::write(path, key.to_bytes()).map_err(|e| format!("write key: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("chmod key: {e}"))?;
    }
    Ok(key)
}
