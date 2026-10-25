#!/bin/bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TARTBOX="$ROOT/tartbox"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tartbox-tests.XXXXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_STATE="$TEST_ROOT/state"
MOCK_LOG="$TEST_ROOT/tart.log"
PASS=0
FAIL=0

cleanup() {
  if [[ -f "$MOCK_STATE/pid" ]]; then
    kill "$(cat "$MOCK_STATE/pid")" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_ROOT"
}

stop_mock_process() {
  if [[ -f "$MOCK_STATE/pid" ]]; then
    kill "$(cat "$MOCK_STATE/pid")" 2>/dev/null || true
    rm -f "$MOCK_STATE/pid"
  fi
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
}

contains() {
  grep -Fq -- "$2" "$1"
}

not_contains() {
  ! grep -Fq -- "$2" "$1"
}

assert() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

count_matches() {
  local expected="$1" file="$2" pattern="$3" actual
  actual="$(grep -Fc -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]]
}

mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$TEST_ROOT/home" \
  "$TEST_ROOT/dev/project space" "$TEST_ROOT/dev/nested/child"
: > "$MOCK_LOG"
: > "$MOCK_STATE/running"

cat > "$MOCK_BIN/tart" <<'MOCK'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$MOCK_LOG"

remove_running() {
  local vm="$1" next="$MOCK_STATE/running.next"
  grep -Fxv -- "$vm" "$MOCK_STATE/running" > "$next" || true
  mv "$next" "$MOCK_STATE/running"
}

case "${1:-}" in
  --version)
    printf '2.29.0-test\n'
    ;;
  get)
    if [[ "$2" == "goldcopy" && "${MOCK_NO_GOLD:-0}" != "1" ]]; then
      exit 0
    fi
    [[ -e "$MOCK_STATE/vm-$2" ]]
    ;;
  list)
    while IFS= read -r vm; do
      [[ -n "$vm" ]] && printf 'local %s test running\n' "$vm"
    done < "$MOCK_STATE/running"
    ;;
  clone)
    : > "$MOCK_STATE/vm-$3"
    ;;
  run)
    vm="${!#}"
    printf '%s\n' "$vm" >> "$MOCK_STATE/running"
    printf '%s\n' "$$" > "$MOCK_STATE/pid"
    /bin/sleep 30
    ;;
  exec)
    shift
    [[ "${1:-}" == "-it" ]] && shift
    vm="$1"
    shift
    if [[ "${1:-}" == "true" ]]; then
      [[ "${MOCK_MODE:-ready}" == "timeout" ]] && exit 1
      grep -Fxq -- "$vm" "$MOCK_STATE/running"
      exit
    fi
    if [[ "${1:-}" == "sudo" && "${2:-}" == "networksetup" ]]; then
      if [[ "${MOCK_INTERRUPT_DNS:-0}" == "1" ]]; then
        kill -TERM "$PPID"
        exit 1
      fi
      [[ "${MOCK_FAIL_DNS:-0}" == "1" ]] && exit 1
      exit 0
    fi
    if [[ "${1:-}" == "zsh" && "${3:-}" == *"command -v"* ]]; then
      [[ "${3:-}" == *"codex"* ]]
      exit
    fi
    if [[ "${1:-}" == "zsh" && "${3:-}" == "test -f ~/.codex/config.toml" ]]; then
      [[ -e "$MOCK_STATE/codex-config-$vm" ]]
      exit
    fi
    if [[ "${1:-}" == "zsh" && "${3:-}" == "test -e ~/.codex/config.toml.tartbox-backup" ]]; then
      [[ -e "$MOCK_STATE/codex-backup-$vm" ]]
      exit
    fi
    if [[ "${1:-}" == "zsh" && "${3:-}" == *"cp -p ~/.codex/config.toml"* ]]; then
      : > "$MOCK_STATE/codex-backup-$vm"
      exit 0
    fi
    if [[ "${1:-}" == "zsh" && "${3:-}" == *"cat > ~/.codex/config.toml"* ]]; then
      : > "$MOCK_STATE/codex-config-$vm"
      exit 0
    fi
    exit 0
    ;;
  stop)
    if [[ "${MOCK_FAIL_STOP_ONCE:-0}" == "1" && ! -e "$MOCK_STATE/stop-failed-once" ]]; then
      : > "$MOCK_STATE/stop-failed-once"
      exit 1
    fi
    [[ "${MOCK_FAIL_STOP:-0}" == "1" ]] && exit 1
    remove_running "$2"
    ;;
esac
MOCK

