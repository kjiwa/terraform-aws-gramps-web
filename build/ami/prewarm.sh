#!/bin/sh
# Reads every file on the root filesystem at boot to force EBS to hydrate the
# AMI snapshot's blocks from S3 before the app's own cold-import touches them
# one at a time. Runs concurrently with cloud-init/CodeDeploy (no boot
# dependency), so blocks it reaches first are warm by the time the app wants
# them.
#
# Reads through the filesystem, not `dd` over the raw block device: measured
# on a t3.medium, a whole-device dd sweep took 197-204s regardless of 8 vs 32
# parallel streams -- gp3's 125MB/s baseline throughput cap applies to the
# ~15GiB of never-written address space exactly like it does to real data, so
# sweeping the raw device pays full price for space nothing will ever read.
# Walking real files touches only allocated extents: the same measured root
# (~6.9GB used) came back in 63s at 32-way parallelism (107MB/s) -- comfortably
# inside the ~70-110s window between boot and ApplicationStart. 8-way managed
# only 83MB/s (81s); the gap is per-file open/close overhead, not the device
# ceiling, so parallelism past the device limit still helps here.
#
# Installed by build/ami/install.sh as /usr/local/bin/gramps-prewarm, run by
# gramps-prewarm.service. Always exits 0: an optimisation, never a boot
# dependency.
set -eu

readonly PARALLEL_READERS=32

log() {
  echo "[prewarm] $*"
}

main() {
  _main_rate=""
  log "Pre-warming root filesystem (parallel=$PARALLEL_READERS)..."
  _main_start=$(date +%s)
  find / -xdev -type f -print0 2>/dev/null |
    xargs -0 -P "$PARALLEL_READERS" -n 20 cat >/dev/null 2>/dev/null || true
  _main_end=$(date +%s)
  _main_elapsed=$((_main_end - _main_start))
  _main_used_kb="$(df -x tmpfs -x devtmpfs --output=used / 2>/dev/null | tail -n 1 | tr -d ' ')" || _main_used_kb=0
  if [ "${_main_elapsed:-0}" -gt 0 ] && [ "${_main_used_kb:-0}" -gt 0 ]; then
    _main_rate=$(((_main_used_kb / 1024) / _main_elapsed))
  else
    _main_rate=0
  fi
  log "Pre-warm complete: ${_main_elapsed}s, ${_main_rate}MB/s (used ${_main_used_kb}KB)."
  exit 0
}

main "$@"
