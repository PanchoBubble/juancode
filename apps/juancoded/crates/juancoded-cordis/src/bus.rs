//! The typed event bus, with the dispatch mode carried in the type system.
//!
//! cordis documents an event's dispatch mode in a doc tag and checks declarations
//! against dispatch sites with a generator. Here the mode *is* the trait the event
//! implements, so a wrong dispatch does not compile and there is nothing to generate:
//!
//! | Mode | Trait | Registration | Dispatch | Awaited | Returns |
//! | --- | --- | --- | --- | --- | --- |
//! | observe | [`ObserveEvent`] | [`Bus::on`] | [`Bus::emit`] | no | no |
//! | around | [`AroundEvent`] | [`Bus::around`] | [`Bus::waterfall`] | no | yes |
//! | fan-out | [`FanOutEvent`] | [`Bus::on_fan_out`] | [`Bus::parallel`] | yes | no |
//! | ordered | [`SerialEvent`] | [`Bus::on_serial`] | [`Bus::serial`] | yes | yes |
//!
//! Listeners always run outside the bus lock, so a listener may register or drop
//! effects while it runs without deadlocking or mutating the list underneath the
//! dispatch it is part of.

use std::any::{Any, TypeId};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use futures::future::BoxFuture;

use crate::effect::Effect;

/// An event whose listeners only watch. Registration order, no return value, and the
/// caller is not made to wait.
pub trait ObserveEvent: 'static {
    const NAME: &'static str;
    type Payload: Send + Sync + 'static;
}

/// An around-middleware event. Each listener receives the request and a [`Next`]:
/// call `next.run(request)` to delegate (optionally transforming the result on the
/// way back), or return without calling it to short-circuit and own the decision.
pub trait AroundEvent: 'static {
    const NAME: &'static str;
    type Request: Send + Sync + 'static;
    type Output: Send + Sync + 'static;
}

/// A fan-out event: every listener runs concurrently and the caller awaits them all.
pub trait FanOutEvent: 'static {
    const NAME: &'static str;
    type Payload: Send + Sync + 'static;
}

/// An ordered event with a return value: listeners are awaited in registration order
/// and the first one to answer wins.
pub trait SerialEvent: 'static {
    const NAME: &'static str;
    type Payload: Send + Sync + 'static;
    type Output: Send + Sync + 'static;
}

/// One link of an around chain: a listener that receives the request and the rest of
/// the chain behind it.
pub type AroundFn<E> = Arc<
    dyn Fn(&mut <E as AroundEvent>::Request, Next<'_, E>) -> <E as AroundEvent>::Output
        + Send
        + Sync,
>;

/// The remainder of an around chain.
pub struct Next<'a, E: AroundEvent> {
    rest: &'a [AroundFn<E>],
    terminal: &'a dyn Fn(&mut E::Request) -> E::Output,
}

impl<'a, E: AroundEvent> Next<'a, E> {
    /// Delegate to the next listener, or to the dispatch site's terminal behaviour if
    /// this was the last one.
    pub fn run(self, request: &mut E::Request) -> E::Output {
        match self.rest.split_first() {
            Some((head, tail)) => head(
                request,
                Next {
                    rest: tail,
                    terminal: self.terminal,
                },
            ),
            None => (self.terminal)(request),
        }
    }

    /// How many listeners are still ahead of the terminal behaviour.
    pub fn remaining(&self) -> usize {
        self.rest.len()
    }
}

type ObserveFn<E> = Arc<dyn Fn(&<E as ObserveEvent>::Payload) + Send + Sync>;
type FanOutFn<E> =
    Arc<dyn Fn(Arc<<E as FanOutEvent>::Payload>) -> BoxFuture<'static, ()> + Send + Sync>;
type SerialFn<E> = Arc<
    dyn Fn(
            Arc<<E as SerialEvent>::Payload>,
        ) -> BoxFuture<'static, Option<<E as SerialEvent>::Output>>
        + Send
        + Sync,
>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DispatchMode {
    Observe,
    Around,
    FanOut,
    Serial,
}

impl DispatchMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Observe => "observe",
            Self::Around => "around",
            Self::FanOut => "fan-out",
            Self::Serial => "ordered",
        }
    }
}

struct Listener {
    seq: u64,
    label: String,
    boxed: Box<dyn Any + Send + Sync>,
}

struct EventSlot {
    name: &'static str,
    mode: DispatchMode,
    listeners: Vec<Listener>,
}

#[derive(Default)]
struct Inner {
    events: BTreeMap<TypeId, EventSlot>,
    shutdown: bool,
}

