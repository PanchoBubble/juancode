//! Ephemeral ptys: the user's editor on one file, and a plain interactive shell.
//!
//! Not sessions, and deliberately not sessions. A session is a conversation this
//! daemon persists, rehydrates, reaps, resumes and reports in `listSessions`; an
//! editor pane is none of those things. Modelling one as a session with a `kind`
//! flag would put a row for every `nvim` the user ever opened into the store, into
//! the reaper's sweep and into every client's sidebar, and every one of those
//! consumers would then need the flag to opt back out. The Swift core reached the
//! same answer from the other end (`EphemeralPtyRegistry`, beside the session
//! registry rather than inside it), so both cores agree about what one of these is.
//!
//! Where the two cores differ is ownership, and only because this daemon's
//! connection loop is shaped differently. The Swift core keeps ephemeral ptys in
//! shared app state and has each connection remember the ids it opened so it can
//! kill them on the way out; here they simply live in the connection, which is the
//! same lifetime spelled once instead of twice. It is also what the rest of
//! `conn.rs` does: per-connection state is plain local data, no locks.
//!
//! What they share is the wire: an ephemeral pty is addressed by id over the same
//! `input` / `resize` / `kill` / `output` / `exit` messages as a session, which is
//! the whole point of handing the client an id at all.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use tokio::sync::mpsc::UnboundedSender;
use tracing::debug;

use juancoded_cordis::services::pty::PtySpawnApi;
use juancoded_core::provider::{resolve_editor_command, shell_command};
use juancoded_core::pty::{PtyEvent, PtyHandle, SpawnSpec};

use crate::utf8::Utf8Stream;
use crate::wire::ServerMessage;

/// Why an open did not happen. Each one is a sentence a client can show, because the
/// only thing it can do about any of them is say so.
#[derive(Debug)]
pub enum EphemeralError {
    /// The tree mounted no `pty` service. Not reachable in this daemon; the frame
    /// answers with it rather than panicking, the way the queue frames do.
    NoPtyService,
    /// The file is not inside the directory the client named. A pane is opened on a
    /// path the client chose, so the confinement is the check that keeps
    /// `../../../etc/passwd` out of it.
    OutsideWorkingDir,
    /// No editor resolved from `JUANCODE_EDITOR` / `$VISUAL` / `$EDITOR` / nvim.
    NoEditor,
    Spawn(String),
}

impl std::fmt::Display for EphemeralError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoPtyService => write!(f, "this core has no pty service mounted"),
            Self::OutsideWorkingDir => write!(f, "file is outside the working directory"),
            Self::NoEditor => write!(f, "no editor found on PATH"),
            Self::Spawn(e) => write!(f, "{e}"),
        }
    }
}

/// Which programs an open launches.
///
/// A seam, and only because of what the real answers are: the editor is whatever the
/// user configured and the shell is `$SHELL -i`, so a unit test that used them would
/// launch the developer's own nvim and source their own zshrc. Production always takes
/// [`Commands::real`]; a test pins something that exits when it is told to.
pub struct Commands {
    editor: Box<dyn Fn() -> Option<(String, Vec<String>)> + Send + Sync>,
    shell: Box<dyn Fn() -> (String, Vec<String>) + Send + Sync>,
}

impl Commands {
    /// The user's own editor and the user's own shell, resolved from the environment
    /// this daemon inherited.
    pub fn real() -> Self {
        Self {
            editor: Box::new(resolve_editor_command),
            shell: Box::new(|| shell_command(&|key| std::env::var(key).ok())),
        }
    }
}

/// The editor and shell ptys one connection has open.
///
/// Tab-scoped by construction: nothing else can reach this map, and dropping the
/// connection is what ends the children.
pub struct EphemeralPtys {
    pty: Option<Arc<dyn PtySpawnApi>>,
    /// Where a pump task puts the frames it owes this client. The same side channel
    /// seeded delivery uses, for the same reason: the bytes arrive long after the
    /// frame that asked for them.
    oob: UnboundedSender<ServerMessage>,
    commands: Commands,
    open: HashMap<String, PtyHandle>,
}

impl EphemeralPtys {
    pub fn new(pty: Option<Arc<dyn PtySpawnApi>>, oob: UnboundedSender<ServerMessage>) -> Self {
        Self::with_commands(pty, oob, Commands::real())
    }

