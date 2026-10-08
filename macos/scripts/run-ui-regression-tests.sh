#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
UI_TEST_BUILD="$(mktemp -d)"
trap 'rm -rf "$UI_TEST_BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library \
  macos/SC680Config/HID/*.swift \
  macos/SC680Config/Protocol/*.swift \
  macos/SC680Config/Models/*.swift \
  macos/SC680Config/Views/*.swift \
  macos/tests/UIRegressionTests.swift \
  -o "$UI_TEST_BUILD/ui-regression-tests"
"$UI_TEST_BUILD/ui-regression-tests"