cat > "$MOCK_BIN/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK

cat > "$MOCK_BIN/plutil" <<'MOCK'
#!/bin/bash
exit 0
MOCK

cat > "$MOCK_BIN/launchctl" <<'MOCK'
#!/bin/bash
exit 0
MOCK

chmod +x "$MOCK_BIN/tart" "$MOCK_BIN/sleep" "$MOCK_BIN/plutil" "$MOCK_BIN/launchctl"

export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$TEST_ROOT/home"
export TARTBOX_DEV_ROOT="$TEST_ROOT/dev"
export MOCK_LOG MOCK_STATE

PROJECT="$TEST_ROOT/dev/project space"
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum -a 256 | awk '{print substr($1,1,8)}')"
AUTO_VM="tartbox-project-space-$PROJECT_HASH"

# Invalid workspaces must fail before even read-only Tart inspection.
: > "$MOCK_LOG"
if (cd "$TEST_ROOT/dev/nested/child" && "$TARTBOX" --no-update >"$TEST_ROOT/invalid.out" 2>&1); then
  fail "nested workspace is refused"
else
  pass "nested workspace is refused"
fi
assert "invalid workspace makes no Tart calls" test ! -s "$MOCK_LOG"

# Both deterministic and custom running project VMs must be refused.
: > "$MOCK_STATE/vm-$AUTO_VM"
printf '%s\n' "$AUTO_VM" > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if (cd "$PROJECT" && "$TARTBOX" --no-update >"$TEST_ROOT/running-auto.out" 2>&1); then
  fail "already-running automatic VM is refused"
else
  pass "already-running automatic VM is refused"
fi
assert "automatic refusal explains unverifiable shares" contains "$TEST_ROOT/running-auto.out" "cannot verify how that VM was started"
assert "automatic refusal does not mutate Tart" not_contains "$MOCK_LOG" "run --net-softnet"

: > "$MOCK_STATE/vm-custom.vm"
printf '%s\n' "custom.vm" > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if (cd "$PROJECT" && "$TARTBOX" --name custom.vm --no-update >"$TEST_ROOT/running-custom.out" 2>&1); then
  fail "already-running custom VM is refused"
else
  pass "already-running custom VM is refused"
fi
assert "custom refusal does not stop the existing VM" not_contains "$MOCK_LOG" "stop custom.vm"

# A project VM may never alias the credential-bearing gold VM.
: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if (cd "$PROJECT" && "$TARTBOX" --name goldcopy --no-update >"$TEST_ROOT/gold-alias.out" 2>&1); then
  fail "gold VM cannot be selected as a project VM"
else
  pass "gold VM cannot be selected as a project VM"
fi
assert "gold alias refusal is clear" contains "$TEST_ROOT/gold-alias.out" "cannot be used as a project VM"
assert "gold alias is refused before Tart access" test ! -s "$MOCK_LOG"

# A stopped existing VM is started by Tartbox with exactly one validated share.
: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
(cd "$PROJECT" && "$TARTBOX" --name custom.vm --no-update >"$TEST_ROOT/stopped.out" 2>&1)
assert "stopped existing VM is started" contains "$MOCK_LOG" "run --net-softnet --dir=workspace:$PROJECT custom.vm"
assert "custom name cannot alter workspace share" not_contains "$MOCK_LOG" "--dir=workspace:custom.vm"
assert "Codex launch enforces danger-full-access" contains "$MOCK_LOG" "codex --sandbox danger-full-access --ask-for-approval never -C /Volumes/My Shared Files/workspace"
stop_mock_process

# A new VM is cloned and launched with the canonical workspace share.
: > "$MOCK_STATE/running"
rm -f "$MOCK_STATE/vm-new.vm"
: > "$MOCK_LOG"
(cd "$PROJECT" && "$TARTBOX" --name new.vm --no-update >"$TEST_ROOT/new.out" 2>&1)
assert "new VM is cloned from gold" contains "$MOCK_LOG" "clone goldcopy new.vm"
assert "new VM gets exactly the validated workspace" contains "$MOCK_LOG" "run --net-softnet --dir=workspace:$PROJECT new.vm"
stop_mock_process

