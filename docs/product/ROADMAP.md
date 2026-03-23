# ROADMAP — Add MCP Server to VoxFlow

## 1. Objective

Add a **local MCP server** on top of `VoxFlow` so AI clients such as ChatGPT, Claude, GitHub Copilot, Cursor, and VS Code can discover and invoke the application's transcription capabilities through the **Model Context Protocol (MCP)**.

The server must expose the application's existing local-only Whisper transcription workflow as safe, structured, reusable MCP tools without breaking the current console application behavior.

---

## 2. Current State Analysis

### What the current application already does well

`VoxFlow` is already a strong candidate for MCP enablement because it has a clear local-only workflow and a stable domain:

- local file-based audio transcription
- `ffmpeg` preprocessing
- local Whisper inference via `Whisper.net`
- result writing to local text files
- startup validation
- batch processing support
- configuration-driven behavior via `appsettings.json` / `TRANSCRIPTION_SETTINGS_PATH`

### Current technical characteristics

The repository currently represents a **.NET 9 console application** with orchestration concentrated in `Program.cs` and responsibility-based modules such as:

- `Configuration/TranscriptionOptions.cs`
- `Audio/AudioConversionService.cs`
- `Audio/WavAudioLoader.cs`
- `Services/StartupValidationService.cs`
- `Services/ModelService.cs`
- `Services/LanguageSelectionService.cs`
- `Processing/TranscriptionFilter.cs`
- `Services/OutputWriter.cs`
- batch-related services already added

### Architectural limitations that matter for MCP

1. **The current app is console-first.**
   A lot of behavior is designed around `Console.WriteLine`, console progress output, and a direct end-to-end execution flow.

2. **The orchestration is not yet host-agnostic.**
   `Program.cs` coordinates config loading, validation, conversion, model loading, transcription, filtering, and output writing directly.

3. **The current execution model is file-path + config driven, not request/response driven.**
   MCP tools need strongly defined request and response contracts.

4. **The current app writes user-facing output to stdout.**
   This is acceptable for CLI mode, but it is dangerous for **stdio-based MCP**, because MCP protocol messages also use standard I/O.

### Key design consequence

Do **not** bolt MCP directly into the current `Program.cs` flow.

The correct professional approach is:

- keep the current CLI host
- extract reusable application services
- add a dedicated MCP host on top of the reusable core

---

## 3. Product Goal

After this feature is implemented, the application should support two host modes:

1. **CLI mode** — current behavior remains available
2. **MCP server mode** — AI clients can discover and invoke transcription capabilities as MCP tools/resources/prompts

This should make VoxFlow usable as a **local AI tool server** for transcription workflows.

---

## 4. Success Criteria

The feature is successful when all of the following are true:

- existing console transcription still works
- MCP server starts successfully over **stdio**
- at least one MCP client can connect and list tools
- the MCP server can transcribe a local audio file
- the MCP server can run startup validation
- the MCP server can optionally run batch transcription
- the MCP server returns structured results instead of only console text
- no protocol corruption happens because of accidental stdout logging
- file access is constrained to safe configured roots
- cancellation and long-running progress are handled cleanly

---

## 5. Recommended Scope for v1

### In scope

- local MCP server over **stdio**
- optional HTTP transport as a second step
- reusable transcription application layer
- MCP tools for:
  - startup validation
  - single-file transcription
  - batch transcription
  - supported language inspection
  - model/config inspection
- MCP resources for read-only context
- MCP prompts for discoverability and guided use
- logging to **stderr** / file instead of stdout in MCP mode
- path validation / allowed-roots policy
- integration tests for at least one MCP client workflow

### Out of scope for v1

- remote multi-user SaaS hosting
- authentication / OAuth for local stdio mode
- real-time transcription streaming
- speaker diarization
- transcript editing via MCP
- arbitrary shell command execution
- exposing raw `ffmpeg` command injection to clients
- automatic watching of folders for newly arrived files

---

## 6. Core Architecture Decision

## ADR-MCP-001: Use a separate MCP host, not a dual-purpose console protocol mode

### Decision

Create a **dedicated MCP server project** and a **shared application core** instead of embedding MCP protocol handling directly into the current console application's `Program.cs`.

### Why

- MCP stdio mode must not write arbitrary text to stdout
- current CLI flow is user-console oriented
- MCP requires request/response contracts and structured schemas
- keeping CLI and MCP separate reduces regression risk
- testing becomes much easier

### Consequences

- some refactoring is required up front
- code quality improves significantly
- future HTTP transport becomes much easier

---

## 7. Target Repository Shape

