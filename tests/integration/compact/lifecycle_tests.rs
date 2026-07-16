#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn build_compact_worktree_project() {
    super::with_compact_env(
        "compact-worktree-project",
        super::check_build_compact_worktree_project,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn build_compact_includes_create() {
    super::with_compact_env(
        "compact-includes-create",
        super::check_build_compact_includes_create,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn build_compact_create_fallback() {
    super::with_compact_env(
        "compact-create-fallback",
        super::check_build_compact_create_fallback,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn save_consume_compact_handoff() {
    super::with_compact_env(
        "compact-save-consume",
        super::check_save_consume_compact_handoff,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn pre_compact_persists() {
    super::with_compact_env("compact-pre-compact", super::check_pre_compact_persists);
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_compact_hydrates() {
    super::with_compact_env(
        "compact-start-hydrates",
        super::check_session_start_compact_hydrates,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_compact_worktree() {
    super::with_compact_env(
        "compact-start-worktree",
        super::check_session_start_compact_worktree,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_compact_aborted_resume() {
    super::with_compact_env(
        "compact-aborted-resume",
        super::check_session_start_compact_aborted_resume,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_compact_restores_create() {
    super::with_compact_env(
        "compact-restores-create",
        super::check_session_start_compact_restores_create,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_compact_divergence_warning() {
    super::with_compact_env(
        "compact-divergence-warning",
        super::check_session_start_compact_divergence_warning,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_restores_project() {
    super::with_compact_env(
        "compact-restores-project",
        super::check_session_start_restores_project,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_restores_worktree() {
    super::with_compact_env(
        "compact-restores-worktree",
        super::check_session_start_restores_worktree,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_cross_project() {
    super::with_compact_env(
        "compact-cross-project",
        super::check_session_start_cross_project,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_without_pending_handoff() {
    super::with_compact_env(
        "compact-without-pending",
        super::check_session_start_without_pending_handoff,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_stop_without_pointer() {
    super::with_compact_env(
        "compact-stop-without-pointer",
        super::check_session_stop_without_pointer,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn session_start_no_replay() {
    super::with_compact_env("compact-no-replay", super::check_session_start_no_replay);
}
