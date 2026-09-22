//! `ghostty-iroh` — the iroh backend behind `core/sys/net.nelua`.
//!
//! This file is only the C ABI declared in `include/ghostty_iroh.h` and
//! specified in `docs/IROH.md`. The transport lives in [`node`]; keeping it a
//! plain Rust object is what lets the loopback test run two endpoints in one
//! process, since the ABI is a singleton by design (`gi_init` refcounts one
//! endpoint, one runtime, one key).
//!
//! Boundary rules, from the doc, enforced here:
//!
//! * every buffer is caller-owned and borrowed for the duration of the call;
//!   nothing allocated in Rust ever crosses, so there is no `gi_free`;
//! * no callbacks into the caller, ever — Wine unloads `ghostty_core.dll`
//!   while the process lives on, and a runtime thread holding a pointer into
//!   an unmapped module is the crash this design exists to avoid;
//! * every return is a scalar; strings are written into caller arrays.
//!
//! STATUS: not compiled. There is no cargo or rustc on this machine and none
//! in the build container (docs/IROH.md, "Cross-compilation"). Nothing here has
//! been built, run, or measured.

pub mod node;
mod wakeup;

use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::sync::Mutex;

use node::{Handle, Node, NodeConfig, GI_EADDR, GI_EHANDLE, GI_EINTERNAL};

struct Singleton {
    node: Node,
    refs: u32,
}

static NODE: Mutex<Option<Singleton>> = Mutex::new(None);
/// Set when a call fails before there is a Node to record it on.
static BOOT_ERROR: Mutex<String> = Mutex::new(String::new());

fn with_node<T>(default: T, f: impl FnOnce(&Node) -> T) -> T {
    match NODE.lock() {
        Ok(g) => match g.as_ref() {
            Some(s) => f(&s.node),
            None => default,
        },
        Err(_) => default,
    }
}

fn set_boot_error(msg: impl Into<String>) {
    if let Ok(mut s) = BOOT_ERROR.lock() {
        *s = msg.into();
    }
}

/// Borrow a NUL-terminated C string. `None` for null or non-UTF-8.
///
/// # Safety
/// `p` must be null or a valid NUL-terminated string for the call's duration.
unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// Write `s` plus a NUL into `out[..cap]`. Returns bytes written excluding the
/// NUL, or GI_EINTERNAL if it does not fit.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
unsafe fn write_str(s: &str, out: *mut c_char, cap: usize) -> i32 {
    if out.is_null() || cap == 0 {
        return GI_EINTERNAL;
    }
    let b = s.as_bytes();
    if b.len() + 1 > cap {
        return GI_EINTERNAL;
    }
    std::ptr::copy_nonoverlapping(b.as_ptr(), out.cast::<u8>(), b.len());
    *out.add(b.len()) = 0;
    b.len() as i32
}

// ---------------------------------------------------------------------------
// lifecycle
// ---------------------------------------------------------------------------

/// 0 on success, <0 on failure. Refcounted: the core and the agent in one
/// process each call it, and only the last `gi_shutdown` stops the runtime.
///
/// # Safety
/// `secret_key_path` must be null or a valid NUL-terminated path.
#[no_mangle]
pub unsafe extern "C" fn gi_init(secret_key_path: *const c_char) -> i32 {
    let path: Option<PathBuf> = cstr(secret_key_path).map(PathBuf::from);
    let mut guard = match NODE.lock() {
        Ok(g) => g,
        Err(_) => return GI_EINTERNAL,
    };
    if let Some(s) = guard.as_mut() {
        s.refs += 1;
        return 0;
    }
    let cfg = NodeConfig { secret_key_path: path.as_deref(), relays: true };
    match Node::new(cfg) {
        Ok(n) => {
            *guard = Some(Singleton { node: n, refs: 1 });
            0
        }
        Err(e) => {
            set_boot_error(e);
            GI_EINTERNAL
        }
    }
}

/// Drops one reference; on the last one, stops the runtime, closes the
/// endpoint and *joins* the threads before returning. Blocking and bounded.
#[no_mangle]
pub extern "C" fn gi_shutdown() {
    let taken = {
        let mut guard = match NODE.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        match guard.as_mut() {
            None => None,
            Some(s) if s.refs > 1 => {
                s.refs -= 1;
                None
            }
            Some(_) => guard.take(),
        }
    };
    // Join outside the lock: shutdown blocks, and a caller racing gi_init must
    // not deadlock behind it.
    if let Some(s) = taken {
        s.node.shutdown();
    }
}

// ---------------------------------------------------------------------------
// identity
// ---------------------------------------------------------------------------

/// Writes this endpoint's z-base-32 NodeId. `cap` should be >= 64.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn gi_node_id(out: *mut c_char, cap: usize) -> i32 {
    with_node(GI_EINTERNAL, |n| write_str(&n.node_id().to_string(), out, cap))
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

/// Returns immediately with a pending handle, or 0 on a bad NodeId / no init.
/// Failure is signalled by the handle, which is what `net.connect` already
/// expects (`net.is_valid(conn.sock) == false`).
///
/// # Safety
/// `node_id` must be null or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn gi_connect(node_id: *const c_char) -> u32 {
    let s = match cstr(node_id) {
        Some(s) => s,
        None => {
            set_boot_error("gi_connect: null or non-utf8 node id");
            return 0;
        }
    };
    let id = match node::parse_node_id(s) {
        Some(id) => id,
        None => {
            set_boot_error(format!("gi_connect: unparseable node id: {s}"));
            return 0;
        }
    };
    with_node(0, |n| n.connect(iroh::NodeAddr::from(id)))
}

