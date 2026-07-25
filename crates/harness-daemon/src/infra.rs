pub mod exec {
    use std::sync::LazyLock;

    use tokio::runtime::{Builder, Runtime};

    pub(crate) static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
        Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to initialize tokio runtime")
    });
}

pub use harness_kernel::io;

#[path = "../../../src/infra/persistence/mod.rs"]
pub mod persistence;
