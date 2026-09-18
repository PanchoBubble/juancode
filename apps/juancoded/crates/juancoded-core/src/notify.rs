//! Outbound notification routing: the one notification the DAEMON sends itself.
//!
//! A port of `JuancodeServices/NotificationWebhook.swift`, and a deliberate move of
//! where it runs. In Swift the body builder was pure and the POST lived in `AppModel`,
//! so the webhook only ever fired while the desktop app was open — which is exactly
//! backwards for a notification whose whole job is to reach you when you are not at
//! the Mac. Here the daemon owns both halves, so background work reaches you whether
//! or not the UI is running.
//!
//! **Everything else about notifications stays in the Node sidecar** (juancode-52e8.14.7).
//! Telegram, the phone console, voice, triggers and cron are 14k lines of TypeScript
//! that gain nothing from being Rust; the sidecar keeps its one long-lived WS client
//! and fans `activity` out in-process. What the daemon owes it is a complete event
//! stream, not a second bridge. This module is the single exception: one outbound POST
//! that must survive the app being closed.
//!
//! The body is Slack-incoming-webhook-compatible (a top-level `text`) *and* carries
//! structured fields (`event` / `title` / `sessionId` / `cwd`), so one URL covers
//! Slack, Discord-compatible relays and custom endpoints alike. Key set and wording
//! are byte-identical to the Swift version's: a webhook a person already configured
//! must not start saying something new because the core underneath it changed.
//!
//! Delivery is `curl`, for the same reason `gh.rs` shells out rather than linking a
//! client: the daemon has no HTTP client crate and one POST an hour does not justify
//! pulling a TLS stack into the build. The URL and the body both travel in a curl
//! config on stdin rather than in argv — a Slack webhook URL is a bearer credential,
//! and argv is readable.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use serde::Deserialize;

/// Per-POST budget. A webhook endpoint that hangs must not hold the notify task; the
/// event is dropped and the next turn boundary tries again.
const POST_TIMEOUT: Duration = Duration::from_secs(10);

/// What happened to a session that is worth telling somebody off-device about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationEvent {
    /// The agent stopped to ask a question / permission — blocked on the user.
    WaitingInput,
    /// A turn simply finished.
    TurnEnd,
    /// A session's folder holds uncommitted/unpushed work and the session went idle
    /// or exited — the work is about to be forgotten (juancode-rxu).
    ///
    /// Defined here and not yet fired by this daemon: the detector behind it
    /// (`WorkAtRisk.swift`) is being ported by juancode-52e8.14.5, and this core has
    /// no `at_risk` module to fire from. The wording lands now so the two cores never
    /// disagree about what a `work_at_risk` webhook says.
    WorkAtRisk,
}

impl NotificationEvent {
    /// The `event` field, and the string the Swift core used. Stable: consumers key
    /// on it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WaitingInput => "waiting_input",
            Self::TurnEnd => "turn_end",
            Self::WorkAtRisk => "work_at_risk",
        }
    }
}

/// The human-readable one-liner (the Slack `text`).
pub fn notification_text(event: NotificationEvent, title: &str) -> String {
    let name = if title.is_empty() { "A session" } else { title };
    match event {
        NotificationEvent::WaitingInput => format!("⏳ {name} needs your input"),
        NotificationEvent::TurnEnd => format!("✅ {name} finished a turn"),
        NotificationEvent::WorkAtRisk => format!("⚠️ {name} has uncommitted or unpushed work"),
    }
}

/// The JSON POST body. Slack reads `text`; generic consumers read the structured
/// fields. A `BTreeMap` so the keys come out sorted whatever `serde_json`'s map
/// ordering feature is set to — the Swift version sorted them, and a body that
/// diffs cleanly is what makes this testable at all.
pub fn webhook_body(event: NotificationEvent, title: &str, session_id: &str, cwd: &str) -> String {
    let text = notification_text(event, title);
    let mut obj: BTreeMap<&str, &str> = BTreeMap::new();
    obj.insert("text", &text);
    obj.insert("event", event.as_str());
    obj.insert("title", title);
    obj.insert("sessionId", session_id);
    obj.insert("cwd", cwd);
    // Never fails for a map of strings; the fallback keeps the Slack half working if
    // it somehow did.
    serde_json::to_string(&obj).unwrap_or_else(|_| {
        serde_json::json!({ "text": notification_text(event, title) }).to_string()
    })
}

/// The daemon's own notification config file: `{"webhookUrl": "https://..."}`.
///
/// A file rather than the app's `UserDefaults`, deliberately. A daemon that had to
/// ask the Swift app for a setting would still be coupled to it, and would go silent
/// the moment the app it was asking is the thing that is closed.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyConfig {
    #[serde(default)]
    pub webhook_url: Option<String>,
}

