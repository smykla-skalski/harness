# Command-Line Help for `harness-mcp`

This document contains the help content for the `harness-mcp` command-line program.

**Command Overview:**

* [`harness-mcp`↴](#harness-mcp)
* [`harness-mcp serve`↴](#harness-mcp-serve)

## `harness-mcp`

Harness MCP server

**Usage:** `harness-mcp [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `serve` — Run the MCP server on stdio. Reads JSON-RPC 2.0 requests from stdin, writes responses to stdout

###### **Options:**

* `--delay <DELAY>` — Seconds to wait before executing the command

  Default value: `0`



## `harness-mcp serve`

Run the MCP server on stdio. Reads JSON-RPC 2.0 requests from stdin, writes responses to stdout

**Usage:** `harness-mcp serve [OPTIONS]`

###### **Options:**

* `--socket <SOCKET>` — Override the accessibility registry socket path. Normally inferred from the macOS app-group container; override for unsandboxed dev



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
