# Connect an MCP client to VoxFlow

Connect **Codex directly over HTTP**, or **Claude Desktop through the `mcp-remote` bridge**, to
use `transcribe_file`, `dictate` and `search_history` (off by default). Keep VoxFlow running with
its MCP server enabled. The endpoint accepts only loopback connections; every request needs the
access token. Protocol and policy: [ADR-008](../adr/008-loopback-mcp-server.md).

VoxFlow processes audio locally. Tool results are handed to the client you approve, which may send
them to its model provider. Use non-sensitive recordings for the release checks.

## 1. Turn it on and copy the token

Settings › MCP Server:

1. Turn on **Enable MCP server**. The endpoint row shows `http://127.0.0.1:7331/mcp` — the port
   moves if 7331 was already taken by something else; see §5.
2. Click **Copy** next to **Access token** to copy the full `vf_…` token to the clipboard. The
   page only ever shows it masked (`vf_••••••••••••1a2b`); Copy is the only way to get the real
   value.

The token lives in the Keychain (service `dev.artemsem.voxflow`, account `mcp-token`), created the
first time it's read. It is the **only** credential the server checks — anyone who has it can call
every tool you've enabled, so treat it like a password and don't paste it anywhere other than a
client config you trust.

## 2. Connect Codex (direct HTTP)

Add this table to `~/.codex/config.toml`, keeping your other settings:

```toml
[mcp_servers.voxflow]
url = "http://127.0.0.1:7331/mcp"
bearer_token_env_var = "VOXFLOW_MCP_TOKEN"
tool_timeout_sec = 1200
```

Use the actual endpoint from Settings if its port differs. For the CLI, copy the token and launch
from the same terminal:

```sh
export VOXFLOW_MCP_TOKEN="$(pbpaste)"
codex
```

A desktop app opened from the Dock does not inherit that terminal's exports. For that setup,
replace `bearer_token_env_var` with this line, substituting your copied token:

```toml
http_headers = { "Authorization" = "Bearer vf_REPLACE_WITH_COPIED_TOKEN" }
```