/// An empty variable counts as unset, so an exported-but-blank knob cannot point the
/// config at the process's working directory.
fn env_value(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

/// Where the config file lives: `JUANCODE_NOTIFY_CONFIG` outright, else
/// `notify.json` beside the daemon's own store (`~/.juancode/rust-core` by default,
/// `JUANCODED_DATA_DIR` before `JUANCODE_DATA_DIR` for the same reason `db_path`
/// orders them that way — the daemon's own knob wins, but a harness that only knows
/// the Swift core's variable still isolates us).
pub fn config_path() -> PathBuf {
    if let Some(path) = env_value("JUANCODE_NOTIFY_CONFIG") {
        return PathBuf::from(path);
    }
    let dir = env_value("JUANCODED_DATA_DIR")
        .or_else(|| env_value("JUANCODE_DATA_DIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            PathBuf::from(home).join(".juancode").join("rust-core")
        });
    dir.join("notify.json")
}

/// The configured webhook URL, or `None` for "notify nobody".
///
/// Read on every fire rather than cached at boot: setting a webhook must not require
/// restarting the daemon, because restarting the daemon ends every live session. A
/// missing, unreadable or malformed file is "no webhook", never an error — the whole
/// path is best-effort by construction.
pub fn webhook_url_at(path: &std::path::Path) -> Option<String> {
    if let Some(url) = env_value("JUANCODE_NOTIFY_WEBHOOK_URL") {
        return valid_webhook_url(&url);
    }
    let raw = std::fs::read_to_string(path).ok()?;
    let config: NotifyConfig = serde_json::from_str(&raw).ok()?;
    valid_webhook_url(config.webhook_url.as_deref()?)
}

/// The same trim-and-check the Swift side did: a non-http scheme is not a webhook,
/// and handing one to `curl` would be handing it a file read or an SMTP session.
pub fn valid_webhook_url(raw: &str) -> Option<String> {
    let url = raw.trim();
    if url.starts_with("http://") || url.starts_with("https://") {
        Some(url.to_string())
    } else {
        None
    }
}

/// The curl config that carries one POST, written to curl's stdin.
///
/// Both the URL and the body go in here rather than in argv: the URL is a bearer
/// credential (a Slack webhook URL is the whole authentication), and `ps` shows argv.
/// Curl's config parser unescapes `\\` and `\"` inside a quoted value, so escaping
/// those two is the whole contract — and JSON's own escapes survive it, because a
/// `\n` in the JSON text is a backslash and an `n`, which round-trips as `\\n`.
pub fn curl_config(url: &str, body: &str) -> String {
    format!(
        "url = \"{}\"\nrequest = \"POST\"\nheader = \"Content-Type: application/json\"\n\
         data-binary = \"{}\"\n",
        escape_curl(url),
        escape_curl(body),
    )
}

fn escape_curl(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(ch),
        }
    }
    out
}

