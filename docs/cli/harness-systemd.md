# Command-Line Help for `harness-systemd`

This document contains the help content for the `harness-systemd` command-line program.

**Command Overview:**

* [`harness-systemd`↴](#harness-systemd)
* [`harness-systemd install`↴](#harness-systemd-install)
* [`harness-systemd upgrade`↴](#harness-systemd-upgrade)
* [`harness-systemd rollback`↴](#harness-systemd-rollback)
* [`harness-systemd recover`↴](#harness-systemd-recover)
* [`harness-systemd uninstall`↴](#harness-systemd-uninstall)
* [`harness-systemd status`↴](#harness-systemd-status)

## `harness-systemd`

Harness systemd lifecycle controller

**Usage:** `harness-systemd <COMMAND>`

###### **Subcommands:**

* `install` — Install a hardened remote daemon service
* `upgrade` — Transactionally upgrade the daemon and its durable state
* `rollback` — Restore the retained daemon and state generation
* `recover` — Recover an interrupted lifecycle transaction
* `uninstall` — Remove a managed remote daemon service
* `status` — Show managed service status



## `harness-systemd install`

Install a hardened remote daemon service

**Usage:** `harness-systemd install [OPTIONS] --domain <DOMAIN> --acme-email <ACME_EMAIL>`

###### **Options:**

* `--domain <DOMAIN>` — Public DNS name clients use for the remote daemon
* `--host <HOST>` — Network interface to bind

  Default value: `0.0.0.0`
* `--https-port <HTTPS_PORT>` — HTTPS/WSS listener port

  Default value: `443`
* `--http-port <HTTP_PORT>` — HTTP listener port used for HTTP-01

  Default value: `80`
* `--acme-email <ACME_EMAIL>` — ACME account email address
* `--acme-challenge <ACME_CHALLENGE>` — ACME challenge type

  Default value: `tls-alpn`

  Possible values: `tls-alpn`, `http`, `dns`

* `--acme-dns-provider <ACME_DNS_PROVIDER>` — DNS provider used by DNS-01

  Possible values: `aftermarket`, `cloudflare`, `route53`, `exec`

* `--companion-upstream <COMPANION_UPSTREAM>` — Loopback origin of a companion web service to forward part of the public traffic to, for example `http://127.0.0.1:8787`
* `--companion-path-prefix <COMPANION_PATH_PREFIX>` — Path subtree handed to the companion service

  Default value: `/panel`
* `--companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE>` — Source file systemd loads as the daemon-to-companion authentication credential
* `--companion-panel-socket-unit <COMPANION_PANEL_SOCKET_UNIT>` — Socket unit that reserves the panel listener for the managed companion
* `--unit <UNIT>` — systemd unit name

  Default value: `harness-remote-daemon`
* `--binary-path <BINARY_PATH>` — Explicit path to the `harness-daemon` binary. Defaults to the release-set sibling
* `--env-file <ENV_FILE>` — Path for the `EnvironmentFile` referenced by the service unit
* `--dry-run` — Render and report the install plan without writing files or calling systemctl
* `--reconfigure` — Transactionally replace a drifted managed unit while preserving rollback state
* `--json` — Output as JSON



## `harness-systemd upgrade`

Transactionally upgrade the daemon and its durable state

**Usage:** `harness-systemd upgrade [OPTIONS]`

###### **Options:**

* `--unit <UNIT>` — systemd unit name

  Default value: `harness-remote-daemon`
* `--candidate-path <CANDIDATE_PATH>` — New harness-daemon executable. Omission performs a same-binary health check
* `--binary-path <BINARY_PATH>` — Installed executable referenced by the systemd unit

  Default value: `/usr/local/bin/harness-daemon`
* `--env-file <ENV_FILE>` — Environment file referenced by the systemd unit
* `--readiness-timeout-seconds <READINESS_TIMEOUT_SECONDS>` — Maximum time to wait for systemd readiness

  Default value: `180`
* `--stabilization-window-seconds <STABILIZATION_WINDOW_SECONDS>` — Time the ready process must remain stable without a restart

  Default value: `15`
* `--dry-run` — Show the transaction paths without stopping or changing the service
* `--json` — Output as JSON



## `harness-systemd rollback`

Restore the retained daemon and state generation

**Usage:** `harness-systemd rollback [OPTIONS]`

###### **Options:**

* `--unit <UNIT>` — systemd unit name

  Default value: `harness-remote-daemon`
* `--binary-path <BINARY_PATH>` — Installed executable referenced by the systemd unit

  Default value: `/usr/local/bin/harness-daemon`
* `--env-file <ENV_FILE>` — Environment file referenced by the systemd unit
* `--confirm-data-loss` — Confirm that restoring the previous database discards newer writes
* `--readiness-timeout-seconds <READINESS_TIMEOUT_SECONDS>` — Maximum time to wait for systemd readiness

  Default value: `180`
* `--stabilization-window-seconds <STABILIZATION_WINDOW_SECONDS>` — Time the restored process must remain stable without a restart

  Default value: `15`
* `--dry-run` — Show the retained generation without changing the service
* `--json` — Output as JSON



## `harness-systemd recover`

Recover an interrupted lifecycle transaction

**Usage:** `harness-systemd recover [OPTIONS] --store-path <STORE_PATH>`

###### **Options:**

* `--store-path <STORE_PATH>` — Durable transaction store containing the recovery arm
* `--json` — Output as JSON



## `harness-systemd uninstall`

Remove a managed remote daemon service

**Usage:** `harness-systemd uninstall [OPTIONS]`

###### **Options:**

* `--unit <UNIT>` — systemd unit name

  Default value: `harness-remote-daemon`
* `--env-file <ENV_FILE>` — Path for the `EnvironmentFile` referenced by the service unit
* `--json` — Output as JSON



## `harness-systemd status`

Show managed service status

**Usage:** `harness-systemd status [OPTIONS]`

###### **Options:**

* `--unit <UNIT>` — systemd unit name

  Default value: `harness-remote-daemon`
* `--env-file <ENV_FILE>` — Path for the `EnvironmentFile` referenced by the service unit
* `--json` — Output as JSON



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