/// 1 connected, 0 pending, <0 GI_E*.
#[no_mangle]
pub extern "C" fn gi_connect_poll(h: Handle) -> i32 {
    with_node(GI_EHANDLE, |n| n.connect_poll(h))
}

// ---------------------------------------------------------------------------
// server
// ---------------------------------------------------------------------------

/// Starts accepting inbound connections on the endpoint. `allowlist_path` may
/// be null, which accepts any peer and leaves authorisation entirely to the
/// PROTO_HELLO token.
///
/// # Safety
/// `allowlist_path` must be null or a valid NUL-terminated path.
#[no_mangle]
pub unsafe extern "C" fn gi_listen(allowlist_path: *const c_char) -> u32 {
    let path: Option<PathBuf> = cstr(allowlist_path).map(PathBuf::from);
    with_node(0, |n| n.listen(path.as_deref()))
}

/// 0 when nothing is pending — same loop-termination shape as `net.accept`.
#[no_mangle]
pub extern "C" fn gi_accept(listener: Handle) -> u32 {
    with_node(0, |n| n.accept(listener))
}

/// Writes the peer's z-base-32 NodeId for an accepted or connected handle.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn gi_peer_id(h: Handle, out: *mut c_char, cap: usize) -> i32 {
    with_node(GI_EHANDLE, |n| match n.peer_id(h) {
        Some(id) => write_str(&id, out, cap),
        None => GI_EHANDLE,
    })
}

// ---------------------------------------------------------------------------
// data
// ---------------------------------------------------------------------------

/// >0 bytes copied out, 0 "again next frame", <0 GI_E*.
///
/// # Safety
/// `buf` must be writable for `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn gi_recv(h: Handle, buf: *mut c_void, cap: usize) -> i32 {
    if buf.is_null() {
        return GI_EINTERNAL;
    }
    let cap = cap.min(i32::MAX as usize);
    let slice = std::slice::from_raw_parts_mut(buf.cast::<u8>(), cap);
    with_node(GI_EHANDLE, |n| n.recv(h, slice))
}

/// >=0 bytes accepted, <0 GI_E*. A blocked stream window is 0, never an error.
///
/// # Safety
/// `buf` must be readable for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn gi_send(h: Handle, buf: *const c_void, len: usize) -> i32 {
    if buf.is_null() {
        return GI_EINTERNAL;
    }
    let len = len.min(i32::MAX as usize);
    let slice = std::slice::from_raw_parts(buf.cast::<u8>(), len);
    with_node(GI_EHANDLE, |n| n.send(h, slice))
}

/// No-op on 0 or on a stale handle. Synchronous; the graceful QUIC close
/// drains on the runtime after the slot is already gone.
#[no_mangle]
pub extern "C" fn gi_close(h: Handle) {
    with_node((), |n| n.close(h));
}

// ---------------------------------------------------------------------------
// readiness
// ---------------------------------------------------------------------------

/// POSIX read end of the endpoint-wide readiness pipe, or -1 if there is none.
/// Level-triggered and deliberately coarse: "something, somewhere".
#[no_mangle]
pub extern "C" fn gi_wakeup_fd() -> i32 {
    with_node(-1, |n| n.wakeup_fd())
}

/// Windows manual-reset event HANDLE, or NULL if there is none.
#[no_mangle]
pub extern "C" fn gi_wakeup_handle() -> *mut c_void {
    with_node(std::ptr::null_mut(), |n| n.wakeup_handle())
}

/// Clears the readiness signal. Called once per caller pass.
#[no_mangle]
pub extern "C" fn gi_wakeup_drain() {
    with_node((), |n| n.wakeup_drain());
}

/// How long the caller may sleep, never more than `cap_ms`. Plugs into
/// `windows_cap` the way `windows:wait_ms` does, so an fd-less platform still
/// gets its sleep shortened.
#[no_mangle]
pub extern "C" fn gi_wait_ms(cap_ms: i32) -> i32 {
    with_node(cap_ms, |n| n.wait_ms(cap_ms))
}

// ---------------------------------------------------------------------------
// diagnostics
// ---------------------------------------------------------------------------

/// Human text for the log line only. Never parsed; the caller has already
/// collapsed every negative code to -1 by the time it calls this.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn gi_last_error(out: *mut c_char, cap: usize) -> i32 {
    let msg = with_node(String::new(), |n| n.last_error());
    let msg = if msg.is_empty() {
        BOOT_ERROR.lock().map(|s| s.clone()).unwrap_or_default()
    } else {
        msg
    };
    // Truncate rather than fail: a log line is never worth an error path.
    let mut msg = msg;
    if cap > 0 && msg.len() + 1 > cap {
        msg.truncate(cap - 1);
        while !msg.is_char_boundary(msg.len()) {
            msg.pop();
        }
    }
    write_str(&msg, out, cap)
}

/// Exposed so `net.nelua` can assert the header it compiled against matches
/// the library it linked. Bump on any ABI change.
#[no_mangle]
pub extern "C" fn gi_abi_version() -> i32 {
    1
}

const _: () = {
    // GI_EADDR has no call site yet: gi_connect reports a bad NodeId by
    // returning handle 0, per the doc. Keep the constant wired so the header
    // and the crate cannot drift apart silently.
    assert!(GI_EADDR == -6);
};
