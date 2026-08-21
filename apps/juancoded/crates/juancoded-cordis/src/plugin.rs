//! What a plugin is, and the context it is handed.
//!
//! A plugin is a value that declares the service keys it needs and gets one call to
//! `apply`. Everything it registers during that call is tracked in the context's
//! effect scope, so unmounting is "drop the context" and teardown order is the
//! language's problem rather than the author's.

use std::sync::{Arc, Mutex};

use futures::future::BoxFuture;

use crate::bus::{AroundEvent, Bus, FanOutEvent, Next, ObserveEvent, SerialEvent};
use crate::effect::{Effect, EffectScope};
use crate::service::{ResolveError, Service, ServiceRegistry, ServiceTaken};

/// A mounted plugin's lifecycle state, and the reason when it is not running.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FiberState {
    Active,
    /// Waiting on service keys nobody provides yet. A legitimate state, but never a
    /// silent one: see [`crate::loader::LoadReport`].
    Pending {
        missing: Vec<String>,
    },
    /// The entry says `disabled = true`.
    Disabled,
    /// `apply` returned an error, or the entry names a plugin nobody registered.
    Failed {
        error: String,
    },
}

impl FiberState {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Active => "ACTIVE",
            Self::Pending { .. } => "PENDING",
            Self::Disabled => "DISABLED",
            Self::Failed { .. } => "FAILED",
        }
    }

    pub fn is_active(&self) -> bool {
        matches!(self, Self::Active)
    }

    pub fn is_pending(&self) -> bool {
        matches!(self, Self::Pending { .. })
    }
}

/// What a plugin sees of the daemon: the services, the bus, and its own effect scope.
pub struct Context {
    id: String,
    config: serde_json::Value,
    services: ServiceRegistry,
    bus: Bus,
    scope: Mutex<EffectScope>,
}

impl Context {
    pub(crate) fn new(
        id: impl Into<String>,
        config: serde_json::Value,
        services: ServiceRegistry,
        bus: Bus,
    ) -> Self {
        let id = id.into();
        Self {
            scope: Mutex::new(EffectScope::new(id.clone())),
            id,
            config,
            services,
            bus,
        }
    }

    /// The entry id this plugin was mounted under. Also its `dump-config` address.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The entry's `config` value, verbatim.
    pub fn config(&self) -> &serde_json::Value {
        &self.config
    }

    pub fn services(&self) -> &ServiceRegistry {
        &self.services
    }

    pub fn bus(&self) -> &Bus {
        &self.bus
    }

    /// Hand an effect to this plugin's scope, so it is undone when the plugin unmounts.
    pub fn track(&self, effect: Effect) {
        self.lock().push(effect);
    }

    /// Register arbitrary teardown, tracked like any other effect.
    pub fn effect(&self, label: impl Into<String>, disposer: impl FnOnce() + Send + 'static) {
        self.track(Effect::new(label, disposer));
    }

    pub fn resolve<S: Service>(&self) -> Result<Arc<S::Api>, ResolveError> {
        self.services.resolve::<S>()
    }

    /// Claim a service key for as long as this plugin is mounted.
    pub fn provide<S: Service>(&self, api: Arc<S::Api>) -> Result<(), ServiceTaken> {
        let effect = self.services.provide::<S>(&self.id, api)?;
        self.track(effect);
        Ok(())
    }

    pub fn on<E, F>(&self, label: &str, listener: F)
    where
        E: ObserveEvent,
        F: Fn(&E::Payload) + Send + Sync + 'static,
    {
        self.track(self.bus.on::<E, F>(label, listener));
    }

    pub fn around<E, F>(&self, label: &str, listener: F)
    where
        E: AroundEvent,
        F: Fn(&mut E::Request, Next<'_, E>) -> E::Output + Send + Sync + 'static,
    {
        self.track(self.bus.around::<E, F>(label, listener));
    }

    pub fn on_fan_out<E, F>(&self, label: &str, listener: F)
    where
        E: FanOutEvent,
        F: Fn(Arc<E::Payload>) -> BoxFuture<'static, ()> + Send + Sync + 'static,
    {
        self.track(self.bus.on_fan_out::<E, F>(label, listener));
    }

    pub fn on_serial<E, F>(&self, label: &str, listener: F)
    where
        E: SerialEvent,
        F: Fn(Arc<E::Payload>) -> BoxFuture<'static, Option<E::Output>> + Send + Sync + 'static,
    {
        self.track(self.bus.on_serial::<E, F>(label, listener));
    }

    /// How many effects this plugin currently holds. `dump-config` prints it.
    pub fn effect_count(&self) -> usize {
        self.lock().len()
    }

    pub fn effect_labels(&self) -> Vec<String> {
        self.lock().labels().into_iter().map(String::from).collect()
    }

    /// Unwind every effect now, in reverse registration order.
    ///
    /// The loader calls this rather than relying on the last `Arc<Context>` going away,
    /// because a plugin is free to have cloned the context into a closure and an
    /// unmount must not depend on whether it did.
    pub fn dispose_all(&self) {
        self.lock().unwind();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, EffectScope> {
        self.scope.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        // Belt and braces: an unmount path that forgets `dispose_all` still unwinds.
        self.dispose_all();
    }
}

/// A unit of composition. Implementors are values, registered by name with the loader.
pub trait Plugin: Send + Sync + 'static {
    /// The name entries refer to. Unique across registered plugins.
    fn name(&self) -> &'static str;

    /// Service keys this plugin needs before it can be mounted. Until every one of
    /// them is claimed the plugin stays [`FiberState::Pending`].
    fn inject(&self) -> &'static [&'static str] {
        &[]
    }

    /// Called once per mount. Register through `ctx` so everything unwinds on unmount.
    fn apply(&self, ctx: &Context) -> anyhow::Result<()>;
}
