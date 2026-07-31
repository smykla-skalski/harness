//! The `harness-panel` command-line surface, shared with the docs generator.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::config::{DEFAULT_LISTEN, PanelArgs};

/// Default unit name, matching the binary so the unit and its state directory
/// read the same in a status listing.
const DEFAULT_UNIT: &str = "harness-panel";

#[derive(Debug, Parser)]
#[command(
    name = "harness-panel",
    about = "Harness panel: GitHub sign-in and account roster",
    version
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Serve the panel.
    Serve(Box<PanelArgs>),
    /// Claim the daemon credential the panel mints with, once.
    ///
    /// Separate from `serve` because the code is one-time: left in a unit file
    /// it would be spent on the first start and refused on every restart.
    Pair {
        #[command(flatten)]
        args: Box<PanelArgs>,
        /// File holding the one-time pairing code. A file rather than a flag
        /// value, which any local process can read out of `/proc`.
        #[arg(long, env = "HARNESS_PANEL_DAEMON_PAIR_CODE_FILE")]
        code_file: PathBuf,
    },
    /// Print the hardened systemd service for review before it is installed.
    PrintUnit {
        #[command(flatten)]
        args: Box<PanelArgs>,
        /// Unit name, which also names the state directory.
        #[arg(long, default_value = DEFAULT_UNIT)]
        unit: String,
        /// Path the unit starts the panel from.
        #[arg(long, default_value = "/usr/local/bin/harness-panel")]
        binary_path: PathBuf,
    },
    /// Print the systemd socket that reserves the panel listener across
    /// service restarts.
    PrintSocketUnit {
        /// Address systemd owns and passes to the panel service.
        #[arg(long, default_value = DEFAULT_LISTEN)]
        listen: SocketAddr,
        /// Unit stem shared by the socket and service.
        #[arg(long, default_value = DEFAULT_UNIT)]
        unit: String,
    },
}
