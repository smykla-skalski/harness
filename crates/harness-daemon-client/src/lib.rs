#![deny(unsafe_code)]

mod client;
mod locator;

pub use client::{ClientError, DaemonClient};
pub use locator::{discovery, state};