# Predictable legacy log names cannot be used to truncate another file.
VICTIM="$TEST_ROOT/victim"
SYMLINK_VM="symlink-${RANDOM}.vm"
LEGACY_LOG="/tmp/tartbox-${SYMLINK_VM}.log"
UNTRUSTED_TMP="$TEST_ROOT/untrusted-tmp"
mkdir -p "$UNTRUSTED_TMP"
printf 'do not truncate\n' > "$VICTIM"
ln -s "$VICTIM" "$LEGACY_LOG"
: > "$MOCK_STATE/running"
rm -f "$MOCK_STATE/vm-$SYMLINK_VM"
(cd "$PROJECT" && TMPDIR="$UNTRUSTED_TMP" "$TARTBOX" --name "$SYMLINK_VM" --no-update >"$TEST_ROOT/symlink.out" 2>&1)
assert "predictable log symlink is not followed" contains "$VICTIM" "do not truncate"
assert "startup logs do not trust invoking TMPDIR" test -z "$(find "$UNTRUSTED_TMP" -mindepth 1 -print -quit)"
rm -f "$LEGACY_LOG"
stop_mock_process

# Timeout cleanup terminates its process and stops only its own attempted VM.
printf '%s\n' "unrelated.vm" > "$MOCK_STATE/running"
rm -f "$MOCK_STATE/vm-timeout.vm"
: > "$MOCK_LOG"
if (cd "$PROJECT" && MOCK_MODE=timeout "$TARTBOX" --name timeout.vm --no-update >"$TEST_ROOT/timeout.out" 2>&1); then
  fail "startup timeout fails"
else
  pass "startup timeout fails"
fi
assert "timeout stops the VM Tartbox attempted" contains "$MOCK_LOG" "stop timeout.vm"
assert "timeout does not stop an unrelated VM" not_contains "$MOCK_LOG" "stop unrelated.vm"
assert "unrelated VM remains running" contains "$MOCK_STATE/running" "unrelated.vm"
if [[ -f "$MOCK_STATE/pid" ]] && kill -0 "$(cat "$MOCK_STATE/pid")" 2>/dev/null; then
  fail "timeout terminates its Tart process"
else
  pass "timeout terminates its Tart process"
fi

# Gold names fail before Tart is invoked.
: > "$MOCK_LOG"
if (cd "$PROJECT" && TARTBOX_GOLD_VM='bad gold/name' "$TARTBOX" --no-update >"$TEST_ROOT/gold-name.out" 2>&1); then
  fail "malformed gold VM name is refused"
else
  pass "malformed gold VM name is refused"
fi
assert "malformed gold name makes no Tart calls" test ! -s "$MOCK_LOG"

# Gold maintenance refuses pre-running VMs and owns stopped VMs through cleanup.
printf '%s\n' "goldcopy" > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if "$TARTBOX" --update-gold >"$TEST_ROOT/gold-running.out" 2>&1; then
  fail "already-running gold maintenance is refused"
else
  pass "already-running gold maintenance is refused"
fi
assert "pre-running gold VM is not stopped" not_contains "$MOCK_LOG" "stop goldcopy"

: > "$MOCK_STATE/running"
: > "$MOCK_STATE/codex-config-goldcopy"
rm -f "$MOCK_STATE/codex-backup-goldcopy"
: > "$MOCK_LOG"
"$TARTBOX" --update-gold >"$TEST_ROOT/gold-success.out" 2>&1
assert "successful gold maintenance stops its VM" contains "$MOCK_LOG" "stop goldcopy"
assert "successful gold cleanup stops exactly once" count_matches 1 "$MOCK_LOG" "stop goldcopy"
assert "first Codex configuration preserves original backup" contains "$MOCK_LOG" "cp -p ~/.codex/config.toml ~/.codex/config.toml.tartbox-backup"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
rm -f "$MOCK_STATE/stop-failed-once"
if MOCK_FAIL_STOP_ONCE=1 "$TARTBOX" --update-gold >"$TEST_ROOT/gold-stop-failure.out" 2>&1; then
  fail "gold stop failure is reported"
else
  pass "gold stop failure is reported"
fi
assert "gold stop failure does not report refresh success" not_contains "$TEST_ROOT/gold-stop-failure.out" "Gold image refreshed"
assert "failed explicit cleanup retains ownership for EXIT" count_matches 2 "$MOCK_LOG" "stop goldcopy"
assert "final EXIT cleanup stops the gold VM" not_contains "$MOCK_STATE/running" "goldcopy"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if MOCK_FAIL_STOP=1 "$TARTBOX" --update-gold >"$TEST_ROOT/gold-stop-always-fails.out" 2>&1; then
  fail "persistent gold stop failure is reported"
else
  pass "persistent gold stop failure is reported"