### Recommended target structure

```text
VoxFlow.sln

/src
  /WhisperNET.Application
    /Audio
    /Configuration
    /Contracts
    /Execution
    /Processing
    /Services
    WhisperNET.Application.csproj

  /WhisperNET.Cli
    Program.cs
    WhisperNET.Cli.csproj

  /WhisperNET.McpServer
    Program.cs
    /Configuration
    /Tools
    /Resources
    /Prompts
    /Logging
    WhisperNET.McpServer.csproj

/tests
  /WhisperNET.Application.Tests
  /WhisperNET.McpServer.Tests
```

### Acceptable incremental fallback

If a full restructuring is too much for the first pass:

- keep the existing console project
- add `WhisperNET.McpServer` as a new project
- expose internal reusable logic via shared facades or `InternalsVisibleTo`
- still move protocol-safe orchestration out of the current console entry point

The codebase is small enough that this `InternalsVisibleTo` approach is pragmatic and recommended for the first pass. It gets to a working MCP server faster while deferring a full project split to a later iteration when the boundaries are better understood through real usage. Start here, restructure later if needed.

---

## 8. New Architectural Building Blocks

## 8.1 Application Facade Layer

Introduce a reusable application layer that is independent from CLI and MCP.

### Required interfaces

```text
IStartupValidationFacade
ITranscriptionFacade
IModelInspectionFacade
ILanguageInfoFacade
IPathPolicy
IResultLocator
```

### Required request/response contracts

```text
StartupValidationRequest
StartupValidationResult
StartupCheckDto

TranscribeFileRequest
TranscribeFileResult

BatchTranscribeRequest
BatchTranscribeResult
BatchFileResult

ModelInfoResult
SupportedLanguageDto
TranscriptReadResult
```

### Design rule

The application layer must return **structured DTOs**, not only console strings.

---

## 8.2 Host-Agnostic Orchestration

Move the end-to-end flow out of `Program.cs` into orchestration services such as:

```text
TranscriptionExecutionService
BatchTranscriptionExecutionService
StartupValidationExecutionService
```

Each service should:

- accept strongly typed request objects
- return strongly typed result objects
- avoid direct console output
- support `CancellationToken`
- optionally emit progress through an abstraction

---

## 8.3 Progress Reporting Abstraction

The existing app already has console progress behavior. MCP needs a different progress sink.

Create an abstraction such as:

```csharp
public interface IProgressReporter
{
    ValueTask ReportAsync(string stage, double? percentage, string message, CancellationToken ct);
}
```

Implementations:

- `ConsoleProgressReporter` for CLI
- `McpProgressReporter` for MCP tools
- `NullProgressReporter` for tests or silent execution

---

## 8.4 Path Safety Layer

Add a strict path policy because MCP clients will pass file paths as tool arguments.

### Rules

- normalize every incoming path with `Path.GetFullPath`
- reject empty / relative / traversal-based paths when policy requires absolute paths
- restrict access to configured `allowedRoots`
- separate input roots and output roots if needed
- reject output writes outside allowed roots
- reject shell-like path fragments that are not valid paths
- do not expose arbitrary file system browsing beyond the allowed policy

---

## 9. MCP Server Capability Design

MCP servers can expose **tools**, **resources**, and **prompts**.

For `VoxFlow`, the best design is:

- **tools** = actions the AI may invoke
- **resources** = read-only context the AI may inspect
- **prompts** = user-selectable guided workflows

---

## 10. MCP Tools for v1

## 10.1 `validate_environment`

### Purpose
Run startup validation and return structured diagnostic results.

### Input

- optional `configurationPath`
- optional `detailed`

### Output

- final outcome
- full check list
- warnings / failures
- resolved config path

### Notes

This should be marked as:

- read-only
- idempotent
- closed-world

---

## 10.2 `transcribe_file`

### Purpose
Transcribe a single local audio file.

### Input

- `inputPath`
- optional `resultFilePath`
- optional `configurationPath`
- optional `forceLanguages`
- optional `overwriteExistingResult`

### Output

- success/failure
- detected language
- result file path
- number of accepted segments
- duration / elapsed time
- warnings
- optionally transcript preview

### Rules

- must validate path safety before execution
- must not allow arbitrary output location outside allowed roots
- must support cancellation
- should support MCP progress notifications

---

## 10.3 `transcribe_batch`

### Purpose
Run batch transcription over a directory.

### Input

- `inputDirectory`
- `outputDirectory`
- optional `filePattern`
- optional `summaryFilePath`
- optional `stopOnFirstError`
- optional `keepIntermediateFiles`
- optional `configurationPath`

