#!/usr/bin/env bash
# Checks the editor engine against Docmost's document format (Engine/FORMAT.md), type-checks it and builds it (TipTap +
# Yjs + the engine's own extensions for the format) into Diderot/Resources/Engine/engine.js, as CI does. Requires Node 24
# and Corepack, which takes pnpm's version from Engine/package.json; the lockfile stays as committed.
set -euo pipefail
cd "$(dirname "$0")/../Engine"
corepack pnpm install --frozen-lockfile --silent
corepack pnpm run --silent check
corepack pnpm run --silent typecheck
corepack pnpm run --silent build
