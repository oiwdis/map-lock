#!/bin/bash
# Checks question counts, require-100% rules, name/capital matching, and CountryFacts.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d)/quiz"
swiftc -O -o "$out" \
  Sources/MapLock/Countries.swift \
  Sources/MapLock/Answers.swift \
  Sources/MapLock/CountryFacts.swift \
  Sources/MapLock/Settings.swift \
  Sources/MapLock/Speedrun.swift \
  Sources/MapLock/Stats.swift \
  Sources/MapLock/QuizEngine.swift \
  Checks/quiz/main.swift
"$out" "$@"
