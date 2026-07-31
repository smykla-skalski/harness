# Command-Line Help for `harness-daemon`

This document contains the help content for the `harness-daemon` command-line program.

**Command Overview:**

* [`harness-daemon`↴](#harness-daemon)
* [`harness-daemon serve`↴](#harness-daemon-serve)
* [`harness-daemon dev`↴](#harness-daemon-dev)
* [`harness-daemon remote`↴](#harness-daemon-remote)
* [`harness-daemon remote serve`↴](#harness-daemon-remote-serve)
* [`harness-daemon remote pair`↴](#harness-daemon-remote-pair)
* [`harness-daemon remote pair create`↴](#harness-daemon-remote-pair-create)
* [`harness-daemon remote clients`↴](#harness-daemon-remote-clients)
* [`harness-daemon remote clients list`↴](#harness-daemon-remote-clients-list)
* [`harness-daemon remote clients revoke`↴](#harness-daemon-remote-clients-revoke)
* [`harness-daemon remote clients rotate`↴](#harness-daemon-remote-clients-rotate)
* [`harness-daemon remote acme`↴](#harness-daemon-remote-acme)
* [`harness-daemon remote acme status`↴](#harness-daemon-remote-acme-status)
* [`harness-daemon remote acme renew`↴](#harness-daemon-remote-acme-renew)
* [`harness-daemon remote doctor`↴](#harness-daemon-remote-doctor)
* [`harness-daemon status`↴](#harness-daemon-status)
* [`harness-daemon identity`↴](#harness-daemon-identity)
* [`harness-daemon stop`↴](#harness-daemon-stop)
* [`harness-daemon restart`↴](#harness-daemon-restart)
* [`harness-daemon install-launch-agent`↴](#harness-daemon-install-launch-agent)
* [`harness-daemon remove-launch-agent`↴](#harness-daemon-remove-launch-agent)
* [`harness-daemon doctor`↴](#harness-daemon-doctor)
* [`harness-daemon snapshot`↴](#harness-daemon-snapshot)

## `harness-daemon`

Harness daemon

**Usage:** `harness-daemon [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `serve` — Serve the local daemon HTTP API
* `dev` — Serve an unsandboxed dev daemon whose manifest the sandboxed Harness Monitor app can read. Thin wrapper over `serve` with dev defaults
* `remote` — Serve and manage an internet-reachable remote daemon
* `status` — Show daemon manifest and project/session counts
* `identity` — Show the daemon's stable identity, optionally renaming it
* `stop` — Stop the local daemon
* `restart` — Restart the local daemon
* `install-launch-agent` — Install the per-user `LaunchAgent` plist
* `remove-launch-agent` — Remove the per-user `LaunchAgent` plist
* `doctor` — Run a local daemon diagnostics summary
* `snapshot` — Print a single session snapshot for contract debugging

###### **Options:**

* `--delay <DELAY>` — Seconds to wait before executing the command

  Default value: `0`



## `harness-daemon serve`

Serve the local daemon HTTP API

**Usage:** `harness-daemon serve [OPTIONS]`

###### **Options:**

* `--host <HOST>` — Loopback host interface to bind

  Default value: `127.0.0.1`
* `--port <PORT>` — TCP port to bind. Use 0 for an ephemeral port

  Default value: `0`
* `--refresh-seconds <REFRESH_SECONDS>` — Periodic refresh interval in seconds

  Default value: `2`
* `--observe-seconds <OBSERVE_SECONDS>` — Poll interval in seconds for daemon-owned observe loops

  Default value: `5`
* `--sandboxed` — Run in macOS App Sandbox mode. Disables subprocess features (launchctl install/remove, daemon respawn) and surfaces structured errors instead. Enabled automatically when `HARNESS_SANDBOXED` is set to a truthy value (`1`, `true`, `yes`, `on`) in the environment
* `--codex-ws-url <URL>` — WebSocket URL of a user-launched `codex app-server --listen ws://...`. Overrides the transport selected by sandbox mode; equivalent to setting `HARNESS_CODEX_WS_URL`. Sandboxed daemon flows require a loopback endpoint
* `--enable-acp` — Enable ACP managed-agent routes for this daemon process
* `--disable-acp` — Disable ACP managed-agent routes for this daemon process without mutating the caller's `HARNESS_FEATURE_ACP` shell environment



## `harness-daemon dev`

Serve an unsandboxed dev daemon whose manifest the sandboxed Harness Monitor app can read. Thin wrapper over `serve` with dev defaults

**Usage:** `harness-daemon dev [OPTIONS]`

###### **Options:**

* `--host <HOST>` — Host interface to bind

  Default value: `127.0.0.1`
* `--port <PORT>` — TCP port to bind. Use 0 for an ephemeral port

  Default value: `0`
* `--app-group-id <APP_GROUP_ID>` — macOS app group identifier used when resolving the daemon data root. Defaults to the sandboxed Harness Monitor app's group so the monitor can read the manifest written by this process

  Default value: `Q498EB36N4.io.harnessmonitor`
* `--codex-ws-url <URL>` — Optional WebSocket URL of an externally-managed `codex app-server`. Leave unset to let the unsandboxed dev daemon spawn codex over stdio, which is the whole point of dev mode (no codex bridge required)
* `--enable-acp` — Enable ACP managed-agent routes for the dev daemon
* `--disable-acp` — Disable ACP managed-agent routes for the dev daemon



## `harness-daemon remote`

Serve and manage an internet-reachable remote daemon

**Usage:** `harness-daemon remote [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `serve` — Serve the remote daemon over HTTPS/WSS
* `pair` — Create or manage one-time pairing flows
* `clients` — List, revoke, or rotate paired remote clients
* `acme` — Inspect or renew ACME certificate state
* `doctor` — Run remote daemon diagnostics

###### **Options:**

* `--systemd-unit <SYSTEMD_UNIT>` — Use the private state directory of an installed systemd unit



## `harness-daemon remote serve`

Serve the remote daemon over HTTPS/WSS

**Usage:** `harness-daemon remote serve [OPTIONS] --domain <DOMAIN> --acme-email <ACME_EMAIL>`

###### **Options:**

* `--domain <DOMAIN>` — Public DNS name clients use for the remote daemon
* `--host <HOST>` — Network interface to bind. Remote mode defaults to all IPv4 interfaces

  Default value: `0.0.0.0`
* `--https-port <HTTPS_PORT>` — HTTPS/WSS listener port

  Default value: `443`
* `--http-port <HTTP_PORT>` — HTTP listener port used when issuing certificates with HTTP-01

  Default value: `80`
* `--acme-email <ACME_EMAIL>` — ACME account email address
* `--acme-challenge <ACME_CHALLENGE>` — ACME challenge type used for certificate issuance

  Default value: `tls-alpn`

  Possible values: `tls-alpn`, `http`, `dns`

* `--acme-dns-provider <ACME_DNS_PROVIDER>` — DNS provider used by DNS-01 challenges

  Possible values: `aftermarket`, `cloudflare`, `route53`, `exec`




## `harness-daemon remote pair`

Create or manage one-time pairing flows

**Usage:** `harness-daemon remote pair <COMMAND>`

###### **Subcommands:**

* `create` — Create a one-time remote pairing code



## `harness-daemon remote pair create`

Create a one-time remote pairing code

**Usage:** `harness-daemon remote pair create [OPTIONS]`

###### **Options:**

* `--role <ROLE>` — Role granted to the paired client

  Default value: `admin`

  Possible values: `admin`, `operator`, `viewer`, `execution-coordinator`, `pairing-broker`

* `--scopes <SCOPES>` — Optional explicit scopes. Defaults to the selected role's scopes

  Possible values: `read`, `write`, `admin`, `execute`, `pair-mint`, `pair-manage`

* `--ttl <TTL>` — Pairing code time-to-live

  Default value: `10m`
* `--reviews-authors <AUTHORS>` — Optional GitHub authors included in the paired client's Reviews query
* `--reviews-organizations <ORGANIZATIONS>` — GitHub organizations included in the paired client's Reviews query
* `--reviews-repositories <REPOSITORIES>` — GitHub owner/repository scopes included in the paired client's Reviews query
* `--reviews-exclude-repositories <EXCLUDE_REPOSITORIES>` — GitHub owner/repository scopes excluded from the paired client's Reviews query
* `--reviews-cache-max-age-seconds <CACHE_MAX_AGE_SECONDS>` — Maximum age of cached Reviews data returned to the paired client



## `harness-daemon remote clients`

List, revoke, or rotate paired remote clients

**Usage:** `harness-daemon remote clients <COMMAND>`

###### **Subcommands:**

* `list` — List paired remote clients
* `revoke` — Revoke a paired remote client
* `rotate` — Rotate a paired remote client's token



## `harness-daemon remote clients list`

List paired remote clients

**Usage:** `harness-daemon remote clients list`



## `harness-daemon remote clients revoke`

Revoke a paired remote client

**Usage:** `harness-daemon remote clients revoke --client-id <CLIENT_ID>`

###### **Options:**

* `--client-id <CLIENT_ID>` — Remote client identifier



## `harness-daemon remote clients rotate`

Rotate a paired remote client's token

**Usage:** `harness-daemon remote clients rotate --client-id <CLIENT_ID>`

###### **Options:**

* `--client-id <CLIENT_ID>` — Remote client identifier



## `harness-daemon remote acme`

Inspect or renew ACME certificate state

**Usage:** `harness-daemon remote acme <COMMAND>`

###### **Subcommands:**

* `status` — Show ACME account, challenge, and certificate status
* `renew` — Renew the active certificate



## `harness-daemon remote acme status`

Show ACME account, challenge, and certificate status

**Usage:** `harness-daemon remote acme status`



## `harness-daemon remote acme renew`

Renew the active certificate

**Usage:** `harness-daemon remote acme renew`



## `harness-daemon remote doctor`

Run remote daemon diagnostics

**Usage:** `harness-daemon remote doctor`



## `harness-daemon status`

Show daemon manifest and project/session counts

**Usage:** `harness-daemon status`



## `harness-daemon identity`

Show the daemon's stable identity, optionally renaming it

**Usage:** `harness-daemon identity [OPTIONS]`

###### **Options:**

* `--set-name <NAME>` — Replace the name this daemon reports to clients



## `harness-daemon stop`

Stop the local daemon

**Usage:** `harness-daemon stop [OPTIONS]`

###### **Options:**

* `--json` — Output as JSON



## `harness-daemon restart`

Restart the local daemon

**Usage:** `harness-daemon restart [OPTIONS]`

###### **Options:**

* `--json` — Output as JSON



## `harness-daemon install-launch-agent`

Install the per-user `LaunchAgent` plist

**Usage:** `harness-daemon install-launch-agent [OPTIONS]`

###### **Options:**

* `--binary-path <BINARY_PATH>` — Explicit path to the `harness-daemon` binary. Defaults to the current executable
* `--json` — Print the full post-install `launchd` status as JSON



## `harness-daemon remove-launch-agent`

Remove the per-user `LaunchAgent` plist

**Usage:** `harness-daemon remove-launch-agent [OPTIONS]`

###### **Options:**

* `--json` — Print the full post-remove `launchd` status as JSON



## `harness-daemon doctor`

Run a local daemon diagnostics summary

**Usage:** `harness-daemon doctor`



## `harness-daemon snapshot`

Print a single session snapshot for contract debugging

**Usage:** `harness-daemon snapshot [OPTIONS] --session <SESSION>`

###### **Options:**

* `--session <SESSION>` — Session ID to snapshot
* `--json` — Output as JSON



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
