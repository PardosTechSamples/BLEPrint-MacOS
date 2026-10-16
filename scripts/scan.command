#!/bin/zsh
cd "$(dirname "$0")/.."
.build/debug/bleprint-selftest --scan 2>&1 | tee scripts/live_log.txt
