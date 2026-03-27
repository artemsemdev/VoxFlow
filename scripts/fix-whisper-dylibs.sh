#!/bin/bash
set -euo pipefail

APP_BUNDLE_PATH="${1:?expected app bundle path}"

run_install_name_tool() {
    local output
    if ! output=$("$@" 2>&1); then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

set_id() {
    local file="$1"
    if [ -f "$file" ]; then
        local expected_id="@loader_path/$(basename "$file")"
        local current_id
        current_id="$(otool -D "$file" | sed -n '2p')"

        if [ "$current_id" != "$expected_id" ]; then
            run_install_name_tool install_name_tool -id "$expected_id" "$file"
        fi
    fi
}

change_dep() {
    local file="$1"
    local old_dep="$2"
    local new_dep="$3"

    if [ -f "$file" ] && otool -L "$file" | grep -Fq "$old_dep"; then
        run_install_name_tool install_name_tool -change "$old_dep" "$new_dep" "$file"
    fi
}

fix_runtime_dir() {
    local runtime_dir="$1"

    if [ ! -d "$runtime_dir" ]; then
        return 0
    fi

    local base="$runtime_dir/libggml-base-whisper.dylib"
    local blas="$runtime_dir/libggml-blas-whisper.dylib"
    local cpu="$runtime_dir/libggml-cpu-whisper.dylib"
    local metal="$runtime_dir/libggml-metal-whisper.dylib"
    local ggml="$runtime_dir/libggml-whisper.dylib"
    local whisper="$runtime_dir/libwhisper.dylib"

    set_id "$base"
    set_id "$blas"
    set_id "$cpu"
    set_id "$metal"
    set_id "$ggml"
    set_id "$whisper"

    change_dep "$blas" "@rpath/libggml-base-whisper.dylib" "@loader_path/libggml-base-whisper.dylib"
    change_dep "$cpu" "@rpath/libggml-base-whisper.dylib" "@loader_path/libggml-base-whisper.dylib"
    change_dep "$metal" "@rpath/libggml-base-whisper.dylib" "@loader_path/libggml-base-whisper.dylib"

    change_dep "$ggml" "@rpath/libggml-cpu-whisper.dylib" "@loader_path/libggml-cpu-whisper.dylib"
    change_dep "$ggml" "@rpath/libggml-blas-whisper.dylib" "@loader_path/libggml-blas-whisper.dylib"
    change_dep "$ggml" "@rpath/libggml-metal-whisper.dylib" "@loader_path/libggml-metal-whisper.dylib"
    change_dep "$ggml" "@rpath/libggml-base-whisper.dylib" "@loader_path/libggml-base-whisper.dylib"

    change_dep "$whisper" "@rpath/libggml-whisper.dylib" "@loader_path/libggml-whisper.dylib"
    change_dep "$whisper" "@rpath/libggml-cpu-whisper.dylib" "@loader_path/libggml-cpu-whisper.dylib"
    change_dep "$whisper" "@rpath/libggml-blas-whisper.dylib" "@loader_path/libggml-blas-whisper.dylib"
    change_dep "$whisper" "@rpath/libggml-metal-whisper.dylib" "@loader_path/libggml-metal-whisper.dylib"
    change_dep "$whisper" "@rpath/libggml-base-whisper.dylib" "@loader_path/libggml-base-whisper.dylib"
}

fix_runtime_dir "$APP_BUNDLE_PATH/Contents/MonoBundle/runtimes/macos-x64"
fix_runtime_dir "$APP_BUNDLE_PATH/Contents/MonoBundle/runtimes/macos-arm64"
fix_runtime_dir "$APP_BUNDLE_PATH/Contents/MonoBundle/cli"
fix_runtime_dir "$APP_BUNDLE_PATH/Contents/MonoBundle/cli/runtimes/macos-x64"
fix_runtime_dir "$APP_BUNDLE_PATH/Contents/MonoBundle/cli/runtimes/macos-arm64"
