#!/bin/bash
# Checks MapZoomState clamp / pan / hit-point math (no AppKit needed).
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/zoom"
swiftc -D MAPLOCK_LOGIC_CHECKS -O -o "$out" \
  Sources/MapLock/MapZoom.swift \
  Checks/zoom/main.swift
"$out" "$@"
