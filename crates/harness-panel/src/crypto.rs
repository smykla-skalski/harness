//! The one place the panel settles which TLS backend it uses.

use rustls::crypto::{CryptoProvider, ring};

/// Install a process-wide crypto provider once.
///
/// `rustls` refuses to guess between providers, and the panel builds more than
/// one TLS client: the GitHub client and the daemon client. Whichever is built
/// first settles it for the process, so both call this before building.
/// Without it, building a client panics rather than failing, which is a poor
/// way to learn the backend was never chosen.
pub fn ensure_crypto_provider() {
    if CryptoProvider::get_default().is_none() {
        // An error means another thread won the race, which is the outcome this
        // function exists to reach.
        let _ = ring::default_provider().install_default();
    }
}