/// One row of `dump-config`'s listener table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventRow {
    pub name: &'static str,
    pub mode: DispatchMode,
    pub listeners: Vec<String>,
}

/// Clone-cheap handle to the shared bus.
#[derive(Clone, Default)]
pub struct Bus {
    inner: Arc<Mutex<Inner>>,
}

static SEQ: AtomicU64 = AtomicU64::new(1);

impl Bus {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on<E, F>(&self, label: &str, listener: F) -> Effect
    where
        E: ObserveEvent,
        F: Fn(&E::Payload) + Send + Sync + 'static,
    {
        let f: ObserveFn<E> = Arc::new(listener);
        self.insert::<E>(E::NAME, DispatchMode::Observe, label, Box::new(f))
    }

    pub fn around<E, F>(&self, label: &str, listener: F) -> Effect
    where
        E: AroundEvent,
        F: Fn(&mut E::Request, Next<'_, E>) -> E::Output + Send + Sync + 'static,
    {
        let f: AroundFn<E> = Arc::new(listener);
        self.insert::<E>(E::NAME, DispatchMode::Around, label, Box::new(f))
    }

    pub fn on_fan_out<E, F>(&self, label: &str, listener: F) -> Effect
    where
        E: FanOutEvent,
        F: Fn(Arc<E::Payload>) -> BoxFuture<'static, ()> + Send + Sync + 'static,
    {
        let f: FanOutFn<E> = Arc::new(listener);
        self.insert::<E>(E::NAME, DispatchMode::FanOut, label, Box::new(f))
    }

    pub fn on_serial<E, F>(&self, label: &str, listener: F) -> Effect
    where
        E: SerialEvent,
        F: Fn(Arc<E::Payload>) -> BoxFuture<'static, Option<E::Output>> + Send + Sync + 'static,
    {
        let f: SerialFn<E> = Arc::new(listener);
        self.insert::<E>(E::NAME, DispatchMode::Serial, label, Box::new(f))
    }

    /// Observe dispatch: every listener sees the payload, in registration order.
    pub fn emit<E: ObserveEvent>(&self, payload: &E::Payload) {
        for listener in self.snapshot::<E, ObserveFn<E>>() {
            listener(payload);
        }
    }

    /// Around dispatch. `terminal` is what happens when every listener delegates.
    pub fn waterfall<E: AroundEvent>(
        &self,
        request: &mut E::Request,
        terminal: impl Fn(&mut E::Request) -> E::Output,
    ) -> E::Output {
        let chain = self.snapshot::<E, AroundFn<E>>();
        Next::<E> {
            rest: &chain,
            terminal: &terminal,
        }
        .run(request)
    }

    /// Fan-out dispatch: all listeners run concurrently, the caller awaits them all.
    pub async fn parallel<E: FanOutEvent>(&self, payload: E::Payload) {
        let listeners = self.snapshot::<E, FanOutFn<E>>();
        if listeners.is_empty() {
            return;
        }
        let payload = Arc::new(payload);
        let futures = listeners
            .into_iter()
            .map(|l| l(Arc::clone(&payload)))
            .collect::<Vec<_>>();
        futures::future::join_all(futures).await;
    }

    /// Ordered dispatch with a return value: awaited in registration order, and the
    /// first listener to answer `Some` short-circuits the rest.
    pub async fn serial<E: SerialEvent>(&self, payload: E::Payload) -> Option<E::Output> {
        let listeners = self.snapshot::<E, SerialFn<E>>();
        let payload = Arc::new(payload);
        for listener in listeners {
            if let Some(out) = listener(Arc::clone(&payload)).await {
                return Some(out);
            }
        }
        None
    }

    /// Registered listener labels for one event, in registration order.
    pub fn listeners_of<E: 'static>(&self) -> Vec<String> {
        self.lock()
            .events
            .get(&TypeId::of::<E>())
            .map(|slot| slot.listeners.iter().map(|l| l.label.clone()).collect())
            .unwrap_or_default()
    }

    /// Every event the daemon has ever registered a listener for, sorted by name so
    /// `dump-config` is stable across runs (`TypeId` ordering is not).
    pub fn rows(&self) -> Vec<EventRow> {
        let mut rows: Vec<EventRow> = self
            .lock()
            .events
            .values()
            .map(|slot| EventRow {
                name: slot.name,
                mode: slot.mode,
                listeners: slot.listeners.iter().map(|l| l.label.clone()).collect(),
            })
            .collect();
        rows.sort_by(|a, b| a.name.cmp(b.name));
        rows
    }

