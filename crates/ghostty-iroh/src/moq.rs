//! Media over QUIC on top of the iroh connection this crate already opens.
//!
//! moq-net is generic over `web_transport_trait::Session`, not tied to its own
//! endpoint, so a moq session can ride the link the plugin and the agent
//! already have: one QUIC connection, authenticated by public key, carrying
//! both the existing protocol and any media tracks. That is the whole reason
//! this file is an adapter and not a second transport.
//!
//! What a track buys, per docs/MOQ.md: the frame path today is RAW or QOI
//! tiles, which is lossless and cheap for a terminal and hopeless for video --
//! pixman caps such a window near 6 fps at 1280x720. A window that behaves
//! like video, and a camera feed above all, belongs on a track with a real
//! codec. Terminal panels stay on tiles: a lossy codec on text is worse than
//! what is there now.
//!
//! UNVERIFIED: nothing here has carried a frame between two machines yet. The
//! test below establishes a session over a loopback iroh connection.

use std::time::Duration;

use bytes::Bytes;
use iroh::endpoint::{Connection, RecvStream, SendStream};

/// Errors from the iroh side of the adapter, in the shape moq wants.
#[derive(Debug)]
pub struct IrohWtError(String, Option<u32>);

impl std::fmt::Display for IrohWtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for IrohWtError {}

impl web_transport_trait::Error for IrohWtError {
    fn session_error(&self) -> Option<(u32, String)> {
        self.1.map(|c| (c, self.0.clone()))
    }
}

/// Not a blanket `From<E: Error>`: that collides with the reflexive
/// `From<T> for T`. One helper, used explicitly.
impl IrohWtError {
    fn of(e: impl std::fmt::Display) -> Self {
        IrohWtError(e.to_string(), None)
    }
}

/// An iroh connection presented as a WebTransport-shaped session.
#[derive(Clone)]
pub struct IrohSession(pub Connection);

/// A QUIC stream is not a WebTransport stream in name only: the byte semantics
/// are the same, so these are thin wrappers rather than translations.
pub struct IrohSend(SendStream);
pub struct IrohRecv(RecvStream);

impl web_transport_trait::Session for IrohSession {
    type SendStream = IrohSend;
    type RecvStream = IrohRecv;
    type Error = IrohWtError;

    fn accept_uni(&self) -> impl std::future::Future<Output = Result<Self::RecvStream, Self::Error>> {
        async move { self.0.accept_uni().await.map(IrohRecv).map_err(IrohWtError::of) }
    }

    fn accept_bi(
        &self,
    ) -> impl std::future::Future<Output = Result<(Self::SendStream, Self::RecvStream), Self::Error>> {
        async move {
            let (s, r) = self.0.accept_bi().await.map_err(IrohWtError::of)?;
            Ok((IrohSend(s), IrohRecv(r)))
        }
    }

    fn open_bi(
        &self,
    ) -> impl std::future::Future<Output = Result<(Self::SendStream, Self::RecvStream), Self::Error>> {
        async move {
            let (s, r) = self.0.open_bi().await.map_err(IrohWtError::of)?;
            Ok((IrohSend(s), IrohRecv(r)))
        }
    }

    fn open_uni(&self) -> impl std::future::Future<Output = Result<Self::SendStream, Self::Error>> {
        async move { self.0.open_uni().await.map(IrohSend).map_err(IrohWtError::of) }
    }

    fn send_datagram(&self, payload: Bytes) -> Result<(), Self::Error> {
        self.0.send_datagram(payload).map_err(IrohWtError::of)
    }

    fn recv_datagram(&self) -> impl std::future::Future<Output = Result<Bytes, Self::Error>> {
        async move { self.0.read_datagram().await.map_err(IrohWtError::of) }
    }

    fn max_datagram_size(&self) -> usize {
        // None means the peer disabled datagrams; moq wants a number, and 0
        // reads as "do not use them", which is the honest answer then.
        self.0.max_datagram_size().unwrap_or(0)
    }

    fn close(&self, code: u32, reason: &str) {
        self.0.close(code.into(), reason.as_bytes());
    }

    fn closed(&self) -> impl std::future::Future<Output = Self::Error> {
        async move { IrohWtError(self.0.closed().await.to_string(), None) }
    }
}

impl web_transport_trait::SendStream for IrohSend {
    type Error = IrohWtError;

    fn write(&mut self, buf: &[u8]) -> impl std::future::Future<Output = Result<usize, Self::Error>> {
        async move { self.0.write(buf).await.map_err(IrohWtError::of) }
    }

    /// The trait's priority is a u8; iroh takes quinn's i32. A failure here
    /// only means the stream is already gone, which the next write reports.
    fn set_priority(&mut self, order: u8) {
        let _ = self.0.set_priority(order as i32);
    }

    /// Stops accepting writes. The peer learns the stream ended when the FIN
    /// arrives, which is why this is not "closed".
    fn finish(&mut self) -> Result<(), Self::Error> {
        self.0.finish().map_err(IrohWtError::of)
    }

    fn reset(&mut self, code: u32) {
        let _ = self.0.reset(code.into());
    }

    fn closed(&mut self) -> impl std::future::Future<Output = Result<(), Self::Error>> {
        async move {
            self.0.stopped().await.map_err(IrohWtError::of)?;
            Ok(())
        }
    }
}

impl web_transport_trait::RecvStream for IrohRecv {
    type Error = IrohWtError;

    /// Fills the caller's buffer and answers how much; None is end of stream.
    fn read(
        &mut self,
        dst: &mut [u8],
    ) -> impl std::future::Future<Output = Result<Option<usize>, Self::Error>> {
        async move { self.0.read(dst).await.map_err(IrohWtError::of) }
    }

    fn stop(&mut self, code: u32) {
        let _ = self.0.stop(code.into());
    }

    fn closed(&mut self) -> impl std::future::Future<Output = Result<(), Self::Error>> {
        async move {
            // A receive stream is done when the peer's FIN has been read; iroh
            // reports that through the next read, so there is nothing to await
            // here beyond it.
            Ok(())
        }
    }
}

/// How long a moq handshake may take before we give up. Generous: the first
/// exchange on a fresh connection may still be finding a path.
pub const MOQ_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
