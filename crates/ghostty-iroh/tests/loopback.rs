//! Two endpoints in one process, over loopback, bytes both ways.
//!
//! This is the crate's proof-without-the-game: no relay, no discovery, no
//! tailnet, no Wine. It exercises the same `Node` methods the C ABI is a thin
//! wrapper over — connect/connect_poll/listen/accept/send/recv/close — in the
//! poll shape the caller actually uses (`gi_connect_poll` per frame, `gi_recv`
//! returning 0 for "again").
//!
//! It proves the crate's own plumbing. It proves NOTHING about iroh under
//! Wine, about hole punching, or about relay fallback — those are separate and
//! unmeasured (docs/IROH.md).
//!
//! NOT RUN: there is no cargo on this machine.

use std::time::{Duration, Instant};

use ghostty_iroh::node::{Node, NodeConfig, GI_EAGAIN};

/// Spin the way the caller does, instead of sleeping on a condition the caller
/// has no way to wait for.
fn spin<T>(what: &str, timeout: Duration, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn recv_exact(node: &Node, h: u32, want: usize, timeout: Duration) -> Vec<u8> {
    let mut got = Vec::with_capacity(want);
    spin("bytes", timeout, || {
        let mut buf = [0u8; 4096];
        let n = node.recv(h, &mut buf);
        assert!(n >= GI_EAGAIN, "recv failed: {n} ({})", node.last_error());
        if n > 0 {
            got.extend_from_slice(&buf[..n as usize]);
        }
        (got.len() >= want).then_some(())
    });
    got
}

#[test]
fn loopback_roundtrip_both_ways() {
    // relays: false — this must not touch the network. Without discovery the
    // client is handed the server's direct socket addresses explicitly.
    let server = Node::new(NodeConfig { secret_key_path: None, relays: false })
        .expect("server endpoint");
    let client = Node::new(NodeConfig { secret_key_path: None, relays: false })
        .expect("client endpoint");

    let listener = server.listen(None);
    assert_ne!(listener, 0, "listen: {}", server.last_error());

    let addr = server.node_addr();
    assert!(addr.direct_addresses().count() > 0, "server has no direct address");

    let c = client.connect(addr);
    assert_ne!(c, 0, "connect: {}", client.last_error());

    spin("connect", Duration::from_secs(10), || match client.connect_poll(c) {
        0 => None,
        1 => Some(()),
        e => panic!("connect_poll: {e} ({})", client.last_error()),
    });

    // The client writes first, as PROTO_HELLO does: the server's accept_bi
    // only completes once the stream carries data.
    let hello = b"ghostty-agent 1 nonce";
    let mut sent = 0usize;
    spin("client send", Duration::from_secs(5), || {
        let n = client.send(c, &hello[sent..]);
        assert!(n >= 0, "send: {n} ({})", client.last_error());
        sent += n as usize;
        (sent == hello.len()).then_some(())
    });

    let s = spin("accept", Duration::from_secs(10), || match server.accept(listener) {
        0 => None,
        h => Some(h),
    });

    assert_eq!(recv_exact(&server, s, hello.len(), Duration::from_secs(10)), hello);
    assert_eq!(
        server.peer_id(s).expect("peer id"),
        client.node_id().to_string(),
        "accepted connection reports the wrong peer"
    );

    // And back the other way.
    let ok = b"OK ghostty-agent 1 nonce";
    let mut sent = 0usize;
    spin("server send", Duration::from_secs(5), || {
        let n = server.send(s, &ok[sent..]);
        assert!(n >= 0, "send: {n} ({})", server.last_error());
        sent += n as usize;
        (sent == ok.len()).then_some(())
    });
    assert_eq!(recv_exact(&client, c, ok.len(), Duration::from_secs(10)), ok);

    // A second exchange on the same stream: the byte stream is contiguous and
    // reusable, which is what core/protocol.nelua's framing assumes.
    assert_eq!(client.send(c, b"ping"), 4);
    assert_eq!(recv_exact(&server, s, 4, Duration::from_secs(5)), b"ping");
    assert_eq!(server.send(s, b"pong"), 4);
    assert_eq!(recv_exact(&client, c, 4, Duration::from_secs(5)), b"pong");

    // Nothing pending means 0, not an error — the contract the caller's frame
    // loop depends on.
    let mut idle = [0u8; 64];
    assert_eq!(client.recv(c, &mut idle), GI_EAGAIN);

    client.close(c);
    // The close is graceful, so the peer sees end-of-stream, which the caller
    // collapses to -1 at the net.recv boundary.
    spin("server sees close", Duration::from_secs(10), || {
        let mut buf = [0u8; 64];
        match server.recv(s, &mut buf) {
            GI_EAGAIN => None,
            n if n < 0 => Some(()),
            n => panic!("unexpected {n} bytes after close"),
        }
    });

    server.close(s);
    server.close(listener);
    // Stale handles are rejected, not aliased.
    assert!(server.connect_poll(s) < 0);
    // close on 0 and on a stale handle is a no-op, by contract.
    server.close(0);
    server.close(s);

    server.shutdown();
    client.shutdown();
}

#[test]
fn bad_handles_and_empty_buffers() {
    let node = Node::new(NodeConfig { secret_key_path: None, relays: false }).expect("endpoint");
    let mut buf = [0u8; 16];
    assert!(node.recv(0, &mut buf) < 0);
    assert!(node.send(0, b"x") < 0);
    assert!(node.connect_poll(0xdead_beef) < 0);
    assert_eq!(node.accept(0), 0);
    assert!(node.peer_id(0).is_none());
    node.close(0);
    // wait_ms never exceeds the cap it was given.
    assert!(node.wait_ms(250) <= 250);
    node.shutdown();
}
