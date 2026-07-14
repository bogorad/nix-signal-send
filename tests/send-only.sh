#!/usr/bin/env bash

fail() {
  printf 'send-only test: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  fail 'expected paths to signal-send source script and Bash'
fi

signal_send=$1
test_bash=$2
root="$(mktemp -d)" || exit $?
cleanup() {
  rm -rf "$root"
}
trap cleanup EXIT

bin_dir="$root/bin"
state_dir="$root/state"
project_dir="$state_dir/projects/nix-config"
log="$root/presage.log"
mkdir -p "$bin_dir" "$project_dir" "$root/home" || exit $?
printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  >"$project_dir/group_master_key" || exit $?

fake_presage="$bin_dir/presage-cli"
printf '%s\n' \
  "#!$test_bash" \
  "printf '%s\\n' \"\$*\" >>\"\$PRESAGE_FAKE_LOG\"" \
  'exit 0' \
  >"$fake_presage" || exit $?
chmod 0755 "$fake_presage" || exit $?

PATH="$bin_dir:$PATH"
export PATH
HOME="$root/home"
export HOME
SIGNAL_SEND_STATE_DIR="$state_dir"
export SIGNAL_SEND_STATE_DIR
SIGNAL_SEND_PROJECT='nix-config'
export SIGNAL_SEND_PROJECT
PRESAGE_FAKE_LOG="$log"
export PRESAGE_FAKE_LOG

status=0
bash "$signal_send" 'hello' || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "send exited $status"
fi
if ! grep -Fq ' send-to-group ' "$log"; then
  fail 'send did not call send-to-group'
fi
if grep -Fq ' sync-contacts' "$log" || grep -Fq ' sync --stop-after-empty-queue' "$log"; then
  fail 'send invoked synchronization'
fi

: >"$log"
status=0
bash "$signal_send" sync || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "explicit sync exited $status"
fi
if ! grep -Fq ' sync-contacts' "$log"; then
  fail 'explicit sync did not synchronize contacts'
fi
if ! grep -Fq ' sync --stop-after-empty-queue' "$log"; then
  fail 'explicit sync did not drain the linked-device queue'
fi
if grep -Fq ' send-to-group ' "$log"; then
  fail 'explicit sync sent a message'
fi

: >"$log"
status=0
bash "$signal_send" reset-sessions || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "reset-sessions exited $status"
fi
if ! grep -Fq ' reset-sessions' "$log"; then
  fail 'reset-sessions did not call the Presage reset command'
fi
if [[ "$(wc -l <"$log")" -ne 1 ]]; then
  fail 'reset-sessions invoked more than one Presage command'
fi
if grep -Eq ' (sync-contacts|sync|send-to-group|link-device|unlink-device|whoami)( |$)' "$log"; then
  fail 'reset-sessions invoked receive, synchronization, send, link, unlink, or identity output'
fi