    pub fn with_commands(
        pty: Option<Arc<dyn PtySpawnApi>>,
        oob: UnboundedSender<ServerMessage>,
        commands: Commands,
    ) -> Self {
        Self {
            pty,
            oob,
            commands,
            open: HashMap::new(),
        }
    }

    /// Spawn the user's editor on `file`, confined to `cwd`.
    pub fn open_editor(
        &mut self,
        cwd: &str,
        file: &str,
        cols: u16,
        rows: u16,
    ) -> Result<String, EphemeralError> {
        let path = confine(cwd, file).ok_or(EphemeralError::OutsideWorkingDir)?;
        let (program, mut args) = (self.commands.editor)().ok_or(EphemeralError::NoEditor)?;
        args.push(path.to_string_lossy().into_owned());
        self.spawn(program, args, cwd, cols, rows)
    }

    /// Spawn an interactive shell in `cwd`.
    pub fn open_terminal(
        &mut self,
        cwd: &str,
        cols: u16,
        rows: u16,
    ) -> Result<String, EphemeralError> {
        let (program, args) = (self.commands.shell)();
        self.spawn(program, args, cwd, cols, rows)
    }

    fn spawn(
        &mut self,
        program: String,
        args: Vec<String>,
        cwd: &str,
        cols: u16,
        rows: u16,
    ) -> Result<String, EphemeralError> {
        let pty = self.pty.clone().ok_or(EphemeralError::NoPtyService)?;
        let id = uuid::Uuid::new_v4().to_string();
        let handle = pty
            .spawn(
                &id,
                SpawnSpec {
                    program,
                    args,
                    cwd: cwd.to_string(),
                    cols,
                    rows,
                    // Untouched, like every other spawn in this daemon: an editor
                    // that did not see the user's real environment would not be
                    // the editor they configured.
                    env_overlay: Default::default(),
                },
            )
            .map_err(|e| EphemeralError::Spawn(e.to_string()))?;
        self.pump(id.clone(), handle.clone(), pty);
        self.open.insert(id.clone(), handle);
        Ok(id)
    }

