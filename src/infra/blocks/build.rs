#[path = "build/contract.rs"]
mod contract;
#[cfg(test)]
#[path = "build/fake.rs"]
mod fake;
#[path = "build/runtime.rs"]
mod runtime;

pub use contract::{BuildSystem, BuildTarget};
pub use runtime::ProcessBuildSystem;

#[cfg(test)]
pub use fake::FakeBuildSystem;

#[cfg(test)]
#[path = "build/tests.rs"]
mod tests;
