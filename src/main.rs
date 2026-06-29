use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const LOCK_EX: i32 = 2;

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

#[derive(Debug)]
struct AppError {
    code: i32,
    message: String,
}

impl AppError {
    fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

type AppResult<T> = Result<T, AppError>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GroupKeySource {
    Project,
    Explicit,
}

#[derive(Debug)]
struct Config {
    state_dir: PathBuf,
    db: PathBuf,
    device_name: String,
    discover_timeout: Duration,
    project_id: String,
    group_key_file: PathBuf,
    legacy_group_key_file: PathBuf,
    group_key_source: GroupKeySource,
}

#[derive(Debug)]
struct StateLock {
    _file: File,
}

#[derive(Debug)]
struct PresageOutput {
    status: ExitStatus,
    stdout: String,
    stderr: String,
}

fn main() {
    match run() {
        Ok(()) => {}
        Err(err) => {
            if !err.message.is_empty() {
                eprintln!("{}", err.message);
            }
            std::process::exit(err.code);
        }
    }
}

fn run() -> AppResult<()> {
    let args: Vec<OsString> = env::args_os().skip(1).collect();

    if args.first().and_then(|arg| arg.to_str()) == Some("-h")
        || args.first().and_then(|arg| arg.to_str()) == Some("--help")
        || args.first().and_then(|arg| arg.to_str()) == Some("help")
    {
        usage(io::stderr()).map_err(io_error)?;
        return Ok(());
    }

    let config = Config::from_env()?;
    let _lock = acquire_state_lock(&config.state_dir)?;
    dispatch(&config, args)
}

fn dispatch(config: &Config, args: Vec<OsString>) -> AppResult<()> {
    let command = args
        .first()
        .and_then(|arg| arg.to_str())
        .unwrap_or("send")
        .to_string();

    match command.as_str() {
        "setup" => {
            expect_no_extra(&args[1..])?;
            cmd_setup(config)
        }
        "setup-device" => {
            expect_no_extra(&args[1..])?;
            cmd_setup_device(config)
        }
        "setup-project" => {
            expect_no_extra(&args[1..])?;
            cmd_setup_project(config)
        }
        "link" => {
            expect_no_extra(&args[1..])?;
            cmd_link(config)
        }
        "sync" => {
            expect_no_extra(&args[1..])?;
            cmd_sync(config)
        }
        "groups" => {
            expect_no_extra(&args[1..])?;
            cmd_groups(config)
        }
        "projects" => {
            expect_no_extra(&args[1..])?;
            cmd_projects(config)
        }
        "select-group" => {
            expect_no_extra(&args[1..])?;
            cmd_select_group(config)
        }
        "discover-group" => {
            expect_no_extra(&args[1..])?;
            cmd_discover_group(config)
        }
        "status" => {
            expect_no_extra(&args[1..])?;
            cmd_status(config)
        }
        "check" => {
            expect_no_extra(&args[1..])?;
            cmd_check(config)
        }
        "send" => cmd_send(config, args.into_iter().skip(1).collect()),
        _ => cmd_send(config, args),
    }
}

fn expect_no_extra(args: &[OsString]) -> AppResult<()> {
    if args.is_empty() {
        return Ok(());
    }

    usage(io::stderr()).map_err(io_error)?;
    Err(AppError::new(64, "signal-send: unexpected arguments"))
}

fn usage(mut writer: impl Write) -> io::Result<()> {
    writeln!(
        writer,
        "usage:
  signal-send setup
  signal-send setup-device
  signal-send setup-project
  signal-send link
  signal-send sync
  signal-send groups
  signal-send projects
  signal-send select-group
  signal-send discover-group
  signal-send status
  signal-send check
  signal-send [--attach PATH ...] MESSAGE
  printf '%s\\n' MESSAGE | signal-send [--attach PATH ...]"
    )
}

impl Config {
    fn from_env() -> AppResult<Self> {
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| AppError::new(64, "signal-send: HOME is unset"))?;
        let state_dir = env::var_os("SIGNAL_SEND_STATE_DIR")
            .map(PathBuf::from)
            .or_else(|| {
                env::var_os("XDG_STATE_HOME")
                    .map(PathBuf::from)
                    .map(|path| path.join("signal-send"))
            })
            .unwrap_or_else(|| home.join(".local/state/signal-send"));
        let db = env::var_os("SIGNAL_SEND_DB")
            .map(PathBuf::from)
            .unwrap_or_else(|| state_dir.join("cli.db3"));
        let device_name = match env::var("SIGNAL_SEND_DEVICE_NAME") {
            Ok(value) if !value.is_empty() => value,
            Ok(_) => {
                return Err(AppError::new(
                    64,
                    "signal-send: SIGNAL_SEND_DEVICE_NAME is empty",
                ));
            }
            Err(_) => format!("{}-signal-send", host_name()),
        };
        let discover_timeout = env::var("SIGNAL_SEND_DISCOVER_TIMEOUT")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map(Duration::from_secs)
            .unwrap_or_else(|| Duration::from_secs(120));
        let project_id = resolve_project_id()?;

