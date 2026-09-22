/*
 * ghostty_iroh.h — the C ABI of the iroh backend behind core/sys/net.nelua.
 *
 * Specified in docs/IROH.md. Hand-written rather than cbindgen-generated so it
 * can carry the contract; it must be kept in step with src/lib.rs by hand, and
 * gi_abi_version() exists so a mismatch fails loudly instead of corrupting a
 * handle.
 *
 * STATUS: nothing here has been compiled or run. There is no cargo on the
 * workstation and none in the build container yet.
 *
 * Rules that hold for every function below:
 *   - Every buffer is caller-owned and borrowed only for the duration of the
 *     call. gi_send copies in before returning, gi_recv copies out. No pointer
 *     given to the library is retained and none returned by it is owned by the
 *     caller. There is deliberately no gi_free.
 *   - There are no callbacks into the caller, ever. Wine unloads
 *     ghostty_core.dll while the process lives on; readiness is polled.
 *   - Every function is non-blocking except gi_init and gi_shutdown.
 *   - Handles are thread-confined: one caller thread (the game thread in the
 *     core, the main loop in the agent).
 */

#ifndef GHOSTTY_IROH_H
#define GHOSTTY_IROH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * A handle is a 1-based generation-tagged index: low 16 bits slot, high 16 bits
 * generation. 0 is ALWAYS invalid, on both platforms — unlike net.invalid(),
 * which is -1 on POSIX (where 0 is a valid fd) and INVALID_SOCKET on Windows.
 * The backend choice in net.nelua must therefore be a type choice, not a value
 * test.
 */
typedef uint32_t gi_handle;

/* Error codes. Negative only; 0 is "again", never an error. */
#define GI_EAGAIN     0  /* not an error: nothing right now, retry next frame */
#define GI_ECLOSED   -1  /* peer closed cleanly (FIN) */
#define GI_ERESET    -2  /* RESET_STREAM */
#define GI_ETIMEOUT  -3  /* idle timeout / connection lost / connect deadline */
#define GI_EREFUSED  -4  /* peer reachable, refused (not allowlisted) */
#define GI_EUNREACH  -5  /* no path, relay included */
#define GI_EADDR     -6  /* unparseable NodeId */
#define GI_EHANDLE   -7  /* stale or unknown handle */
#define GI_EINTERNAL -8

/* Bump on any change below. net.nelua should assert this at init. */
#define GI_ABI_VERSION 1
int32_t gi_abi_version(void);

/* ---- lifecycle ------------------------------------------------------- */

/*
 * Brings up the runtime and the single endpoint. secret_key_path may be NULL
 * for an ephemeral key; otherwise it is 32 raw ed25519 bytes, created with
 * mode 0600 if absent, so the NodeId survives an agent restart.
 * Refcounted: returns 0 on success (including on a second call), <0 otherwise.
 */
int32_t gi_init(const char *secret_key_path);

/*
 * Drops one reference. On the last one it stops the runtime, closes the
 * endpoint and JOINS the runtime threads before returning, bounded in time —
 * the DLL must not unmap while a runtime thread is alive.
 */
void gi_shutdown(void);

/* ---- identity -------------------------------------------------------- */

/* Writes this endpoint's z-base-32 NodeId + NUL. cap >= 64. Bytes written
 * excluding the NUL, or <0. */
int32_t gi_node_id(char *out, size_t cap);

/* ---- client ---------------------------------------------------------- */

/*
 * Starts a connect and returns immediately with a handle in the pending state.
 * Returns 0 on a bad NodeId or before gi_init — failure by handle, which is
 * exactly the shape net.connect already has (net.is_valid(conn.sock) == false).
 *
 * The library applies its own connect deadline BELOW the client's 5 s timer
 * (core/agent_client.nelua:657) and reports GI_ETIMEOUT itself, rather than
 * letting the caller's timer fire against a handle still doing work.
 */
gi_handle gi_connect(const char *node_id);

/*
 * 1 connected, 0 pending, <0 GI_E*. A slot lookup and an atomic read: no
 * syscall, cheap at ~60 calls/second, idempotent once it latches.
 */
int32_t gi_connect_poll(gi_handle h);

/* ---- server ---------------------------------------------------------- */

/*
 * Starts accepting inbound connections on the endpoint. allowlist_path is a
 * file of z-base-32 node ids, one per line, '#' starts a comment; NULL accepts
 * any peer and leaves authorisation entirely to the PROTO_HELLO token. A peer
 * that is not allowlisted is refused at the transport, before any frame.
 * Returns 0 on failure.
 */
gi_handle gi_listen(const char *allowlist_path);

/* 0 when nothing is pending — same loop termination as net.accept. */
gi_handle gi_accept(gi_handle listener);

/* Writes the peer's z-base-32 NodeId + NUL. cap >= 64. */
int32_t gi_peer_id(gi_handle h, char *out, size_t cap);

/* ---- data ------------------------------------------------------------ */

/*
 * >0 bytes copied, 0 nothing right now, <0 GI_E*.
 *
 * Buffered bytes are handed over before any end-of-stream code, so a peer that
 * writes and then closes does not lose its last frame. At the net.recv
 * boundary every negative value collapses to -1, matching
 * core/sys/net.nelua:229-235; the distinction survives only in gi_last_error.
 */
int32_t gi_recv(gi_handle h, void *buf, size_t cap);

/*
 * >=0 bytes accepted, <0 GI_E*. A full QUIC stream window returns 0, NOT an
 * error: flush at core/agent_client.nelua:631-637 treats -1 as "connection
 * lost" and tears the link down, while 0 means "retry next frame". Partial
 * writes are expected and already handled by the caller.
 */
int32_t gi_send(gi_handle h, const void *buf, size_t len);

/*
 * No-op on 0 or on a stale handle. Synchronous and void: the slot is freed
 * immediately and the graceful QUIC close drains on the runtime. The reconnect
 * path runs this forever while an agent is down, so per cycle it must leak no
 * slot, no task and no socket. UNPROVEN — run it under valgrind and a
 * multi-hour agent-down loop before believing it.
 */
void gi_close(gi_handle h);

/* ---- readiness ------------------------------------------------------- */

/*
 * A QUIC stream is not a file descriptor. These give the agent's wait loop a
 * single endpoint-wide, level-triggered "something, somewhere" signal: enough
 * for a loop that pumps everything each pass (agent/agent.nelua:843-856 never
 * reads revents), useless for one that dispatches on readiness.
 */
int32_t gi_wakeup_fd(void);      /* POSIX read end; -1 if none */
void   *gi_wakeup_handle(void);  /* Windows manual-reset event; NULL if none */
void    gi_wakeup_drain(void);   /* clear it; once per pass */

/* How long the caller may sleep, <= cap_ms. Plugs into windows_cap the way
 * windows:wait_ms does, so a platform with no fd still shortens its sleep. */
int32_t gi_wait_ms(int32_t cap_ms);

/* ---- diagnostics ----------------------------------------------------- */

/* Human text for the log line only, never parsed. Truncated to fit. */
int32_t gi_last_error(char *out, size_t cap);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GHOSTTY_IROH_H */
