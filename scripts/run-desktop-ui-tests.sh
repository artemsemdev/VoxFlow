#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
RESULTS_DIR="$ROOT_DIR/artifacts/test-results/desktop-ui/$RUN_ID"
BUILD_TIME_LOG="$RESULTS_DIR/build.time.txt"
TEST_TIME_LOG="$RESULTS_DIR/test.time.txt"
TRX_FILE="desktop-ui-$RUN_ID.trx"
PROGRESS_LOG="$RESULTS_DIR/progress.log"

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

mkdir -p "$RESULTS_DIR"
touch "$PROGRESS_LOG"

cleanup_background_processes() {
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi

    if [[ -n "${TEST_PID:-}" ]] && kill -0 "$TEST_PID" 2>/dev/null; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
}

trap cleanup_background_processes EXIT INT TERM

monitor_test_progress() {
    local watched_pid="$1"
    local started_at
    local next_heartbeat_at
    local last_line=0

    started_at="$(date +%s)"
    next_heartbeat_at=$((started_at + 15))

    while kill -0 "$watched_pid" 2>/dev/null; do
        if [[ -f "$PROGRESS_LOG" ]]; then
            local current_line_count
            current_line_count="$(wc -l < "$PROGRESS_LOG" | tr -d ' ')"
            if (( current_line_count > last_line )); then
                sed -n "$((last_line + 1)),${current_line_count}p" "$PROGRESS_LOG" | while IFS= read -r line; do
                    [[ -n "$line" ]] && echo "[ui-progress] $line"
                done
                last_line="$current_line_count"
            fi
        fi

        local now
        now="$(date +%s)"
        if (( now >= next_heartbeat_at )); then
            local elapsed=$((now - started_at))
            printf '[heartbeat] ui tests still running, elapsed %02d:%02d\n' $((elapsed / 60)) $((elapsed % 60))
            next_heartbeat_at=$((now + 15))
        fi

        sleep 2
    done

    if [[ -f "$PROGRESS_LOG" ]]; then
        local final_line_count
        final_line_count="$(wc -l < "$PROGRESS_LOG" | tr -d ' ')"
        if (( final_line_count > last_line )); then
            sed -n "$((last_line + 1)),${final_line_count}p" "$PROGRESS_LOG" | while IFS= read -r line; do
                [[ -n "$line" ]] && echo "[ui-progress] $line"
            done
        fi
    fi
}

echo "Desktop UI test run: $RUN_ID"
echo "Results directory: $RESULTS_DIR"
echo "Target app bundle: $APP_PATH"
echo "Live progress log: $PROGRESS_LOG"
echo

echo "Building VoxFlow.Desktop..."
/usr/bin/time -p -o "$BUILD_TIME_LOG" \
    dotnet build "$ROOT_DIR/src/VoxFlow.Desktop/VoxFlow.Desktop.csproj" -f net9.0-maccatalyst
echo "Build timing:"
cat "$BUILD_TIME_LOG"
echo

echo "Running real Desktop UI tests..."
set +e
/usr/bin/time -p -o "$TEST_TIME_LOG" \
    env \
    VOXFLOW_RUN_DESKTOP_UI_TESTS=1 \
    VOXFLOW_DESKTOP_UI_APP_PATH="$APP_PATH" \
    VOXFLOW_DESKTOP_UI_PROGRESS_LOG="$PROGRESS_LOG" \
    dotnet test "$ROOT_DIR/tests/VoxFlow.Desktop.UiTests/VoxFlow.Desktop.UiTests.csproj" \
    --logger "trx;LogFileName=$TRX_FILE" \
    --results-directory "$RESULTS_DIR" \
    "$@" &
TEST_PID=$!

monitor_test_progress "$TEST_PID" &
MONITOR_PID=$!

wait "$TEST_PID"
TEST_EXIT_CODE=$?
wait "$MONITOR_PID" || true
set -e
trap - EXIT INT TERM

echo "Test timing:"
cat "$TEST_TIME_LOG"
echo

echo "TRX report: $RESULTS_DIR/$TRX_FILE"
echo "Build timing log: $BUILD_TIME_LOG"
echo "Test timing log: $TEST_TIME_LOG"
echo "Live progress log: $PROGRESS_LOG"

if (( TEST_EXIT_CODE != 0 )); then
    echo "Desktop UI tests failed with exit code $TEST_EXIT_CODE" >&2
    exit "$TEST_EXIT_CODE"
fi
