# Shared helpers for Recap scripts. Source this file; do not execute it
# directly.
#
#   source "$(dirname "$0")/lib.sh"
#
# Provides an mkdir-based mutex around xcodebuild/SPM invocations, because
# concurrent agent sessions building Recap at the same time can collide
# (transient xcodebuild exit 65, corrupted derived data, etc). See the
# "Multi-session build collisions" note in project memory.

RECAP_BUILD_LOCK_DIR="${RECAP_BUILD_LOCK_DIR:-/tmp/recap-build.lock}"
RECAP_BUILD_LOCK_TIMEOUT="${RECAP_BUILD_LOCK_TIMEOUT:-600}" # seconds (~10 min)
_recap_lock_acquired=0

# acquire_build_lock — blocks (with a poll-wait message) until the lock is
# free, then claims it and registers a trap to release it on EXIT. Reclaims
# stale locks automatically (holder PID no longer alive).
acquire_build_lock() {
  local waited=0
  local poll_interval=2
  local announced=0

  while true; do
    if mkdir "$RECAP_BUILD_LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$RECAP_BUILD_LOCK_DIR/pid"
      _recap_lock_acquired=1
      trap release_build_lock EXIT
      return 0
    fi

    local holder_pid=""
    if [[ -f "$RECAP_BUILD_LOCK_DIR/pid" ]]; then
      holder_pid="$(cat "$RECAP_BUILD_LOCK_DIR/pid" 2>/dev/null || true)"
    fi

    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      echo "stale Recap build lock held by dead pid $holder_pid — reclaiming"
      rm -rf "$RECAP_BUILD_LOCK_DIR"
      continue
    fi

    if [[ "$announced" -eq 0 ]]; then
      echo "waiting for concurrent Recap build (pid ${holder_pid:-unknown})..."
      announced=1
    fi

    if [[ "$waited" -ge "$RECAP_BUILD_LOCK_TIMEOUT" ]]; then
      echo "timed out after ${RECAP_BUILD_LOCK_TIMEOUT}s waiting for concurrent Recap build (pid ${holder_pid:-unknown})" >&2
      return 1
    fi

    sleep "$poll_interval"
    waited=$((waited + poll_interval))
  done
}

# release_build_lock — releases the lock if this process holds it. Safe to
# call multiple times (e.g. once explicitly, once via the EXIT trap).
release_build_lock() {
  if [[ "$_recap_lock_acquired" -eq 1 ]]; then
    rm -rf "$RECAP_BUILD_LOCK_DIR"
    _recap_lock_acquired=0
  fi
}
