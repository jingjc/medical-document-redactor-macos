#!/bin/sh

set -eu

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

mkdir -p Docs

module_cache="$repository_root/.build/privacy-guard-module-cache"
mkdir -p "$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

chmod +x .githooks/pre-commit .githooks/pre-push Scripts/install_privacy_hooks.sh
git config --local core.hooksPath .githooks

configured_path="$(git config --local --get core.hooksPath)"
if [ "$configured_path" != ".githooks" ]; then
    echo "Privacy hook installation failed." >&2
    exit 1
fi

/usr/bin/xcrun swift Scripts/privacy_guard.swift --self-test
/usr/bin/xcrun swift Scripts/privacy_guard.swift --worktree

echo "Privacy hooks are active for this checkout."
