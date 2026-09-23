//! The allowlist, exercised rather than asserted: a real connection between
//! two endpoints, with a real file on disk deciding what the peer gets.
//!
//! The agent's refusals are bit tests (`caps & CAP_SHELL == 0`), so the part
//! worth proving is everything underneath them -- that a key is matched to its
//! line, that the grants on that line survive the connection, and that a key
//! which is not in the file cannot connect at all. If any of that is wrong,
//! the refusals are decorative no matter how they are written.

use std::io::Write;
use std::time::{Duration, Instant};

use ghostty_iroh::node::{Handle, Node, NodeConfig, GI_CAP_ALL, GI_CAP_CLIP_READ, GI_CAP_CLIP_WRITE,
                         GI_CAP_RUN, GI_CAP_SHELL, GI_CAP_WINDOWS};

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

/// An allowlist file in a temp dir, removed when the test ends.
struct Listing(std::path::PathBuf);

impl Listing {
    fn new(name: &str, body: &str) -> Self {
        let mut p = std::env::temp_dir();
        p.push(format!("ghostty-allowlist-{name}"));
        let mut f = std::fs::File::create(&p).expect("create allowlist");
        f.write_all(body.as_bytes()).expect("write allowlist");
        Listing(p)
    }
}

impl Drop for Listing {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Connect, wait for the connection, and write the greeting.
///
/// The server's `accept` does not complete until the client sends: iroh's
/// `accept_bi` only yields a stream that carries data. A test that connects
/// and then waits is waiting for something that never happens -- which is
/// also why the refusal test below must send too, or it passes for the wrong
/// reason.
fn say_hello(client: &Node, addr: iroh::NodeAddr) -> Handle {
    let c = client.connect(addr);
    assert_ne!(c, 0, "connect failed: {}", client.last_error());
    spin("the connection", Duration::from_secs(20), || match client.connect_poll(c) {
        0 => None,
        1 => Some(()),
        e => panic!("connect_poll: {e} ({})", client.last_error()),
    });
    let hello = b"ghostty-agent 1 nonce linux";
    let mut sent = 0usize;
    spin("the greeting", Duration::from_secs(5), || {
        let n = client.send(c, &hello[sent..]);
        assert!(n >= 0, "send: {n} ({})", client.last_error());
        sent += n as usize;
        (sent == hello.len()).then_some(())
    });
    c
}

/// The same, for a client that is expected to be turned away: every step may
/// fail, and none of them failing is not yet proof of anything.
fn try_hello(client: &Node, addr: iroh::NodeAddr) {
    let c = client.connect(addr);
    if c == 0 {
        return;
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match client.connect_poll(c) {
            0 => {}
            1 => {
                let _ = client.send(c, b"ghostty-agent 1 nonce linux");
                return;
            }
            _ => return, // refused at the QUIC layer, which is the point
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn node() -> Node {
    // No relay and no discovery: this is loopback, and a test that reaches the
    // network is a test that fails on a train.
    Node::new(NodeConfig { secret_key_path: None, relays: false }).expect("start node")
}

/// A line's grants reach the accepted connection, and the ones left off are
/// actually off.
#[test]
fn grants_survive_the_connection() {
    let server = node();
    let client = node();
    let client_id = client.node_id().to_string();

    // Exactly the shape docs/MULTI_AGENT.md describes for a friend: shown
    // windows, allowed to read the clipboard, and nothing else.
    let list = Listing::new(
        "grants",
        &format!("# a friend\n{client_id} name=friend run=no shell=no clipboard=read\n"),
    );
    let listener = server.listen(Some(&list.0));
    assert_ne!(listener, 0, "listen failed: {}", server.last_error());

    say_hello(&client, server.node_addr());

    let sh = spin("the server to accept", Duration::from_secs(20), || {
        let h = server.accept(listener);
        if h != 0 { Some(h) } else { None }
    });

    let caps = server.peer_caps(sh).expect("caps for an accepted handle");
    assert_eq!(caps & GI_CAP_WINDOWS, GI_CAP_WINDOWS, "windows was granted");
    assert_eq!(caps & GI_CAP_CLIP_READ, GI_CAP_CLIP_READ, "clipboard=read grants reading");
    assert_eq!(caps & GI_CAP_RUN, 0, "run=no must not grant starting programs");
    assert_eq!(caps & GI_CAP_SHELL, 0, "shell=no must not grant a shell");
    assert_eq!(caps & GI_CAP_CLIP_WRITE, 0, "clipboard=read must not grant writing");
}

/// A bare id still means everything: files written before grants existed keep
/// working, which is why the default cannot be restrictive.
#[test]
fn a_bare_id_grants_everything() {
    let server = node();
    let client = node();
    let client_id = client.node_id().to_string();
    let list = Listing::new("bare", &format!("{client_id}\n"));
    let listener = server.listen(Some(&list.0));
    assert_ne!(listener, 0, "listen failed: {}", server.last_error());

    say_hello(&client, server.node_addr());
    let sh = spin("the server to accept", Duration::from_secs(20), || {
        let h = server.accept(listener);
        if h != 0 { Some(h) } else { None }
    });
    assert_eq!(server.peer_caps(sh), Some(GI_CAP_ALL), "a bare id grants everything");
}

/// A key that is not in the file does not get in. Without this the grants
/// above are the only thing standing between a stranger and the agent, and
/// they are not meant to be.
#[test]
fn a_key_not_listed_cannot_connect() {
    let server = node();
    let stranger = node();
    let other = node();
    // The file names someone else entirely.
    let list = Listing::new(
        "stranger",
        &format!("{}\n", other.node_id().to_string()),
    );
    let listener = server.listen(Some(&list.0));
    assert_ne!(listener, 0, "listen failed: {}", server.last_error());

    try_hello(&stranger, server.node_addr());

    // Nothing may ever arrive. Waiting a fixed moment is the honest test here:
    // an accept that has not happened yet is indistinguishable from one that
    // never will, so this gives it far longer than the successful cases above
    // took and then insists on silence.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        assert_eq!(server.accept(listener), 0, "an unlisted key was accepted");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// An unknown key fails the load instead of being ignored: a typo in a
/// security file must not read as permission.
#[test]
fn a_typo_fails_the_load() {
    let server = node();
    let client = node();
    let client_id = client.node_id().to_string();
    let list = Listing::new("typo", &format!("{client_id} shel=no\n"));
    assert_eq!(
        server.listen(Some(&list.0)),
        0,
        "a line with an unknown key must not produce a listener"
    );
    assert!(
        server.last_error().contains("shel"),
        "the error should name the key it did not understand, got: {}",
        server.last_error()
    );
}
