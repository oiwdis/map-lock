#!/bin/bash
# Checks the contrast of every Light and Dark color pair in Sources/MapLock/Palette.swift.
# Exits with an error if any text is under 4.5:1 or a map shape is under 3:1.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/contrast"
swiftc -O -o "$out" Sources/MapLock/Palette.swift Checks/contrast/main.swift
"$out" "$@"
