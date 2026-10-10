#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
log_file="macos-test-$(date +%Y%m%d-%H%M%S).log"
echo "Runtime log: $PWD/$log_file"
./scrcpy_flutter_example.app/Contents/MacOS/scrcpy_flutter_example 2>&1 | tee "$log_file"
