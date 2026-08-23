//! The contribution contract, against a real booted tree.
//!
//! The ticket's bar, restated as tests: a plugin puts a section in the sidebar and a
//! badge on a session row, unmounting the plugin takes both away with nothing
//! restarted, and adding a second such plugin is an entry row rather than a code
//! change to the shell. The shell never runs plugin logic: activating an item is a
//! round trip the daemon answers.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use juancoded_cordis::plugins::{default_entries, INTERRUPT_ID};
use juancoded_cordis::{
    boot, boot_with, dump_config, Activation, ActivationOutcome, Badge, Context, Contribution,
    DataNeed, Entry, Placement, Plugin, Tone,
};

/// A plugin whose only job is chrome: one sidebar section, one item in it, and one
/// badge on every session row. Nothing about it is special-cased anywhere.
struct GoalTracker;

impl Plugin for GoalTracker {
    fn name(&self) -> &'static str {
        "goal-tracker"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        ctx.contribute(
            Contribution::new(
                "goals.section",
                Placement::SidebarSection {
                    title: "Goals".into(),
                    icon: Some("target".into()),
                    collapsible: true,
                },
            )
            .sort_key(20),
        )?;
        ctx.contribute(
            Contribution::new(
                "goals.item.active",
                Placement::SidebarItem {
                    section: "goals.section".into(),
                    label: "In flight".into(),
                    icon: None,
                    badge: Some(Badge::new("3")),
                },
            )
            .sort_key(21)
            .needs(DataNeed::ProjectSessions),
        )?;
        ctx.contribute(
            Contribution::new(
                "goals.badge.phase",
                Placement::SessionBadge {
                    badge: Badge::new("phase 2").tone(Tone::Info),
                    when_activity: vec![],
                },
            )
            .sort_key(5)
            .needs(DataNeed::SessionActivity),
        )?;
        Ok(())
    }
}

/// A second chrome plugin, added purely to show the cost of the second one.
struct StuckWatch;

impl Plugin for StuckWatch {
    fn name(&self) -> &'static str {
        "stuck-watch"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        ctx.contribute(
            Contribution::new(
                "stuck.badge",
                Placement::SessionBadge {
                    badge: Badge::new("stuck").tone(Tone::Danger),
                    when_activity: vec!["waitingInput".into()],
                },
            )
            .sort_key(1)
            .needs(DataNeed::SessionActivity),
        )?;
        Ok(())
    }
}

fn tree_with(extra: &[(&str, &str)]) -> juancoded_cordis::EntryList {
    let mut entries = default_entries();
    for (id, name) in extra {
        entries = entries.push(Entry::new(*id, *name));
    }
    entries
}

#[test]
fn a_plugin_puts_a_section_in_the_sidebar_and_a_badge_on_the_session_row() {
    let mut loader = juancoded_cordis::Loader::new();
    juancoded_cordis::plugins::register_builtins(&mut loader);
    loader.register(Arc::new(GoalTracker));
    loader
        .apply(&tree_with(&[("goals", "goal-tracker")]))
        .unwrap();

    let sections = loader.contributions().rows_for("sidebarSection");
    assert_eq!(sections.len(), 1);
    assert_eq!(sections[0].id, "goals.section");
    assert_eq!(sections[0].owner, "goals");

    let badges: Vec<String> = loader
        .contributions()
        .rows_for("sessionBadge")
        .into_iter()
        .map(|c| c.id)
        .collect();
    assert!(
        badges.contains(&"goals.badge.phase".to_string()),
        "{badges:?}"
    );
}

#[test]
fn unmounting_the_plugin_takes_its_chrome_with_it() {
    let mut loader = juancoded_cordis::Loader::new();
    juancoded_cordis::plugins::register_builtins(&mut loader);
    loader.register(Arc::new(GoalTracker));
    let mut entries = tree_with(&[("goals", "goal-tracker")]);
    loader.apply(&entries).unwrap();
    let before = loader.contributions().len();
    let revision = loader.contributions().revision();

    // Disabling the row is the whole unmount. Nothing is told to redraw and nothing
    // restarts: the guards the plugin was holding go, and with them the descriptors.
    entries.set_disabled("goals", true);
    loader.apply(&entries).unwrap();

    assert_eq!(loader.contributions().len(), before - 3);
    assert!(loader.contributions().rows_for("sidebarSection").is_empty());
    assert!(loader.contributions().get("goals.badge.phase").is_none());
    assert!(
        loader.contributions().revision() > revision,
        "a client holding the old revision has to know it is stale"
    );

    // And the built-in chrome, contributed by a different plugin, is untouched.
    assert!(loader.contributions().get("session.badge.busy").is_some());
}

