//! The daemon's half of outbound notification routing: one task, one webhook.
//!
//! The policy and the body live in [`juancoded_core::notify`]; this is who watches
//! and when. It subscribes to the session bus once for the whole daemon and POSTs on
//! every notifying turn boundary.
//!
//! **One per daemon, deliberately not in `conn.rs`.** The ticket sketched it on the
//! activity path there, but `conn.rs` runs once per connected client — the desktop,
//! the sidecar and every phone tab each hold a socket — so a POST fired from it would
//! send the same notification two or three times, and the count would depend on how
//! many tabs happened to be open. A notification is a fact about a session, not about
//! a socket, so it belongs beside the other daemon-wide watchers `serve` spawns.
//!
//! **What it deliberately does NOT do: everything the sidecar already does.** Telegram,
//! the phone console and the rest stay in `apps/oracle-mcp`, which consumes the same
//! `activity` broadcast over its one long-lived WS. This task is the single outbound
//! notification the daemon owns itself, because it is the one that has to survive the
//! desktop app being closed (juancode-52e8.14.7).
//!
//! It does no work at all when no webhook is configured: the gate is a file read on a
//! notifying edge, which happens a handful of times an hour.

use std::path::PathBuf;
use std::sync::Arc;

use tokio::task::JoinHandle;
use tracing::debug;

use juancoded_core::model::SessionActivity;
use juancoded_core::notify::{self, NotificationEvent};
use juancoded_state::{SessionEvent, SessionsApi};

/// Which notification an activity edge is, or `None` when it is not one.
///
/// `notify` is the core's own de-spam gate — the same flag the sidebar bounce and the
/// Telegram ping key on — so this never re-derives "was that a real turn boundary".
/// Busy is never a notification: a turn STARTING is not news off-device.
pub fn event_for(state: SessionActivity, notify: bool) -> Option<NotificationEvent> {
    if !notify {
        return None;
    }
    match state {
        SessionActivity::WaitingInput => Some(NotificationEvent::WaitingInput),
        SessionActivity::Idle => Some(NotificationEvent::TurnEnd),
        SessionActivity::Busy => None,
    }
}

/// Watch the bus and fire the webhook on every notifying turn boundary.
///
/// The handle is kept by `serve` for the life of the process; dropping it ends the
/// watch, which is what a test wants and what shutdown gets for free.
pub fn spawn(sessions: Arc<dyn SessionsApi>, config: PathBuf) -> JoinHandle<()> {
    let mut events = sessions.subscribe();
    tokio::spawn(async move {
        loop {
            let event = match events.recv().await {
                Ok(event) => event,
                // Lagged: notifications missed while this task was behind are simply
                // gone. There is nothing to catch up to — a turn boundary announced
                // late is worse than one not announced at all.
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    debug!(missed = n, "the notify hook fell behind the session bus");
                    continue;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
            };
            let SessionEvent::Activity {
                session_id,
                state,
                notify: notifying,
                ..
            } = event
            else {
                continue;
            };
            let Some(kind) = event_for(state, notifying) else {
                continue;
            };
            // The URL is read per fire, not cached at boot: configuring a webhook must
            // not need a daemon restart, and a restart ends every live session.
            let Some(url) = notify::webhook_url_at(&config) else {
                continue;
            };
            let Some(meta) = sessions.meta(&session_id) else {
                continue;
            };
            let body = notify::webhook_body(kind, &meta.title, &session_id, meta.effective_cwd());
            // Detached: a slow endpoint must not delay the next event's notification,
            // and there is nothing here to report a failure to.
            tokio::spawn(async move {
                if !notify::post_webhook(&url, &body).await {
                    debug!(session = %session_id, "the notification webhook did not deliver");
                }
            });
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use juancoded_state::registry::SessionEvent as Event;

    use crate::testing::FakeChild;

    /// The three edges that matter, and the one that does not. A turn STARTING is not
    /// news: the Swift core gated on the same `notify` flag for the same reason.
    #[test]
    fn only_a_notifying_boundary_is_a_notification() {
        assert_eq!(
            event_for(SessionActivity::WaitingInput, true),
            Some(NotificationEvent::WaitingInput)
        );
        assert_eq!(
            event_for(SessionActivity::Idle, true),
            Some(NotificationEvent::TurnEnd)
        );
        assert_eq!(event_for(SessionActivity::Busy, true), None);
        assert_eq!(event_for(SessionActivity::Idle, false), None);
        assert_eq!(event_for(SessionActivity::WaitingInput, false), None);
    }

    /// A stand-in webhook endpoint: one request, then a 200. Returns what it read.
    async fn stand_in() -> (u16, tokio::task::JoinHandle<String>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("a loopback port");
        let port = listener.local_addr().expect("the bound port").port();
        let task = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.expect("curl connects");
            let mut buf = vec![0u8; 8192];
            let n = sock.read(&mut buf).await.expect("curl writes a request");
            let _ = sock
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                .await;
            let _ = sock.shutdown().await;
            String::from_utf8_lossy(&buf[..n]).to_string()
        });
        (port, task)
    }

    fn config_naming(dir: &std::path::Path, port: u16) -> PathBuf {
        std::fs::create_dir_all(dir).expect("the temp config dir");
        let path = dir.join("notify.json");
        std::fs::write(
            &path,
            format!(r#"{{"webhookUrl":"http://127.0.0.1:{port}/hook"}}"#),
        )
        .expect("write the config");
        path
    }

    /// The whole point of the move, end to end and with no desktop app anywhere in it:
    /// a notifying turn boundary on the bus becomes a real POST at the configured URL.
    #[tokio::test]
    async fn a_notifying_boundary_posts_to_the_configured_webhook() {
        let (port, endpoint) = stand_in().await;
        let dir = std::env::temp_dir().join(format!("notify-hook-{}-{port}", std::process::id()));
        let config = config_naming(&dir, port);

        let child = FakeChild::new(false);
        let _hook = spawn(child.api(), config);
        child.publish(Event::Activity {
            session_id: "s-1".into(),
            state: SessionActivity::WaitingInput,
            notify: true,
            changes: None,
            dispatch_id: None,
        });

        let request = tokio::time::timeout(std::time::Duration::from_secs(20), endpoint)
            .await
            .expect("the endpoint was reached")
            .expect("the endpoint task");
        assert!(request.starts_with("POST /hook "), "{request}");
        assert!(request.contains(r#""event":"waiting_input""#), "{request}");
        assert!(request.contains(r#""sessionId":"s-1""#), "{request}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A turn STARTING is not news, and the endpoint must never hear about it. Asserted
    /// by the absence of a connection within a window the POST above clears easily.
    #[tokio::test]
    async fn a_busy_edge_posts_nothing() {
        let (port, endpoint) = stand_in().await;
        let dir = std::env::temp_dir().join(format!("notify-quiet-{}-{port}", std::process::id()));
        let config = config_naming(&dir, port);

        let child = FakeChild::new(false);
        let _hook = spawn(child.api(), config);
        child.publish(Event::Activity {
            session_id: "s-1".into(),
            state: SessionActivity::Busy,
            notify: true,
            changes: None,
            dispatch_id: None,
        });
        child.publish(Event::Activity {
            session_id: "s-1".into(),
            state: SessionActivity::Idle,
            notify: false,
            changes: None,
            dispatch_id: None,
        });

        let quiet = tokio::time::timeout(std::time::Duration::from_secs(2), endpoint).await;
        assert!(quiet.is_err(), "something POSTed for a non-boundary edge");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
