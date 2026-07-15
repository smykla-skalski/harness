use std::sync::LazyLock;

#[path = "../../../src/infra/blocks/error.rs"]
mod error;
#[path = "../../../src/infra/io/mod.rs"]
pub mod io;
#[path = "../../../src/infra/persistence/mod.rs"]
pub mod persistence;
#[path = "../../../src/infra/blocks/registry.rs"]
mod registry;

pub mod blocks {
    pub use super::registry::BlockRequirement;
}

pub mod exec {
    use super::LazyLock;

    pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build Harness hook runtime")
    });
}
