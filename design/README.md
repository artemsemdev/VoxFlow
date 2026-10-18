# Design source

`VoxFlow.dc.html` is the Claude Design canvas that specifies v2 (three design turns:
Flow Bar, menu bar, main window, onboarding, settings, sheets, empty states, edge cases,
plus the screen inventory in section 3b and interaction timings in 3d). `support.js` is
its runtime; open the HTML in a browser to browse the screens interactively.

Treat it as the product spec: screen IDs such as `FB-04b` or `ST-03v` in issues, code
comments and tests refer to this file. Export from
https://claude.ai/design/p/4f3875cb-2265-49cb-90e2-829c17812240 when it changes.

## App icon

`VoxFlow/Assets.xcassets/AppIcon.appiconset` contains the exact blue four-bar logo from
canvas `MW-06c`, rendered at 1024 px with transparent corners and resized for the macOS
16/32/128/256/512 pt slots at 1× and 2×. The source is the first 56 px logo span inside
`#s-MW-06c`; its four bar heights are 13/27/19/10 px. Do not replace it with the generic
application icon or a differently shaped waveform.