fi
assert "cleanup failure gets one bounded EXIT attempt without recursion" count_matches 2 "$MOCK_LOG" "stop goldcopy"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
"$TARTBOX" --update-gold >"$TEST_ROOT/gold-second.out" 2>&1
assert "subsequent Codex configuration does not overwrite backup" not_contains "$MOCK_LOG" "cp -p ~/.codex/config.toml ~/.codex/config.toml.tartbox-backup"
assert "existing original backup is reported as preserved" contains "$TEST_ROOT/gold-second.out" "Preserving existing backup"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
if MOCK_FAIL_DNS=1 "$TARTBOX" --update-gold >"$TEST_ROOT/gold-failure.out" 2>&1; then
  fail "post-readiness gold failure is reported"
else
  pass "post-readiness gold failure is reported"
fi
assert "post-readiness failure stops owned gold VM" contains "$MOCK_LOG" "stop goldcopy"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
MOCK_INTERRUPT_DNS=1 "$TARTBOX" --update-gold >"$TEST_ROOT/gold-interrupt.out" 2>&1
interrupt_status=$?
if [[ "$interrupt_status" -eq 0 ]]; then
  fail "gold maintenance interruption exits unsuccessfully"
else
  pass "gold maintenance interruption exits unsuccessfully"
fi
assert "gold maintenance interruption preserves status 130" test "$interrupt_status" -eq 130
assert "interruption stops owned gold VM" contains "$MOCK_LOG" "stop goldcopy"
assert "successful signal cleanup stops exactly once" count_matches 1 "$MOCK_LOG" "stop goldcopy"
stop_mock_process

: > "$MOCK_STATE/running"
: > "$MOCK_LOG"
MOCK_INTERRUPT_DNS=1 MOCK_FAIL_STOP=1 \
  "$TARTBOX" --update-gold >"$TEST_ROOT/gold-interrupt-stop-failure.out" 2>&1
interrupt_cleanup_status=$?
assert "signal cleanup failure preserves status 130" test "$interrupt_cleanup_status" -eq 130
assert "signal cleanup failure is reported" contains "$TEST_ROOT/gold-interrupt-stop-failure.out" "Gold VM cleanup failed"
assert "signal cleanup gets one bounded EXIT attempt" count_matches 2 "$MOCK_LOG" "stop goldcopy"
stop_mock_process

# Scheduling refuses guest-writable executables, then works from a host-only path.
: > "$MOCK_LOG"
if TARTBOX_DEV_ROOT="$ROOT" "$TARTBOX" --schedule-update >"$TEST_ROOT/schedule-unsafe.out" 2>&1; then
  fail "scheduling refuses executable inside development root"
else
  pass "scheduling refuses executable inside development root"
fi
assert "unsafe scheduling explains host-only install" contains "$TEST_ROOT/schedule-unsafe.out" "host-only location"

mkdir -p "$TEST_ROOT/dev/tool" "$TEST_ROOT/host-bin"
cp "$TARTBOX" "$TEST_ROOT/dev/tool/tartbox"
chmod +x "$TEST_ROOT/dev/tool/tartbox"
ln -s "$TEST_ROOT/dev/tool/tartbox" "$TEST_ROOT/host-bin/tartbox"
if "$TEST_ROOT/host-bin/tartbox" --schedule-update >"$TEST_ROOT/schedule-symlink.out" 2>&1; then
  fail "scheduling resolves symlink into development root"
else
  pass "scheduling resolves symlink into development root"
fi

# Scheduled jobs use Sunday and a fixed PATH, not the invoking value.
: > "$MOCK_LOG"
PATH="$MOCK_BIN:/evil/bin:/usr/bin:/bin" "$TARTBOX" --schedule-update >"$TEST_ROOT/schedule.out" 2>&1
PLIST="$HOME/Library/LaunchAgents/dev.tartbox.update-gold.plist"
assert "LaunchAgent excludes arbitrary PATH entries" not_contains "$PLIST" "/evil/bin"
assert "LaunchAgent includes explicit Homebrew and system paths" contains "$PLIST" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
assert "LaunchAgent records the intended Tartbox executable" contains "$PLIST" "$TARTBOX"
assert "LaunchAgent schedules Sunday" contains "$PLIST" "<key>Weekday</key><integer>0</integer>"

# Doctor may inspect but must not mutate.
: > "$MOCK_LOG"
"$TARTBOX" --doctor >"$TEST_ROOT/doctor.out" 2>&1
if grep -Eq '^(clone|run|stop) ' "$MOCK_LOG"; then
  fail "doctor remains read-only"
else
  pass "doctor remains read-only"
fi

printf '\n%d passed; %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
