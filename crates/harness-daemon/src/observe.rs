// `#[path]`-included `src/daemon/` files reference `crate::observe::types`
// under this crate's own namespace too. `session::observe`'s own storage and
// classifier needs now go through `harness_session::observe` and
// `harness_observe::classifier` directly instead of this facade, since that
// module moved into `harness-session`.
pub(crate) use harness_observe::types;
