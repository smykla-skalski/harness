use std::ffi::OsStr;
use std::process::ExitCode;

use clap::Parser;
use codex_arg0::arg0_dispatch_or_else;
use codex_utils_cli::CliConfigOverrides;

const PROBE_IDENTITY: &str = "harness-codex-acp";

fn main() -> ExitCode {
    if std::env::args_os().nth(1).as_deref() == Some(OsStr::new("--probe")) {
        println!("{PROBE_IDENTITY}");
        return ExitCode::SUCCESS;
    }

    match arg0_dispatch_or_else(|args| async move {
        let cli_config_overrides = CliConfigOverrides::parse();
        codex_acp::run_main(args.codex_linux_sandbox_exe, cli_config_overrides).await?;
        Ok(())
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
