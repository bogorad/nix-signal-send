#!/usr/bin/env bash

fail() {
  printf 'send-only test: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'send-only test: %s\n' "$*" >&2
}

message_tmp_files_exist() {
  compgen -G "$TMPDIR/signal-send-message.*.txt" >/dev/null
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
if message_tmp_files_exist; then
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

# The Signal body limit is on encoded bytes, not characters. 600 copies of
# U+1F600 are 600 characters but 2400 bytes, so they must take the attachment
# path. Under a UTF-8 locale a character-counting implementation sees 600 and
# skips it, which is what this checks.
msg_emoji="$(printf '\xf0\x9f\x98\x80%.0s' {1..600})"
emoji_bytes="$(printf '%s' "$msg_emoji" | wc -c)"
if [[ "$emoji_bytes" -ne 2400 ]]; then
  fail "multibyte fixture is $emoji_bytes bytes, expected 2400"
fi

# Probe the property the check depends on directly: whether '${#x}' counts a
# 2-byte sequence as one character. This avoids needing the 'locale' binary.
utf8_probe() {
  LC_ALL="$1" "$test_bash" <<'PROBE'
x="$(printf '\xc3\xa9')"
[[ "${#x}" -eq 1 ]]
PROBE
}

utf8_locale=""
for candidate in C.UTF-8 en_US.UTF-8; do
  if utf8_probe "$candidate" 2>/dev/null; then
    utf8_locale="$candidate"
    break
  fi
done
if [[ -z "$utf8_locale" ]]; then
  note 'no UTF-8 locale available; byte-vs-character check is weaker here'
fi

: >"$log"
status=0
LC_ALL="${utf8_locale:-${LC_ALL:-C}}" bash "$signal_send" "$msg_emoji" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "multibyte send exited $status"
fi
if ! grep -Fq ' --attach ' "$log"; then
  fail 'multibyte message over 2000 bytes did not use an attachment'
fi
if ! grep -Fq '[...]' "$log"; then
  fail 'multibyte long send did not use the preview body'
fi
if message_tmp_files_exist; then
  fail 'multibyte long send left a temp file behind'
fi

# 400 copies are 1600 bytes and must stay inline.
: >"$log"
msg_emoji_short="$(printf '\xf0\x9f\x98\x80%.0s' {1..400})"
status=0
LC_ALL="${utf8_locale:-${LC_ALL:-C}}" bash "$signal_send" "$msg_emoji_short" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "short multibyte send exited $status"
fi
if grep -Fq ' --attach ' "$log"; then
  fail 'multibyte message under 2000 bytes used an unexpected attachment'
fi

# A failed chmod must abort the send. '$?' inside 'if ! cmd' is the negated
# status, so capturing it there yields 0 and reports success.
shadow_dir="$root/shadow"
mkdir -p "$shadow_dir" || exit $?
printf '%s\n' "#!$test_bash" 'exit 1' >"$shadow_dir/chmod" || exit $?
chmod 0755 "$shadow_dir/chmod" || exit $?

: >"$log"
status=0
PATH="$shadow_dir:$PATH" bash "$signal_send" "$msg_2001" || status=$?
if [[ "$status" -eq 0 ]]; then
  fail 'long send reported success after chmod failed on the temp file'
fi
if grep -Fq ' send-to-group ' "$log"; then
  fail 'long send called send-to-group after chmod failed'
fi
if message_tmp_files_exist; then
  fail 'temp file survived a failed chmod'
fi

# An unwritable TMPDIR must fail the same way.
: >"$log"
ro_tmp="$root/ro-tmp"
mkdir -p "$ro_tmp" || exit $?
chmod 0500 "$ro_tmp" || exit $?
status=0
TMPDIR="$ro_tmp" bash "$signal_send" "$msg_2001" || status=$?
chmod 0700 "$ro_tmp" || exit $?
if [[ "$status" -eq 0 ]]; then
  fail 'long send reported success when the temp file could not be created'
fi
if grep -Fq ' send-to-group ' "$log"; then
  fail 'long send called send-to-group after mktemp failed'
fi

# An interrupted long send must not strand message plaintext in TMPDIR.
: >"$log"
slow_dir="$root/slow"
mkdir -p "$slow_dir" || exit $?
{
  printf '%s\n' "#!$test_bash"
  cat <<'EOF'
printf '%s\n' "$*" >>"$PRESAGE_FAKE_LOG"
sleep 3
EOF
} >"$slow_dir/presage-cli" || exit $?
chmod 0755 "$slow_dir/presage-cli" || exit $?

PATH="$slow_dir:$PATH" bash "$signal_send" "$msg_2001" &
send_pid=$!
waited=0
while [[ ! -s "$log" ]] && ((waited < 100)); do
  sleep 0.1
  waited=$((waited + 1))
done
if [[ ! -s "$log" ]]; then
  kill "$send_pid" 2>/dev/null
  wait "$send_pid" 2>/dev/null
  fail 'interrupt fixture never reached presage'
fi
if ! message_tmp_files_exist; then
  kill "$send_pid" 2>/dev/null
  wait "$send_pid" 2>/dev/null
  fail 'interrupt fixture never created a temp message file'
fi
kill -TERM "$send_pid" 2>/dev/null
wait "$send_pid" 2>/dev/null
if message_tmp_files_exist; then
  fail 'interrupted long send left message plaintext in TMPDIR'
fi

# A newline supplied as an argument is a real message, not an empty one.
: >"$log"
status=0
bash "$signal_send" $'\n' || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "newline-only argument was rejected (exit $status)"
fi
if ! grep -Fq ' send-to-group ' "$log"; then
  fail 'newline-only argument did not reach send-to-group'
fi

# Piped input still sends its body; command substitution drops the newline.
: >"$log"
status=0
printf '%s\n' 'piped hello' | bash "$signal_send" || status=$?
if [[ "$status" -ne 0 ]]; then
  fail "piped send exited $status"
fi
if ! grep -Fq ' --message piped hello' "$log"; then
  fail 'piped send did not pass the message body'
fi
if grep -Fq ' --attach ' "$log"; then
  fail 'piped short send used an unexpected attachment'
fi
