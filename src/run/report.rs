mod markdown;
mod model;
mod verdict;

pub use model::{RunReport, RunReportFrontmatter};
pub use verdict::{GroupVerdict, Verdict};

#[cfg(test)]
mod tests;