        let (group_key_source, group_key_file, legacy_group_key_file) =
            match env::var_os("SIGNAL_SEND_GROUP_KEY_FILE") {
                Some(value) if !value.is_empty() => (
                    GroupKeySource::Explicit,
                    PathBuf::from(value),
                    PathBuf::new(),
                ),
                Some(_) => {
                    return Err(AppError::new(
                        64,
                        "signal-send: SIGNAL_SEND_GROUP_KEY_FILE is empty",
                    ));
                }
                None => (
                    GroupKeySource::Project,
                    state_dir
                        .join("projects")
                        .join(&project_id)
                        .join("group_master_key"),
                    state_dir.join("group_master_key"),
                ),
            };

        Ok(Self {
            state_dir,
            db,
            device_name,
            discover_timeout,
            project_id,
            group_key_file,
            legacy_group_key_file,
            group_key_source,
        })
    }
}

fn host_name() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|value| value.trim().to_string())
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| env::var("HOSTNAME").ok())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "host".to_string())
}

fn resolve_project_id() -> AppResult<String> {
    let raw = match env::var("SIGNAL_SEND_PROJECT") {
        Ok(value) if !value.is_empty() => value,
        Ok(_) => {
            return Err(AppError::new(
                64,
                "signal-send: SIGNAL_SEND_PROJECT is empty",
            ))
        }
        Err(_) => find_project_root()
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("default")
            .to_string(),
    };

    Ok(sanitize_project_id(&raw))
}

fn find_project_root() -> PathBuf {
    let mut dir = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    loop {
        if dir.join(".git").exists() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }

    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn sanitize_project_id(raw: &str) -> String {
    let mapped: String = raw
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '_' || ch == '.' || ch == '-' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = mapped.trim_matches('_');

    if trimmed.is_empty() {
        "default".to_string()
    } else {
        trimmed.to_string()
    }
}

fn ensure_state_dir(config: &Config) -> AppResult<()> {
    create_private_dir(&config.state_dir)
}

fn ensure_project_state_dir(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    create_private_dir(&config.state_dir.join("projects"))?;
    create_private_dir(&config.state_dir.join("projects").join(&config.project_id))
}

fn create_private_dir(path: &Path) -> AppResult<()> {
    fs::create_dir_all(path).map_err(io_error)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(io_error)
}

fn acquire_state_lock(state_dir: &Path) -> AppResult<StateLock> {
    create_private_dir(state_dir)?;
    let lock_path = state_dir.join(".signal-send.lock");
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&lock_path)
        .map_err(io_error)?;
    fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o600)).map_err(io_error)?;

    let status = unsafe { flock(file.as_raw_fd(), LOCK_EX) };
    if status != 0 {
        return Err(io_error(io::Error::last_os_error()));
    }

    Ok(StateLock { _file: file })
}

fn presage(config: &Config, args: &[&str]) -> Command {
    let mut command = Command::new("presage-cli");
    command.arg("--sqlite-db-path").arg(&config.db).args(args);
    command
}

