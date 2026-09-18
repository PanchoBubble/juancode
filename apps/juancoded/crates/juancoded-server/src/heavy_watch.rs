//! The heavy queue as something a client can watch: one snapshot per change, pushed.
//!
//! The policy lives in [`juancoded_core::heavy`]; this is the daemon's half — who
//! reads the registry, how often, and who hears about it.
//!
//! **How the registry is watched: a 1-second stat loop, not FSEvents.** The queue is
//! a directory of tiny JSON files that changes a handful of times an hour, and a job
//! whose entry moved is already going to wait up to 3 seconds for its own wrapper to
//! poll — so a second of latency on the notification is below the resolution of the
//! thing being notified about. The loop compares the whole snapshot and publishes
//! only a change, which is also what makes it safe to run against a directory three
//! other processes are writing: a file caught mid-rewrite decodes as nothing, and the
//! next pass corrects it. A kqueue watch would have bought 900ms and a per-platform
//! seam for a registry that does not exist on Linux at all.
//!
//! The loop does its reads only while at least one connection is subscribed —
//! `receiver_count()` is the gate, so an unsubscribe or a closed socket releases it
//! without anything having to be counted by hand.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use juancoded_core::heavy::{HeavyQueue, HeavyQueueSnapshot};

/// How often the registry is re-read while somebody is watching. See the module
/// comment: the wrapper's own poll is 3s, so this is already finer than the thing it
/// reports on.
pub const POLL: Duration = Duration::from_secs(1);

/// How many snapshots a slow subscriber may fall behind before it starts losing
/// them. Survivable by construction: every frame is the complete queue, so the next
/// one is the whole truth again.
const CHANGE_BUFFER: usize = 8;

/// The registry reader, its change fan-out, and the last snapshot published.
///
/// One per daemon. The queue is machine state shared with every other `heavy` on
/// this Mac, so two watches would be two readers of one directory disagreeing about
/// when it changed.
pub struct HeavyWatch {
    queue: HeavyQueue,
    changes: broadcast::Sender<Arc<HeavyQueueSnapshot>>,
    /// What was last put on the bus, so an unchanged registry publishes nothing.
    /// A `std::sync::Mutex`, never held across an `await`.
    last: Mutex<Option<Arc<HeavyQueueSnapshot>>>,
}

impl HeavyWatch {
    pub fn new(queue: HeavyQueue) -> Arc<Self> {
        Arc::new(Self {
            queue,
            changes: broadcast::channel(CHANGE_BUFFER).0,
            last: Mutex::new(None),
        })
    }

    /// The queue this machine's `heavy` wrapper uses, or whatever
    /// `JUANCODE_HEAVY_ROOT` redirects it to.
    pub fn from_env() -> Arc<Self> {
        Self::new(HeavyQueue::from_env())
    }

    /// A receiver for every change from here on. Taken only when a client asks to
    /// watch: while nobody holds one, the poll below does no filesystem work at all.
    pub fn subscribe(&self) -> broadcast::Receiver<Arc<HeavyQueueSnapshot>> {
        self.changes.subscribe()
    }

    /// Read the registry right now. What a `heavyQueueSubscribe` is answered with,
    /// so a client that just arrived starts from the truth rather than from whatever
    /// the last change happened to be.
    ///
    /// Deliberately does NOT move `last`: that field is what the poll compares
    /// against, and a second client subscribing would otherwise mark a change as
    /// already published and swallow the frame the first client was owed. A
    /// subscriber may therefore be handed the same queue twice — once here and once
    /// off the bus — which costs it nothing, because the frame is a complete state
    /// and a connection drops a snapshot identical to the one it last sent.
    pub fn snapshot(&self) -> Arc<HeavyQueueSnapshot> {
        Arc::new(self.queue.snapshot())
    }

    /// Re-read and publish, but only if the queue actually moved.
    ///
    /// Called on the poll tick and again straight after every mutation, so a client
    /// that reordered the line sees it reordered without waiting out a tick.
    pub fn publish_if_changed(&self) {
        let fresh = self.queue.snapshot();
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        if last.as_deref() == Some(&fresh) {
            return;
        }
        let fresh = Arc::new(fresh);
        *last = Some(Arc::clone(&fresh));
        drop(last);
        // A send with no receivers is the ordinary case between subscriptions.
        let _ = self.changes.send(fresh);
    }

    /// Move a job in line. `false` when the entry is gone — a job that finished
    /// between the snapshot a client is holding and its click.
    pub fn set_priority(&self, pid: i32, prio: i64) -> bool {
        let ok = self.queue.set_priority(pid, prio);
        self.publish_if_changed();
        ok
    }

    /// Widen or narrow the queue. `false` for anything below one slot: a queue with
    /// no slots admits nothing forever, and the wrapper clamps it back anyway.
    pub fn set_slots(&self, slots: i64) -> bool {
        let ok = self.queue.set_slots(slots);
        self.publish_if_changed();
        ok
    }

