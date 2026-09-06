#!/usr/bin/env bash
fail() { printf 'signal-cli contract: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'expected wrapper and Bash paths'
signal_send=$1
test_bash=$2
root="$(mktemp -d)" || exit $?
cleanup() { rm -rf "$root"; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
mkdir -p "$root/bin" "$root/state/projects/test" "$root/tmp" || exit $?
group_id='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
printf '%s\n' "$group_id" >"$root/state/projects/test/group_id" || exit $?
cat >"$root/bin/signal-cli" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --config && "$2" == "$SIGNAL_SEND_STATE_DIR/signal-cli" ]] || exit 90
shift 2
if [[ "$1" == --output ]]; then
  [[ "$2" == json ]] || exit 91
  shift 2
fi
command=$1
shift
printf '%s\n' "$command" >>"$FAKE_LOG"
case "$command" in
  listAccounts) printf '%s\n' '[{"number":"+12025550123"}]' ;;
  listGroups)
    [[ "${FAKE_BAD_JSON:-0}" == 0 ]] || { printf 'broken'; exit 0; }
    printf '%s\n' '[{"id":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","name":"a group / revision 5\nwith tabs\tand quotes\"","isMember":true,"isBlocked":false},{"id":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=","name":"another","isMember":true,"isBlocked":false}]'
    ;;
  sendSyncRequest) exit "${FAKE_SYNC_STATUS:-0}" ;;
  receive)
    [[ "$*" == '--timeout 5 --ignore-attachments' ]] || exit 92
    printf 'PRIVATE INCOMING MESSAGE\n'
    exit "${FAKE_RECEIVE_STATUS:-0}"
    ;;
  send)
    [[ "$1" == --group-id ]] || exit 93
    printf '%s' "$2" >"$FAKE_CAPTURE/group"
    shift 2
    [[ "$1" == --message ]] || exit 94
    printf '%s' "$2" >"$FAKE_CAPTURE/body"
    shift 2
    if [[ $# -gt 0 ]]; then
      [[ "$1" == --attachment ]] || exit 95
      shift
      index=0
      for file in "$@"; do
        [[ -f "$file" ]] || exit 96
        index=$((index + 1))
        cp -- "$file" "$FAKE_CAPTURE/attachment-$index" || exit $?
      done
    fi
    exit "${FAKE_SEND_STATUS:-0}"
    ;;
  *) exit 97 ;;
esac
MOCK
chmod 700 "$root/bin/signal-cli" || exit $?
PATH="$root/bin:$PATH"
SIGNAL_SEND_STATE_DIR="$root/state"
SIGNAL_SEND_PROJECT='test'
FAKE_LOG="$root/calls"
FAKE_CAPTURE="$root/capture"
TMPDIR="$root/tmp"
export PATH SIGNAL_SEND_STATE_DIR SIGNAL_SEND_PROJECT FAKE_LOG FAKE_CAPTURE TMPDIR
unset SIGNAL_SEND_DB SIGNAL_SEND_GROUP_KEY_FILE
reset_capture() {
  rm -rf "$FAKE_CAPTURE" || exit $?
  mkdir "$FAKE_CAPTURE" || exit $?
  : >"$FAKE_LOG"
}
invoke() { "$test_bash" "$signal_send" "$@"; }
assert_no_message_tmp() {
  local file
  for file in "$TMPDIR"/signal-send-message.*; do
    [[ ! -e "$file" ]] || fail 'plaintext temporary file left'
  done
}
reset_capture
invoke hello || fail 'short send failed'
[[ "$(cat "$FAKE_LOG")" == send ]] || fail 'send performed maintenance'
[[ "$(cat "$FAKE_CAPTURE/group")" == "$group_id" ]] || fail 'wrong target'
[[ "$(cat "$FAKE_CAPTURE/body")" == hello ]] || fail 'body changed'
[[ ! -e "$FAKE_CAPTURE/attachment-1" ]] || fail 'unexpected attachment'
reset_capture
invoke link >/dev/null || fail 'idempotent link failed'
[[ "$(cat "$FAKE_LOG")" == listAccounts ]] || fail 'existing account was relinked'
reset_capture
status=0
invoke '' >/dev/null 2>&1 || status=$?
[[ $status -eq 64 && ! -s "$FAKE_LOG" ]] || fail 'empty message sent'
status=0
invoke --attach "$root/missing.txt" hello >/dev/null 2>&1 || status=$?
[[ $status -eq 66 && ! -s "$FAKE_LOG" ]] || fail 'missing attachment sent'
reset_capture
output="$(invoke sync)" || fail 'sync failed'
[[ -z "$output" ]] || fail 'sync exposed received content'
[[ "$(cat "$FAKE_LOG")" == $'sendSyncRequest\nreceive' ]] || fail 'sync sequence wrong'
reset_capture
status=0
FAKE_SYNC_STATUS=5 invoke sync >/dev/null 2>&1 || status=$?
[[ $status -eq 5 && "$(cat "$FAKE_LOG")" == sendSyncRequest ]] || fail 'sync request failure masked'
status=0
FAKE_RECEIVE_STATUS=3 invoke sync >/dev/null 2>&1 || status=$?
[[ $status -eq 3 ]] || fail 'receive failure masked'
reset_capture
status=0
invoke reset-sessions >/dev/null 2>&1 || status=$?
[[ $status -eq 64 && ! -s "$FAKE_LOG" ]] || fail 'unsupported reset changed state'
reset_capture
printf '2\n' | invoke select-group >/dev/null || fail 'group selection failed'
[[ "$(cat "$SIGNAL_SEND_STATE_DIR/projects/test/group_id")" == BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA= ]] || fail 'multiline name broke indexing'
status=0
FAKE_BAD_JSON=1 invoke groups >/dev/null 2>&1 || status=$?
[[ $status -ne 0 ]] || fail 'malformed group JSON accepted'
printf '%s\n' "$group_id" >"$SIGNAL_SEND_STATE_DIR/projects/test/group_id" || exit $?
reset_capture
printf 'piped hello\n' | invoke || fail 'stdin send failed'
[[ "$(cat "$FAKE_CAPTURE/body")" == 'piped hello' ]] || fail 'stdin changed'
reset_capture
printf '%s\n' 'first file' >"$root/first file.txt" || exit $?
printf '%s\n' 'second file' >"$root/second.txt" || exit $?
invoke --attach "$root/first file.txt" --attach "$root/second.txt" hello || fail 'attachments failed'
cmp "$root/first file.txt" "$FAKE_CAPTURE/attachment-1" || fail 'first attachment changed'
cmp "$root/second.txt" "$FAKE_CAPTURE/attachment-2" || fail 'second attachment lost'
reset_capture
printf -v message '%2000s' ''
message=${message// /a}
invoke "$message" || fail '2000 byte send failed'
[[ ! -e "$FAKE_CAPTURE/attachment-1" ]] || fail 'boundary message attached'
message+=a
invoke --attach "$root/first file.txt" "$message" || fail 'long send failed'
[[ "$(cat "$FAKE_CAPTURE/attachment-2")" == "$message" ]] || fail 'long message truncated'
[[ "$(cat "$FAKE_CAPTURE/body")" == "${message:0:200}[...]" ]] || fail 'preview wrong'
assert_no_message_tmp
reset_capture
printf -v emoji '\xf0\x9f\x98\x80%.0s' {1..600}
invoke "$emoji" || fail 'UTF-8 send failed'
[[ "$(cat "$FAKE_CAPTURE/attachment-1")" == "$emoji" ]] || fail 'UTF-8 long message lost'
reset_capture
status=0
FAKE_SEND_STATUS=4 invoke "$message" || status=$?
[[ $status -eq 4 ]] || fail 'send failure masked'
assert_no_message_tmp
reset_capture
printf '%064d\n' 0 >"$SIGNAL_SEND_STATE_DIR/projects/test/group_id" || exit $?
status=0
invoke hello >/dev/null 2>&1 || status=$?
[[ $status -eq 65 && ! -s "$FAKE_LOG" ]] || fail 'Presage master key accepted as group ID'
rm "$SIGNAL_SEND_STATE_DIR/projects/test/group_id" || exit $?
printf '%064d\n' 0 >"$SIGNAL_SEND_STATE_DIR/projects/test/group_master_key" || exit $?
status=0
invoke hello >/dev/null 2>&1 || status=$?
[[ $status -eq 64 && ! -s "$FAKE_LOG" ]] || fail 'legacy group target silently reused'
printf 'signal-cli contract checks passed\n'
