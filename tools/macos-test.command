#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
log_file="macos-test-$(date +%Y%m%d-%H%M%S).log"
echo "Runtime log: $PWD/$log_file"
export NSUnbufferedIO=YES
export OS_ACTIVITY_DT_MODE=YES
./scrcpy_flutter_example.app/Contents/MacOS/scrcpy_flutter_example 2>&1 | tee "$log_file"