### Output

- total files discovered
- succeeded / failed / skipped counts
- summary file path
- per-file structured result list

### Rules

- must be optional via configuration flag `mcp.allowBatch`
- must enforce `maxBatchFiles`
- must support progress reporting per file and overall batch

---

## 10.4 `get_supported_languages`

### Purpose
Return supported languages from effective configuration/runtime.

### Input

- optional `configurationPath`

### Output

- configured languages
- display names
- tie-break priorities

### Notes

Read-only, safe, fast.

---

## 10.5 `inspect_model`

### Purpose
Return structured information about the configured Whisper model.

### Output

- model path
- model type
- whether file exists
- file size
- whether startup validation can load it
- whether it would need download/re-download

---

## 10.6 `read_transcript`

### Purpose
Read a produced transcript file under allowed roots.

### Input

- `path`
- optional `maxCharacters`

### Output

- transcript path
- content preview
- total length

### Notes

This is useful when a model wants to inspect the generated transcript after tool execution.

---

## 11. MCP Resources for v1

Resources should be **read-only** and help the model understand the environment.

### Recommended resources

1. `whisper://config/effective`
   - resolved effective configuration snapshot

2. `whisper://languages/supported`
   - list of configured / supported languages

3. `whisper://model/current`
   - current model status

4. `whisper://runs/last-summary`
   - last execution summary if available

5. `whisper://transcripts/{name}`
   - transcript content for known generated artifacts

### Important note

Do not overexpose the filesystem as generic resources.
Keep resources bounded and domain-specific.

---

## 12. MCP Prompts for v1

Prompts are useful for discoverability and guided workflows.

### Recommended prompts

1. `transcribe-local-audio`
   - asks for audio path and desired output location

2. `batch-transcribe-folder`
   - asks for folder path and output directory

3. `diagnose-transcription-setup`
   - runs environment validation and suggests next steps

4. `inspect-last-transcript`
   - helps review a generated transcript

---

## 13. New Configuration Section

Add a dedicated MCP configuration section.

### Example

```json
{
  "mcp": {
    "enabled": true,
    "transport": "stdio",
    "serverName": "whispernet",
    "serverVersion": "1.0.0",
    "allowBatch": true,
    "allowedInputRoots": [
      "/absolute/path/to/artifacts/input",
      "/absolute/path/to/audio"
    ],
    "allowedOutputRoots": [
      "/absolute/path/to/artifacts/output",
      "/absolute/path/to/transcripts"
    ],
    "maxBatchFiles": 100,
    "requireAbsolutePaths": true,
    "resources": {
      "enabled": true,
      "exposeLastRun": true
    },
    "prompts": {
      "enabled": true
    },
    "logging": {
      "minimumLevel": "Information",
      "writeToStdErr": true,
      "writeToFile": false,
      "logFilePath": "artifacts/logs/mcp.log"
    },
    "http": {
      "enabled": false,
      "basePath": "/mcp",
      "urls": [
        "http://localhost:5238"
      ]
    }
  }
}
```

### Validation rules

- `transport` must be `stdio` or `http`
- input and output roots must be non-empty when path restriction is enabled
- `maxBatchFiles` must be positive
- if HTTP is enabled, `basePath` and `urls` must be valid
- if `writeToFile` is enabled, `logFilePath` must be writable

---

## 14. Logging Requirements

## Critical rule

When the server runs in **stdio MCP mode**, the implementation must **never** write arbitrary messages to stdout.

### Required behavior

- protocol frames use stdio transport
- all operational logs go to `stderr` or a file
- progress bars / ANSI console rendering used by CLI must not be reused as-is in MCP mode
- MCP tool progress must be sent through MCP progress notifications, not via console output

### Refactoring implication

All current direct console writes must be behind an abstraction or environment-specific host behavior.

---

## 15. Security Requirements

### Mandatory controls

- allow access only to configured local roots
- reject path traversal attempts
- do not expose arbitrary shell execution
- do not allow raw ffmpeg command strings from the model
- return sanitized error messages
- avoid leaking sensitive local paths beyond what is necessary
- redact secrets / environment variables from logs

### Destructive behavior policy

For MCP metadata:

- inspection tools: read-only
- transcription tools: not read-only, but non-destructive relative to source input
- transcript-reading tools: read-only

---

## 16. Implementation Phases

## Phase 0 — Baseline and Preparation

### Tasks

- create a new branch for MCP work
- document current CLI behavior that must remain unchanged
- inventory all direct `Console.WriteLine` / `Console.Error.WriteLine` usage
- inventory all places where file paths are accepted or constructed

