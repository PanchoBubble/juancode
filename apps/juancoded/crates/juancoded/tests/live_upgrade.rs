//! A live upgrade, end to end, against real processes.
//!
//! Boots a daemon of its own (its own port, socket and data dir, never the user's)
//! with a fake CLI in a real pty, then runs the real trigger, `juancoded upgrade`, from
//! a second copy of the binary. The questions are the ones a person who just upgraded
//! would ask: is it the same daemon, is it the new code, is my session still running,
//! does it still answer, and is its history intact. Then the safety half: an upgrade
//! onto something that is not a juancoded is refused before a pty is handed over, and
//! the session goes on answering on the old code.

#![cfg(unix)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

/// Generous: one fork+exec costs a quarter second on a quiet machine here and several
/// on a loaded one, and the fake CLI is a shell script.
const PATIENCE: Duration = Duration::from_secs(60);

/// Echoes, and says "esc to interrupt" so the activity classifier has something to
/// see. `read` blocks, so it is a bounded workload that ends when its pty does.
const FAKE_CLI: &str = r#"#!/bin/sh
printf 'FAKE-CLI-READY\r\n'
printf 'esc to interrupt\r\n'
while IFS= read -r line; do
  printf 'echo:%s\r\n' "$line"
  printf 'esc to interrupt\r\n'
done
"#;

/// Everything this test starts, ended on every exit path including a panic.
struct Rig {
    dir: PathBuf,
    port: u16,
    daemon: Child,
}

