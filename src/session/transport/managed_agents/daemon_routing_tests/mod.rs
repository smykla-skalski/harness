//! Managed-agent transport daemon-routing coverage.
//!
//! Every command here used to reach a typed method on the root
//! `daemon::client` facade. They now build their own request against the leaf
//! `harness-daemon-client`'s generic `get`/`post`/`delete`, so a mismatch
//! between a hand-written URL and the daemon's actual route (or a dropped
//! request field) would compile fine but silently break at runtime. These
//! tests stand up a fake running daemon via `install_fake_running_xdg_daemon`,
//! run each `Execute::execute()` end-to-end, and assert the exact HTTP method,
//! path, and JSON body sent. Split by command group so no file grows past the
//! repo's line-count guideline; `support` holds the shared fake-daemon
//! fixtures and snapshot builders every group file uses.

mod acp_sessions;
mod adopt;
mod codex;
mod managed_agents;
mod start;
mod support;