### Deliverable

A clear list of CLI-only behaviors vs reusable application logic.

---

## Phase 1 — Extract Reusable Application Core

### Tasks

- create `WhisperNET.Application` project
- move configuration, audio, processing, and core services into reusable assemblies/namespaces
- introduce DTO contracts for request/response execution
- move orchestration out of `Program.cs` into host-agnostic execution services
- keep batch and single-file flows available through the same application layer

### Deliverable

A reusable application service that can be invoked from both CLI and MCP.

---

## Phase 2 — Preserve and Rewire CLI Host

### Tasks

- create or adapt `WhisperNET.Cli`
- keep current startup and config loading behavior
- adapt console progress and validation output to use host-specific reporters
- verify no regression in existing single and batch execution modes

### Deliverable

Current console app still works after refactoring.

---

## Phase 3 — Create MCP Server Host

### Tasks

- create `WhisperNET.McpServer` project
- add NuGet package `ModelContextProtocol` for stdio support
- add `ModelContextProtocol.AspNetCore` only if HTTP transport is also enabled in this iteration
- configure MCP server registration and transport
- register tool classes, prompt classes, resource handlers
- load shared application services through DI

### Required package baseline

- `ModelContextProtocol` `1.1.0`
- `ModelContextProtocol.AspNetCore` `1.1.0` only if HTTP transport is needed

### Deliverable

An MCP host that starts and is discoverable by an MCP client.

---

## Phase 4 — Implement Tool Layer

### Tasks

- add `WhisperMcpTools` class/classes
- implement explicit request validation inside each tool
- add structured descriptions for tool methods and parameters
- support `CancellationToken`
- support progress reporting where useful
- return structured content for main execution tools

### Design rules

- validate all tool inputs explicitly
- do not rely only on data annotations
- convert application results into MCP-friendly structured responses
- use clear descriptions because models depend on them

---

## Phase 5 — Implement Resources and Prompts

### Tasks

- add resources for config, model, languages, and last-run information
- add prompt templates for guided workflows
- make prompts optional via configuration

### Deliverable

Better discoverability and a more useful server UX in MCP-capable clients.

---

## Phase 6 — Add Safe Logging and Diagnostics

### Tasks

- route logs to stderr in stdio mode
- route logs to file if configured
- capture structured execution metadata
- add correlation/request IDs where reasonable
- create a small health/startup diagnostic path for MCP startup troubleshooting

---

## Phase 7 — Testing

### Unit tests

- path policy validation
- config validation
- DTO mapping
- error sanitization
- tool argument validation

### Integration tests

- server starts over stdio
- tools are listed successfully
- `validate_environment` works
- `transcribe_file` works on a small fixture
- batch path validation works
- cancellation works

### Manual tests

- test with MCP Inspector
- test with VS Code / GitHub Copilot `mcp.json`
- verify no stdout pollution

---

## Phase 8 — Documentation and Developer Experience

### Tasks

- update `README.md`
- add `MCP.md` or MCP section to README
- add sample `mcp.json`
- add example workflow screenshots later if desired
- document required environment variables and absolute path recommendations

---

## 17. Concrete File-Level Work Plan

## Files to create

```text
/src/WhisperNET.Application/Contracts/*.cs
/src/WhisperNET.Application/Execution/*.cs
/src/WhisperNET.Application/Security/PathPolicy.cs
/src/WhisperNET.McpServer/Program.cs
/src/WhisperNET.McpServer/Tools/WhisperMcpTools.cs
/src/WhisperNET.McpServer/Resources/WhisperMcpResources.cs
/src/WhisperNET.McpServer/Prompts/WhisperMcpPrompts.cs
/src/WhisperNET.McpServer/Configuration/McpOptions.cs
/tests/WhisperNET.McpServer.Tests/*
```

## Files to modify

```text
Program.cs
Configuration/TranscriptionOptions.cs
Services/StartupValidationService.cs
Services/LanguageSelectionService.cs
Services/ModelService.cs
Services/OutputWriter.cs
Services/ConsoleProgressService.cs
README.md
appsettings.example.json
```

### Important note

Some of the current files may move into the new shared application project rather than remain in their exact current path.

---

## 18. Example MCP Server Registration (Target Shape)

> This is design guidance, not final production code.

