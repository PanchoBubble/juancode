//! The wire layer: the existing juancode WebSocket protocol, served by axum.
//!
//! Nothing new is invented here. `WireProtocol.swift` is the contract, and its TS
//! mirror (`apps/oracle-mcp/src/native-events.ts`) is the other consumer, so this
//! crate is a translation, not a redesign. That is the whole reason the Rust core
//! needs no FFI: the boundary the Swift app would talk over already exists and
//! remote clients already use it.

pub mod conn;
pub mod identity;
pub mod owner;
pub mod queue_delivery;
pub mod screen;
pub mod seed;
pub mod serve;
pub mod utf8;
pub mod wire;

#[cfg(test)]
mod testing;

pub use identity::DaemonIdentity;
pub use owner::{Orphaned, Ownership, Watchdog};
pub use serve::{serve, CoreHandles, ServeConfig};
pub use wire::{ClientMessage, ServerMessage, CAPABILITIES, PROTOCOL_VERSION};
