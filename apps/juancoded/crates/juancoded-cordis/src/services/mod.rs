//! The service contracts the rest of the core resolves by key, plus the adapters that
//! mount the existing crates behind them.
//!
//! The contract is a trait and the key is a string; neither mentions
//! `alacritty_terminal` or `portable-pty`. That is the point: a consumer holds
//! `Arc<dyn TerminalApi>`, so replacing the implementation is a change at one mount
//! site, and a test can stand in a fake without touching a pty.

pub mod pty;
pub mod terminal;

pub use pty::{PtyHost, PtySpawnApi, PtySpawnService};
pub use terminal::{TerminalApi, TerminalService, VtTerminals};
