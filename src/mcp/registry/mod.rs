//! Client for the Harness Monitor in-app accessibility registry.
//!
//! The macOS app binds a Unix domain socket inside its app-group container
//! and speaks newline-delimited JSON. This module ports the Node.js
//! `RegistryClient` implementation to async Rust with tokio primitives.

mod client;
mod path;
mod types;

#[cfg(test)]
mod tests;

pub use client::{RegistryClient, RegistryError};
pub use path::{DEFAULT_APP_GROUP, SOCKET_FILENAME, default_socket_path};
pub use types::{
    ElementKind, GetElementResult, ListElementsResult, ListWindowsResult, Rect,
    RegistryElement, RegistryRequest, RegistryResponse, RegistryWindow,
};
