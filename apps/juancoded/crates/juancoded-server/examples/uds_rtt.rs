//! The cost of the hop itself: input -> inputAck round trip over the Unix socket,
//! measured from a native client so the number is the socket and the protocol, not
//! a scripting runtime's event loop.
//!
//! Run (with juancoded already listening):
//!   cargo run --release -p juancoded-server --example uds_rtt -- /tmp/juancoded-spike.sock

use std::time::Instant;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;

#[tokio::main]
async fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: uds_rtt <socket path>");
    let cwd = std::env::args().nth(2).unwrap_or_else(|| "/tmp".into());

    let stream = tokio::net::UnixStream::connect(&path)
        .await
        .expect("connect");
    let (mut ws, _) = tokio_tungstenite::client_async("ws://localhost/ws", stream)
        .await
        .expect("handshake");

    let create = serde_json::json!({
        "type": "create", "provider": "claude", "cwd": cwd, "cols": 100, "rows": 30
    });
    ws.send(Message::Text(create.to_string().into()))
        .await
        .expect("send create");

    let mut session_id = String::new();
    while session_id.is_empty() {
        if let Some(Ok(Message::Text(t))) = ws.next().await {
            let v: serde_json::Value = serde_json::from_str(&t).expect("json");
            if v["type"] == "created" {
                session_id = v["session"]["id"].as_str().unwrap_or_default().to_string();
            }
        }
    }
    // Let the CLI finish booting so its startup output is not in the way.
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;

    let mut samples = Vec::new();
    for seq in 1..=500u32 {
        // A space: the ack is issued after the pty write, so this times the socket
        // and the protocol rather than anything the child does with it.
        let frame = serde_json::json!({
            "type": "input", "sessionId": session_id, "data": " ", "seq": seq
        });
        let start = Instant::now();
        ws.send(Message::Text(frame.to_string().into()))
            .await
            .expect("send input");
        // Skip whatever else is in flight (screen frames, activity) until our ack.
        loop {
            match ws.next().await {
                Some(Ok(Message::Text(t))) => {
                    let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) else {
                        continue;
                    };
                    if v["type"] == "inputAck" && v["seq"] == seq {
                        samples.push(start.elapsed().as_secs_f64() * 1000.0);
                        break;
                    }
                }
                Some(Ok(_)) => {}
                _ => return,
            }
        }
    }
    let kill = serde_json::json!({ "type": "kill", "sessionId": session_id });
    let _ = ws.send(Message::Text(kill.to_string().into())).await;

    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| samples[((samples.len() as f64 - 1.0) * p) as usize];
    println!("UDS input->inputAck over {} samples (ms)", samples.len());
    println!(
        "  p50 {:.4}  p90 {:.4}  p99 {:.4}  max {:.4}",
        pct(0.5),
        pct(0.9),
        pct(0.99),
        samples[samples.len() - 1]
    );
}
