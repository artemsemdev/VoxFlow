# Connect an MCP client to VoxFlow

VoxFlow can run a local MCP server that Cursor (or Claude Desktop, through the `mcp-remote`
bridge) can connect to and use as a tool — `transcribe_file`, `dictate` and `search_history` (off
by default). The server only ever listens on `127.0.0.1`, never sends anything itself, and every
call needs a valid token. Design: ADR-008 (`docs/adr/008-loopback-mcp-server.md`), canvas ST-06/
ST-06a/ST-06r/3e.

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

## 2. Connect Cursor

Cursor talks to a Streamable HTTP MCP server directly, with a custom header for the token. Add
this to `~/.cursor/mcp.json` (or `.cursor/mcp.json` in a specific project), replacing `vf_…` with
the token you copied:

```json
{"mcpServers":{"voxflow":{"url":"http://127.0.0.1:7331/mcp","headers":{"Authorization":"Bearer vf_…"}}}}
```

If the endpoint moved off 7331 (§5), use the port ST-06 actually shows instead. Restart Cursor (or
reload its MCP servers) after saving the file — the first tool call from it triggers the approval
dialog below.

## 3. Connect Claude Desktop

Claude Desktop's Custom Connectors take a URL but have no field for a custom header, and VoxFlow's
token has to travel as a bearer header — so Claude Desktop needs the `mcp-remote` bridge (an `npx`
package that speaks stdio to Claude Desktop and Streamable HTTP with headers to VoxFlow). Add this
to `~/Library/Application Support/Claude/claude_desktop_config.json`, again with your real token:

```json
{"mcpServers":{"voxflow":{"command":"npx","args":["-y","mcp-remote","http://127.0.0.1:7331/mcp","--header","Authorization: Bearer vf_…"]}}}
```

This needs Node/`npx` available on your Mac (`mcp-remote` downloads on first run). Restart Claude
Desktop after saving. Until Claude Desktop supports custom headers on a Custom Connector directly,
this bridge is required — see ADR-008's Consequences.

## 4. Approve the client

The **first** call from a client you haven't approved yet suspends that call and shows a floating
panel — it appears even if VoxFlow's main window is closed:

> **"Cursor" wants to use VoxFlow**
> A local app connected to the MCP server with a valid token. It can use: transcribe_file,
> dictate.
>
> Process: Cursor (pid 4812) · 127.0.0.1
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
2. Update the `url` (Cursor) or the `mcp-remote` argument (Claude Desktop) in your client's config
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

- Cursor and Claude Desktop both stop working until you paste the new token into their configs.
- The next call from either re-triggers the approval dialog in §4, even for a client you'd
  previously set to Always allow.

Use this if you think the token leaked, or just want a clean slate for who's connected.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Client shows "unauthorized" / 401 | Wrong or stale token in the client config — copy it again from Settings and check for a trailing space. |
| Client can't connect at all | The endpoint's port changed (§5), or **Enable MCP server** is off. |
| `transcribe_file` says the path is rejected | `PathPolicy` only accepts files inside your home directory, not under `~/Library`, with a supported audio/video extension — see ADR-008. |
| `dictate` returns "A dictation is already running." | Another dictation (yours, or a previous MCP `dictate` call) is still in progress; wait for it to finish. |
| `search_history` returns "History unavailable" / an error | History is off, or disabled for the same reason it would show under Settings › Privacy — turn it on there first. |
| Claude Desktop's connector won't start | Confirm `npx` is on your `PATH` (`which npx`) — `mcp-remote` needs Node installed. |