    /// SIGTERM the wrapper of a job **this queue holds**.
    ///
    /// The membership check is the point, not a nicety: without it the frame is an
    /// arbitrary-signal gadget aimed at any pid on the machine by anything that can
    /// reach the socket. A pid with no entry here is not this daemon's to signal.
    pub fn cancel(&self, pid: i32) -> bool {
        if !self.snapshot().holds(pid) {
            return false;
        }
        let ok = self.queue.cancel(pid);
        self.publish_if_changed();
        ok
    }

    /// The poll. One task for the daemon, started at boot like the other pumps, and
    /// a no-op tick while nobody is watching.
    pub fn spawn(self: &Arc<Self>) -> JoinHandle<()> {
        let watch = Arc::clone(self);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(POLL);
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                ticker.tick().await;
                if watch.changes.receiver_count() == 0 {
                    continue;
                }
                watch.publish_if_changed();
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> (std::path::PathBuf, Arc<HeavyWatch>) {
        let root = std::env::temp_dir().join(format!(
            "heavy-watch-{}-{name}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("queue")).unwrap();
        let queue = HeavyQueue::new(root.clone(), root.join("heavy-queue.json"))
            // Every pid in a fixture is "alive": nothing here is a real process, and
            // the liveness half is measured in juancoded-core's own tests.
            .with_probes(Box::new(|_| true), Box::new(|_| None));
        (root.clone(), HeavyWatch::new(queue))
    }

    fn write_entry(root: &std::path::Path, pid: i32, prio: i64, since: i64) {
        let entry = serde_json::json!({
            "pid": pid, "prio": prio, "since": since, "slot": 0,
            "cmd": "pnpm test", "cwd": "/repo", "child": serde_json::Value::Null,
        });
        std::fs::write(
            root.join(format!("queue/{pid}.json")),
            serde_json::to_vec(&entry).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn a_subscribers_read_never_swallows_another_subscribers_change() {
        let (root, watch) = fixture("swallow");
        write_entry(&root, 10, 0, 100);
        let mut first = watch.subscribe();
        watch.publish_if_changed();
        assert!(first.try_recv().is_ok(), "the first read is a change");

        // A change nobody has been told about yet, and then a second client arriving
        // and reading the registry for its own first draw.
        write_entry(&root, 20, 0, 200);
        let second = watch.snapshot();
        assert_eq!(second.waiting.len(), 2);

        // The first client is still owed that change: a read must not count as a
        // publish, or the second subscriber's arrival silently ends the first one's
        // stream one frame short.
        watch.publish_if_changed();
        let frame = first.try_recv().expect("the change is still owed");
        assert_eq!(
            frame.waiting.iter().map(|j| j.pid).collect::<Vec<_>>(),
            [10, 20]
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_unchanged_registry_publishes_nothing() {
        let (root, watch) = fixture("quiet");
        write_entry(&root, 10, 0, 100);
        let mut rx = watch.subscribe();
        watch.publish_if_changed();
        assert!(rx.try_recv().is_ok(), "the first read is a change");
        watch.publish_if_changed();
        watch.publish_if_changed();
        assert!(
            rx.try_recv().is_err(),
            "a registry that did not move must not produce a frame"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_priority_rewrite_publishes_the_reordered_line() {
        let (root, watch) = fixture("reorder");
        write_entry(&root, 10, 0, 100);
        write_entry(&root, 20, 0, 200);
        let mut rx = watch.subscribe();
        assert_eq!(
            watch
                .snapshot()
                .waiting
                .iter()
                .map(|j| j.pid)
                .collect::<Vec<_>>(),
            [10, 20]
        );

        assert!(watch.set_priority(20, 5));
        let frame = rx.try_recv().expect("a reorder is a change");
        assert_eq!(
            frame.waiting.iter().map(|j| j.pid).collect::<Vec<_>>(),
            [20, 10]
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn set_slots_publishes_the_new_capacity_and_refuses_zero() {
        let (root, watch) = fixture("slots");
        let mut rx = watch.subscribe();
        watch.snapshot();
        assert!(watch.set_slots(3));
        assert_eq!(rx.try_recv().expect("capacity is state").slots, 3);

        assert!(!watch.set_slots(0));
        assert!(rx.try_recv().is_err(), "a refusal changes nothing");
        assert_eq!(watch.snapshot().slots, 3);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_cancel_for_a_pid_the_queue_does_not_hold_is_refused() {
        let (root, watch) = fixture("cancel");
        write_entry(&root, 10, 0, 100);
        // Nothing is signalled: 424242 is not in the registry, so the membership
        // check refuses before `kill` is ever reached.
        assert!(!watch.cancel(424_242));
        std::fs::remove_dir_all(&root).ok();
    }
}
