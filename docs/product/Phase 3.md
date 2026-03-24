# Phase 3: Integration Guides and External Polish

Derived from [ROADMAP.md](./ROADMAP.md). This phase focuses on MCP integration guides, output format documentation, and external-facing polish. Basic install and usage docs shipped in Phase 1. Feature docs shipped with Phase 2 features.

## Goal

Make MCP integration and structured outputs usable through tested guides. Polish external-facing materials so the product is presentable.

## What To Implement

### 1. Docs Audit and Restructure

By Phase 3, install, first-run, config, and known-limitations docs already exist from Phase 1. Feature docs (presets, outputs, batch, workspace) exist from Phase 2.

This phase audits and restructures:

- verify all existing docs are current and accurate
- restructure into a consistent hierarchy (e.g., `docs/user/install.md`, `docs/user/config.md`, `docs/integration/mcp-claude-desktop.md`)
- add a docs index or table of contents
- remove any orphaned or outdated content

### 2. MCP Quickstarts

Support these clients first (update list based on actual user demand):

- Claude Desktop (primary — largest MCP user base)
- Cursor (if demand exists)

For each supported client provide:

- exact setup steps with copy-pasteable config snippets
- expected tools and their arguments
- expected prompts and when to use them
- a validation flow: "run this tool, expect this output"
- common failure modes and fixes (e.g., path policy rejections, missing ffmpeg)

Each quickstart must be tested against the actual release build before shipping.

### 3. Output Format Reference

Document all output formats available after Phase 2:

- plain text: format spec, line structure
- JSON: schema reference (link to versioned JSON Schema file)
- Markdown: structure and heading conventions
- SRT/VTT: if implemented, subtitle format details
- metadata sidecar: field reference
- bundle layout: directory structure and file naming

### 4. Visual Assets

Add only the minimum product visuals:

- current desktop screenshots (home, transcribe flow, result, settings)
- one short demo GIF or video showing: launch → drop file → transcription → result
- MCP tool invocation screenshot from Claude Desktop

Rules:

- screenshots must be regenerated from the actual build before each release
- store originals in `docs/assets/` with descriptive names, not `screenshot1.png`

### 5. Release Notes and Changelog

Standardize release output using `CHANGELOG.md` in the repo root:

- follow Keep a Changelog format
- sections: Added, Changed, Fixed, Removed, Known Issues
- link each release to its git tag
- include minimum macOS version and runtime requirements

## Out of Scope

- Category narrative or competitive positioning
- Comparison pages
- Community program
- Large example or recipe library
- Marketing content not tied to actual product use
- Tutorial content beyond quickstarts (defer to a wiki or blog if needed)

## Implementation Order

1. Audit existing docs from Phase 1 and Phase 2 for accuracy.
2. Restructure docs into consistent hierarchy.
3. Write and test Claude Desktop MCP quickstart.
4. Write and test additional MCP quickstarts if demand exists.
5. Write output format reference.
6. Capture screenshots and demo flow.
7. Set up CHANGELOG.md and release notes format.

## Practical Risks

- Docs will drift if they are not updated as part of each release. Mitigate by adding a "docs check" to the release checklist.
- MCP quickstarts will break if the MCP server changes. Mitigate by running quickstart validation as part of CI or pre-release testing.
- Screenshots will go stale. Mitigate by dating them and checking during release.

## Done When

- existing docs are audited, current, and consistently structured
- Claude Desktop MCP quickstart is tested and working
- output format reference is complete
- screenshots reflect the actual shipped build
- CHANGELOG.md is established with entries for all prior releases