fn presage_output(config: &Config, args: &[&str]) -> AppResult<PresageOutput> {
    let output = presage(config, args).output().map_err(io_error)?;
    Ok(PresageOutput {
        status: output.status,
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

fn is_registered(config: &Config) -> bool {
    presage(config, &["whoami"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn read_group_lines(config: &Config) -> AppResult<Vec<String>> {
    let output = presage_output(config, &["list-groups"])?;
    if !output.status.success() {
        return Err(AppError::new(
            output.status.code().unwrap_or(1),
            "signal-send: unable to list groups; run signal-send sync first",
        ));
    }

    Ok(output
        .stdout
        .lines()
        .filter(|line| is_group_line(line))
        .map(ToOwned::to_owned)
        .collect())
}

fn is_group_line(line: &str) -> bool {
    let Some((key, _)) = line.split_once(' ') else {
        return false;
    };

    key.len() == 64 && key.chars().all(|ch| ch.is_ascii_hexdigit())
}

fn group_count(config: &Config) -> AppResult<usize> {
    Ok(read_group_lines(config)?.len())
}

fn group_label(line: &str) -> &str {
    let label = line.split_once(' ').map(|(_, label)| label).unwrap_or(line);
    label.split(" / revision ").next().unwrap_or(label)
}

#[derive(Debug, PartialEq, Eq)]
struct SelectedGroup {
    label: String,
    revision: u32,
}

fn group_revision(line: &str) -> Option<u32> {
    let (_, suffix) = line.split_once(" / revision ")?;
    suffix.split_whitespace().next()?.parse().ok()
}

fn selected_group(config: &Config, key: &str) -> AppResult<Option<SelectedGroup>> {
    for line in read_group_lines(config)? {
        let Some((group_key, _)) = line.split_once(' ') else {
            continue;
        };

        if group_key.eq_ignore_ascii_case(key) {
            let Some(revision) = group_revision(&line) else {
                return Err(AppError::new(
                    1,
                    "signal-send: selected group is missing a revision in presage group state",
                ));
            };
            return Ok(Some(SelectedGroup {
                label: group_label(&line).to_string(),
                revision,
            }));
        }
    }

    Ok(None)
}

fn cmd_link(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    if is_registered(config) {
        eprintln!("signal-send: already linked at {}", config.db.display());
        return Ok(());
    }

    let status = presage(
        config,
        &["link-device", "--device-name", &config.device_name],
    )
    .status()
    .map_err(io_error)?;
    if !status.success() {
        return Err(AppError::new(status.code().unwrap_or(1), ""));
    }

    chmod_db_files(&config.db);
    Ok(())
}

fn chmod_db_files(db: &Path) {
    let mut paths = vec![db.to_path_buf()];
    if let Some(name) = db.file_name().and_then(|name| name.to_str()) {
        if let Some(parent) = db.parent() {
            paths.push(parent.join(format!("{name}-shm")));
            paths.push(parent.join(format!("{name}-wal")));
        }
    }

    for path in paths {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
}

fn run_sync_steps(config: &Config) -> AppResult<()> {
    let contacts = presage_output(config, &["sync-contacts"])?;
    if !contacts.status.success() {
        print_sync_diagnostics("sync-contacts", &contacts);
        return Err(AppError::new(contacts.status.code().unwrap_or(1), ""));
    }

    let sync = presage_output(config, &["sync", "--stop-after-empty-queue"])?;
    if !sync.status.success() {
        print_sync_diagnostics("sync", &sync);
        return Err(AppError::new(sync.status.code().unwrap_or(1), ""));
    }

    Ok(())
}

fn quiet_sync(config: &Config) -> AppResult<()> {
    run_sync_steps(config)
}

fn sync_before_send(config: &Config) -> AppResult<()> {
    match run_sync_steps(config) {
        Ok(()) => Ok(()),
        Err(err) => {
            eprintln!("signal-send: pre-send sync failed");
            Err(err)
        }
    }
}

fn print_sync_diagnostics(label: &str, output: &PresageOutput) {
    print_sync_output_file(&format!("{label} stderr"), &output.stderr);
    print_sync_output_file(&format!("{label} stdout"), &output.stdout);
}

fn print_sync_output_file(label: &str, content: &str) {
    for line in content.lines().filter(|line| !line.is_empty()) {
        eprintln!("signal-send: {label}: {line}");
    }
}

fn cmd_sync(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    quiet_sync(config)
}

fn cmd_setup_device(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    cmd_link(config)?;
    quiet_sync(config)
}

fn cmd_groups(config: &Config) -> AppResult<()> {
    let lines = read_group_lines(config)?;
    if lines.is_empty() {
        return Err(AppError::new(
            1,
            "signal-send: no groups found; run signal-send discover-group",
        ));
    }

    for (index, line) in lines.iter().enumerate() {
        println!("{}. {}", index + 1, group_label(line));
    }
    Ok(())
}

fn cmd_projects(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    let projects_dir = config.state_dir.join("projects");
    let mut found = false;

    if let Ok(entries) = fs::read_dir(projects_dir) {
        for entry in entries.flatten().filter(|entry| entry.path().is_dir()) {
            found = true;
            let name = entry.file_name().to_string_lossy().into_owned();
            let key_file = entry.path().join("group_master_key");
            if group_key_file_is_valid(&key_file) {
                println!("{name} selected");
            } else if key_file.is_file() {
                println!("{name} invalid");
            } else {
                println!("{name} not-selected");
            }
        }
    }

    if found {
        Ok(())
    } else {
        Err(AppError::new(1, "signal-send: no project group keys found"))
    }
}

fn cmd_select_group(config: &Config) -> AppResult<()> {
    if config.group_key_source == GroupKeySource::Project {
        ensure_project_state_dir(config)?;
    } else {
        ensure_state_dir(config)?;
    }

    let lines = read_group_lines(config)?;
    if lines.is_empty() {
        return Err(AppError::new(
            1,
            "signal-send: no groups found; run signal-send discover-group",
        ));
    }

    for (index, line) in lines.iter().enumerate() {
        println!("{}. {}", index + 1, group_label(line));
    }
    eprint!("Choose group [1-{}]: ", lines.len());
    io::stderr().flush().map_err(io_error)?;

    let mut choice = String::new();
    io::stdin().read_line(&mut choice).map_err(io_error)?;
    let choice = choice
        .trim()
        .parse::<usize>()
        .ok()
        .filter(|choice| (1..=lines.len()).contains(choice))
        .ok_or_else(|| AppError::new(64, "signal-send: invalid group choice"))?;

    let key = lines[choice - 1]
        .split_once(' ')
        .map(|(key, _)| key)
        .unwrap_or("");
    write_group_key(config, key)?;
    eprintln!("signal-send: selected {}", group_label(&lines[choice - 1]));
    Ok(())
}

fn write_group_key(config: &Config, key: &str) -> AppResult<()> {
    if config.group_key_source == GroupKeySource::Explicit
        && path_has_symlink_component(&config.group_key_file)
    {
        return Err(AppError::new(
            1,
            format!(
                "signal-send: group key file is managed or symlinked: {}\nsignal-send: run selection before redirecting groupKeyFile, or update the secret source",
                config.group_key_file.display()
            ),
        ));
    }

    let key_dir = config
        .group_key_file
        .parent()
        .unwrap_or_else(|| Path::new("."));
    if !key_dir.is_dir() {
        return Err(AppError::new(
            1,
            format!(
                "signal-send: group key directory is not writable: {}\nsignal-send: run selection before redirecting groupKeyFile, or update the secret source",
                key_dir.display()
            ),
        ));
    }

    let tmp = key_dir.join(format!(
        ".signal-send-group-key.{}.{}",
        std::process::id(),
        now_nanos()
    ));
    let write_result = (|| -> AppResult<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(io_error)?;
        file.write_all(format!("{key}\n").as_bytes())
            .map_err(io_error)?;
        file.sync_all().map_err(io_error)?;
        drop(file);
        fs::rename(&tmp, &config.group_key_file).map_err(io_error)?;
        fs::set_permissions(&config.group_key_file, fs::Permissions::from_mode(0o600))
            .map_err(io_error)?;
        if !config.group_key_file.is_file() {
            return Err(AppError::new(
                1,
                format!(
                    "signal-send: group key file was not written: {}",
                    config.group_key_file.display()
                ),
            ));
        }
        Ok(())
    })();

    if write_result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    write_result
}

fn path_has_symlink_component(path: &Path) -> bool {
    let mut current = if path.is_absolute() {
        PathBuf::from("/")
    } else {
        PathBuf::from(".")
    };

    for component in path.components() {
        use std::path::Component;
        match component {
            Component::RootDir | Component::CurDir => continue,
            Component::Normal(part) => current.push(part),
            _ => continue,
        }

        if fs::symlink_metadata(&current)
            .map(|metadata| metadata.file_type().is_symlink())
            .unwrap_or(false)
        {
            return true;
        }
    }

    false
}

fn cmd_discover_group(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;
    let before = group_count(config)?;
    let deadline = Instant::now() + config.discover_timeout;

    eprintln!(
        "signal-send: listening for group activity for up to {} seconds",
        config.discover_timeout.as_secs()
    );
    eprintln!("signal-send: send a small message from your phone to the target group now");

    while Instant::now() < deadline {
        let _ = presage(config, &["sync", "--stop-after-empty-queue"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();

        let after = group_count(config)?;
        if after > before {
            return cmd_select_group(config);
        }
        thread::sleep(Duration::from_secs(2));
    }

    Err(AppError::new(
        1,
        "signal-send: no group activity discovered before timeout",
    ))
}

fn cmd_onboard_project_group(config: &Config) -> AppResult<()> {
    if group_count(config)? == 0 {
        cmd_discover_group(config)
    } else {
        cmd_select_group(config)
    }
}

fn cmd_setup_project(config: &Config) -> AppResult<()> {
    ensure_project_state_dir(config)?;
    if !is_registered(config) {
        return Err(AppError::new(
            64,
            "signal-send: device is not linked; run signal-send setup-device first",
        ));
    }

    quiet_sync(config)?;
    cmd_onboard_project_group(config)
}

fn cmd_setup(config: &Config) -> AppResult<()> {
    cmd_setup_device(config)?;
    ensure_project_state_dir(config)?;
    cmd_onboard_project_group(config)
}

fn cmd_status(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;

    if is_registered(config) {
        println!("linked: yes");
    } else {
        println!("linked: no");
    }

    println!("project: {}", config.project_id);
    println!(
        "group-key-source: {}",
        match config.group_key_source {
            GroupKeySource::Project => "project",
            GroupKeySource::Explicit => "explicit",
        }
    );
    println!("db: {}", config.db.display());
    println!("group-key-file: {}", config.group_key_file.display());

    if uses_legacy_group_key(config) {
        println!(
            "legacy-group-key-file: {}",
            config.legacy_group_key_file.display()
        );
        println!("group: selected (legacy fallback)");
    } else if group_key_file_is_valid(&config.group_key_file) {
        println!("group: selected");
    } else if config.group_key_file.is_file() {
        println!("group: invalid");
    } else {
        println!("group: not selected");
    }

    Ok(())
}

fn legacy_group_key_allowed(config: &Config) -> bool {
    config.group_key_source == GroupKeySource::Project && config.project_id == "default"
}

fn uses_legacy_group_key(config: &Config) -> bool {
    legacy_group_key_allowed(config)
        && !group_key_file_has_content(&config.group_key_file)
        && group_key_file_is_valid(&config.legacy_group_key_file)
}

fn active_group_key_file(config: &Config) -> &Path {
    if uses_legacy_group_key(config) {
        &config.legacy_group_key_file
    } else {
        &config.group_key_file
    }
}

fn missing_group_key_error(config: &Config) -> AppError {
    if config.group_key_source == GroupKeySource::Project {
        let mut message = format!(
            "signal-send: no selected group for project {}; run signal-send setup-project or signal-send select-group",
            config.project_id
        );
        if config.project_id != "default" && config.legacy_group_key_file.is_file() {
            message.push_str(&format!(
                "\nsignal-send: legacy key at {} is only used for project default",
                config.legacy_group_key_file.display()
            ));
        }
        return AppError::new(64, message);
    }

    AppError::new(
        64,
        "signal-send: no selected group; check SIGNAL_SEND_GROUP_KEY_FILE",
    )
}

fn read_selected_group_key(key_file: &Path) -> AppResult<String> {
    let key = fs::read_to_string(key_file)
        .map_err(io_error)?
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect::<String>();
    if key.len() != 64 || !key.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(AppError::new(
            65,
            "signal-send: group key file is not a 64-character hex key",
        ));
    }

    Ok(key)
}

fn group_key_file_has_content(path: &Path) -> bool {
    path.metadata()
        .map(|metadata| metadata.is_file() && metadata.len() > 0)
        .unwrap_or(false)
}

fn group_key_file_is_valid(path: &Path) -> bool {
    read_selected_group_key(path).is_ok()
}

fn cmd_check(config: &Config) -> AppResult<()> {
    ensure_state_dir(config)?;

    if !is_registered(config) {
        return Err(AppError::new(
            1,
            "signal-send: device is not linked; run signal-send setup-device",
        ));
    }

    let key_file = active_group_key_file(config);
    if !key_file.is_file() {
        return Err(missing_group_key_error(config));
    }

    let key = read_selected_group_key(key_file)?;
    let Some(group) = selected_group(config, &key)? else {
        return Err(AppError::new(
            1,
            format!(
                "signal-send: selected group key is not present in current Signal groups for project {}; run signal-send sync or signal-send select-group",
                config.project_id
            ),
        ));
    };

    println!("linked: yes");
    println!("project: {}", config.project_id);
    println!("group: selected");
    println!("selected-group: {}", group.label);
    println!("selected-group-revision: {}", group.revision);
    println!("db: {}", config.db.display());
    println!("group-key-file: {}", key_file.display());

    Ok(())
}

fn cmd_send(config: &Config, args: Vec<OsString>) -> AppResult<()> {
    let (attachments, message_args) = parse_send_args(args)?;
    let key_file = active_group_key_file(config);
    if !key_file.is_file() {
        return Err(missing_group_key_error(config));
    }

    let key = read_selected_group_key(key_file)?;

    let message = if message_args.is_empty() {
        let mut input = String::new();
        io::stdin().read_to_string(&mut input).map_err(io_error)?;
        input
    } else {
        message_args
            .iter()
            .map(|arg| arg.to_string_lossy())
            .collect::<Vec<_>>()
            .join(" ")
    };

    if message.is_empty() {
        return Err(AppError::new(64, "signal-send: empty message"));
    }

    sync_before_send(config)?;

    let Some(group) = selected_group(config, &key)? else {
        return Err(AppError::new(
            1,
            format!(
                "signal-send: selected group key is not present in current Signal groups for project {}; run signal-send sync or signal-send select-group",
                config.project_id
            ),
        ));
    };
    let revision = group.revision.to_string();
    let mut command = presage(
        config,
        &[
            "send-to-group",
            "--master-key",
            &key,
            "--message",
            &message,
            "--revision",
            &revision,
        ],
    );
    for attachment in attachments {
        command.arg("--attach").arg(attachment);
    }

    let status = command.status().map_err(io_error)?;
    if status.success() {
        Ok(())
    } else {
        Err(AppError::new(status.code().unwrap_or(1), ""))
    }
}

fn parse_send_args(args: Vec<OsString>) -> AppResult<(Vec<OsString>, Vec<OsString>)> {
    let mut attachments = Vec::new();
    let mut message = Vec::new();
    let mut iter = args.into_iter();

    while let Some(arg) = iter.next() {
        if arg == "--attach" {
            let Some(path) = iter.next() else {
                return Err(AppError::new(64, "signal-send: missing value for --attach"));
            };
            attachments.push(path);
        } else if arg == "-h" || arg == "--help" {
            usage(io::stderr()).map_err(io_error)?;
            std::process::exit(0);
        } else if arg == "--" {
            message.extend(iter);
            break;
        } else if arg.to_string_lossy().starts_with('-') {
            usage(io::stderr()).map_err(io_error)?;
            return Err(AppError::new(
                64,
                format!("signal-send: unknown option: {}", arg.to_string_lossy()),
            ));
        } else {
            message.push(arg);
            message.extend(iter);
            break;
        }
    }

    Ok((attachments, message))
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn io_error(error: io::Error) -> AppError {
    AppError::new(1, format!("signal-send: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_project_id_replaces_unsafe_chars() {
        assert_eq!(sanitize_project_id(" nix config! "), "nix_config");
        assert_eq!(sanitize_project_id("___"), "default");
    }

    #[test]
    fn group_line_detection_requires_hex_key() {
        let good = format!("{} Nix Config / revision 1", "a".repeat(64));
        assert!(is_group_line(&good));
        assert!(!is_group_line("not-a-key Nix Config"));
    }

    #[test]
    fn symlink_component_detection_finds_parent_symlink() {
        let root = test_dir("symlink-detection");
        let real = root.join("real");
        let link = root.join("link");
        fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert!(path_has_symlink_component(&link.join("group_master_key")));
        fs::remove_dir_all(root).unwrap();
    }

    fn test_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!(
            "signal-send-test-{name}-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
