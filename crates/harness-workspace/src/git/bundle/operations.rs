use std::path::Path;
use std::process::Output;

use super::super::command::stdout;
use super::GitBundleImportPlan;
use crate::git::{GitError, GitResult};

impl GitBundleImportPlan {
    pub(super) fn require_direct_ref(&self, reference: &str) -> GitResult<()> {
        let output = self.git_probe(["symbolic-ref", "--quiet", reference])?;
        if output.status.success() {
            Err(GitError::unsafe_state(
                &self.worktree,
                format!("bundle import refuses symbolic ref {reference}"),
            ))
        } else {
            Ok(())
        }
    }

    pub(super) fn require_no_git_operation(&self) -> GitResult<()> {
        for marker in [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "BISECT_LOG",
            "rebase-apply",
            "rebase-merge",
            "sequencer",
        ] {
            let marker_path = stdout(&self.git_read([
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                marker,
            ])?);
            if Path::new(marker_path.trim()).exists() {
                return Err(GitError::unsafe_state(
                    &self.worktree,
                    "bundle import refuses an in-progress git operation",
                ));
            }
        }
        Ok(())
    }

    pub(super) fn attach_result_branch(&self) -> GitResult<()> {
        let transaction = format!(
            "start\noption no-deref\nverify {} {}\nsymref-update HEAD {} oid {}\nprepare\ncommit\n",
            self.branch_ref, self.result_revision, self.branch_ref, self.result_revision,
        );
        self.git_mutation_with_input(["update-ref", "--stdin"], transaction.as_bytes())?;
        Ok(())
    }

    pub(super) fn symbolic_head(&self) -> GitResult<Option<String>> {
        let output = self.git_probe(["symbolic-ref", "--quiet", "HEAD"])?;
        Ok(output.status.success().then(|| stdout(&output)))
    }

    pub(super) fn revision(&self, revision: &str) -> GitResult<String> {
        let output = self.git_contract(["rev-parse", "--verify", revision])?;
        Ok(stdout(&output))
    }

    pub(super) fn optional_revision(&self, revision: &str) -> GitResult<Option<String>> {
        let output = self.git_probe(["rev-parse", "--verify", "--quiet", revision])?;
        Ok(output.status.success().then(|| stdout(&output)))
    }

    pub(super) fn git_read<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.read(args)
    }

    pub(super) fn git_contract<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.contract(args)
    }

    pub(super) fn git_contract_bounded_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.coordinates
            .runner()?
            .contract_bounded_with_input(args, input, max_bytes)
    }

    pub(super) fn git_probe<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.probe(args)
    }

    pub(super) fn git_mutation<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.mutation(args)
    }

    pub(super) fn git_mutation_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
    ) -> GitResult<Output> {
        self.coordinates.runner()?.mutation_with_input(args, input)
    }
}
