#!/bin/sh
# Forwarding stub. The tool itself moved to targets/comfyui/scripts/ (2026-08-15, s35),
# where it sits beside model_scanner.py and rides into the comfyui image with it -- the
# scanner and the adopt tools classify the same files from the same evidence and now
# share one module of execution-free readers, so they live together.
#
# This stub exists ONLY so the host-side path documented in README.md / BUILD_NOTES.md
# (`./scripts/droste-hf-adopt.sh ...`) keeps working. It is four lines of shell, not a
# second copy of anything: delete it the moment those docs point at the new path.
# Everything (--help, exit codes, argv) passes straight through.
exec python3 "$(CDPATH= cd -- "$(dirname -- "$0")/../targets/comfyui/scripts" && pwd)/droste-hf-adopt.py" "$@"
