//! The wire layer: the existing juancode WebSocket protocol, served by axum.
//!
//! Nothing new is invented here. `WireProtocol.swift` is the contract, and its TS
//! mirror (`apps/oracle-mcp/src/native-events.ts`) is the other consumer, so this
//! crate is a translation, not a redesign. That is the whole reason the Rust core
//! needs no FFI: the boundary the Swift app would talk over already exists and
//! remote clients already use it.

pub mod conn;
pub mod screen;
pub mod serve;
pub mod utf8;
pub mod wire;

pub use serve::{serve, ServeConfig};
pub use wire::{ClientMessage, ServerMessage, CAPABILITIES, PROTOCOL_VERSION};
