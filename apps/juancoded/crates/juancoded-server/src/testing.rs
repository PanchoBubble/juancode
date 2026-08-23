//! A `sessions` handle for the tests in this crate: the real state layer over an
//! in-memory store and `/bin/cat` in place of a provider CLI, so nothing here needs
//! a database file or an installed agent.

use std::sync::Arc;

use juancoded_state::SessionsApi;

use crate::serve::CoreHandles;

pub fn handles() -> CoreHandles {
    let (loader, _, sessions) =
        juancoded_state::boot_with(&juancoded_state::test_entries("/bin/cat", &[]))
            .expect("the test tree mounts");
    let contributions = loader.contributions().clone();
    // The loader owns every mounted plugin's effects, so it has to outlive the handles
    // it vended; leaking it for the length of a test is cheaper than threading it
    // through every call site.
    std::mem::forget(loader);
    CoreHandles::new(sessions, contributions)
}

pub fn sessions() -> Arc<dyn SessionsApi> {
    handles().sessions
}