/// POST one notification, best-effort.
///
/// Returns whether curl reported success, which is what a test asserts on; nothing in
/// the daemon branches on it. Every failure — no curl, no network, a 500 from the
/// endpoint, a hang — is the same outcome: this notification is gone and the next turn
/// boundary is a fresh attempt. A notification is not worth a retry queue.
pub async fn post_webhook(url: &str, body: &str) -> bool {
    use tokio::io::AsyncWriteExt;

    let Some(url) = valid_webhook_url(url) else {
        return false;
    };
    let config = curl_config(&url, body);
    let mut child = match tokio::process::Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--max-time",
            "10",
            "--config",
            "-",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(e) => {
            tracing::debug!(error = %e, "could not run curl for the notification webhook");
            return false;
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(config.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }
    match tokio::time::timeout(POST_TIMEOUT, child.wait()).await {
        Ok(Ok(status)) => status.success(),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(body: &str) -> BTreeMap<String, String> {
        serde_json::from_str(body).expect("the body is a flat JSON object of strings")
    }

    /// The wording is the contract: a webhook somebody already points at Slack must
    /// not start saying something new because the core changed underneath it.
    #[test]
    fn text_per_event_matches_the_swift_wording() {
        assert_eq!(
            notification_text(NotificationEvent::WaitingInput, "Fix CI"),
            "⏳ Fix CI needs your input"
        );
        assert_eq!(
            notification_text(NotificationEvent::TurnEnd, "Fix CI"),
            "✅ Fix CI finished a turn"
        );
        assert_eq!(
            notification_text(NotificationEvent::WorkAtRisk, "Fix CI"),
            "⚠️ Fix CI has uncommitted or unpushed work"
        );
    }

    #[test]
    fn an_empty_title_falls_back() {
        assert_eq!(
            notification_text(NotificationEvent::TurnEnd, ""),
            "✅ A session finished a turn"
        );
    }

    #[test]
    fn the_body_carries_slack_text_and_structured_fields() {
        let obj = decode(&webhook_body(
            NotificationEvent::WaitingInput,
            "Fix CI",
            "s-1",
            "/Users/me/api",
        ));
        assert_eq!(obj["text"], "⏳ Fix CI needs your input"); // Slack reads this
        assert_eq!(obj["event"], "waiting_input"); // structured, for everyone else
        assert_eq!(obj["title"], "Fix CI");
        assert_eq!(obj["sessionId"], "s-1");
        assert_eq!(obj["cwd"], "/Users/me/api");
    }

    /// Sorted, like the Swift version's `.sortedKeys`: a body that diffs cleanly is
    /// what makes the payload reviewable at all.
    #[test]
    fn the_body_keys_are_sorted() {
        let body = webhook_body(NotificationEvent::TurnEnd, "t", "s", "/c");
        assert_eq!(
            body,
            r#"{"cwd":"/c","event":"turn_end","sessionId":"s","text":"✅ t finished a turn","title":"t"}"#
        );
    }

    #[test]
    fn only_an_http_url_is_a_webhook() {
        assert_eq!(
            valid_webhook_url("  https://hooks.example/x  ").as_deref(),
            Some("https://hooks.example/x")
        );
        assert!(valid_webhook_url("http://127.0.0.1:9/x").is_some());
        assert!(valid_webhook_url("file:///etc/passwd").is_none());
        assert!(valid_webhook_url("").is_none());
        assert!(valid_webhook_url("hooks.example/x").is_none());
    }

    /// The escaping is the only thing between a title with a quote in it and a curl
    /// config that means something else.
    #[test]
    fn the_curl_config_escapes_quotes_and_backslashes() {
        let body = webhook_body(NotificationEvent::TurnEnd, "say \"hi\"", "s", "C:\\work");
        let config = curl_config("https://hooks.example/x", &body);
        assert!(
            config.contains("url = \"https://hooks.example/x\""),
            "{config}"
        );
        // Every quote inside the body value is escaped, so the value ends where the
        // format string ends it and nowhere earlier.
        let value = config
            .lines()
            .find(|l| l.starts_with("data-binary = "))
            .expect("the body line is there");
        let inner = value
            .trim_start_matches("data-binary = \"")
            .trim_end_matches('"');
        assert!(inner.contains("\\\\\\\"hi\\\\\\\""), "{inner}");
    }

    #[test]
    fn a_missing_config_file_is_no_webhook_rather_than_an_error() {
        let dir = std::env::temp_dir().join(format!("juancoded-notify-{}", std::process::id()));
        assert!(webhook_url_at(&dir.join("nope.json")).is_none());
    }

    #[test]
    fn the_config_file_carries_the_url() {
        let dir = std::env::temp_dir().join(format!("juancoded-notify-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("notify.json");
        std::fs::write(&path, r#"{"webhookUrl":"https://hooks.example/x"}"#).expect("write");
        assert_eq!(
            webhook_url_at(&path).as_deref(),
            Some("https://hooks.example/x")
        );
        std::fs::write(&path, "not json at all").expect("write");
        assert!(webhook_url_at(&path).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The end-to-end leg, against a socket in this process: proves the POST really
    /// goes out, that the body survives the curl config unmangled, and that none of
    /// it needs the desktop app — which is the whole point of moving it here.
    #[tokio::test]
    async fn the_webhook_really_posts_the_body() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("a loopback port");
        let port = listener.local_addr().expect("the bound port").port();
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.expect("curl connects");
            let mut buf = vec![0u8; 8192];
            let n = sock.read(&mut buf).await.expect("curl writes a request");
            let _ = sock
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                .await;
            let _ = sock.shutdown().await;
            String::from_utf8_lossy(&buf[..n]).to_string()
        });

        let body = webhook_body(
            NotificationEvent::WaitingInput,
            "say \"hi\"",
            "s-1",
            "/Users/me/api",
        );
        let ok = post_webhook(&format!("http://127.0.0.1:{port}/hook"), &body).await;
        let request = tokio::time::timeout(Duration::from_secs(10), server)
            .await
            .expect("the stand-in answered")
            .expect("the stand-in task");

        assert!(ok, "curl reported a failure for a 200");
        assert!(request.starts_with("POST /hook "), "{request}");
        assert!(
            request.contains("Content-Type: application/json"),
            "{request}"
        );
        // Byte-identical: an escape that leaked would land here as a mangled body.
        assert!(request.ends_with(&body), "{request}");
    }
}
