#!/bin/zsh
# Print every row of a CSV on a Nelko P21 (template "{Names}\n{Model}"), like "Print ALL rows".
# Usage: scripts/nelko_csv.command /path/to/labels.csv
cd "$(dirname "$0")/.."
.build/debug/bleprint-selftest --nelko-csv "${1:?usage: nelko_csv.command file.csv}" 2>&1 | tee scripts/nelko_log.txt
