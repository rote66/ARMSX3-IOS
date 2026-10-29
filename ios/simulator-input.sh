#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 'Usage: zsh ios/simulator-input.sh <JSON command> [simulator UDID]'
  exit 2
fi

container=$(xcrun simctl get_app_container "${2:-booted}" com.armsx3.ios data)
python3 - "$container/Documents/SimulatorInput.json" "$1" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

destination = pathlib.Path(sys.argv[1])
command = json.loads(sys.argv[2])
if not isinstance(command, dict):
    raise SystemExit("Simulator input must be a JSON object")
payload = json.dumps(command).encode("utf-8")
if len(payload) > 4096:
    raise SystemExit("Simulator input exceeds 4096 bytes")
with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
    temporary_path = pathlib.Path(temporary.name)
    temporary.write(payload)
try:
    os.replace(temporary_path, destination)
finally:
    temporary_path.unlink(missing_ok=True)
print(destination)
PY
