# Command-Line Help for `harness-bridge`

This document contains the help content for the `harness-bridge` command-line program.

**Command Overview:**

* [`harness-bridge`↴](#harness-bridge)
* [`harness-bridge start`↴](#harness-bridge-start)
* [`harness-bridge stop`↴](#harness-bridge-stop)
* [`harness-bridge status`↴](#harness-bridge-status)
* [`harness-bridge reconfigure`↴](#harness-bridge-reconfigure)
* [`harness-bridge install-launch-agent`↴](#harness-bridge-install-launch-agent)
* [`harness-bridge remove-launch-agent`↴](#harness-bridge-remove-launch-agent)

## `harness-bridge`

Harness host bridge

**Usage:** `harness-bridge [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `start` — Start the unified host bridge
* `stop` — Stop the running host bridge, if any
* `status` — Print the current bridge status
* `reconfigure` — Reconfigure the running bridge without restarting it
* `install-launch-agent` — Install a per-user `LaunchAgent` that starts the bridge at login
* `remove-launch-agent` — Remove the bridge `LaunchAgent` and clean up persisted state

###### **Options:**

* `--delay <DELAY>` — Seconds to wait before executing the command

  Default value: `0`



## `harness-bridge start`

Start the unified host bridge

**Usage:** `harness-bridge start [OPTIONS]`

###### **Options:**

* `--capability <CAPABILITIES>` — Explicit capability list. Omit the flag to enable every compiled capability

  Possible values: `codex`, `agent-tui`, `acp`

* `--socket-path <PATH>` — Override the control socket path
* `--codex-port <CODEX_PORT>` — Port for the codex WebSocket capability
* `--codex-path <PATH>` — Explicit path to the `codex` binary
* `--daemon` — Detach from the terminal and run in the background



## `harness-bridge stop`

Stop the running host bridge, if any

**Usage:** `harness-bridge stop [OPTIONS]`

###### **Options:**

* `--json` — Print the final status as JSON



## `harness-bridge status`

Print the current bridge status

**Usage:** `harness-bridge status [OPTIONS]`

###### **Options:**

* `--plain` — Print a one-line summary instead of JSON



## `harness-bridge reconfigure`

Reconfigure the running bridge without restarting it

**Usage:** `harness-bridge reconfigure [OPTIONS]`

###### **Options:**

* `--enable <ENABLE>` — Enable one capability without restarting the bridge

  Possible values: `codex`, `agent-tui`, `acp`

* `--disable <DISABLE>` — Disable one capability without restarting the bridge

  Possible values: `codex`, `agent-tui`, `acp`

* `--force` — Force-disable `agent-tui` by stopping active TUI sessions first
* `--json` — Print the updated bridge status as JSON



## `harness-bridge install-launch-agent`

Install a per-user `LaunchAgent` that starts the bridge at login

**Usage:** `harness-bridge install-launch-agent [OPTIONS]`

###### **Options:**

* `--capability <CAPABILITIES>` — Explicit capability list. Omit the flag to enable every compiled capability

  Possible values: `codex`, `agent-tui`, `acp`

* `--socket-path <PATH>` — Override the control socket path
* `--codex-port <CODEX_PORT>` — Port for the codex WebSocket capability
* `--codex-path <PATH>` — Explicit path to the `codex` binary



## `harness-bridge remove-launch-agent`

Remove the bridge `LaunchAgent` and clean up persisted state

**Usage:** `harness-bridge remove-launch-agent [OPTIONS]`

###### **Options:**

* `--json` — Print confirmation as JSON



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

