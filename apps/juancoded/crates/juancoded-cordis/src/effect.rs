//! Reversible effects: the one idea in cordis that Rust expresses better than the
//! language it came from.
//!
//! In cordis a registration hands back a disposer and the author has to remember to
//! call it. Here it hands back a value whose `Drop` undoes the registration, so the
//! only way to keep a contribution alive is to keep its guard alive, and the only way
//! to leak one is to deliberately `std::mem::forget` it. `#[must_use]` closes the
//! last hole: ignoring the return value unregisters immediately, loudly, at compile
//! time.

/// The undo half of a registration. Runs at most once.
pub type Disposer = Box<dyn FnOnce() + Send>;

/// A live registration. Dropping it unregisters.
///
/// Disposers are written to tolerate a world that has moved on: they hold weak
/// references to the registry they came from, so dropping a guard after the registry
/// has been shut down (or freed) is a no-op rather than a panic.
#[must_use = "an effect is undone the moment its guard drops; bind it or hand it to a scope"]
pub struct Effect {
    label: String,
    disposer: Option<Disposer>,
}

impl Effect {
    pub fn new(label: impl Into<String>, disposer: impl FnOnce() + Send + 'static) -> Self {
        Self {
            label: label.into(),
            disposer: Some(Box::new(disposer)),
        }
    }

    /// An effect with nothing to undo. Useful when a registration is conditional and
    /// the caller still wants one uniform guard to hold.
    pub fn inert(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            disposer: None,
        }
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    /// Undo now instead of at end of scope. The guard is consumed, and the disposer
    /// is taken out of it, so the `Drop` that follows finds nothing left to run.
    pub fn dispose(mut self) {
        if let Some(d) = self.disposer.take() {
            d();
        }
    }

    /// True while this guard still owns an undo.
    pub fn is_live(&self) -> bool {
        self.disposer.is_some()
    }
}

impl Drop for Effect {
    fn drop(&mut self) {
        if let Some(d) = self.disposer.take() {
            d();
        }
    }
}

impl std::fmt::Debug for Effect {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Effect")
            .field("label", &self.label)
            .field("live", &self.disposer.is_some())
            .finish()
    }
}

/// A bag of effects that unwinds in reverse registration order.
///
/// `Vec`'s own drop glue runs front to back, which would tear a plugin down in the
/// order it was built. Popping instead mirrors how a Rust block drops its locals, so
/// a later registration that depends on an earlier one is always gone first.
#[must_use = "dropping the scope unwinds every effect in it"]
#[derive(Default)]
pub struct EffectScope {
    label: String,
    effects: Vec<Effect>,
}

impl EffectScope {
    pub fn new(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            effects: Vec::new(),
        }
    }

    pub fn push(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn len(&self) -> usize {
        self.effects.len()
    }

    pub fn is_empty(&self) -> bool {
        self.effects.is_empty()
    }

    /// Labels in registration order, for `dump-config`.
    pub fn labels(&self) -> Vec<&str> {
        self.effects.iter().map(|e| e.label()).collect()
    }

    /// Unwind everything now and leave the scope empty.
    pub fn unwind(&mut self) {
        while let Some(effect) = self.effects.pop() {
            drop(effect);
        }
    }
}

impl Drop for EffectScope {
    fn drop(&mut self) {
        self.unwind();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn recorder() -> (
        Arc<Mutex<Vec<&'static str>>>,
        impl Fn(&'static str) -> Effect,
    ) {
        let log: Arc<Mutex<Vec<&'static str>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&log);
        let make = move |name: &'static str| {
            let sink = Arc::clone(&sink);
            Effect::new(name, move || sink.lock().unwrap().push(name))
        };
        (log, make)
    }

    #[test]
    fn a_scope_unwinds_in_reverse_registration_order() {
        let (log, make) = recorder();
        {
            let mut scope = EffectScope::new("plugin");
            scope.push(make("first"));
            scope.push(make("second"));
            scope.push(make("third"));
            assert_eq!(scope.labels(), ["first", "second", "third"]);
        }
        assert_eq!(*log.lock().unwrap(), ["third", "second", "first"]);
    }

    #[test]
    fn bare_locals_unwind_in_reverse_too_because_the_language_says_so() {
        let (log, make) = recorder();
        {
            let _first = make("first");
            let _second = make("second");
        }
        assert_eq!(*log.lock().unwrap(), ["second", "first"]);
    }

    #[test]
    fn an_explicit_dispose_is_not_run_again_by_drop() {
        let (log, make) = recorder();
        let effect = make("once");
        effect.dispose();
        assert_eq!(*log.lock().unwrap(), ["once"], "dispose should have run");
        let (log2, make2) = recorder();
        let mut held = make2("held");
        assert!(held.is_live());
        // Emulate the double-drop shape: dispose through the same path Drop uses.
        if let Some(d) = held.disposer.take() {
            d();
        }
        drop(held);
        assert_eq!(*log2.lock().unwrap(), ["held"], "drop must not re-run it");
    }

    #[test]
    fn unwinding_a_scope_twice_is_harmless() {
        let (log, make) = recorder();
        let mut scope = EffectScope::new("plugin");
        scope.push(make("only"));
        scope.unwind();
        scope.unwind();
        drop(scope);
        assert_eq!(*log.lock().unwrap(), ["only"]);
    }
}