Keep this credential in your personal config, outside the repository. Restart the client after
changes; `/mcp` in Codex CLI shows active servers. VoxFlow uses a copied bearer token, so no OAuth
login is needed. Configuration reference: [OpenAI's MCP documentation](https://developers.openai.com/codex/mcp/).

The 1,200-second tool timeout accommodates VoxFlow's capture/processing budget and long file jobs.
The first **tool invocation**, rather than discovery, triggers §4's approval dialog.

## 3. Connect Claude Desktop

Use Claude Desktop's **local** MCP configuration. Its launched command speaks stdio, so the
current HTTP-only VoxFlow build needs Node and `mcp-remote`. A cloud-hosted connector cannot reach
this Mac's `127.0.0.1`. See the [local server setup guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

Check `node --version` and `command -v npx`. In
`~/Library/Application Support/Claude/claude_desktop_config.json`, merge this `voxflow` entry into
your existing `mcpServers` object; preserve other servers. The example uses Homebrew's Apple Silicon
paths: replace the command and the first PATH directory if your Node installation is elsewhere.

```json
{
  "mcpServers": {
    "voxflow": {
      "command": "/opt/homebrew/bin/npx",
      "args": [
        "-y", "mcp-remote", "http://127.0.0.1:7331/mcp",
        "--transport", "http-only", "--allow-http",
        "--header", "Authorization:${VOXFLOW_AUTH_HEADER}"
      ],
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "VOXFLOW_AUTH_HEADER": "Bearer vf_REPLACE_WITH_COPIED_TOKEN"
      }
    }
  }
}
```

Replace the endpoint and token, then fully quit and reopen Claude Desktop. `npx` may download the
bridge and its dependencies from npm; this setup step needs internet access. The header's `${…}`
placeholder is expanded by the bridge from `env`, keeping the token out of command-line arguments.
Bridge options: [mcp-remote documentation](https://github.com/punkpeye/mcp-remote#custom-headers).

VoxFlow identifies the HTTP peer, which for this bridge can be **node**, not Claude Desktop.
Review its executable path in the approval dialog: an **Always allow** grant to that Node
executable also covers other processes using that executable and the same token. **Allow once**
avoids persistence, but still grants that identity access for the VoxFlow session.

## 4. Approve the client

The **first tool invocation** from a client you haven't approved yet suspends that call and shows a floating
panel — it appears even if VoxFlow's main window is closed:

> **"{process name}" wants to use VoxFlow**
> A local app connected to the MCP server with a valid token. It can use: transcribe_file,
> dictate.
>
> Process: {process name} (pid {pid}) · 127.0.0.1
> {executable path}
>
> [Always allow]  [Allow once]  [Deny]

- **Always allow** adds the client to **Connected clients** (name + path) permanently — it won't
  ask again, including after VoxFlow restarts.
- **Allow once** lets just the rest of this app session through, then asks again next launch. It
  never appears in Connected clients.
- **Deny** answers the call with an error and won't ask again this session (it also doesn't appear
  in Connected clients — a denied client leaves no persistent trace).
- If VoxFlow couldn't identify the calling process, the dialog shows **"Unknown app"** with no pid
  line and **no "Always allow" option** — every unidentified process would otherwise share one
  approval, so it can only ever be allowed for the current session.

Leaving the dialog untouched for 60 seconds answers the waiting call with an error, as if you'd
clicked Deny, and the dialog closes.

## 5. If the endpoint moved

VoxFlow tries port 7331 first, then 7332…7340 if something else already had 7331. If you see the
note **"Port 7331 was busy — update your client with the Copy button"** under the endpoint in
Settings › MCP Server:

1. Click **Copy** next to the endpoint to get the actual URL VoxFlow bound.
2. Update the `url` (Codex) or the `mcp-remote` argument (Claude Desktop) in your client's config
   to match — the port number is the only thing that changes.
3. Restart the client.

If every port from 7331 to 7340 is taken, the toggle snaps back off and Settings shows "Couldn't
start the server — ports 7331–7340 are all in use." — quit whatever else is holding all ten ports
(or restart it after freeing one) and turn the server back on.

## 6. Revoke a client

Settings › MCP Server → **Connected clients** lists every approved client with when it was last
used. Click **Revoke** next to one to remove it immediately — its very next call re-triggers the
approval dialog in §4 rather than going straight through, even though the client itself hasn't
changed anything on its end.

## 7. Regenerating the token disconnects everyone

**Regenerate** next to Access token creates a brand-new token and — because a client's approval is
tied to "holds a token that's still valid" — also clears every row in Connected clients. After
regenerating:

- Update Codex's environment variable or static header and Claude Desktop's `VOXFLOW_AUTH_HEADER`
  with the new token, then restart each client. Both stop working with the old token.
- The next call from either re-triggers the approval dialog in §4, even for a client you'd
  previously set to Always allow.

Use this if you think the token leaked, or just want a clean slate for who's connected.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Client shows "unauthorized" / 401 | Wrong or stale token in the client config — copy it again from Settings and check for a trailing space. |
| Client can't connect at all | The endpoint's port changed (§5), or **Enable MCP server** is off. |
| Codex reports the token environment variable is missing | Start the CLI from the terminal where you exported it, or use the static header for a desktop launch (§2). |
| Tool call times out while recording or transcribing | Check the client's tool timeout; Codex's example raises it to 1,200 seconds. Start the checklist with a short recording; client limits can expire before VoxFlow finishes. |
| `transcribe_file` says the path is rejected | `PathPolicy` only accepts files inside your home directory, not under `~/Library`, with a supported audio/video extension — see ADR-008. |
| `dictate` returns "A dictation is already running." | Another dictation (yours, or a previous MCP `dictate` call) is still in progress; wait for it to finish. |
| `search_history` is absent or returns an error | Enable its tool toggle in Settings › MCP Server, then reload the client's tools. For "History unavailable", also check Settings › Privacy. |
| Claude Desktop's connector won't start | Validate the JSON, absolute `npx` path and Node directory in `env.PATH`. Inspect `~/Library/Logs/Claude/mcp-server-voxflow.log`; the first download also needs npm connectivity. |

Cursor is optional: it can use the same endpoint with an `Authorization: Bearer …` header in its
MCP configuration. Neither the runbook nor the release checklist requires it.
