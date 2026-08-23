//! The two rows the state layer adds to the entry list.
//!
//! `sqlite-store` claims `store`; `session-registry` claims `sessions` and declares
//! `pty`, `terminal` and `store` in `inject`, so load order is a fact the loader
//! derives rather than an order this file has to get right. Put the registry row
//! first in the list and it simply stays PENDING until its providers exist, which is
//! the property the loader was built for.

use std::sync::Arc;

use juancoded_cordis::plugin::{Context, Plugin};
use juancoded_cordis::services::pty::PtySpawnService;
use juancoded_cordis::services::terminal::TerminalService;
use juancoded_cordis::{Entry, EntryList, Loader};
use juancoded_persistence::{SessionStore, SqliteStore};

use crate::registry::{RegistryConfig, SessionRegistry};
use crate::service::{SessionsService, StoreService};

/// Claims the `store` key with a real SQLite file. `config.path` overrides where it
/// lives; `:memory:` gives a store that dies with the process, which is what a test
/// wants and what production must never get by accident.
pub struct SqliteStorePlugin;

impl Plugin for SqliteStorePlugin {
    fn name(&self) -> &'static str {
        "sqlite-store"
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let path = ctx.config().get("path").and_then(|v| v.as_str());
        let store: Arc<dyn SessionStore> = match path {
            Some(":memory:") => Arc::new(SqliteStore::in_memory()?),
            Some(path) => Arc::new(SqliteStore::open(path)?),
            None => Arc::new(SqliteStore::open_default()?),
        };
        ctx.provide::<StoreService>(store)?;
        Ok(())
    }
}

/// Claims the `sessions` key with the real registry, over the pty, grid and store
/// services it resolves by key.
pub struct SessionRegistryPlugin;

impl Plugin for SessionRegistryPlugin {
    fn name(&self) -> &'static str {
        "session-registry"
    }

    fn inject(&self) -> &'static [&'static str] {
        &["pty", "store", "terminal"]
    }

    fn apply(&self, ctx: &Context) -> anyhow::Result<()> {
        let pty = ctx.resolve::<PtySpawnService>()?;
        let terminal = ctx.resolve::<TerminalService>()?;
        let store = ctx.resolve::<StoreService>()?;

        let mut config = RegistryConfig::default();
        if let Some(cap) = ctx.config().get("scrollback").and_then(|v| v.as_u64()) {
            config.scrollback_cap = cap as usize;
        }
        if let Some(keep) = ctx.config().get("retention").and_then(|v| v.as_u64()) {
            config.retention = keep as usize;
        }
        if let (Some(cols), Some(rows)) = (
            ctx.config().get("cols").and_then(|v| v.as_u64()),
            ctx.config().get("rows").and_then(|v| v.as_u64()),
        ) {
            config.default_grid = (cols as u16, rows as u16);
        }
        // A test tree points every provider at one program (`/bin/cat`) so it needs
        // no CLI installed. Production leaves it unset and resolves from PATH.
        if let Some(program) = ctx.config().get("program").and_then(|v| v.as_str()) {
            let args = ctx
                .config()
                .get("args")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            config.program_override = Some((program.to_string(), args));
            // A stand-in program means there is no real CLI here, so nothing will
            // ever write a rollout file or a session row for this session to find.
            config.discover_id = None;
        }

        let registry = SessionRegistry::new(pty, terminal, store, ctx.bus().clone(), config);
        ctx.provide::<SessionsService>(Arc::new(registry))?;
        Ok(())
    }
}

/// Register the state layer's plugins with a loader that already knows the cordis
/// built-ins. Registering does not mount: the entry list decides what runs.
pub fn register(loader: &mut Loader) {
    loader
        .register(Arc::new(SqliteStorePlugin))
        .register(Arc::new(SessionRegistryPlugin));
}

/// The daemon's tree: the cordis built-ins plus the state layer.
///
/// `session-registry` is listed **before** the services it needs, on purpose: the
/// loader settles by dependency rather than by position, and a tree that only works
/// in one order is a tree whose order someone has to maintain.
pub fn default_entries() -> EntryList {
    EntryList::new()
        .push(Entry::new("sessions", "session-registry"))
        .push(Entry::new("terminal", "vt-terminal"))
        .push(Entry::new("pty", "core-pty"))
        .push(Entry::new("input-guard", "input-guard"))
        .push(Entry::new("pty-to-grid", "pty-to-grid"))
        .push(Entry::new("store", "sqlite-store"))
        .push(Entry::new("activity-log", "activity-log"))
        .push(Entry::new("session-chrome", "session-chrome"))
}
