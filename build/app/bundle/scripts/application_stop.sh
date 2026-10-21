#!/bin/sh
# ApplicationStop: intentionally a no-op. An in-place image bump is handled by
# `docker compose up -d` in ApplicationStart, which recreates changed
# containers without a full teardown (a `down` would needlessly drop valkey
# and the network). Runs from the previous revision; kept trivial so it can
# never fail a deploy.
set -eu

main() {
  echo "[codedeploy] ApplicationStop: nothing to do (in-place upgrade)" >&2
}

main "$@"
