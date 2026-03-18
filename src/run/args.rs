use std::path::PathBuf;

use clap::Args;

/// Run-directory resolution arguments shared by many commands.
#[derive(Debug, Clone, Args)]
pub struct RunDirArgs {
    /// Run directory path.
    #[arg(long)]
    pub run_dir: Option<PathBuf>,
    /// Run ID to resolve from session context.
    #[arg(long)]
    pub run_id: Option<String>,
    /// Parent directory containing run directories.
    #[arg(long)]
    pub run_root: Option<PathBuf>,
}
