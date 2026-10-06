#!/bin/sh
# Generates App/Grimoire.xcodeproj, injecting machine-specific values from .env (see .env.example).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$root/.env" ]; then set -a; . "$root/.env"; set +a; fi
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
cd "$root/App"
xcodegen generate "$@"
