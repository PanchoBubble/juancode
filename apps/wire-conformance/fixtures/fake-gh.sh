#!/bin/bash
# Stand-in for `gh` while the conformance suite runs (JUANCODE_GH_BIN).
#
# The tracked-PR engine polls GitHub. A test run must not: no token, no network,
# no rate limit, and no chance of touching a real repository. Failing the way an
# unauthenticated gh fails is exactly what the engine already tolerates, so the
# watch list stays exactly what the scenario put in it.

echo "fake-gh: refusing to reach GitHub from a conformance run ($*)" >&2
exit 1
