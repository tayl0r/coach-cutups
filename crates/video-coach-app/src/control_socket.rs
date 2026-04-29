// `mod control_socket;` in main.rs is already gated by the feature flag;
// no inner `#![cfg(...)]` needed (clippy::duplicated_attributes).
use crate::bus::BusHandle;
use crate::protocol::{IncomingFrame, OutgoingFrame};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;

/// Bind a TCP listener on 127.0.0.1 at `port` (0 = OS-chosen).
/// Returns the bound address; the caller is responsible for emitting it.
pub async fn bind(port: u16) -> std::io::Result<(TcpListener, std::net::SocketAddr)> {
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    let addr = listener.local_addr()?;
    Ok((listener, addr))
}

pub async fn serve(
    listener: TcpListener,
    bus: BusHandle,
    events: broadcast::Sender<OutgoingFrame>,
) {
    loop {
        let (sock, _peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(target: "control_socket", error = %e, "accept failed");
                continue;
            }
        };
        let bus = bus.clone();
        let events_rx = events.subscribe();
        tokio::spawn(handle_connection(sock, bus, events_rx));
    }
}

async fn handle_connection(
    sock: TcpStream,
    bus: BusHandle,
    mut events_rx: broadcast::Receiver<OutgoingFrame>,
) {
    let (read_half, write_half) = sock.into_split();
    let mut lines = BufReader::new(read_half).lines();
    let write_handle: Arc<tokio::sync::Mutex<tokio::net::tcp::OwnedWriteHalf>> =
        Arc::new(tokio::sync::Mutex::new(write_half));

    let writer_for_events = write_handle.clone();
    tokio::spawn(async move {
        loop {
            match events_rx.recv().await {
                Ok(frame) => {
                    let line = match serde_json::to_string(&frame) {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let mut w = writer_for_events.lock().await;
                    if w.write_all(line.as_bytes()).await.is_err() {
                        return;
                    }
                    if w.write_all(b"\n").await.is_err() {
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    });

    while let Ok(Some(line)) = lines.next_line().await {
        let frame: IncomingFrame = match serde_json::from_str(&line) {
            Ok(f) => f,
            Err(e) => {
                let reply = OutgoingFrame::Reply {
                    reply_to: "".into(),
                    ok: false,
                    error: Some(format!("bad frame: {e}")),
                };
                let mut w = write_handle.lock().await;
                let _ = w
                    .write_all(serde_json::to_string(&reply).unwrap().as_bytes())
                    .await;
                let _ = w.write_all(b"\n").await;
                continue;
            }
        };
        let id = frame.id.clone();
        let reply = bus.send(id.clone(), frame.command).await;
        let out = OutgoingFrame::Reply {
            reply_to: id,
            ok: reply.ok,
            error: reply.error,
        };
        let mut w = write_handle.lock().await;
        if w.write_all(serde_json::to_string(&out).unwrap().as_bytes())
            .await
            .is_err()
        {
            return;
        }
        if w.write_all(b"\n").await.is_err() {
            return;
        }
    }
}
