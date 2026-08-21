//! The keyed service registry.
//!
//! A service claims a stable string key. Consumers resolve by that key against a
//! contract trait, never by importing the implementation, so swapping the Swift-shaped
//! adapter for a real one is a one-line change at the mount site and invisible
//! everywhere else.
//!
//! The key is the identity and the `Api` associated type is the contract. Resolving a
//! key that holds a different contract is an error rather than a panic, because a key
//! collision between two crates is a config mistake and should read like one.

use std::any::{type_name, Any};
use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use crate::effect::Effect;

/// A service contract: a stable key plus the trait consumers program against.
///
/// The implementing type is a marker only. `Api` is normally `dyn SomeTrait`, which
/// is what keeps consumers off the concrete implementation.
pub trait Service: 'static {
    const KEY: &'static str;
    type Api: Send + Sync + ?Sized + 'static;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveError {
    Missing {
        key: &'static str,
    },
    TypeMismatch {
        key: &'static str,
        wanted: &'static str,
        found: &'static str,
    },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing { key } => write!(f, "no service claims the key `{key}`"),
            Self::TypeMismatch { key, wanted, found } => write!(
                f,
                "service `{key}` is a {found}, not a {wanted} (two contracts claim one key)"
            ),
        }
    }
}

impl std::error::Error for ResolveError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceTaken {
    pub key: &'static str,
    pub held_by: String,
}

impl fmt::Display for ServiceTaken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "service `{}` is already provided by `{}`",
            self.key, self.held_by
        )
    }
}

impl std::error::Error for ServiceTaken {}

struct Slot {
    /// Monotonic, so a stale guard cannot evict a service someone re-provided.
    seq: u64,
    api: &'static str,
    provider: String,
    value: Box<dyn Any + Send + Sync>,
}

#[derive(Default)]
struct Inner {
    slots: BTreeMap<&'static str, Slot>,
    shutdown: bool,
}

/// What is currently mounted under one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceRow {
    pub key: &'static str,
    pub api: &'static str,
    pub provider: String,
}

/// Clone-cheap handle to the shared registry.
#[derive(Clone, Default)]
pub struct ServiceRegistry {
    inner: Arc<Mutex<Inner>>,
}

static SEQ: AtomicU64 = AtomicU64::new(1);

