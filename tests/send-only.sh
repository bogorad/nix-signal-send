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
{
  printf '%s\n' "#!$test_bash"
  cat <<'EOF'
printf '%s\n' "$*" >>"$PRESAGE_FAKE_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--attach" ]]; then
    shift
    if [[ -n "${1:-}" && -f "$1" ]]; then
      printf 'ATTACH_FILE %s\n' "$1" >>"$PRESAGE_FAKE_LOG"
      cat "$1" >>"$PRESAGE_FAKE_LOG"
      printf '\nATTACH_END\n' >>"$PRESAGE_FAKE_LOG"
    fi
  fi
  shift || true
done
exit 0
EOF
} >"$fake_presage" || exit $?
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
TMPDIR="$root/tmp"
export TMPDIR
mkdir -p "$TMPDIR" || exit $?

status=0
bash "$signal_send" 'hello' || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "send exited $status"
fi
if ! grep -Fq ' send-to-group ' "$log"; then
  fail 'send did not call send-to-group'
fi
if grep -Fq ' --attach ' "$log"; then
  fail 'short send used an unexpected attachment'
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

# Exactly 2000 chars stays in the body with no auto-attachment.
: >"$log"
msg_2000="$(printf '%*s' 2000 '' | tr ' ' 'a')"
status=0
bash "$signal_send" "$msg_2000" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "2000-char send exited $status"
fi
if ! grep -Fq " --message $msg_2000" "$log"; then
  fail '2000-char send did not pass the full body'
fi
if grep -Fq ' --attach ' "$log"; then
  fail '2000-char send used an unexpected attachment'
fi

# Over 2000 chars: preview body + full text attachment.
: >"$log"
msg_2001="$(printf '%*s' 2001 '' | tr ' ' 'b')"
preview="${msg_2001:0:200}[...]"
status=0
bash "$signal_send" "$msg_2001" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "2001-char send exited $status"
fi
if ! grep -Fq " --message $preview" "$log"; then
  fail '2001-char send did not use the 200-char preview body'
fi
if ! grep -Fq ' --attach ' "$log"; then
  fail '2001-char send did not attach the full message'
fi
if ! grep -Fq "ATTACH_FILE " "$log"; then
  fail 'fake presage did not see the auto attachment file'
fi
attach_body="$(awk '/^ATTACH_FILE /{flag=1; next} /^ATTACH_END$/{flag=0} flag' "$log")"
if [[ "$attach_body" != "$msg_2001" ]]; then
  fail 'auto attachment content did not match the full message'
fi
# Temp attachment must be removed after send.
if compgen -G "$TMPDIR/signal-send-message."*.txt >/dev/null; then
  fail 'auto attachment temp file was not cleaned up'
fi

# User --attach is preserved alongside the auto full-message attach.
: >"$log"
user_attach="$root/user-note.txt"
printf '%s\n' 'user note' >"$user_attach" || exit $?
status=0
bash "$signal_send" --attach "$user_attach" "$msg_2001" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "long send with user attach exited $status"
fi
if ! grep -Fq -- "--attach $user_attach" "$log"; then
  fail 'user --attach was not passed through on long send'
fi
attach_flags="$(grep -o -- '--attach' "$log" | wc -l)"
if [[ "$attach_flags" -lt 2 ]]; then
  fail "long send with user attach did not pass two --attach flags (got $attach_flags)"
fi
