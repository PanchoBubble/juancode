//! Renaming and archiving a session, and the pin that makes a rename stick.
//!
//! Under `JUANCODE_CORE=rust` neither operation reached this daemon at all: the
//! desktop wrote the new name into its own mirror row and sent nothing, so the row
//! here still said whatever the CLI had called the session. That alone would only
//! have been a rename nobody else could see. What made it a bug the user watches
//! happen is the other half — a CLI repaints its OSC 0/2 window title several times a
//! turn, this core adopted every one of them and broadcast the row, and the desktop's
//! mirror is a cache that takes the broadcast. So a new name held for a few seconds
//! and then flipped back, and an archived session came back unarchived on the next
//! launch, when the boot backfill replaced the whole list (juancode-0yao).
//!
//! Both halves are asserted here from the daemon's own state: the write lands, and it
//! then survives the escape that used to take it away — across the pty's next repaint,
//! and across a restart, which is where the desktop's private flag could never have
//! reached.

mod harness;

use harness::{wait_for, wait_for_screen, Harness};
use juancoded_core::model::SessionMeta;
use juancoded_state::registry::{SessionEvent, StateError};
use tokio::sync::broadcast::Receiver;

const DESKTOP: u64 = 1;

async fn next_meta(rx: &mut Receiver<SessionEvent>, id: &str) -> SessionMeta {
    match wait_for(
        rx,
        20,
        |e| matches!(e, SessionEvent::Meta { session_id, .. } if session_id == id),
    )
    .await
    {
        SessionEvent::Meta { meta, .. } => meta,
        _ => unreachable!("the predicate only matches a meta change"),
    }
}

/// Paint an OSC 0/2 window title, then wait until a printable marker behind it has
/// reached the grid.
///
/// The marker is how we know the escape was PARSED, rather than how long we were
/// willing to wait for it: anything the title was going to do to the row is already
/// done by the time the bytes after it are on screen. Sleeping instead would make a
/// pin that does not work look like one that does on a slow machine.
async fn paint_title_and_settle(harness: &Harness, id: &str, title: &str, marker: &str) {
    let bytes = format!("\x1b]2;{title}\x07\n{marker}\n");
    harness.sessions.input(id, bytes.as_bytes()).expect("input");
    wait_for_screen(&harness.sessions, id, marker, 20).await;
}

#[tokio::test]
async fn a_renamed_session_keeps_its_name_when_the_cli_repaints_its_window_title() {
    // The whole bug, in one test. Before the pin, the second half of this took the
    // name away within seconds of the first.
    let harness = Harness::new("set-meta-pin");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    // The CLI names itself first, which is the ordinary case and must still work.
    paint_title_and_settle(&harness, &id, "claude in tmp", "cli named it").await;
    assert_eq!(next_meta(&mut events, &id).await.title, "claude in tmp");

    harness
        .sessions
        .set_meta(&id, Some("the refactor"), None)
        .expect("set_meta");
    let renamed = next_meta(&mut events, &id).await;
    assert_eq!(renamed.title, "the refactor");
    assert!(renamed.title_is_manual, "a rename has to pin itself");

    // And now the escape that used to win.
    paint_title_and_settle(&harness, &id, "claude in tmp", "repainted").await;
    assert_eq!(
        harness.sessions.meta(&id).expect("a row").title,
        "the refactor",
        "the CLI's window title walked over a name the user chose"
    );
    // Nothing was announced either: a broadcast carrying the CLI's name would put it
    // back into every mirror even if the row here had held.
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, SessionEvent::Meta { .. }),
            "the adopted title was broadcast: {event:?}"
        );
    }
}

#[tokio::test]
async fn the_name_and_the_pin_and_the_archive_flag_all_survive_a_restart() {
    // The restart is the real test. The desktop's mirror is a cache and this daemon
    // is the source of truth after a backfill, so a pin that lived in daemon memory
    // would be re-lost on the first window title after every launch — and a launch is
    // exactly when a resumed CLI repaints one. Archive reverting on the next launch
    // was the same fact seen from the other side.
    let harness = Harness::new("set-meta-restart");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    harness
        .sessions
        .set_meta(&id, Some("kept across a boot"), Some(true))
        .expect("set_meta");

    let harness = harness.restart();
    let meta = harness.sessions.meta(&id).expect("the row is rehydrated");
    assert_eq!(meta.title, "kept across a boot");
    assert!(
        meta.archived,
        "the archive flag did not survive the restart"
    );
    assert!(
        meta.title_is_manual,
        "the pin did not survive the restart, so the next OSC title takes the name"
    );
}

