#!/usr/bin/env bash
# Checks the editor engine against Docmost's document format (Engine/FORMAT.md) and builds it (TipTap + Yjs + the
# engine's own extensions for the format) into Diderot/Resources/Engine/engine.js. Requires Node 24 and Corepack (pnpm).
set -euo pipefail
cd "$(dirname "$0")/../Engine"
corepack pnpm install --silent
corepack pnpm run --silent check
corepack pnpm run --silent build
