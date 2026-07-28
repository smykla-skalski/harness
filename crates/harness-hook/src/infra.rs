use std::sync::LazyLock;

pub use harness_kernel::io;
pub use harness_infra::persistence;

pub mod blocks {
    pub use harness_infra::blocks::all_denied_binaries;
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
