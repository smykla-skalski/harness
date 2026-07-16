#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CrashBoundary {
    PermitReloaded,
    ServiceSpawned,
    PermitRemoved,
}

impl CrashBoundary {
    pub(super) const ALL: [Self; 3] = [
        Self::PermitReloaded,
        Self::ServiceSpawned,
        Self::PermitRemoved,
    ];

    pub(super) const fn name(self) -> &'static str {
        match self {
            Self::PermitReloaded => "permit-reloaded-before-start",
            Self::ServiceSpawned => "main-pid-before-permit-removal",
            Self::PermitRemoved => "permit-removed-before-persistent-reload",
        }
    }

    const fn service_suffix(self) -> &'static str {
        match self {
            Self::PermitReloaded => "permit-reloaded",
            Self::ServiceSpawned => "main-pid",
            Self::PermitRemoved => "permit-removed",
        }
    }

    pub(super) fn selector(self, occurrence: usize) -> String {
        format!("{}:{occurrence}", self.name())
    }

    pub(super) fn transient_service_name(self, unit: &str) -> String {
        format!(
            "{unit}-harness-upgrade-crash-{}.service",
            self.service_suffix()
        )
    }
}
