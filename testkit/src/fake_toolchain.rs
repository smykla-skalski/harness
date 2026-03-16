use std::fs;
use std::path::Path;

use tempfile::TempDir;

use crate::fake_binary::{write_fake_binary, write_fake_binary_with_script};

/// A temporary directory populated with fake binaries for integration testing.
///
/// Prepend `bin_dir()` to PATH so that commands invoking `kubectl`, `make`, etc.
/// hit these stubs instead of the real tools.
pub struct FakeToolchain {
    dir: TempDir,
}

impl FakeToolchain {
    /// Create a new toolchain with an empty temp directory.
    ///
    /// # Panics
    /// Panics if the temporary directory cannot be created.
    #[must_use]
    pub fn new() -> Self {
        Self {
            dir: TempDir::new().expect("create FakeToolchain temp dir"),
        }
    }

    /// Path to the directory containing fake binaries.
    #[must_use]
    pub fn bin_dir(&self) -> &Path {
        self.dir.path()
    }

    /// Add a generic fake binary that prints `stdout` and exits with `exit_code`.
    pub fn add(&mut self, name: &str, stdout: &str, exit_code: i32) -> &mut Self {
        let _ = write_fake_binary(self.dir.path(), name, stdout, exit_code);
        self
    }

    /// Add a fake `kubectl` that prints `stdout` and exits 0.
    pub fn add_kubectl(&mut self, stdout: &str) -> &mut Self {
        self.add("kubectl", stdout, 0)
    }

    /// Add a fake `make` that exits 0 with no output.
    pub fn add_make(&mut self) -> &mut Self {
        self.add("make", "", 0)
    }

    /// Add a fake `k3d` that responds to `cluster list --no-headers` with the
    /// given cluster names (one per line).
    pub fn add_k3d_cluster_list(&mut self, clusters: &[&str]) -> &mut Self {
        let listing = clusters
            .iter()
            .map(|name| format!("{name}   1/1   0/0   true"))
            .collect::<Vec<_>>()
            .join("\n");
        let script = format!(
            "#!/bin/sh\n\
             echo \"$0 $*\" >> \"{dir}/k3d.invocations\"\n\
             if [ \"$1\" = \"cluster\" ] && [ \"$2\" = \"list\" ]; then\n\
               printf '%s\\n' '{listing}'\n\
               exit 0\n\
             fi\n\
             exit 0\n",
            dir = self.dir.path().display(),
            listing = listing.replace('\'', "'\\''"),
        );
        let _ = write_fake_binary_with_script(self.dir.path(), "k3d", &script);
        self
    }

    /// Add a fake `kubectl-validate` that prints `stdout` and exits 0.
    pub fn add_kubectl_validate(&mut self, stdout: &str) -> &mut Self {
        self.add("kubectl-validate", stdout, 0)
    }

    /// Add a fake `git` that responds to common subcommands.
    pub fn add_git(&mut self) -> &mut Self {
        let script = format!(
            "#!/bin/sh\n\
             echo \"$0 $*\" >> \"{dir}/git.invocations\"\n\
             case \"$1\" in\n\
               status) printf '' ; exit 0 ;;\n\
               rev-parse) printf 'abc1234567' ; exit 0 ;;\n\
               *) exit 0 ;;\n\
             esac\n",
            dir = self.dir.path().display(),
        );
        let _ = write_fake_binary_with_script(self.dir.path(), "git", &script);
        self
    }

    /// Add a fake `docker` that responds to common subcommands.
    ///
    /// Supports: ps, inspect, run, rm, exec, cp, network, logs.
    /// All invocations are logged for assertion.
    pub fn add_docker(&mut self) -> &mut Self {
        let script = format!(
            "#!/bin/sh\n\
             echo \"$0 $*\" >> \"{dir}/docker.invocations\"\n\
             case \"$1\" in\n\
               ps) printf '' ; exit 0 ;;\n\
               inspect) printf '{{{{}}}}' ; exit 0 ;;\n\
               run) printf 'fake-container-id' ; exit 0 ;;\n\
               rm) exit 0 ;;\n\
               exec) exit 0 ;;\n\
               cp) exit 0 ;;\n\
               network) exit 0 ;;\n\
               logs) printf 'fake log output' ; exit 0 ;;\n\
               compose) exit 0 ;;\n\
               *) exit 0 ;;\n\
             esac\n",
            dir = self.dir.path().display(),
        );
        let _ = write_fake_binary_with_script(self.dir.path(), "docker", &script);
        self
    }

    /// Add a fake `openssl` that returns a PEM certificate.
    ///
    /// All invocations are logged for assertion.
    pub fn add_openssl(&mut self) -> &mut Self {
        let script = format!(
            "#!/bin/sh\n\
             echo \"$0 $*\" >> \"{dir}/openssl.invocations\"\n\
             printf '-----BEGIN CERTIFICATE-----\\nMIIBfake\\n-----END CERTIFICATE-----\\n'\n\
             exit 0\n",
            dir = self.dir.path().display(),
        );
        let _ = write_fake_binary_with_script(self.dir.path(), "openssl", &script);
        self
    }

    /// Add a fake `curl` that exits 0.
    pub fn add_curl(&mut self) -> &mut Self {
        // Simulate curl -sL -o <file> <url> by writing a placeholder file
        let script = format!(
            "#!/bin/sh\n\
             echo \"$0 $*\" >> \"{dir}/curl.invocations\"\n\
             # Find -o flag and write placeholder\n\
             while [ $# -gt 0 ]; do\n\
               case \"$1\" in\n\
                 -o) shift; printf 'apiVersion: v1\\nkind: CustomResourceDefinition\\n' > \"$1\" ;;\n\
               esac\n\
               shift\n\
             done\n\
             exit 0\n",
            dir = self.dir.path().display(),
        );
        let _ = write_fake_binary_with_script(self.dir.path(), "curl", &script);
        self
    }

    /// Read the invocation log for a fake binary. Each entry is one line.
    #[must_use]
    pub fn invocations(&self, name: &str) -> Vec<String> {
        let path = self.dir.path().join(format!("{name}.invocations"));
        fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect()
    }

    /// Build a PATH string with `bin_dir()` prepended to the original PATH.
    #[must_use]
    pub fn path_with_prepend(&self, orig_path: &str) -> String {
        format!("{}:{orig_path}", self.bin_dir().display())
    }
}

impl Default for FakeToolchain {
    fn default() -> Self {
        Self::new()
    }
}
