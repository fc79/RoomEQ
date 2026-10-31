#!/bin/bash
# Runs the unit tests (RoomEQCore: render kernel, channel layout, latency math…).
# They don't touch audio hardware and need no permissions.
#
# Usage: ./run-tests.sh

set -euo pipefail
cd "$(dirname "$0")"
swift test "$@"
