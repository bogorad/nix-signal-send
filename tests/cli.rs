use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_signal-send"))
}

fn test_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = env::temp_dir().join(format!(
        "signal-send-cli-test-{name}-{}-{nanos}",
        std::process::id()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

fn write_fake_presage(bin_dir: &Path) -> PathBuf {
    let fake = bin_dir.join("presage-cli");
    let bash = env::var("TEST_BASH").unwrap_or_else(|_| "/usr/bin/env bash".to_string());
    let script = format!(
        r#"#!{bash}
log="${{PRESAGE_FAKE_LOG:?}}"
printf '%s\n' "$*" >> "$log"
if [ "${{PRESAGE_FAKE_SLEEP_SYNC:-0}}" != 0 ]; then
  case "$*" in
    *" sync --stop-after-empty-queue"*) sleep "$PRESAGE_FAKE_SLEEP_SYNC" ;;
  esac
fi
case "$*" in
  *" whoami"*)
    if [ "${{PRESAGE_FAKE_REGISTERED:-1}}" = 1 ]; then
      printf 'linked\n'
      exit 0
    fi
    exit 1
    ;;
  *" list-groups"*)
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa Nix-config / revision 1\n'
    exit 0
    ;;
  *" sync-contacts"*)
    exit "${{PRESAGE_FAKE_SYNC_CONTACTS_STATUS:-0}}"
    ;;
  *" sync --stop-after-empty-queue"*)
    exit "${{PRESAGE_FAKE_SYNC_STATUS:-0}}"
    ;;
  *" send-to-group "*)
    exit 0
    ;;
  *" link-device "*)
    exit 0
    ;;
esac
exit 0
"#
    );
    fs::write(&fake, script).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
    fake
}

fn base_command(root: &Path) -> Command {
    let bin_dir = root.join("bin");
    fs::create_dir_all(&bin_dir).unwrap();
    write_fake_presage(&bin_dir);
    let mut path_entries = vec![bin_dir];
    if let Some(path) = env::var_os("PATH") {
        path_entries.extend(env::split_paths(&path));
    }
    let path = env::join_paths(path_entries).unwrap();

    let mut command = Command::new(bin());
    command.env("PATH", path);
    command.env("HOME", root.join("home"));
    command.env("SIGNAL_SEND_STATE_DIR", root.join("state"));
    command.env("SIGNAL_SEND_PROJECT", "nix-config");
    command.env("PRESAGE_FAKE_LOG", root.join("presage.log"));
    command
}

fn select_group(root: &Path) {
    let mut command = base_command(root);
    command.arg("select-group");
    command.stdin(Stdio::piped());
    let mut child = command.spawn().unwrap();
    child.stdin.as_mut().unwrap().write_all(b"1\n").unwrap();
    let status = child.wait().unwrap();
    assert!(status.success());
}

fn write_selected_group(root: &Path, key: &str) {
    let project_dir = root.join("state/projects/nix-config");
    fs::create_dir_all(&project_dir).unwrap();
    fs::write(project_dir.join("group_master_key"), format!("{key}\n")).unwrap();
}

#[test]
fn send_runs_sync_before_send_to_group() {
    let root = test_dir("send-sync-order");
    select_group(&root);

    let status = base_command(&root).arg("hello").status().unwrap();
    assert!(status.success());

    let log = fs::read_to_string(root.join("presage.log")).unwrap();
    let contacts = log.find("sync-contacts").unwrap();
    let sync = log.find("sync --stop-after-empty-queue").unwrap();
    let send = log.find("send-to-group").unwrap();
    assert!(contacts < sync);
    assert!(sync < send);
}

#[test]
fn failed_sync_prevents_send() {
    let root = test_dir("failed-sync");
    select_group(&root);

    let status = base_command(&root)
        .env("PRESAGE_FAKE_SYNC_STATUS", "9")
        .arg("hello")
        .status()
        .unwrap();
    assert!(!status.success());

    let log = fs::read_to_string(root.join("presage.log")).unwrap();
    assert!(log.contains("sync --stop-after-empty-queue"));
    assert!(!log.contains("send-to-group"));
}

#[test]
fn check_reports_selected_group_label() {
    let root = test_dir("check-selected-group");
    select_group(&root);

    let output = base_command(&root).arg("check").output().unwrap();
    assert!(output.status.success());

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("linked: yes"));
    assert!(stdout.contains("project: nix-config"));
    assert!(stdout.contains("selected-group: Nix-config"));
}

#[test]
fn check_fails_when_selected_group_is_not_current() {
    let root = test_dir("check-stale-group");
    write_selected_group(
        &root,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );

    let output = base_command(&root).arg("check").output().unwrap();
    assert!(!output.status.success());

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("selected group key is not present"));
}

#[test]
fn status_and_projects_report_invalid_group_key() {
    let root = test_dir("invalid-group-key");
    write_selected_group(&root, "not-a-valid-key");

    let status = base_command(&root).arg("status").output().unwrap();
    assert!(status.status.success());
    let status_stdout = String::from_utf8_lossy(&status.stdout);
    assert!(status_stdout.contains("group: invalid"));

    let projects = base_command(&root).arg("projects").output().unwrap();
    assert!(projects.status.success());
    let projects_stdout = String::from_utf8_lossy(&projects.stdout);
    assert!(projects_stdout.contains("nix-config invalid"));
}

#[test]
fn status_waits_for_concurrent_sync_lock() {
    let root = test_dir("lock");
    let mut sync = base_command(&root)
        .env("PRESAGE_FAKE_SLEEP_SYNC", "2")
        .arg("sync")
        .spawn()
        .unwrap();

    thread::sleep(Duration::from_millis(250));
    let started = Instant::now();
    let status = base_command(&root).arg("status").status().unwrap();
    let elapsed = started.elapsed();
    assert!(status.success());
    assert!(
        elapsed >= Duration::from_millis(1500),
        "elapsed={elapsed:?}"
    );

    let sync_status = sync.wait().unwrap();
    assert!(sync_status.success());

    let log = fs::read_to_string(root.join("presage.log")).unwrap();
    let sync_pos = log.find("sync --stop-after-empty-queue").unwrap();
    let whoami_pos = log.rfind("whoami").unwrap();
    assert!(sync_pos < whoami_pos);
}