    /// The one reader of an ephemeral pty. It frames bytes under the pty's own id,
    /// carries a split code point across chunks the way the session fan-out does, and
    /// reports the exit once.
    ///
    /// No scrollback and no grid, unlike a session: there is nothing to replay to,
    /// because the pane that opened this pty is the only thing that will ever read it
    /// and it has been listening since the `editorReady`.
    fn pump(&self, id: String, handle: PtyHandle, pty: Arc<dyn PtySpawnApi>) {
        let oob = self.oob.clone();
        let mut rx = handle.subscribe();
        tokio::spawn(async move {
            let mut carry = Utf8Stream::default();
            loop {
                match rx.recv().await {
                    Ok(PtyEvent::Output(bytes)) => {
                        let data = carry.push(&bytes);
                        if !data.is_empty()
                            && oob
                                .send(ServerMessage::Output {
                                    session_id: id.clone(),
                                    data,
                                })
                                .is_err()
                        {
                            break;
                        }
                    }
                    Ok(PtyEvent::Exit(exit_code)) => {
                        let _ = oob.send(ServerMessage::Exit {
                            session_id: id.clone(),
                            exit_code,
                        });
                        break;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        debug!(pty = id, dropped = n, "ephemeral pty pump lagged");
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
            // Hand the key back whether the child died on its own or was killed, so
            // the pty service's index does not accumulate a row per pane the user
            // ever opened.
            let _ = pty.stop(&id);
        });
    }

    /// Whether this id names one of this connection's ptys. The routing question the
    /// `input` / `resize` / `kill` handlers ask before they reach for a session.
    pub fn holds(&self, id: &str) -> bool {
        self.open.contains_key(id)
    }

    pub fn input(&self, id: &str, bytes: &[u8]) {
        if let Some(handle) = self.open.get(id) {
            if let Err(e) = handle.write(bytes) {
                debug!(pty = id, error = %e, "input to an ephemeral pty went nowhere");
            }
        }
    }

    /// Resize, reporting whether it reached a live pty.
    ///
    /// Unarbitrated, and that is the difference from a session: a session's grid is
    /// shared between every viewer of it, so a second one's resize is denied rather
    /// than allowed to flap the CLI's width. This pane belongs to one tab, so there is
    /// nobody to arbitrate with. `applied` is "the pty is live and now has that grid",
    /// including when it already did — a no-op reported as un-applied would have a
    /// sequenced client re-asserting a size it already has forever.
    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> bool {
        match self.open.get(id) {
            Some(handle) if !handle.has_exited() => handle.resize(cols, rows).is_ok(),
            _ => false,
        }
    }

    /// End one pty on the same ladder a session `kill` uses: SIGTERM, the flush
    /// grace, then SIGKILL, and a group reap so the language server an editor started
    /// does not outlive the pane. The `exit` the client sees comes from the pump, like
    /// any other.
    pub fn kill(&self, id: &str) {
        if let Some(handle) = self.open.get(id) {
            end(handle.clone());
        }
    }

    /// The connection is going away, and these panes go with it.
    ///
    /// Every child is asked first and only then walked through the ladder, so N panes
    /// cost one grace rather than N — the same shape `PtyHost`'s own shutdown uses,
    /// and for the same reason.
    pub fn close_all(&mut self) {
        for handle in self.open.values() {
            handle.request_stop();
        }
        for (_, handle) in self.open.drain() {
            end(handle);
        }
    }
}

/// Run the stop ladder somewhere other than the connection's own task.
///
/// The ladder blocks for the flush grace when a child ignores SIGTERM, and nothing on
/// this connection is waiting for it: the `exit` frame comes from the pump, and the
/// pty service's index is released there too. Blocking the loop for three seconds
/// would stall every other frame the client has in flight.
fn end(handle: PtyHandle) {
    tokio::task::spawn_blocking(move || {
        if let Err(e) = handle.stop() {
            debug!(error = %e, "an ephemeral pty did not stop cleanly");
        }
    });
}

/// `file` resolved against `root`, or `None` when it lands outside it.
///
/// Lexical, like the Swift core's `standardizedFileURL`: `..` is popped without
/// touching the filesystem, so the answer does not depend on what exists yet and a
/// symlinked temp dir does not read as an escape.
fn confine(root: &str, file: &str) -> Option<PathBuf> {
    let root = normalize(Path::new(root));
    let candidate = if Path::new(file).is_absolute() {
        normalize(Path::new(file))
    } else {
        normalize(&root.join(file))
    };
    candidate.starts_with(&root).then_some(candidate)
}

/// Collapse `.` and `..` without asking the filesystem anything.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                // A `..` above the root is dropped, which is what the kernel does too.
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
pub(crate) mod testing {
    use super::Commands;

    /// Both programs pinned to `/bin/cat`, which is on every machine this builds on,
    /// stays alive until its stdin closes, and echoes what it is written. A test wants
    /// a pty that behaves, not the developer's nvim.
    pub fn cat_commands() -> Commands {
        Commands {
            editor: Box::new(|| Some(("/bin/cat".to_string(), Vec::new()))),
            shell: Box::new(|| ("/bin/cat".to_string(), Vec::new())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_under_the_root_resolves_absolute() {
        assert_eq!(
            confine("/work/repo", "src/main.rs"),
            Some(PathBuf::from("/work/repo/src/main.rs"))
        );
        assert_eq!(
            confine("/work/repo", "/work/repo/src/main.rs"),
            Some(PathBuf::from("/work/repo/src/main.rs"))
        );
    }

    /// The pane is opened on a path the client chose, so this is the only thing
    /// standing between `openEditor` and any file the daemon's user can read.
    #[test]
    fn a_file_outside_the_root_is_refused() {
        assert_eq!(confine("/work/repo", "../../etc/passwd"), None);
        assert_eq!(confine("/work/repo", "/etc/passwd"), None);
        // A sibling whose name merely starts with the root's is not inside it.
        assert_eq!(confine("/work/repo", "/work/repo-other/x"), None);
    }

    #[test]
    fn the_root_itself_is_inside_itself() {
        assert_eq!(
            confine("/work/repo", "."),
            Some(PathBuf::from("/work/repo"))
        );
    }

    /// A trailing `.` or a doubled separator is the same directory, and a client that
    /// spelled its cwd that way must not have its own file refused.
    #[test]
    fn a_noisy_root_still_contains_its_files() {
        assert_eq!(
            confine("/work/./repo/", "src/main.rs"),
            Some(PathBuf::from("/work/repo/src/main.rs"))
        );
    }
}
