#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -m)" in
    arm64)
        RID="maccatalyst-arm64"
        ;;
    x86_64)
        RID="maccatalyst-x64"
        ;;
    *)
        echo "Unsupported host architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

APP_PATH="$ROOT_DIR/src/VoxFlow.Desktop/bin/Debug/net9.0-maccatalyst/$RID/VoxFlow.Desktop.app"

dotnet build "$ROOT_DIR/src/VoxFlow.Desktop/VoxFlow.Desktop.csproj" -f net9.0-maccatalyst
VOXFLOW_RUN_DESKTOP_UI_TESTS=1 \
VOXFLOW_DESKTOP_UI_APP_PATH="$APP_PATH" \
dotnet test "$ROOT_DIR/tests/VoxFlow.Desktop.UiTests/VoxFlow.Desktop.UiTests.csproj" "$@"
