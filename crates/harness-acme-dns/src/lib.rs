//! ACME DNS-01 challenge automation: third-party DNS-provider plugins
//! (Aftermarket, Cloudflare, Route53, and a generic exec hook), the runner
//! that drives a chosen plugin through a present/cleanup cycle, and the
//! authoritative-DNS propagation check that follows a change.
//!
//! Extracted from `harness-daemon`'s `daemon::remote_acme_dns*` modules: this
//! layer is reached only by the daemon's ACME issuance/renewal code
//! (`remote_acme.rs`, `remote_acme_challenge.rs`), never by `db`, `service`,
//! HTTP, WebSocket, or task-board. `harness-daemon` depends on this crate,
//! not the other way around.
//!
//! `RemoteDnsProvider` moved here too, even though it originally lived in
//! `daemon::remote` alongside `RemoteRole`/`RemoteAcmeChallenge` and their
//! other small config enums: the DNS-01 runner and provider selector match on
//! it directly, so keeping it in `daemon::remote` would force this crate to
//! depend back on `harness-daemon`. `daemon::remote` now re-exports it under
//! the same path, so every other caller (`db`, `transport`,
//! `remote_acme_issuer.rs`) keeps compiling unchanged.

mod remote_acme_dns;
mod remote_acme_dns_provider;
mod remote_acme_dns_runner;

pub use remote_acme_dns::{
    CloudflareDns01ChangeRequest, Dns01ChangeOperation, Dns01ExecHookError,
    Dns01ExecHookInvocation, Dns01ExecHookOperation, Dns01ProviderChangeError, RemoteDnsProvider,
    Route53Dns01ChangeBatch,
};
pub use remote_acme_dns_provider::{SystemDns01Lease, SystemDns01Provider};
pub use remote_acme_dns_runner::{
    Dns01ProviderAction, Dns01ProviderChangeRunner, Dns01ProviderExecutionConfig,
    Dns01ProviderExecutionError,
};