impl Drop for Rig {
    fn drop(&mut self) {
        let pid = self.daemon.id() as i32;
        // SAFETY: a pid this test spawned and still holds a `Child` for.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if matches!(self.daemon.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        if std::thread::panicking() {
            if let Ok(log) = std::fs::read_to_string(self.dir.join("daemon.log")) {
                let tail: Vec<&str> = log.lines().rev().take(40).collect();
                eprintln!("--- daemon log tail ---");
                for line in tail.into_iter().rev() {
                    eprintln!("{line}");
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Rig {
    fn data(&self) -> PathBuf {
        self.dir.join("data")
    }

    fn env(&self, cmd: &mut Command) {
        Self::env_for(&self.dir, self.port)(cmd);
    }

    /// The daemon's whole world, and the trigger's: both must agree on the data dir,
    /// because that is where the run file and the request file live.
    fn env_for(dir: &Path, port: u16) -> impl Fn(&mut Command) {
        let dir = dir.to_path_buf();
        move |cmd: &mut Command| {
            cmd.env("JUANCODED_PORT", port.to_string())
                .env("JUANCODED_SOCKET", dir.join("d.sock"))
                .env("JUANCODED_DATA_DIR", dir.join("data"))
                .env("JUANCODE_CLAUDE_BIN", dir.join("fake-claude"))
                .env("JUANCODE_OWNER_GRACE_SECONDS", "0")
                .env_remove("JUANCODE_OWNER_PID")
                .env_remove("JUANCODED_REEXEC")
                .env_remove("JUANCODE_DATA_DIR");
        }
    }

    fn run_file(&self) -> HashMap<String, String> {
        std::fs::read_to_string(self.data().join("juancoded.run"))
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn upgrade(&self, binary: &Path, args: &[&str]) -> std::process::Output {
        let mut cmd = Command::new(binary);
        cmd.arg("upgrade").args(args).stdin(Stdio::null());
        self.env(&mut cmd);
        cmd.output().expect("run juancoded upgrade")
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn boot() -> Rig {
    // Short on purpose: `sun_path` is 104 bytes on macOS.
    let dir = std::env::temp_dir().join(format!("jcd-upg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("data")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let cli = dir.join("fake-claude");
    std::fs::write(&cli, FAKE_CLI).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    // The first image, under a name of its own, so "running the new code" is a path
    // that changed rather than an assertion.
    let v1 = dir.join("juancoded-v1");
    std::fs::copy(env!("CARGO_BIN_EXE_juancoded"), &v1).unwrap();

    let log = std::fs::File::create(dir.join("daemon.log")).unwrap();
    let port = free_port();
    let mut cmd = Command::new(&v1);
    cmd.stdin(Stdio::null())
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .env("JUANCODE_BUILD_ID", "upgrade-test-v1")
        .env("JUANCODED_LOG", "info");
    let env_of = Rig::env_for(&dir, port);
    env_of(&mut cmd);
    let daemon = cmd.spawn().expect("spawn daemon");
    let mut rig = Rig { dir, port, daemon };

    let deadline = Instant::now() + PATIENCE;
    while rig.run_file().get("pid").map(String::as_str) != Some(&rig.daemon.id().to_string()) {
        assert!(
            Instant::now() < deadline,
            "the daemon never wrote its run file"
        );
        assert!(
            rig.daemon.try_wait().unwrap().is_none(),
            "the daemon exited while starting"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    rig
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(port: u16) -> Ws {
    let deadline = Instant::now() + PATIENCE;
    loop {
        match tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/ws")).await {
            Ok((ws, _)) => return ws,
            Err(e) if Instant::now() < deadline => {
                let _ = e;
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(e) => panic!("could not connect to :{port}: {e}"),
        }
    }
}

async fn send(ws: &mut Ws, v: Value) {
    ws.send(Message::Text(v.to_string().into())).await.unwrap();
}

/// Read frames until `done` says so, accumulating every `output` and `attached`
/// scrollback for the session into one transcript. Returns the frame that satisfied it.
async fn until(
    ws: &mut Ws,
    seen: &mut String,
    mut done: impl FnMut(&Value, &str) -> bool,
) -> Value {
    let deadline = Instant::now() + PATIENCE;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "timed out; transcript so far: {seen:?}");
        let Ok(Some(Ok(msg))) = tokio::time::timeout(left, ws.next()).await else {
            panic!("the socket closed or timed out; transcript so far: {seen:?}");
        };
        let Message::Text(text) = msg else { continue };
        let v: Value = serde_json::from_str(&text).unwrap();
        match v["type"].as_str() {
            Some("output") => seen.push_str(v["data"].as_str().unwrap_or_default()),
            Some("attached") => seen.push_str(v["scrollback"].as_str().unwrap_or_default()),
            _ => {}
        }
        if done(&v, seen) {
            return v;
        }
    }
}

async fn type_and_wait(ws: &mut Ws, session: &str, text: &str) {
    send(
        ws,
        json!({ "type": "input", "sessionId": session, "data": format!("{text}\r") }),
    )
    .await;
    let mut seen = String::new();
    let marker = format!("echo:{text}");
    until(ws, &mut seen, |_, s| s.contains(&marker)).await;
}

fn children_of(pid: u32) -> Vec<u32> {
    let out = Command::new("pgrep")
        .arg("-P")
        .arg(pid.to_string())
        .output()
        .expect("pgrep");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect()
}

fn running_image(pid: u32) -> String {
    // Not `ps -o comm=`: an exec that keeps argv keeps argv[0], so ps still names the
    // binary the process started as. lsof's first `txt` entry is the mapped image.
    let out = Command::new("lsof")
        .args(["-p", &pid.to_string(), "-a", "-d", "txt", "-Fn"])
        .output()
        .expect("lsof");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.strip_prefix('n').map(str::to_string))
        .unwrap_or_default()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_upgrade_keeps_the_session_its_child_and_its_scrollback() {
    let rig = boot();
    let daemon_pid = rig.daemon.id();
    assert_eq!(
        rig.run_file()["upgrade"],
        "sigusr2",
        "the trigger must be advertised"
    );

    // A session, typed into before the swap.
    let mut ws = connect(rig.port).await;
    let cwd = rig.dir.to_string_lossy().into_owned();
    send(
        &mut ws,
        json!({ "type": "create", "provider": "claude", "cwd": cwd, "cols": 100, "rows": 30 }),
    )
    .await;
    let mut seen = String::new();
    let created = until(&mut ws, &mut seen, |v, _| v["type"] == "created").await;
    let session = created["session"]["id"].as_str().unwrap().to_string();
    until(&mut ws, &mut seen, |_, s| s.contains("FAKE-CLI-READY")).await;
    type_and_wait(&mut ws, &session, "before-swap").await;
    drop(ws);

    let kids = children_of(daemon_pid);
    assert_eq!(kids.len(), 1, "one CLI under the daemon, got {kids:?}");
    let cli_pid = kids[0];
    let started_before = rig.run_file()["started_at_ms"].clone();

    // The real trigger, run from the NEW binary: it names itself as the target.
    let v2 = rig.dir.join("juancoded-v2");
    std::fs::copy(env!("CARGO_BIN_EXE_juancoded"), &v2).unwrap();
    let out = rig.upgrade(&v2, &["--build-id", "upgrade-test-v2"]);
    assert!(
        out.status.success(),
        "upgrade failed: {}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );

    // Same daemon, new code, new build stamp.
    assert!(rig.daemon.id() == daemon_pid);
    let run = rig.run_file();
    assert_eq!(run["pid"], daemon_pid.to_string(), "an exec keeps the pid");
    assert_ne!(
        run["started_at_ms"], started_before,
        "the new image wrote its own run file"
    );
    assert_eq!(
        run["build_id"], "upgrade-test-v2",
        "the badge must see the new build"
    );
    assert_eq!(
        running_image(daemon_pid),
        v2.to_string_lossy(),
        "pid is running the new binary"
    );

    // Same CLI, still the daemon's child: nothing was signalled.
    assert_eq!(
        children_of(daemon_pid),
        vec![cli_pid],
        "the CLI survived as the same pid"
    );

    // Still running, still answering, and the history spans the swap.
    let mut ws = connect(rig.port).await;
    send(
        &mut ws,
        json!({ "type": "attach", "sessionId": session, "cols": 100, "rows": 30 }),
    )
    .await;
    let mut history = String::new();
    let attached = until(&mut ws, &mut history, |v, _| v["type"] == "attached").await;
    assert_eq!(attached["session"]["status"], "running", "{attached}");
    assert!(
        history.contains("FAKE-CLI-READY"),
        "lost the first line: {history:?}"
    );
    assert!(
        history.contains("echo:before-swap"),
        "lost pre-swap output: {history:?}"
    );
    type_and_wait(&mut ws, &session, "after-swap").await;

    // The safety half. Not a juancoded: the probe refuses it before any pty is handed
    // over, the trigger reports the daemon's own reason, and nothing changed.
    let impostor = rig.dir.join("not-juancoded");
    std::fs::write(&impostor, "#!/bin/sh\necho hello\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&impostor, std::fs::Permissions::from_mode(0o755)).unwrap();
    let started_mid = rig.run_file()["started_at_ms"].clone();
    let out = rig.upgrade(
        &v2,
        &["--binary", impostor.to_str().unwrap(), "--timeout", "60"],
    );
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(!out.status.success(), "an impostor must be refused: {said}");
    assert!(
        said.contains("cannot adopt"),
        "the daemon's reason reaches the trigger: {said}"
    );
    assert_eq!(
        rig.run_file()["started_at_ms"],
        started_mid,
        "no exec happened"
    );
    assert_eq!(children_of(daemon_pid), vec![cli_pid]);
    type_and_wait(&mut ws, &session, "after-refusal").await;
}
