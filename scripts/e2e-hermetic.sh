#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../engine"
bun install --frozen-lockfile
bun run test:e2e