    /// Drop every listener and refuse further registration. Guards dropped afterwards
    /// are no-ops.
    pub fn shutdown(&self) {
        let mut inner = self.lock();
        inner.shutdown = true;
        inner.events.clear();
    }

    fn insert<E: 'static>(
        &self,
        name: &'static str,
        mode: DispatchMode,
        label: &str,
        boxed: Box<dyn Any + Send + Sync>,
    ) -> Effect {
        let key = TypeId::of::<E>();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        {
            let mut inner = self.lock();
            if inner.shutdown {
                return Effect::inert(format!("{name}:{label}"));
            }
            inner
                .events
                .entry(key)
                .or_insert_with(|| EventSlot {
                    name,
                    mode,
                    listeners: Vec::new(),
                })
                .listeners
                .push(Listener {
                    seq,
                    label: label.to_string(),
                    boxed,
                });
        }
        let weak: Weak<Mutex<Inner>> = Arc::downgrade(&self.inner);
        Effect::new(format!("{name}:{label}"), move || {
            if let Some(inner) = weak.upgrade() {
                if let Ok(mut inner) = inner.lock() {
                    // The event row itself stays even when the last listener leaves:
                    // its dispatch mode is a fact about the daemon, not about who
                    // happens to be listening, and dump-config should still show it.
                    if let Some(slot) = inner.events.get_mut(&key) {
                        slot.listeners.retain(|l| l.seq != seq);
                    }
                }
            }
        })
    }

    /// Clone the listener list out from under the lock, so listeners can touch the
    /// bus while they run.
    fn snapshot<E: 'static, F: Clone + 'static>(&self) -> Vec<F> {
        self.lock()
            .events
            .get(&TypeId::of::<E>())
            .map(|slot| {
                slot.listeners
                    .iter()
                    .filter_map(|l| l.boxed.downcast_ref::<F>().cloned())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    struct Ping;
    impl ObserveEvent for Ping {
        const NAME: &'static str = "test.ping";
        type Payload = u32;
    }

    struct Decide;
    impl AroundEvent for Decide {
        const NAME: &'static str = "test.decide";
        type Request = Vec<&'static str>;
        type Output = String;
    }

    struct Spread;
    impl FanOutEvent for Spread {
        const NAME: &'static str = "test.spread";
        type Payload = u32;
    }

    struct Ask;
    impl SerialEvent for Ask {
        const NAME: &'static str = "test.ask";
        type Payload = &'static str;
        type Output = String;
    }

    #[test]
    fn observe_reaches_every_listener_in_registration_order() {
        let bus = Bus::new();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let a = Arc::clone(&seen);
        let b = Arc::clone(&seen);
        let _first = bus.on::<Ping, _>("first", move |n| a.lock().unwrap().push(("first", *n)));
        let _second = bus.on::<Ping, _>("second", move |n| b.lock().unwrap().push(("second", *n)));
        bus.emit::<Ping>(&7);
        assert_eq!(*seen.lock().unwrap(), [("first", 7), ("second", 7)]);
        assert_eq!(bus.listeners_of::<Ping>(), ["first", "second"]);
    }

    #[test]
    fn dropping_a_listener_guard_removes_only_that_listener() {
        let bus = Bus::new();
        let hits = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&hits);
        let first = bus.on::<Ping, _>("first", move |_| {
            counted.fetch_add(1, Ordering::Relaxed);
        });
        let _second = bus.on::<Ping, _>("second", |_| {});
        drop(first);
        bus.emit::<Ping>(&1);
        assert_eq!(hits.load(Ordering::Relaxed), 0);
        assert_eq!(bus.listeners_of::<Ping>(), ["second"]);
    }

    #[test]
    fn around_delegates_through_the_chain_to_the_terminal() {
        let bus = Bus::new();
        let _outer = bus.around::<Decide, _>("outer", |req, next| {
            req.push("outer-in");
            let out = next.run(req);
            req.push("outer-out");
            format!("[{out}]")
        });
        let _inner = bus.around::<Decide, _>("inner", |req, next| {
            req.push("inner");
            next.run(req)
        });
        let mut trail = Vec::new();
        let out = bus.waterfall::<Decide>(&mut trail, |req| {
            req.push("terminal");
            "done".to_string()
        });
        assert_eq!(out, "[done]");
        assert_eq!(trail, ["outer-in", "inner", "terminal", "outer-out"]);
    }

    #[test]
    fn around_short_circuits_when_a_listener_owns_the_decision() {
        let bus = Bus::new();
        let _policy = bus.around::<Decide, _>("policy", |req, _next| {
            req.push("policy");
            "refused".to_string()
        });
        let _never = bus.around::<Decide, _>("never", |req, next| {
            req.push("never");
            next.run(req)
        });
        let mut trail = Vec::new();
        let out = bus.waterfall::<Decide>(&mut trail, |_| "delivered".to_string());
        assert_eq!(out, "refused");
        assert_eq!(trail, ["policy"], "downstream listeners must not run");
    }

    #[test]
    fn around_with_no_listeners_is_just_the_terminal() {
        let bus = Bus::new();
        let mut trail = Vec::new();
        assert_eq!(
            bus.waterfall::<Decide>(&mut trail, |_| "raw".to_string()),
            "raw"
        );
    }

    #[tokio::test]
    async fn fan_out_runs_listeners_concurrently() {
        let bus = Bus::new();
        // Each listener waits on the other at the barrier. Only a genuinely parallel
        // dispatch gets past it; a sequential one would never release the first.
        let gate = Arc::new(tokio::sync::Barrier::new(2));
        let done = Arc::new(AtomicUsize::new(0));
        for label in ["left", "right"] {
            let gate = Arc::clone(&gate);
            let done = Arc::clone(&done);
            std::mem::forget(bus.on_fan_out::<Spread, _>(label, move |_| {
                let gate = Arc::clone(&gate);
                let done = Arc::clone(&done);
                Box::pin(async move {
                    gate.wait().await;
                    done.fetch_add(1, Ordering::Relaxed);
                })
            }));
        }
        bus.parallel::<Spread>(1).await;
        assert_eq!(done.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn ordered_dispatch_stops_at_the_first_answer() {
        let bus = Bus::new();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let first = Arc::clone(&calls);
        let _override = bus.on_serial::<Ask, _>("override", move |_| {
            let first = Arc::clone(&first);
            Box::pin(async move {
                first.lock().unwrap().push("override");
                None
            })
        });
        let second = Arc::clone(&calls);
        let _lookup = bus.on_serial::<Ask, _>("lookup", move |q| {
            let second = Arc::clone(&second);
            Box::pin(async move {
                second.lock().unwrap().push("lookup");
                Some(format!("/usr/bin/{q}"))
            })
        });
        let third = Arc::clone(&calls);
        let _never = bus.on_serial::<Ask, _>("never", move |_| {
            let third = Arc::clone(&third);
            Box::pin(async move {
                third.lock().unwrap().push("never");
                Some("wrong".to_string())
            })
        });
        assert_eq!(
            bus.serial::<Ask>("claude").await.as_deref(),
            Some("/usr/bin/claude")
        );
        assert_eq!(*calls.lock().unwrap(), ["override", "lookup"]);
    }

    #[tokio::test]
    async fn ordered_dispatch_with_no_answer_returns_none() {
        let bus = Bus::new();
        let _shrug = bus.on_serial::<Ask, _>("shrug", |_| Box::pin(async move { None }));
        assert_eq!(bus.serial::<Ask>("codex").await, None);
    }

    #[test]
    fn rows_are_sorted_by_event_name_and_carry_the_mode() {
        let bus = Bus::new();
        let _p = bus.on::<Ping, _>("p", |_| {});
        let _d = bus.around::<Decide, _>("d", |req, next| next.run(req));
        let rows = bus.rows();
        assert_eq!(
            rows.iter().map(|r| r.name).collect::<Vec<_>>(),
            ["test.decide", "test.ping"]
        );
        assert_eq!(rows[0].mode, DispatchMode::Around);
        assert_eq!(rows[1].mode, DispatchMode::Observe);
    }

    #[test]
    fn a_listener_may_register_another_while_it_runs() {
        let bus = Bus::new();
        let inner = bus.clone();
        let added = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&added);
        let _outer = bus.on::<Ping, _>("outer", move |_| {
            let sink = Arc::clone(&sink);
            // Would deadlock if dispatch held the bus lock across listener calls.
            std::mem::forget(inner.on::<Ping, _>("late", move |n| sink.lock().unwrap().push(*n)));
        });
        bus.emit::<Ping>(&1);
        assert!(
            added.lock().unwrap().is_empty(),
            "late listener joins next dispatch"
        );
        bus.emit::<Ping>(&2);
        assert_eq!(added.lock().unwrap().len(), 1);
    }

    #[test]
    fn dropping_a_guard_after_shutdown_is_a_no_op() {
        let bus = Bus::new();
        let guard = bus.on::<Ping, _>("first", |_| {});
        bus.shutdown();
        drop(guard);
        assert!(bus.rows().is_empty());
        let late = bus.on::<Ping, _>("late", |_| {});
        assert!(!late.is_live());
        assert!(bus.listeners_of::<Ping>().is_empty());
    }
}
