#!/bin/zsh
cd "$(dirname "$0")/.."
.build/debug/bleprint-selftest --e10 "Swift!" 2>&1 | tee scripts/live_log.txt
