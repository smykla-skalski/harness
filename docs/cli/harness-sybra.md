# Command-Line Help for `harness-sybra`

This document contains the help content for the `harness-sybra` command-line program.

**Command Overview:**

* [`harness-sybra`↴](#harness-sybra)

## `harness-sybra`

Local Harness Sybra gateway

**Usage:** `harness-sybra [OPTIONS] --upstream <UPSTREAM> --upstream-token-file <UPSTREAM_TOKEN_FILE> --browser-token-file <BROWSER_TOKEN_FILE>`

###### **Options:**

* `--listen <LISTEN>` — Numeric loopback listener. Port zero selects an ephemeral port

  Default value: `127.0.0.1:0`
* `--upstream <UPSTREAM>` — Numeric loopback HTTP origin of the private Sybra backend
* `--upstream-token-file <UPSTREAM_TOKEN_FILE>` — Private bearer token presented only to the Sybra backend
* `--browser-token-file <BROWSER_TOKEN_FILE>` — Private bearer token accepted from the local browser



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
