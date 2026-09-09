# v2 Architecture Decision Records

| ADR | Decision | Status |
|-----|----------|--------|
| [001](001-project-structure.md) | SwiftPM package for logic, XcodeGen app shell, Swift 6 | Accepted |
| [002](002-whisper-cpp-speech-engine.md) | whisper.cpp via XCFramework; streaming dictation viable | Accepted |
| [003](003-dictation-state-machine.md) | Dictation as a pure state machine with windowed transcription | Accepted |
| [004](004-history-encryption.md) | History encryption: per-row AES-GCM with a Secure Enclave-wrapped key | Accepted |
| [005](005-rule-based-styling-pipeline.md) | Rule-based styling pipeline and where the LLM plugs in | Accepted |

v1 ADRs (001–027) live in the repository root under `docs/adr/` and `docs/architecture/06-decision-log.md`
until promotion; they describe the archived .NET implementation and do not apply to v2.
