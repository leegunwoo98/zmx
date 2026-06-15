#!/usr/bin/env bats
# Manifest persistence tests.
#
# The manifest is the first half of reboot persistence: a JSON file per session
# in {ZMX_DIR}/manifest/{name}.json that survives daemon death so `zmx restore`
# can re-spawn the session after a reboot.
#
# Contract:
#   - written when a non-task session is created via `attach`
#   - left in place on SIGTERM / daemon crash
#   - removed only when the user explicitly kills the session (`zmx kill`)
#   - task-mode sessions (`zmx run …`) are NOT persisted

load test_helper

manifest_file() {
  echo "$ZMX_DIR/manifest/$1.json"
}

# Create a long-lived non-task session by backgrounding `attach name cmd`.
# The client stays connected (in bg with no stdio); the daemon survives until
# we explicitly kill it. zmx's `attach` with a command is non-task-mode and
# is the only non-interactive way to create a persistent session.
start_attached_session() {
  local name="$1"
  # Subshell + background so the attach client outlives our test scope.
  # macOS has no setsid(1), so a subshell is the portable detach.
  ( "$ZMX" attach "$name" sleep 600 </dev/null >/dev/null 2>&1 & )
  wait_for_session "$name"
}

@test "manifest: written when an attach session is created" {
  start_attached_session persist-create

  [ -f "$(manifest_file persist-create)" ]

  run cat "$(manifest_file persist-create)"
  [[ "$output" == *'"name": "persist-create"'* ]]
  [[ "$output" == *'"cwd":'* ]]
  [[ "$output" == *'"command":'* ]]
  [[ "$output" == *'"created_at_ns":'* ]]
}

@test "manifest: removed on explicit \`zmx kill\`" {
  start_attached_session persist-kill
  [ -f "$(manifest_file persist-kill)" ]

  "$ZMX" kill persist-kill

  # Daemon shutdown is async-ish; poll briefly
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f "$(manifest_file persist-kill)" ] && break
    sleep 0.1
  done
  [ ! -f "$(manifest_file persist-kill)" ]
}

@test "manifest: survives SIGTERM on the daemon (simulates reboot)" {
  start_attached_session persist-sigterm
  [ -f "$(manifest_file persist-sigterm)" ]

  # SIGTERM the daemon directly (simulates `shutdown -r now` / reboot)
  local pid
  pid=$("$ZMX" list | grep persist-sigterm | sed -E 's/.*pid=([0-9]+).*/\1/')
  [ -n "$pid" ]
  kill -TERM "$pid"

  # Wait for socket file to disappear (proxy for daemon exit)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    "$ZMX" list --short 2>/dev/null | grep -qx persist-sigterm || break
    sleep 0.1
  done

  # Critical: manifest survives external SIGTERM
  [ -f "$(manifest_file persist-sigterm)" ]
}

@test "manifest: NOT written for task-mode sessions (\`zmx run …\`)" {
  # `run` without `-d` blocks until the wrapped command exits → task mode.
  # echo hi finishes immediately so this returns quickly without coreutils' timeout(1).
  run env SHELL=/bin/bash "$ZMX" run task-mode-test echo hi
  [ "$status" -eq 0 ]
  [ ! -f "$(manifest_file task-mode-test)" ]
}

# ============================================================================
# Snapshot (VT terminal state dump)
# ============================================================================

snapshot_file() {
  echo "$ZMX_DIR/snapshots/$1.vt"
}

# Boot a session that prints a known marker and then sleeps. Used to verify
# the snapshot captures live terminal content.
start_marked_session() {
  local name="$1" marker="$2"
  ( "$ZMX" attach "$name" bash -c "echo $marker; sleep 600" </dev/null >/dev/null 2>&1 & )
  wait_for_session "$name"
  sleep 0.5  # let the bash spawn + echo propagate through the VT
}

@test "snapshot: written on SIGTERM with the live VT contents" {
  start_marked_session snap-sigterm SNAPSHOT_MARKER_SIGTERM

  local pid
  pid=$("$ZMX" list | grep snap-sigterm | sed -E 's/.*pid=([0-9]+).*/\1/')
  [ -n "$pid" ]
  kill -TERM "$pid"

  # Wait for the daemon to exit (socket goes away)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    "$ZMX" list --short 2>/dev/null | grep -qx snap-sigterm || break
    sleep 0.1
  done

  [ -f "$(snapshot_file snap-sigterm)" ]
  # Snapshot is VT bytes — strip escapes and grep for the marker
  run cat "$(snapshot_file snap-sigterm)"
  [[ "$output" == *"SNAPSHOT_MARKER_SIGTERM"* ]]
}

@test "snapshot: removed on explicit \`zmx kill\` (no zombie restore data)" {
  start_marked_session snap-kill SNAPSHOT_MARKER_KILL
  # Even before the periodic timer fires, kill triggers the cleanup branch
  "$ZMX" kill snap-kill

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f "$(snapshot_file snap-kill)" ] && [ ! -f "$(manifest_file snap-kill)" ] && break
    sleep 0.1
  done
  [ ! -f "$(snapshot_file snap-kill)" ]
  [ ! -f "$(manifest_file snap-kill)" ]
}

@test "snapshot: NOT written for task-mode sessions" {
  run env SHELL=/bin/bash "$ZMX" run snap-task echo hi
  [ "$status" -eq 0 ]
  [ ! -f "$(snapshot_file snap-task)" ]
}