impl ServiceRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Claim `S::KEY` for as long as the returned guard lives.
    pub fn provide<S: Service>(
        &self,
        provider: &str,
        api: Arc<S::Api>,
    ) -> Result<Effect, ServiceTaken> {
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        {
            let mut inner = self.lock();
            if inner.shutdown {
                return Ok(Effect::inert(format!("service:{}", S::KEY)));
            }
            if let Some(existing) = inner.slots.get(S::KEY) {
                return Err(ServiceTaken {
                    key: S::KEY,
                    held_by: existing.provider.clone(),
                });
            }
            inner.slots.insert(
                S::KEY,
                Slot {
                    seq,
                    api: type_name::<S::Api>(),
                    provider: provider.to_string(),
                    value: Box::new(api),
                },
            );
        }
        tracing::debug!(key = S::KEY, provider, "service provided");
        let weak: Weak<Mutex<Inner>> = Arc::downgrade(&self.inner);
        Ok(Effect::new(format!("service:{}", S::KEY), move || {
            // A dead registry, or a slot someone else has since re-provided, means
            // there is nothing of ours left to take back.
            if let Some(inner) = weak.upgrade() {
                if let Ok(mut inner) = inner.lock() {
                    if inner.slots.get(S::KEY).is_some_and(|s| s.seq == seq) {
                        inner.slots.remove(S::KEY);
                        tracing::debug!(key = S::KEY, "service withdrawn");
                    }
                }
            }
        }))
    }

    pub fn resolve<S: Service>(&self) -> Result<Arc<S::Api>, ResolveError> {
        let inner = self.lock();
        let slot = inner
            .slots
            .get(S::KEY)
            .ok_or(ResolveError::Missing { key: S::KEY })?;
        slot.value
            .downcast_ref::<Arc<S::Api>>()
            .cloned()
            .ok_or(ResolveError::TypeMismatch {
                key: S::KEY,
                wanted: type_name::<S::Api>(),
                found: slot.api,
            })
    }

    /// Is this key claimed? The loader gates plugin mounting on exactly this.
    pub fn has(&self, key: &str) -> bool {
        self.lock().slots.contains_key(key)
    }

    pub fn keys(&self) -> Vec<&'static str> {
        self.lock().slots.keys().copied().collect()
    }

    pub fn rows(&self) -> Vec<ServiceRow> {
        self.lock()
            .slots
            .iter()
            .map(|(key, slot)| ServiceRow {
                key,
                api: slot.api,
                provider: slot.provider.clone(),
            })
            .collect()
    }

    /// Withdraw everything and refuse further claims. Guards dropped afterwards find
    /// their slot gone and do nothing, which is what makes shutdown order a non-issue.
    pub fn shutdown(&self) {
        let mut inner = self.lock();
        inner.shutdown = true;
        inner.slots.clear();
    }

    pub fn is_shutdown(&self) -> bool {
        self.lock().shutdown
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        // A poisoned registry lock means a listener panicked mid-registration; the
        // map itself is still structurally sound, so keep serving rather than
        // taking the whole daemon down with it.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    trait Greeter: Send + Sync {
        fn greet(&self) -> String;
    }
    struct GreeterService;
    impl Service for GreeterService {
        const KEY: &'static str = "greeter";
        type Api = dyn Greeter;
    }
    struct Polite;
    impl Greeter for Polite {
        fn greet(&self) -> String {
            "hello".into()
        }
    }

    trait Counter: Send + Sync {
        fn count(&self) -> usize;
    }
    struct CounterService;
    impl Service for CounterService {
        const KEY: &'static str = "greeter";
        type Api = dyn Counter;
    }

    #[test]
    fn a_consumer_resolves_by_key_and_gets_the_contract() {
        let reg = ServiceRegistry::new();
        let _guard = reg
            .provide::<GreeterService>("polite", Arc::new(Polite))
            .unwrap();
        assert_eq!(reg.resolve::<GreeterService>().unwrap().greet(), "hello");
    }

    #[test]
    fn the_service_is_gone_when_its_guard_is() {
        let reg = ServiceRegistry::new();
        {
            let _guard = reg
                .provide::<GreeterService>("polite", Arc::new(Polite))
                .unwrap();
            assert!(reg.has("greeter"));
        }
        assert!(!reg.has("greeter"));
        assert!(matches!(
            reg.resolve::<GreeterService>(),
            Err(ResolveError::Missing { key: "greeter" })
        ));
    }

    #[test]
    fn two_contracts_cannot_share_one_key() {
        let reg = ServiceRegistry::new();
        let _guard = reg
            .provide::<GreeterService>("polite", Arc::new(Polite))
            .unwrap();
        let tally: Arc<dyn Counter> = Arc::new(Tally);
        assert_eq!(tally.count(), 0);
        let err = reg.provide::<CounterService>("tally", tally).unwrap_err();
        assert_eq!(err.held_by, "polite");
    }
    struct Tally;
    impl Counter for Tally {
        fn count(&self) -> usize {
            0
        }
    }

    #[test]
    fn resolving_a_key_with_the_wrong_contract_is_an_error_not_a_panic() {
        let reg = ServiceRegistry::new();
        let _guard = reg
            .provide::<GreeterService>("polite", Arc::new(Polite))
            .unwrap();
        match reg.resolve::<CounterService>() {
            Err(ResolveError::TypeMismatch { key, .. }) => assert_eq!(key, "greeter"),
            Err(other) => panic!("expected a type mismatch, got {other:?}"),
            Ok(_) => panic!("expected a type mismatch, got a service"),
        }
    }

    #[test]
    fn a_stale_guard_does_not_evict_a_re_provided_service() {
        let reg = ServiceRegistry::new();
        let first = reg
            .provide::<GreeterService>("first", Arc::new(Polite))
            .unwrap();
        drop(first);
        let _second = reg
            .provide::<GreeterService>("second", Arc::new(Polite))
            .unwrap();
        // The dropped guard already ran; the live one must still hold the key.
        assert_eq!(reg.rows()[0].provider, "second");
    }

    #[test]
    fn dropping_a_guard_after_shutdown_is_a_no_op() {
        let reg = ServiceRegistry::new();
        let guard = reg
            .provide::<GreeterService>("polite", Arc::new(Polite))
            .unwrap();
        reg.shutdown();
        drop(guard);
        assert!(reg.keys().is_empty());
        // And a claim after shutdown yields an inert guard rather than a live slot.
        let late = reg
            .provide::<GreeterService>("late", Arc::new(Polite))
            .unwrap();
        assert!(!late.is_live());
        assert!(!reg.has("greeter"));
    }

    #[test]
    fn dropping_a_guard_after_the_registry_is_freed_is_a_no_op() {
        let reg = ServiceRegistry::new();
        let guard = reg
            .provide::<GreeterService>("polite", Arc::new(Polite))
            .unwrap();
        drop(reg);
        drop(guard);
    }
}
