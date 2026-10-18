# Onboarding appearance regression — 2026-09-12

**Reviewed: the reported white-on-light welcome is fixed in both light and dark appearances.**

The real onboarding canvas was always light, while its semantic title, subtitle and chips followed the dark system appearance. The [native baseline](before/Onboarding-1-welcome-dark.png) reproduces the user's reported screen. Production fix `1d6e8f7` preserves the existing light canvas and pairs dark-appearance foreground colors with a native dark canvas; card/keycap borders and navigation dots follow semantic foreground colors, and the Try It editor uses its native text background. It was integrated at `6172012`.

The baseline uses production `d78e8dd` with only the new render regression. It failed 11 checks: eight dark canvas states and the welcome title/subtitle/chip bands. The corrected run renders eight states in each appearance across three iterations: **48 captures**, all checks passing and clean complete-text and structured warning gates. Fixture correction `836f143` prepares content without ordering a window, preserving Try It’s production `onAppear` before configuration. The original PNGs are unchanged; paths and SHA-256 hashes are recorded in [the manifest](manifest.json).

The raster regression checks the actual canvas luminance in every state, and contrast-bearing text pixels in the welcome title (7:1), subtitle and chip bands (3:1). These are targeted guards against this reported mismatch, not a complete text-contrast or accessibility audit. The test's traffic lights represent window chrome; the production window supplies its real native controls.

| State | Light | Dark |
| --- | --- | --- |
| Welcome | [Capture](after/Onboarding-1-welcome.png) | [Capture](after/Onboarding-1-welcome-dark.png) |
| Permissions | [Capture](after/Onboarding-2-permissions.png) | [Capture](after/Onboarding-2-permissions-dark.png) |
| Accessibility denied | [Capture](after/Onboarding-2a-accessibility-denied.png) | [Capture](after/Onboarding-2a-accessibility-denied-dark.png) |
| Hotkeys | [Capture](after/Onboarding-3-hotkey.png) | [Capture](after/Onboarding-3-hotkey-dark.png) |
| Unknown fn action | [Capture](after/Onboarding-3a-hotkey-fn-unknown.png) | [Capture](after/Onboarding-3a-hotkey-fn-unknown-dark.png) |
| Model download | [Capture](after/Onboarding-4-model.png) | [Capture](after/Onboarding-4-model-dark.png) |
| Try It | [Capture](after/Onboarding-5-tryit.png) | [Capture](after/Onboarding-5-tryit-dark.png) |
| Inserted result | [Capture](after/Onboarding-5b-tryit-inserted.png) | [Capture](after/Onboarding-5b-tryit-inserted-dark.png) |

- [Expected-failing baseline log](validation/voxflow-onboarding-appearance-baseline.log.gz) and [structured report](validation/voxflow-onboarding-appearance-baseline.xcresult.json.gz).
- [Passing targeted log](validation/voxflow-onboarding-content-final.log.gz) and [structured report](validation/voxflow-onboarding-content-final.xcresult.json.gz).
- Source: [production onboarding](../../../VoxFlow/Onboarding/OnboardingWindow.swift) and [native appearance regression](../../../VoxFlowTests/OnboardingRenderTests.swift).

The final 16 after images come from accepted integrated commit `7a17996e93edd550a5ab8e97559e33a368434881` (production UI/release `6172012`). The complete run passed **1,360 cases, with five intentional skips and zero warnings**, including the executed real local LLM rewrite. Its [compressed complete log](../files-models-2026-09-12/validation/voxflow-completion-delivery.log.gz) and [structured report](../files-models-2026-09-12/validation/voxflow-completion-delivery.xcresult.json.gz) are shared with the Files/Models package and hashed in this manifest.
