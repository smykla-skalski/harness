#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DaemonHttpAuthMode {
    #[default]
    Local,
    Remote,
}
