#!/usr/bin/env bash
# Run Echidna (trail of bits' state-invariant fuzzer) on the BeanstalkGov
# reduction. Demonstrates that all plausible state invariants hold even
# while our incentive fuzzer finds a profitable deviation on the same code.
#
# Requires docker. Pulls trailofbits/echidna on first run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

docker run --rm -t \
  -v "${HERE}":/work \
  -w /work \
  trailofbits/echidna \
  echidna BeanstalkGovEchidna.sol \
    --contract EchidnaTest \
    --config echidna.yaml \
    --format text
