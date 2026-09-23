//! A moq session over a real iroh connection, both ends in one process.
//!
//! This is the proof that src/moq.rs is a correct `web_transport_trait::Session`:
//! moq-net's own handshake runs across it, over actual QUIC streams, rather
//! than against a fake session like the one in moq-net's unit tests.
//!
//! What it does NOT prove: anything about Wine, about a second machine, or
//! about carrying frames at a useful rate. Those are separate and unmeasured
//! (docs/MOQ.md).

use std::time::Duration;

use ghostty_iroh::moq::IrohSession;
use iroh::{endpoint::Endpoint, SecretKey};

const ALPN: &[u8] = b"ghostty/moq/1";

/// Bind an endpoint with no relay and no discovery: this is loopback, and a
/// test that reaches the network is a test that fails on a train.
async fn endpoint() -> Endpoint {
    let mut rng = rand::rngs::OsRng;
    Endpoint::builder()
        .secret_key(SecretKey::generate(&mut rng))
        .alpns(vec![ALPN.to_vec()])
        .relay_mode(iroh::RelayMode::Disabled)
        .bind()
        .await
        .expect("bind")
}

#[tokio::test(flavor = "multi_thread")]
async fn moq_handshake_over_iroh() {
    let server_ep = endpoint().await;
    let client_ep = endpoint().await;

    let server_id = server_ep.node_id();
    let addrs: Vec<_> = {
        use iroh::watchable::Watcher as _;
        server_ep
            .direct_addresses()
            .initialized()
            .await
            .expect("direct addresses")
            .into_iter()
            .map(|d| d.addr)
            .collect()
    };
    let server_addr = iroh::NodeAddr::from_parts(server_id, None, addrs);

    // Accept on one side while dialling on the other; a handshake needs both.
    let server = tokio::spawn(async move {
        let incoming = server_ep.accept().await.expect("incoming");
        let conn = incoming.await.expect("accepted connection");
        let session = IrohSession(conn);
        let srv = moq_net::Server::new();
        srv.accept(session).await
    });

    let conn = client_ep
        .connect(server_addr, ALPN)
        .await
        .expect("client connect");
    let client_conn_for_stats = conn.clone();
    let session = IrohSession(conn);

    // A client that neither publishes nor subscribes only warns, so an empty
    // one is enough to drive the handshake we are testing.
    let client = moq_net::Client::new();
    let client_side = tokio::time::timeout(Duration::from_secs(10), client.connect(session))
        .await
        .expect("client handshake timed out");

    let server_side = tokio::time::timeout(Duration::from_secs(10), server)
        .await
        .expect("server handshake timed out")
        .expect("server task panicked");

    let (_client_session, _client_driver) = client_side.expect("client moq session");
    let (_server_session, _server_driver) = server_side.expect("server moq session");

    // A green handshake that moved no bytes would prove nothing: assert the
    // connection actually carried the setup exchange. `finished in 0.00s` is
    // fast enough to be worth distrusting without this.
    let stats = client_conn_for_stats.stats();
    assert!(
        stats.udp_tx.bytes > 0 && stats.udp_rx.bytes > 0,
        "handshake moved no bytes: tx={} rx={}",
        stats.udp_tx.bytes,
        stats.udp_rx.bytes
    );
    assert!(
        stats.frame_tx.stream > 0,
        "handshake opened no QUIC streams: {:?}",
        stats.frame_tx
    );
}