#[tokio::test]
async fn an_absent_field_is_left_alone() {
    // A patch, not a replacement: a rename sheet does not have to send back an
    // archive flag it never asked about, and an archive button does not have to
    // re-send a name it does not know it is responsible for.
    let harness = Harness::new("set-meta-patch");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    harness
        .sessions
        .set_meta(&id, None, Some(true))
        .expect("archive only");
    let meta = harness.sessions.meta(&id).expect("a row");
    assert!(meta.archived);
    assert_eq!(meta.title, "tmp", "archiving is not a rename");
    assert!(
        !meta.title_is_manual,
        "archiving must not pin a name nobody chose"
    );

    harness
        .sessions
        .set_meta(&id, Some("named"), None)
        .expect("rename only");
    let meta = harness.sessions.meta(&id).expect("a row");
    assert_eq!(meta.title, "named");
    assert!(meta.archived, "a rename un-archived the session");

    harness
        .sessions
        .set_meta(&id, None, Some(false))
        .expect("unarchive");
    let meta = harness.sessions.meta(&id).expect("a row");
    assert!(!meta.archived);
    assert_eq!(meta.title, "named");
}

#[tokio::test]
async fn renaming_a_session_to_the_name_it_already_has_still_pins_it() {
    // "This one, keep it" is a statement about the name even when the name does not
    // move. A pass that only pinned on a diff would leave exactly that rename open to
    // the next repaint, which is the failure in its most confusing form: the user
    // typed the name they wanted and it still went away.
    let harness = Harness::new("set-meta-idempotent");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    paint_title_and_settle(&harness, &id, "claude in tmp", "cli named it").await;

    harness
        .sessions
        .set_meta(&id, Some("claude in tmp"), None)
        .expect("set_meta");
    assert!(harness.sessions.meta(&id).expect("a row").title_is_manual);

    paint_title_and_settle(&harness, &id, "something else", "repainted").await;
    assert_eq!(
        harness.sessions.meta(&id).expect("a row").title,
        "claude in tmp"
    );
}

#[tokio::test]
async fn a_blank_title_is_not_a_rename_and_an_unknown_session_is_refused() {
    // Blank gets the same answer an empty OSC escape gets: an unnamed row in a
    // sidebar is not something anybody asked for, so it is dropped rather than
    // written. It must not pin either — a pin taken on a name that was never applied
    // would freeze the row at whatever it happened to say.
    let harness = Harness::new("set-meta-blank");
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;

    harness
        .sessions
        .set_meta(&id, Some("   "), None)
        .expect("a blank title is not an error, it is a no-op");
    let meta = harness.sessions.meta(&id).expect("a row");
    assert_eq!(meta.title, "tmp");
    assert!(!meta.title_is_manual);

    // And a rename that went nowhere must not look like one that landed.
    assert_eq!(
        harness
            .sessions
            .set_meta("no-such-session", Some("named"), None),
        Err(StateError::NotFound)
    );
}

#[tokio::test]
async fn an_exited_session_can_still_be_renamed_and_archived() {
    // Archiving is what a person does to a session that is over, so refusing a row
    // with no pty would refuse the common case. Renaming is a fact about the row too,
    // not about the process behind it.
    let harness = Harness::new("set-meta-exited");
    let mut events = harness.sessions.subscribe();
    let id = harness.create("/tmp", 80, 24, DESKTOP).await;
    harness.sessions.kill(&id).expect("kill");
    harness::wait_for_exit(&mut events, &id).await;

    harness
        .sessions
        .set_meta(&id, Some("done with this one"), Some(true))
        .expect("set_meta on an exited session");
    let meta = harness.sessions.meta(&id).expect("a row");
    assert_eq!(meta.title, "done with this one");
    assert!(meta.archived);
}
