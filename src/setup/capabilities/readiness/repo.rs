use std::path::Path;

use fs_err as fs;

use crate::setup::capabilities::model::{ReadinessCheck, ReadinessCheckScope};

use super::checks::{fail, pass, skipped};

pub(super) fn check_repo_root_resolved(repo_root: Option<&Path>) -> ReadinessCheck {
    if let Some(root) = repo_root {
        pass(
            "repo_root_resolved",
            ReadinessCheckScope::Repo,
            "Kuma repository root is resolved.",
            Some(root),
            None,
        )
    } else {
        fail(
            "repo_root_resolved",
            ReadinessCheckScope::Repo,
            "Kuma repository root is not resolved.",
            None,
            Some("Run from a Kuma checkout or pass `--repo-root`."),
        )
    }
}

pub(super) fn check_repo_root_exists(repo_root: Option<&Path>) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Repository path check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if root.is_dir() {
        pass(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Resolved repository root exists.",
            Some(root),
            None,
        )
    } else {
        fail(
            "repo_root_exists",
            ReadinessCheckScope::Repo,
            "Resolved repository root does not exist.",
            Some(root),
            Some("Verify the repo path or pass the correct `--repo-root`."),
        )
    }
}

pub(super) fn check_repo_is_kuma_checkout(
    repo_root: Option<&Path>,
    repo_exists: bool,
) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Kuma checkout check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_exists {
        return skipped(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Kuma checkout check skipped because the repo root path is missing.",
            Some(root),
            Some("Fix the repo root path first."),
        );
    }

    let go_mod = root.join("go.mod");
    match fs::read_to_string(&go_mod) {
        Ok(text) if text.contains("github.com/kumahq/kuma") => pass(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Repository root is a Kuma checkout.",
            Some(&go_mod),
            None,
        ),
        Ok(_) => fail(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            "Repository root is not a Kuma checkout.",
            Some(&go_mod),
            Some("Point `--repo-root` at a `github.com/kumahq/kuma` checkout."),
        ),
        Err(error) => fail(
            "repo_is_kuma_checkout",
            ReadinessCheckScope::Repo,
            format!("Repository checkout cannot be verified: {error}"),
            Some(&go_mod),
            Some("Ensure the repo root contains a readable `go.mod`."),
        ),
    }
}

pub(super) fn check_repo_make_contract(
    repo_root: Option<&Path>,
    repo_is_kuma: bool,
) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_is_kuma {
        return skipped(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract check skipped because the repo root is not a verified Kuma checkout.",
            Some(root),
            Some("Use a current Kuma checkout before attempting cluster setup."),
        );
    }

    let k3d_makefile_path = root.join("mk").join("k3d.mk");
    let k8s_makefile_path = root.join("mk").join("k8s.mk");
    let expected_targets = [
        "k3d/cluster/start:",
        "k3d/cluster/deploy/helm:",
        "k3d/cluster/stop:",
    ];

    if !k3d_makefile_path.is_file() {
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract is missing `mk/k3d.mk`.",
            Some(&k3d_makefile_path),
            Some("Update the Kuma checkout to the current local-cluster Make contract."),
        );
    }
    if !k8s_makefile_path.is_file() {
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            "Kuma Make contract is missing `mk/k8s.mk`.",
            Some(&k8s_makefile_path),
            Some("Update the Kuma checkout to the current local-cluster Make contract."),
        );
    }

    let cluster_targets_source = match fs::read_to_string(&k3d_makefile_path) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_make_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/k3d.mk`: {error}"),
                Some(&k3d_makefile_path),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };
    let cluster_variable_source = match fs::read_to_string(&k8s_makefile_path) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_make_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/k8s.mk`: {error}"),
                Some(&k8s_makefile_path),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };

    let missing_targets = expected_targets
        .iter()
        .copied()
        .filter(|needle| !cluster_targets_source.contains(needle))
        .collect::<Vec<_>>();
    if !missing_targets.is_empty() || !cluster_variable_source.contains("CLUSTER ?=") {
        let summary = if missing_targets.is_empty() {
            "Kuma Make contract is missing the canonical `CLUSTER` variable in `mk/k8s.mk`."
                .to_string()
        } else {
            format!(
                "Kuma Make contract is missing canonical k3d targets: {}.",
                missing_targets.join(", ")
            )
        };
        return fail(
            "repo_make_contract_present",
            ReadinessCheckScope::Repo,
            summary,
            Some(root),
            Some("Update the Kuma checkout to the current `k3d/cluster/*` contract."),
        );
    }

    pass(
        "repo_make_contract_present",
        ReadinessCheckScope::Repo,
        "Kuma Make contract matches the current `k3d/cluster/*` layout.",
        Some(root),
        None,
    )
}

pub(super) fn check_repo_remote_publish_contract(
    repo_root: Option<&Path>,
    repo_is_kuma: bool,
) -> ReadinessCheck {
    let Some(root) = repo_root else {
        return skipped(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract check skipped because the repo root is not resolved.",
            None,
            Some("Resolve the repo root first."),
        );
    };

    if !repo_is_kuma {
        return skipped(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract check skipped because the repo root is not a verified Kuma checkout.",
            Some(root),
            Some("Use a current Kuma checkout before attempting remote setup."),
        );
    }

    let docker_makefile = root.join("mk").join("docker.mk");
    if !docker_makefile.is_file() {
        return fail(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            "Remote publish contract is missing `mk/docker.mk`.",
            Some(&docker_makefile),
            Some("Update the Kuma checkout to the current image publish contract."),
        );
    }

    let text = match fs::read_to_string(&docker_makefile) {
        Ok(text) => text,
        Err(error) => {
            return fail(
                "repo_remote_publish_contract_present",
                ReadinessCheckScope::Repo,
                format!("Unable to read `mk/docker.mk`: {error}"),
                Some(&docker_makefile),
                Some("Ensure the Kuma Make files are readable."),
            );
        }
    };

    let required = ["images/release:", "docker/push:", "manifests/json/release:"];
    let missing = required
        .iter()
        .copied()
        .filter(|needle| !text.contains(needle))
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return fail(
            "repo_remote_publish_contract_present",
            ReadinessCheckScope::Repo,
            format!(
                "Remote publish contract is missing required targets: {}.",
                missing.join(", ")
            ),
            Some(&docker_makefile),
            Some("Update the Kuma checkout so release image build/push targets are present."),
        );
    }

    pass(
        "repo_remote_publish_contract_present",
        ReadinessCheckScope::Repo,
        "Kuma repo exposes the current remote image publish contract.",
        Some(&docker_makefile),
        None,
    )
}

pub(super) fn is_kuma_checkout(root: &Path) -> bool {
    let go_mod = root.join("go.mod");
    fs::read_to_string(go_mod).is_ok_and(|text| text.contains("github.com/kumahq/kuma"))
}