#[test]
fn a_second_chrome_plugin_is_an_entry_row_and_nothing_else() {
    let mut loader = juancoded_cordis::Loader::new();
    juancoded_cordis::plugins::register_builtins(&mut loader);
    loader.register(Arc::new(GoalTracker));
    loader.register(Arc::new(StuckWatch));
    loader
        .apply(&tree_with(&[
            ("goals", "goal-tracker"),
            ("stuck", "stuck-watch"),
        ]))
        .unwrap();

    // Three plugins now decorate the session row, and the order is the sort key, not
    // who mounted first.
    let badges: Vec<(String, i32)> = loader
        .contributions()
        .rows_for("sessionBadge")
        .into_iter()
        .map(|c| (c.id, c.sort_key))
        .collect();
    assert_eq!(
        badges,
        [
            ("session.badge.waiting".to_string(), 0),
            ("stuck.badge".to_string(), 1),
            ("goals.badge.phase".to_string(), 5),
            ("session.badge.busy".to_string(), 10),
        ]
    );
}

#[test]
fn the_order_is_the_same_on_every_boot() {
    let ids = |()| -> Vec<String> {
        let mut loader = juancoded_cordis::Loader::new();
        juancoded_cordis::plugins::register_builtins(&mut loader);
        loader.register(Arc::new(GoalTracker));
        loader.register(Arc::new(StuckWatch));
        loader
            .apply(&tree_with(&[
                ("stuck", "stuck-watch"),
                ("goals", "goal-tracker"),
            ]))
            .unwrap();
        loader
            .contributions()
            .rows()
            .into_iter()
            .map(|c| c.id)
            .collect()
    };
    assert_eq!(ids(()), ids(()));
}

#[test]
fn activating_an_item_is_a_round_trip_the_daemon_answers() {
    let (loader, _) = boot();
    let outcome = loader
        .contributions()
        .activate(&Activation::new(INTERRUPT_ID).on("sess-7"));
    assert_eq!(
        outcome,
        ActivationOutcome::Handled {
            result: serde_json::json!({ "interrupted": "sess-7" })
        }
    );
    // And an activation the descriptor cannot make sense of is refused, not guessed.
    assert_eq!(
        loader
            .contributions()
            .activate(&Activation::new(INTERRUPT_ID)),
        ActivationOutcome::refused("no session named")
    );
}

/// A plugin that counts how often its handler ran, to prove the handler goes away with
/// the plugin rather than lingering behind a stale descriptor.
struct Counted(Arc<AtomicUsize>);

impl Plugin for Counted {
    fn name(&self) -> &'static str {
        "counted"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let hits = Arc::clone(&self.0);
        ctx.contribute_with(
            Contribution::new(
                "counted.command",
                Placement::Command {
                    title: "Count".into(),
                    keybinding: Some("cmd+shift+k".into()),
                    in_palette: true,
                },
            ),
            move |_, _| {
                hits.fetch_add(1, Ordering::SeqCst);
                ActivationOutcome::handled()
            },
        )?;
        Ok(())
    }
}

#[test]
fn an_unmounted_plugins_action_stops_answering() {
    let hits = Arc::new(AtomicUsize::new(0));
    let mut loader = juancoded_cordis::Loader::new();
    juancoded_cordis::plugins::register_builtins(&mut loader);
    loader.register(Arc::new(Counted(Arc::clone(&hits))));
    let mut entries = tree_with(&[("counted", "counted")]);
    loader.apply(&entries).unwrap();

    assert_eq!(
        loader
            .contributions()
            .activate(&Activation::new("counted.command")),
        ActivationOutcome::handled()
    );
    assert_eq!(hits.load(Ordering::SeqCst), 1);

    entries.set_disabled("counted", true);
    loader.apply(&entries).unwrap();
    assert_eq!(
        loader
            .contributions()
            .activate(&Activation::new("counted.command")),
        ActivationOutcome::Unhandled
    );
    assert_eq!(
        hits.load(Ordering::SeqCst),
        1,
        "the handler ran after unmount"
    );
}

#[test]
fn shutting_the_tree_down_leaves_no_chrome_behind() {
    let (mut loader, _) = boot();
    assert!(!loader.contributions().is_empty());
    loader.shutdown();
    assert!(loader.contributions().is_empty());
    assert!(loader.contributions().is_shutdown());
}

#[test]
fn dump_config_prints_a_contribution_as_an_ordinary_row() {
    let (loader, _) = boot_with(&default_entries()).unwrap();
    let dump = dump_config(&loader);
    assert!(
        dump.contains(
            "├─ session.badge.waiting   sessionBadge     <- session-chrome  sort=0  needs=session.activity"
        ),
        "{dump}"
    );
    assert!(dump.contains("3 contributions"), "{dump}");
}

#[test]
fn a_snapshot_is_what_a_client_would_have_to_render() {
    let (loader, _) = boot();
    let snapshot = loader.contributions().snapshot();
    let json = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(json["schemaVersion"], 1);
    assert_eq!(json["items"][0]["id"], "session.badge.waiting");
    assert_eq!(json["items"][0]["surface"], "sessionBadge");
    assert_eq!(json["items"][0]["owner"], "session-chrome");
    // And it decodes back, which is the half a Swift client has to be able to do.
    let decoded: juancoded_cordis::ContributionSnapshot = serde_json::from_value(json).unwrap();
    assert_eq!(decoded, snapshot);
}
