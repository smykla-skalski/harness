use std::path::Path;

#[derive(Debug, Clone)]
pub struct RecordCommandRequest<'a> {
    pub phase: Option<&'a str>,
    pub label: Option<&'a str>,
    pub gid: Option<&'a str>,
    pub cluster: Option<&'a str>,
    pub command_args: &'a [String],
    pub run_dir: Option<&'a Path>,
}