```csharp
var builder = Host.CreateApplicationBuilder(args);

builder.Services.Configure<McpOptions>(builder.Configuration.GetSection("mcp"));

builder.Services.AddSingleton<IPathPolicy, PathPolicy>();
builder.Services.AddSingleton<IStartupValidationFacade, StartupValidationFacade>();
builder.Services.AddSingleton<ITranscriptionFacade, TranscriptionFacade>();
builder.Services.AddSingleton<IModelInspectionFacade, ModelInspectionFacade>();
builder.Services.AddSingleton<ILanguageInfoFacade, LanguageInfoFacade>();

builder.Services
    .AddMcpServer(options =>
    {
        options.ServerInfo = new()
        {
            Name = "whispernet",
            Version = "1.0.0"
        };
    })
    .WithStdioServerTransport()
    .WithTools<WhisperMcpTools>()
    .WithPrompts<WhisperMcpPrompts>();

var app = builder.Build();
await app.RunAsync();
```

### Optional HTTP transport (phase 2)

```csharp
builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithTools<WhisperMcpTools>();

var app = webBuilder.Build();
app.MapMcp("/mcp");
app.Run();
```

---

## 19. Example MCP Tool Shape

> This is target-shape pseudocode.

```csharp
[McpServerToolType]
public sealed class WhisperMcpTools(
    ITranscriptionFacade transcriptionFacade,
    IStartupValidationFacade startupValidationFacade,
    IPathPolicy pathPolicy)
{
    [McpServerTool(
        Name = "transcribe_file",
        Title = "Transcribe Local Audio File",
        ReadOnly = false,
        Destructive = false,
        Idempotent = false,
        OpenWorld = false,
        UseStructuredContent = true)]
    [Description("Transcribes a local audio file using the existing WhisperNET pipeline and writes a transcript to a safe output path.")]
    public async Task<TranscribeFileResult> TranscribeFileAsync(
        [Description("Absolute path to a local audio file under allowed input roots.")] string inputPath,
        [Description("Optional absolute path for the resulting transcript file under allowed output roots.")] string? resultFilePath = null,
        CancellationToken cancellationToken = default,
        IProgress<ProgressNotificationValue>? progress = null)
    {
        // Validate input explicitly
        // Enforce path policy
        // Call reusable transcription facade
        // Return structured result
    }
}
```

---

## 20. Example `.vscode/mcp.json`

```json
{
  "servers": {
    "WhisperNET": {
      "type": "stdio",
      "command": "dotnet",
      "args": [
        "run",
        "--project",
        "src/WhisperNET.McpServer/WhisperNET.McpServer.csproj"
      ],
      "env": {
        "TRANSCRIPTION_SETTINGS_PATH": "/absolute/path/to/appsettings.json"
      }
    }
  }
}
```

### Important

Use **absolute paths** for configuration and local folders whenever possible.

---

## 21. Acceptance Criteria

## Functional

- MCP client can connect successfully
- tool list is visible
- `validate_environment` returns structured checks
- `transcribe_file` produces a transcript file and structured result
- `transcribe_batch` works when enabled
- `read_transcript` can read an allowed transcript file
- resources and prompts are discoverable when enabled

## Technical

- no stdout protocol corruption in stdio mode
- CLI mode still works
- long-running tools accept cancellation
- structured logging works
- path policy blocks unsafe file access
- tests pass

## Operational

- README documents setup clearly
- sample `mcp.json` works
- startup diagnostics are understandable

---

## 22. Main Risks and Mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Stdout pollution | Breaks stdio MCP protocol | Route logs to stderr/file only in MCP mode |
| Tight coupling to `Program.cs` | Hard to reuse current logic | Extract orchestration into application layer |
| Unsafe file path access | MCP tools receive model-supplied arguments | Enforce strict allowed-roots path policy |
| Batch execution too broad | Large runs may consume time/resources | Add `maxBatchFiles`, batch toggle, cancellation |
| Verbose CLI progress reused in MCP | Breaks protocol and adds noise | Introduce progress abstraction |
| Weak tool descriptions | Models use tools incorrectly | Add precise descriptions on tool methods and parameters |
| Missing runtime validation | Schema alone is not enough | Validate explicitly inside each tool |

---

## 23. Final Recommendation

For a professional implementation, the MCP feature should be built as a **new host over a reusable shared transcription core**, not as a thin wrapper around the current console entry point.

That is the cleanest path to:

- keep current CLI behavior intact
- make the system testable
- avoid stdio protocol corruption
- support future HTTP transport
- expose transcription safely to AI clients

---

## 24. Definition of Done

This roadmap is complete when the repository contains:

- a reusable shared transcription core
- a working CLI host
- a working MCP server host
- tested stdio MCP integration
- safe path handling
- structured tool outputs
- updated documentation

