use crate::context::{unix_ms, Context};
use crate::error::{ToolError, ToolResult, UnitResult};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::jobs::JobManager;
use crate::pty::PtyManager;

static FILE_WRITE_TEMP_ID: AtomicU64 = AtomicU64::new(0);
static SEARCH_DOWNLOAD_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static IN_FLIGHT_COMMANDS: OnceLock<Mutex<HashSet<libc::pid_t>>> = OnceLock::new();
// Match Node's largest explicit helper capture limit (WebHelm/XChat is 4 MiB).
const MAX_CHILD_CAPTURE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug)]
pub struct Handlers {
    pub context: Context,
    pub jobs: JobManager,
    pub ptys: PtyManager,
}

impl Handlers {
    pub fn new(context: Context) -> Self {
        let jobs = JobManager::new(context.clone());
        let ptys = PtyManager::new();
        Self {
            context,
            jobs,
            ptys,
        }
    }

    pub fn require_unlocked(&self) -> UnitResult {
        if self.context.unlocked() {
            Ok(())
        } else {
            Err(ToolError::code(
                format!(
                    "Full-access unlock revoked ({}); refusing further tool calls.",
                    self.context.unlock_file.display()
                ),
                "FULL_ACCESS_REVOKED",
            ))
        }
    }
}

fn require_object(value: &Value) -> Result<&serde_json::Map<String, Value>, ToolError> {
    value
        .as_object()
        .ok_or_else(|| ToolError::new("arguments must be an object"))
}

fn require_string(object: &serde_json::Map<String, Value>, key: &str) -> Result<String, ToolError> {
    let value = object
        .get(key)
        .ok_or_else(|| ToolError::new(format!("{key} is required")))?;
    let text = value
        .as_str()
        .ok_or_else(|| ToolError::new(format!("{key} must be a string")))?;
    if text.is_empty() {
        return Err(ToolError::new(format!("{key} must be non-empty")));
    }
    Ok(text.to_string())
}

fn optional_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    fallback: &str,
) -> Result<String, ToolError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(fallback.to_string()),
        Some(Value::String(value)) => Ok(value.clone()),
        Some(_) => Err(ToolError::new(format!("{key} must be a string"))),
    }
}

fn optional_string_array(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Value, ToolError> {
    let value = object
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| ToolError::new(format!("{key} must be an array of strings")))?;
    if value.iter().any(|item| !item.is_string()) {
        return Err(ToolError::new(format!("{key} must be an array of strings")));
    }
    Ok(Value::Array(value.clone()))
}

fn optional_bool(
    object: &serde_json::Map<String, Value>,
    key: &str,
    fallback: bool,
) -> Result<bool, ToolError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(fallback),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(ToolError::new(format!("{key} must be a boolean"))),
    }
}

fn optional_u64(
    object: &serde_json::Map<String, Value>,
    key: &str,
    fallback: u64,
    minimum: u64,
    maximum: u64,
) -> Result<u64, ToolError> {
    let value = match object.get(key) {
        None | Some(Value::Null) => fallback,
        Some(value) => value
            .as_u64()
            .ok_or_else(|| ToolError::new(format!("{key} must be an integer")))?,
    };
    if value < minimum || value > maximum {
        return Err(ToolError::new(format!(
            "{key} must be between {minimum} and {maximum}"
        )));
    }
    Ok(value)
}

fn valid_env_key(key: &str) -> bool {
    let mut characters = key.chars();
    matches!(characters.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && characters.all(|character| character == '_' || character.is_ascii_alphanumeric())
}

fn set_private_directory(path: &Path) {
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
}

fn valid_identifier(value: &str, prefix: &str, minimum: usize, maximum: usize) -> bool {
    value.strip_prefix(prefix).is_some_and(|suffix| {
        (minimum..=maximum).contains(&suffix.len())
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    })
}

fn unknown_command(facade: &str, command: &str, valid: &[&str]) -> ToolError {
    ToolError::new(format!("Unknown {facade} command '{command}'. Use command='help' to list valid commands. Valid: {}", valid.join(", ")))
}

fn facade_help(facade: &str, args: &serde_json::Map<String, Value>) -> Result<Value, ToolError> {
    let contracts: Value = serde_json::from_str(include_str!("../fixtures/node-help.json"))
        .map_err(|error| ToolError::new(error.to_string()))?;
    let contract = contracts
        .get(facade)
        .ok_or_else(|| ToolError::new(format!("No help contract for {facade}")))?;
    if let Some(command) = args.get("command").and_then(Value::as_str) {
        let command = command.trim();
        return contract
            .pointer(&format!(
                "/named/{}",
                command.replace('~', "~0").replace('/', "~1")
            ))
            .cloned()
            .ok_or_else(|| {
                ToolError::new(format!(
                    "Unknown {facade} command '{command}'. Use command='help' to list valid commands."
                ))
            });
    }
    contract
        .get("help")
        .cloned()
        .ok_or_else(|| ToolError::new(format!("No help contract for {facade}")))
}

fn run_with_timeout(
    command: &mut Command,
    input: Option<&[u8]>,
    timeout: Duration,
) -> Result<(i32, Vec<u8>, Vec<u8>), ToolError> {
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let in_flight = IN_FLIGHT_COMMANDS.get_or_init(|| Mutex::new(HashSet::new()));
    let mut in_flight = in_flight
        .lock()
        .map_err(|_| ToolError::new("in-flight command lock poisoned"))?;
    let mut child = command
        .spawn()
        .map_err(|error| ToolError::new(error.to_string()))?;
    let pid = child.id() as libc::pid_t;
    in_flight.insert(pid);
    drop(in_flight);
    let _registration = InFlightCommand(pid);
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ToolError::new("child stdout pipe unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| ToolError::new("child stderr pipe unavailable"))?;
    // Drain both pipes while the process runs. Waiting before reading can
    // deadlock when either child stream fills its kernel pipe buffer.
    let stdout_reader = std::thread::spawn(move || capture_child_output(stdout));
    let stderr_reader = std::thread::spawn(move || capture_child_output(stderr));
    let mut stdin = child.stdin.take();
    if let Some(data) = input {
        if let Some(pipe) = stdin.as_mut() {
            let _ = pipe.write_all(data);
        }
    }
    drop(stdin);
    let started = Instant::now();
    loop {
        let status = match child.try_wait() {
            Ok(value) => value,
            Err(error) => return Err(ToolError::new(error.to_string())),
        };
        if let Some(status) = status {
            // Synchronous helpers have no durable child-job contract. Reap any
            // descendants that inherited the capture pipes before joining the
            // readers, or a background grandchild can keep the RPC open.
            unsafe {
                libc::killpg(pid, libc::SIGTERM);
            }
            let drain_deadline = Instant::now() + Duration::from_millis(100);
            while Instant::now() < drain_deadline
                && (!stdout_reader.is_finished() || !stderr_reader.is_finished())
            {
                std::thread::sleep(Duration::from_millis(5));
            }
            if !stdout_reader.is_finished() || !stderr_reader.is_finished() {
                unsafe {
                    libc::killpg(pid, libc::SIGKILL);
                }
            }
            let (stdout, stdout_truncated) = stdout_reader
                .join()
                .map_err(|_| ToolError::new("stdout reader panicked"))?
                .map_err(|error| ToolError::new(error.to_string()))?;
            let (stderr, stderr_truncated) = stderr_reader
                .join()
                .map_err(|_| ToolError::new("stderr reader panicked"))?
                .map_err(|error| ToolError::new(error.to_string()))?;
            if stdout_truncated || stderr_truncated {
                return Err(ToolError::code(
                    "Synchronous child output exceeded the 4 MiB per-stream capture limit",
                    "CHILD_OUTPUT_LIMIT",
                ));
            }
            return Ok((status.code().unwrap_or(-1), stdout, stderr));
        }
        if started.elapsed() > timeout {
            // A timed-out shell command may have spawned grandchildren. Kill
            // its process group so no descendant keeps the capture pipes open.
            unsafe {
                libc::killpg(pid, libc::SIGKILL);
            }
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(ToolError::code(
                format!(
                    "Timed out waiting for child after {}ms",
                    timeout.as_millis()
                ),
                "CHILD_TIMEOUT",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

struct InFlightCommand(libc::pid_t);

impl Drop for InFlightCommand {
    fn drop(&mut self) {
        if let Some(commands) = IN_FLIGHT_COMMANDS.get() {
            if let Ok(mut commands) = commands.lock() {
                commands.remove(&self.0);
            }
        }
    }
}

pub(crate) fn kill_in_flight_commands() {
    if let Some(commands) = IN_FLIGHT_COMMANDS.get() {
        if let Ok(commands) = commands.lock() {
            for pid in commands.iter().copied().filter(|pid| *pid > 1) {
                unsafe {
                    libc::killpg(pid, libc::SIGKILL);
                }
            }
        }
    }
}

fn capture_child_output(mut reader: impl std::io::Read) -> std::io::Result<(Vec<u8>, bool)> {
    let mut captured = Vec::new();
    let mut scratch = [0_u8; 16 * 1024];
    let mut truncated = false;
    loop {
        let count = reader.read(&mut scratch)?;
        if count == 0 {
            return Ok((captured, truncated));
        }
        let remaining = MAX_CHILD_CAPTURE_BYTES.saturating_sub(captured.len());
        let retained = count.min(remaining);
        captured.extend_from_slice(&scratch[..retained]);
        truncated |= retained < count;
    }
}

fn text_value(value: Value) -> Value {
    value
}

fn iso_timestamp(time: std::time::SystemTime) -> String {
    let duration = time
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = duration.as_secs() as i64;
    let days = seconds.div_euclid(86_400);
    let day_seconds = seconds.rem_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    let hour = day_seconds / 3_600;
    let minute = day_seconds % 3_600 / 60;
    let second = day_seconds % 60;
    let millis = duration.subsec_millis();
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

#[allow(clippy::too_many_arguments)]
fn list_directory(
    root: &Path,
    directory: &Path,
    depth: u64,
    recursive: bool,
    include_hidden: bool,
    max_entries: usize,
    max_depth: u64,
    entries: &mut Vec<Value>,
    truncated: &mut bool,
) -> Result<(), ToolError> {
    if entries.len() >= max_entries {
        *truncated = true;
        return Ok(());
    }
    let mut children = fs::read_dir(directory)
        .map_err(|error| ToolError::new(error.to_string()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| ToolError::new(error.to_string()))?;
    children.sort_by_key(|entry| entry.file_name().to_string_lossy().to_lowercase());
    for child in children {
        let name = child.file_name();
        if !include_hidden && name.to_string_lossy().starts_with('.') {
            continue;
        }
        if entries.len() >= max_entries {
            *truncated = true;
            return Ok(());
        }
        let path = child.path();
        let metadata =
            fs::symlink_metadata(&path).map_err(|error| ToolError::new(error.to_string()))?;
        let file_type = metadata.file_type();
        let kind = if file_type.is_dir() {
            "directory"
        } else if file_type.is_file() {
            "file"
        } else if file_type.is_symlink() {
            "symlink"
        } else {
            "other"
        };
        let relative = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let mut item = json!({
            "name": name.to_string_lossy(),
            "path": path.to_string_lossy(),
            "relativePath": if relative.is_empty() { "." } else { &relative },
            "type": kind,
            "size": metadata.len(),
            "mode": metadata.permissions().mode() & 0o7777,
            "modifiedAt": iso_timestamp(metadata.modified().unwrap_or(std::time::UNIX_EPOCH))
        });
        if file_type.is_symlink() {
            item["symlinkTarget"] = fs::read_link(&path)
                .ok()
                .map(|target| json!(target.to_string_lossy().to_string()))
                .unwrap_or(Value::Null);
        }
        entries.push(item);
        if recursive && file_type.is_dir() && depth < max_depth {
            list_directory(
                root,
                &path,
                depth + 1,
                recursive,
                include_hidden,
                max_entries,
                max_depth,
                entries,
                truncated,
            )?;
        }
    }
    Ok(())
}

// Match Node fs.rm / fs.cp semantics without spawning shell commands.
fn remove_managed_path(path: &Path, recursive: bool, force: bool) -> UnitResult {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && force => return Ok(()),
        Err(error) => return Err(ToolError::new(error.to_string())),
    };
    let result = if metadata.is_dir() {
        if recursive {
            fs::remove_dir_all(path)
        } else {
            return Err(ToolError::new(
                "Cannot remove a directory without recursive=true",
            ));
        }
    } else {
        fs::remove_file(path)
    };
    result.map_err(|error| ToolError::new(error.to_string()))
}

fn copy_managed_path(from: &Path, to: &Path, recursive: bool, force: bool) -> UnitResult {
    let meta = fs::symlink_metadata(from).map_err(|error| ToolError::new(error.to_string()))?;
    if from == to || (meta.is_dir() && to.starts_with(from)) {
        return Err(ToolError::new(
            "Source and destination must be distinct; cannot copy a directory into itself",
        ));
    }
    if let (Ok(source), Ok(destination)) = (fs::canonicalize(from), fs::canonicalize(to)) {
        if source == destination {
            return Err(ToolError::new("Source and destination are the same file"));
        }
    }
    if meta.is_dir() {
        if let (Ok(source), Some(parent)) = (fs::canonicalize(from), to.parent()) {
            if fs::canonicalize(parent).is_ok_and(|path| path.starts_with(&source)) {
                return Err(ToolError::new("Cannot copy a directory into itself"));
            }
        }
    }
    if fs::symlink_metadata(to).is_ok() {
        if !force {
            return Err(ToolError::new(format!(
                "Destination already exists: {}",
                to.display()
            )));
        }
        remove_managed_path(to, true, true)?;
    }
    if meta.file_type().is_symlink() {
        let target = fs::read_link(from).map_err(|error| ToolError::new(error.to_string()))?;
        std::os::unix::fs::symlink(target, to)
            .map_err(|error| ToolError::new(error.to_string()))?;
    } else if meta.is_dir() {
        if !recursive {
            return Err(ToolError::new("Recursive copy requires recursive=true"));
        }
        fs::create_dir(to).map_err(|error| ToolError::new(error.to_string()))?;
        for entry in fs::read_dir(from).map_err(|error| ToolError::new(error.to_string()))? {
            let entry = entry.map_err(|error| ToolError::new(error.to_string()))?;
            copy_managed_path(&entry.path(), &to.join(entry.file_name()), true, force)?;
        }
        fs::set_permissions(to, meta.permissions())
            .map_err(|error| ToolError::new(error.to_string()))?;
        preserve_file_times(to, &meta)?;
    } else if meta.is_file() {
        fs::copy(from, to).map_err(|error| ToolError::new(error.to_string()))?;
        preserve_file_times(to, &meta)?;
    } else {
        return Err(ToolError::new(format!(
            "Unsupported file type: {}",
            from.display()
        )));
    }
    Ok(())
}

fn preserve_file_times(to: &Path, original: &fs::Metadata) -> UnitResult {
    let times = fs::FileTimes::new()
        .set_accessed(
            original
                .accessed()
                .map_err(|error| ToolError::new(error.to_string()))?,
        )
        .set_modified(
            original
                .modified()
                .map_err(|error| ToolError::new(error.to_string()))?,
        );
    fs::File::open(to)
        .and_then(|file| file.set_times(times))
        .map_err(|error| ToolError::new(error.to_string()))
}

impl Handlers {
    pub fn status(&self) -> ToolResult {
        self.require_unlocked()?;
        let (mut limits, sessions) = self.ptys.status();
        limits["unlockRecheckMs"] = json!(3_000);
        let pty_available = self.ptys.available();
        let architecture = match std::env::consts::ARCH {
            "aarch64" => "arm64",
            "x86_64" => "x64",
            other => other,
        };
        let runtime_version: Value = serde_json::from_str(include_str!("../../../../package.json"))
            .map(|package: Value| package["version"].clone())
            .unwrap_or(Value::Null);
        let mut uname: libc::utsname = unsafe { std::mem::zeroed() };
        let release = if unsafe { libc::uname(&mut uname) } == 0 {
            unsafe { std::ffi::CStr::from_ptr(uname.release.as_ptr()) }
                .to_string_lossy()
                .to_string()
        } else {
            String::new()
        };
        let data_dir = &self.context.data_dir;
        let settings_file = std::env::var_os("NEO_CORE_SETTINGS_FILE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| data_dir.join("settings.json"));
        Ok(json!({
            "version":std::env::var("NEOY_VERSION").ok(),
            "runtimeVersion": runtime_version,
            "coreVersion":crate::context::CORE_VERSION,
            "pid":std::process::id(),
            "hostname":hostname(),
            "username": std::env::var("USER").unwrap_or_default(),
            "uid":unsafe {libc::getuid()},"gid":unsafe {libc::getgid()},
            "home":self.context.home,
            "platform":std::env::consts::OS,"architecture":architecture,"release":release,
            "node":null,"shell":self.context.shell,"codexBin":self.context.codex_bin,
            "tunnelRuntimeKeyScrubbedFromChildEnvironment":self.context.tunnel_key_was_present,
            "cwd":std::env::current_dir().unwrap_or_default(),
            "dataDir":data_dir,"jobDir":self.context.job_dir,
            "guiFocusPolicy":std::env::var("NEO_CORE_GUI_FOCUS_POLICY").unwrap_or_else(|_| "background-first".into()),
            "operatorSettings":crate::gui::operator_settings(&self.context)?,
            "settingsFile":settings_file,"foregroundGuiApproved":crate::gui::foreground_approval_info(&self.context),
            "fullAccessUnlocked":true,"fullAccessUnlockFile":self.context.unlock_file,
            "ptyAvailable":pty_available,
            "ptyHelper":if pty_available {json!({"interpreter":"native","script":"libc::openpty"})} else {Value::Null},
            "ptyLimits":limits,"ptySessions":sessions,
            "accessModel":"No bridge sandbox or path allowlist. Effective access equals the macOS account running tunnel-client/this server, subject to macOS TCC, Full Disk Access, ACLs, and sudo authentication."
        }))
    }

    pub fn shell(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command_name = require_string(object, "command")?;
        let arguments = object.get("args").cloned().unwrap_or_else(|| json!({}));
        let args = require_object(&arguments)?;
        let commands = ["exec", "job.kill", "job.list", "job.status", "start"];
        if command_name == "help" {
            return facade_help("shell", args);
        }
        match command_name.as_str() {
            "exec" => {
                let command = require_string(args, "command")?;
                let timeout = optional_u64(args, "timeout", 600_000, 0, 1_800_000)?;
                let requested_max_output = optional_u64(
                    args,
                    "max_output_bytes",
                    16_384,
                    0,
                    self.context.max_output_bytes as u64,
                )?;
                let max_output = if requested_max_output == 0 {
                    16_384
                } else {
                    requested_max_output
                };
                crate::gui::guard(&self.context, &command)?;
                self.jobs.exec(
                    command,
                    args.get("cwd").and_then(Value::as_str).map(str::to_string),
                    args.get("env").cloned().unwrap_or(Value::Null),
                    args.get("stdin")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    timeout,
                    max_output,
                )
            }
            "start" => {
                let command = require_string(args, "command")?;
                crate::gui::guard(&self.context, &command)?;
                self.jobs.spawn(
                    command,
                    args.get("cwd").and_then(Value::as_str).map(str::to_string),
                    args.get("env").cloned().unwrap_or(Value::Null),
                    args.get("label")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                )
            }
            "job.status" => self.jobs.status(
                &require_string(args, "job_id")?,
                optional_u64(args, "max_log_bytes", 100_000, 1_024, 8_000_000)?,
            ),
            "job.list" => self.jobs.list(),
            "job.kill" => self.jobs.kill(
                &require_string(args, "job_id")?,
                &optional_string(args, "signal", "SIGTERM")?,
            ),
            _ => Err(unknown_command("shell", &command_name, &commands)),
        }
    }

    pub fn filesystem(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command = require_string(object, "command")?;
        let nested = object.get("args").cloned().unwrap_or_else(|| json!({}));
        let args = require_object(&nested)?;
        let commands = ["find", "grep", "list", "manage", "read", "stat", "write"];
        if command == "help" {
            return facade_help("fs", args);
        }
        match command.as_str() {
            "read" => {
                let path = self.context.resolve_path(&require_string(args, "path")?);
                if args.contains_key("start_line") && args.contains_key("startLine") {
                    return Err(ToolError::new("Use only one of start_line or startLine"));
                }
                if args.contains_key("end_line") && args.contains_key("endLine") {
                    return Err(ToolError::new("Use only one of end_line or endLine"));
                }
                let start_line = args.get("start_line").or_else(|| args.get("startLine"));
                let end_line = args.get("end_line").or_else(|| args.get("endLine"));
                if start_line.is_some() || end_line.is_some() {
                    let encoding = optional_string(args, "encoding", "utf8")?;
                    if encoding != "utf8" {
                        return Err(ToolError::new("Line-range reads require encoding='utf8'"));
                    }
                    if args.contains_key("offset") {
                        return Err(ToolError::new(
                            "Line-range reads cannot be combined with offset",
                        ));
                    }
                    let first = start_line
                        .map(|value| value.as_u64().filter(|line| *line >= 1))
                        .unwrap_or(Some(1))
                        .ok_or_else(|| ToolError::new("start_line must be an integer >= 1"))?;
                    let last = end_line
                        .map(|value| value.as_u64().filter(|line| *line >= 1))
                        .unwrap_or(Some(u64::MAX))
                        .ok_or_else(|| ToolError::new("end_line must be an integer >= 1"))?;
                    if last < first {
                        return Err(ToolError::new(
                            "end_line must be greater than or equal to start_line",
                        ));
                    }
                    let max_bytes = optional_u64(
                        args,
                        "max_bytes",
                        self.context.default_output_bytes as u64,
                        1,
                        self.context.max_output_bytes as u64,
                    )?;
                    let text = std::fs::read_to_string(&path)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                    let lines: Vec<&str> = text.split_inclusive('\n').collect();
                    let start = usize::try_from(first.saturating_sub(1)).unwrap_or(usize::MAX);
                    let end = usize::try_from(last).unwrap_or(usize::MAX).min(lines.len());
                    let content = if start < end {
                        lines[start..end].concat()
                    } else {
                        String::new()
                    };
                    if content.len() as u64 > max_bytes {
                        return Err(ToolError::new(format!(
                            "Requested line range exceeds max_bytes ({max_bytes})"
                        )));
                    }
                    return Ok(json!({
                        "path":path,
                        "size":text.len(),
                        "startLine":first,
                        "endLine":last.min(lines.len() as u64),
                        "lineCount":lines.len(),
                        "truncated":last < lines.len() as u64,
                        "encoding":"utf8",
                        "content":content
                    }));
                }
                let metadata =
                    std::fs::metadata(&path).map_err(|error| ToolError::new(error.to_string()))?;
                if !metadata.is_file() {
                    return Err(ToolError::new(format!(
                        "Not a regular file: {}",
                        path.display()
                    )));
                }
                let offset = optional_u64(args, "offset", 0, 0, u64::MAX)?;
                let max_bytes = optional_u64(
                    args,
                    "max_bytes",
                    self.context.default_output_bytes as u64,
                    1,
                    self.context.max_output_bytes as u64,
                )?;
                let bytes =
                    std::fs::read(&path).map_err(|error| ToolError::new(error.to_string()))?;
                let end =
                    ((offset as usize + max_bytes as usize).min(bytes.len())).max(offset as usize);
                let selected = bytes.get(offset as usize..end).unwrap_or_default();
                let encoding = optional_string(args, "encoding", "utf8")?;
                let content = if encoding == "base64" {
                    base64_encode(selected)
                } else if encoding == "utf8" {
                    String::from_utf8_lossy(selected).into_owned()
                } else {
                    return Err(ToolError::new("encoding must be utf8 or base64"));
                };
                let next = if end < bytes.len() {
                    json!(end)
                } else {
                    Value::Null
                };
                Ok(
                    json!({"path":path,"size":bytes.len(),"offset":offset,"bytesRead":selected.len(),"nextOffset":next,"truncated":end<bytes.len(),"encoding":encoding,"content":content}),
                )
            }
            "write" => {
                let path = self.context.resolve_path(&require_string(args, "path")?);
                let raw = args
                    .get("content")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::new("content must be a string"))?;
                let encoding = optional_string(args, "encoding", "utf8")?;
                let bytes = if encoding == "base64" {
                    base64_decode(raw.as_bytes()).map_err(ToolError::new)?
                } else {
                    raw.as_bytes().to_vec()
                };
                let append = optional_bool(args, "append", false)?;
                let atomic = optional_bool(args, "atomic", true)? && !append;
                let create_parents = optional_bool(args, "create_parents", true)?;
                let requested_mode = args
                    .get("mode")
                    .map(|value| {
                        value
                            .as_u64()
                            .filter(|mode| *mode <= 0o7777)
                            .map(|mode| mode as u32)
                            .ok_or_else(|| ToolError::new("mode must be between 0 and 4095"))
                    })
                    .transpose()?;
                if create_parents {
                    if let Some(parent) = path.parent() {
                        std::fs::create_dir_all(parent)
                            .map_err(|error| ToolError::new(error.to_string()))?;
                    }
                }
                let existing_mode = if requested_mode.is_none() && atomic {
                    std::fs::metadata(&path)
                        .ok()
                        .map(|metadata| metadata.permissions().mode() & 0o7777)
                } else {
                    None
                };
                if append {
                    let mut file = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .mode(requested_mode.unwrap_or(0o666))
                        .open(&path)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                    file.write_all(&bytes)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                    if let Some(mode) = requested_mode {
                        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                            .map_err(|error| ToolError::new(error.to_string()))?;
                    }
                } else if atomic {
                    let parent = path.parent().unwrap_or_else(|| std::path::Path::new("."));
                    let name = path
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or("file");
                    let temp = parent.join(format!(
                        ".{name}.{}.{}.{}.tmp",
                        std::process::id(),
                        unix_ms(),
                        FILE_WRITE_TEMP_ID.fetch_add(1, Ordering::Relaxed)
                    ));
                    let result = (|| -> Result<(), std::io::Error> {
                        let mut file = std::fs::OpenOptions::new()
                            .write(true)
                            .create_new(true)
                            .mode(requested_mode.or(existing_mode).unwrap_or(0o666))
                            .open(&temp)?;
                        file.write_all(&bytes)?;
                        file.sync_all()?;
                        std::fs::rename(&temp, &path)?;
                        if let Some(mode) = requested_mode.or(existing_mode) {
                            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))?;
                        }
                        Ok(())
                    })();
                    if let Err(error) = result {
                        let _ = std::fs::remove_file(&temp);
                        return Err(ToolError::new(error.to_string()));
                    }
                } else {
                    let mut file = std::fs::OpenOptions::new()
                        .write(true)
                        .create(true)
                        .truncate(true)
                        .mode(requested_mode.unwrap_or(0o666))
                        .open(&path)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                    file.write_all(&bytes)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                    if let Some(mode) = requested_mode {
                        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                            .map_err(|error| ToolError::new(error.to_string()))?;
                    }
                }
                let metadata =
                    std::fs::metadata(&path).map_err(|error| ToolError::new(error.to_string()))?;
                Ok(
                    json!({"path":path,"bytesWritten":bytes.len(),"size":metadata.len(),"append":append,"atomic":atomic,"mode":metadata.permissions().mode() & 0o7777}),
                )
            }
            "stat" => {
                let path = self.context.resolve_path(&require_string(args, "path")?);
                let metadata = std::fs::symlink_metadata(&path)
                    .map_err(|error| ToolError::new(error.to_string()))?;
                let file_type = metadata.file_type();
                let kind = if file_type.is_dir() {
                    "directory"
                } else if file_type.is_file() {
                    "file"
                } else if file_type.is_symlink() {
                    "symlink"
                } else if file_type.is_socket() {
                    "socket"
                } else {
                    "other"
                };
                let time = |seconds: i64, nanos: i64| {
                    std::time::UNIX_EPOCH
                        + Duration::new(seconds.max(0) as u64, nanos.clamp(0, 999_999_999) as u32)
                };
                let target = if file_type.is_symlink() {
                    std::fs::read_link(&path)
                        .ok()
                        .map(|value| value.to_string_lossy().to_string())
                } else {
                    None
                };
                Ok(json!({
                    "path":path,
                    "type":kind,
                    "size":metadata.len(),
                    "mode":permissions(&metadata),
                    "uid":metadata.uid(),
                    "gid":metadata.gid(),
                    "inode":metadata.ino(),
                    "device":metadata.dev(),
                    "links":metadata.nlink(),
                    "createdAt":iso_timestamp(metadata.created().unwrap_or(std::time::UNIX_EPOCH)),
                    "modifiedAt":iso_timestamp(time(metadata.mtime(), metadata.mtime_nsec())),
                    "changedAt":iso_timestamp(time(metadata.ctime(), metadata.ctime_nsec())),
                    "accessedAt":iso_timestamp(time(metadata.atime(), metadata.atime_nsec())),
                    "symlinkTarget":target
                }))
            }
            "list" => {
                let path = self.context.resolve_path(&require_string(args, "path")?);
                let recursive = optional_bool(args, "recursive", false)?;
                let include_hidden = optional_bool(args, "include_hidden", true)?;
                let max_entries = optional_u64(args, "max_entries", 5_000, 1, 100_000)? as usize;
                let max_depth = optional_u64(args, "max_depth", 10, 0, 100)?;
                let mut entries = Vec::new();
                let mut truncated = false;
                list_directory(
                    &path,
                    &path,
                    0,
                    recursive,
                    include_hidden,
                    max_entries,
                    max_depth,
                    &mut entries,
                    &mut truncated,
                )?;
                Ok(
                    json!({"root":path,"entries":entries,"count":entries.len(),"truncated":truncated}),
                )
            }
            "grep" => self.filesystem_grep(args),
            "find" => self.filesystem_find(args),
            "manage" => self.manage(args),
            _ => Err(unknown_command("fs", &command, &commands)),
        }
    }

    fn manage(&self, args: &serde_json::Map<String, Value>) -> ToolResult {
        let operation = require_string(args, "operation")?;
        let path = self.context.resolve_path(&require_string(args, "path")?);
        let recursive = optional_bool(args, "recursive", false)?;
        let force = optional_bool(args, "force", false)?;
        let mode = args
            .get("mode")
            .map(|_| optional_u64(args, "mode", 0, 0, 0o7777))
            .transpose()?;
        let destination_input = args
            .get("destination")
            .map(|_| require_string(args, "destination"))
            .transpose()?;
        let destination = destination_input.as_deref().map(|input| {
            if operation == "symlink" && !input.starts_with('/') && !input.starts_with("~/") {
                std::path::PathBuf::from(input)
            } else {
                self.context.resolve_path(input)
            }
        });
        match operation.as_str() {
            "mkdir" => {
                if recursive {
                    fs::create_dir_all(&path)
                } else {
                    fs::create_dir(&path)
                }
                .map_err(|error| ToolError::new(error.to_string()))?;
                if let Some(mode) = mode {
                    fs::set_permissions(&path, fs::Permissions::from_mode(mode as u32))
                        .map_err(|error| ToolError::new(error.to_string()))?;
                }
            }
            "remove" => remove_managed_path(&path, recursive, force)?,
            "move" | "copy" => {
                let target = destination
                    .as_ref()
                    .ok_or_else(|| ToolError::new("'destination' is required for move/copy"))?;
                // A forced move also removes the old target. Guard aliasing
                // before either operation can delete the only copy.
                if path == *target
                    || (path.exists()
                        && target.exists()
                        && fs::canonicalize(&path).ok() == fs::canonicalize(target).ok())
                {
                    return Err(ToolError::new("Source and destination are the same file"));
                }
                if path.is_dir()
                    && (target.starts_with(&path)
                        || fs::canonicalize(&path).ok().is_some_and(|source| {
                            target
                                .parent()
                                .and_then(|parent| fs::canonicalize(parent).ok())
                                .is_some_and(|parent| parent.starts_with(source))
                        }))
                {
                    return Err(ToolError::new(
                        "Cannot move or copy a directory into itself",
                    ));
                }
                if force {
                    remove_managed_path(target, true, true)?;
                }
                if let Some(parent) = target.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                }
                if operation == "move" {
                    match fs::rename(&path, target) {
                        Ok(()) => {}
                        Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {
                            copy_managed_path(&path, target, true, force)?;
                            remove_managed_path(&path, true, false)?;
                        }
                        Err(error) => return Err(ToolError::new(error.to_string())),
                    }
                } else {
                    copy_managed_path(&path, target, recursive, force)?;
                }
            }
            "chmod" => {
                let mode = mode.ok_or_else(|| ToolError::new("'mode' is required for chmod"))?;
                fs::set_permissions(&path, fs::Permissions::from_mode(mode as u32))
                    .map_err(|error| ToolError::new(error.to_string()))?;
            }
            "symlink" => {
                let target = destination.as_ref().ok_or_else(|| {
                    ToolError::new("'destination' is required as the symlink target")
                })?;
                if force {
                    remove_managed_path(&path, true, true)?;
                }
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|error| ToolError::new(error.to_string()))?;
                }
                std::os::unix::fs::symlink(target, &path)
                    .map_err(|error| ToolError::new(error.to_string()))?;
            }
            _ => {
                return Err(ToolError::new(format!(
                    "Unsupported operation: {operation}"
                )))
            }
        }
        Ok(
            json!({"operation":operation,"path":path,"destination":destination,"recursive":recursive,"force":force,"mode":mode}),
        )
    }

    fn filesystem_grep(&self, args: &serde_json::Map<String, Value>) -> ToolResult {
        let pattern = require_string(args, "pattern")?;
        let root = self
            .context
            .resolve_path(&optional_string(args, "path", ".")?);
        let max_results = optional_u64(args, "max_results", 100, 1, 5_000)? as usize;
        let timeout_ms = optional_u64(args, "timeout_ms", 60_000, 1_000, 120_000)?;
        let context_lines = optional_u64(args, "context", 0, 0, 20)? as usize;
        let mut command = Command::new(search_binary(&self.context, "rg")?);
        command.args([
            "--json",
            "--line-number",
            "--color=never",
            "--hidden",
            "--no-require-git",
            "--max-columns",
            "1000",
            "--max-columns-preview",
        ]);
        if context_lines > 0 {
            command.arg("--context").arg(context_lines.to_string());
        }
        if optional_bool(args, "ignore_case", false)? {
            command.arg("--ignore-case");
        }
        if optional_bool(args, "literal", false)? {
            command.arg("--fixed-strings");
        }
        if let Some(glob) = args.get("glob") {
            let glob = glob
                .as_str()
                .ok_or_else(|| ToolError::new("glob must be a string"))?;
            command.arg("--glob").arg(glob);
        }
        command.arg("--").arg(pattern).arg(&root);
        let (code, stdout, stderr) =
            run_with_timeout(&mut command, None, Duration::from_millis(timeout_ms))?;
        if code != 0 && code != 1 {
            return Err(ToolError::new(
                String::from_utf8_lossy(&stderr).trim().to_string(),
            ));
        }
        let mut matches = Vec::<Value>::new();
        let mut seen_lines = BTreeMap::<(String, u64), String>::new();
        let mut result_limit_reached = false;
        let mut byte_limit_reached = false;
        let mut lines_truncated = false;
        let mut output_bytes = 0_usize;
        for line in String::from_utf8_lossy(&stdout).lines() {
            let Ok(event) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            let kind = event["type"].as_str().unwrap_or_default();
            if kind != "match" && kind != "context" {
                continue;
            }
            let Some(full_path) = event.pointer("/data/path/text").and_then(Value::as_str) else {
                continue;
            };
            let Some(line_number) = event.pointer("/data/line_number").and_then(Value::as_u64)
            else {
                continue;
            };
            let raw = event
                .pointer("/data/lines/text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim_end_matches(['\r', '\n']);
            let truncated = truncate_search_line(raw);
            lines_truncated |= truncated.1;
            let relative = Path::new(full_path)
                .strip_prefix(&root)
                .unwrap_or(Path::new(full_path))
                .to_string_lossy()
                .replace('\\', "/");
            let relative = if relative.is_empty() {
                Path::new(full_path)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned()
            } else {
                relative
            };
            if context_lines > 0 {
                seen_lines.insert((relative.clone(), line_number), truncated.0.clone());
            }
            if kind != "match" || result_limit_reached || byte_limit_reached {
                continue;
            }
            let item = json!({"path":relative,"line":line_number,"text":truncated.0});
            let item_bytes = serde_json::to_vec(&item)
                .map_err(|error| ToolError::new(error.to_string()))?
                .len();
            if output_bytes + item_bytes > 50 * 1024 {
                byte_limit_reached = true;
                continue;
            }
            output_bytes += item_bytes;
            matches.push(item);
            if matches.len() >= max_results {
                result_limit_reached = true;
            }
        }
        if context_lines > 0 {
            for item in &mut matches {
                let path = item["path"].as_str().unwrap_or_default().to_string();
                let line = item["line"].as_u64().unwrap_or_default();
                let mut before = Vec::new();
                let mut after = Vec::new();
                for number in line.saturating_sub(context_lines as u64)..line {
                    if let Some(text) = seen_lines.get(&(path.clone(), number)) {
                        before.push(json!({"line":number,"text":text}));
                    }
                }
                for number in line + 1..=line + context_lines as u64 {
                    if let Some(text) = seen_lines.get(&(path.clone(), number)) {
                        after.push(json!({"line":number,"text":text}));
                    }
                }
                item["before"] = json!(before);
                item["after"] = json!(after);
            }
        }
        Ok(json!({
            "root":root,"matches":matches,"count":matches.len(),
            "truncated":result_limit_reached || byte_limit_reached || lines_truncated,
            "resultLimitReached":result_limit_reached,
            "byteLimitReached":byte_limit_reached,"linesTruncated":lines_truncated
        }))
    }

    fn filesystem_find(&self, args: &serde_json::Map<String, Value>) -> ToolResult {
        let mut pattern = require_string(args, "pattern")?;
        let root = self
            .context
            .resolve_path(&optional_string(args, "path", ".")?);
        let max_results = optional_u64(args, "max_results", 500, 1, 10_000)? as usize;
        let timeout_ms = optional_u64(args, "timeout_ms", 60_000, 1_000, 120_000)?;
        let mut command = Command::new(search_binary(&self.context, "fd")?);
        command.args([
            "--glob",
            "--color=never",
            "--hidden",
            "--no-require-git",
            "--max-results",
        ]);
        command.arg(max_results.to_string());
        if pattern.contains('/') {
            command.arg("--full-path");
            if !pattern.starts_with('/') && !pattern.starts_with("**/") && pattern != "**" {
                pattern = format!("**/{pattern}");
            }
        }
        command.arg("--").arg(pattern).arg(&root);
        let (code, stdout, stderr) =
            run_with_timeout(&mut command, None, Duration::from_millis(timeout_ms))?;
        if code != 0 {
            return Err(ToolError::new(
                String::from_utf8_lossy(&stderr).trim().to_string(),
            ));
        }
        let mut paths = Vec::new();
        let mut output_bytes = 0_usize;
        let mut byte_limit_reached = false;
        for line in String::from_utf8_lossy(&stdout).lines() {
            let full = Path::new(line.trim_end_matches('\r'));
            let relative = full
                .strip_prefix(&root)
                .unwrap_or(full)
                .to_string_lossy()
                .replace('\\', "/");
            if relative.is_empty() {
                continue;
            }
            let bytes = relative.len();
            if output_bytes + bytes > 50 * 1024 {
                byte_limit_reached = true;
                break;
            }
            output_bytes += bytes;
            paths.push(relative);
        }
        let result_limit_reached = paths.len() >= max_results;
        Ok(json!({
            "root":root,"paths":paths,"count":paths.len(),
            "truncated":result_limit_reached || byte_limit_reached,
            "resultLimitReached":result_limit_reached,"byteLimitReached":byte_limit_reached
        }))
    }

    pub fn patch(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let patch = require_string(object, "patch")?;
        let cwd = require_string(object, "cwd")?;
        if patch.contains("*** Begin Patch") {
            return Err(ToolError::new(
                "Do not pass Codex Begin Patch markers; send a standard unified diff.",
            ));
        }
        if !std::path::Path::new(&cwd).is_absolute() {
            return Err(ToolError::new("cwd must be an absolute working directory"));
        }
        let mut command = Command::new("/usr/bin/git");
        command.current_dir(&cwd).arg("apply");
        if optional_bool(object, "check_only", false)? {
            command.arg("--check");
        }
        if optional_bool(object, "reverse", false)? {
            command.arg("--reverse");
        }
        if optional_bool(object, "three_way", false)? {
            command.arg("--3way");
        }
        let (code, stdout, stderr) = run_with_timeout(
            &mut command,
            Some(patch.as_bytes()),
            Duration::from_secs(120),
        )?;
        let value = json!({"exitCode":code,"stdout":String::from_utf8_lossy(&stdout),"stderr":String::from_utf8_lossy(&stderr)});
        if code == 0 {
            Ok(value)
        } else {
            Err(ToolError::new(format!(
                "git apply exited {code}: {}",
                String::from_utf8_lossy(&stderr)
            )))
        }
    }

    pub fn codex(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command = require_string(object, "command")?;
        let nested = object.get("args").cloned().unwrap_or_else(|| json!({}));
        let args = require_object(&nested)?;
        let commands = ["thread.list", "thread.read", "thread.turns.list"];
        if command == "help" {
            return facade_help("codex", args);
        }
        let timeout = optional_u64(args, "timeout_ms", 30_000, 1_000, 120_000)?;
        let params = match command.as_str() {
            "thread.read" => {
                json!({"threadId":require_string(args,"thread_id")?,"includeTurns":optional_bool(args,"include_turns",true)?})
            }
            "thread.turns.list" => {
                let sort_direction = optional_string(args, "sort_direction", "asc")?;
                if sort_direction != "asc" && sort_direction != "desc" {
                    return Err(ToolError::new("sort_direction must be asc or desc"));
                }
                let items_view = optional_string(args, "items_view", "full")?;
                if !["notLoaded", "summary", "full"].contains(&items_view.as_str()) {
                    return Err(ToolError::new(
                        "items_view must be notLoaded, summary, or full",
                    ));
                }
                let mut value = json!({"threadId":require_string(args,"thread_id")?,"limit":optional_u64(args,"limit",50,1,200)?,"sortDirection":sort_direction,"itemsView":items_view});
                if args.contains_key("cursor") {
                    value["cursor"] = json!(optional_string(args, "cursor", "")?);
                }
                value
            }
            "thread.list" => {
                let mut value = json!({"limit":optional_u64(args,"limit",50,1,200)?,"sortKey":optional_string(args,"sort_key","recency_at")?,"sortDirection":optional_string(args,"sort_direction","desc")?});
                for (input, output) in [("cursor", "cursor"), ("search_term", "searchTerm")] {
                    if args.contains_key(input) {
                        value[output] = json!(optional_string(args, input, "")?);
                    }
                }
                if args.contains_key("cwd") {
                    let cwd = optional_string(args, "cwd", "")?;
                    value["cwd"] = json!(self.context.resolve_path(&cwd));
                }
                for (input, output) in [
                    ("archived", "archived"),
                    ("is_pinned", "isPinned"),
                    ("use_state_db_only", "useStateDbOnly"),
                ] {
                    if args.contains_key(input) {
                        value[output] = json!(optional_bool(args, input, false)?);
                    }
                }
                for (input, output) in [
                    ("model_providers", "modelProviders"),
                    ("source_kinds", "sourceKinds"),
                ] {
                    if args.contains_key(input) {
                        value[output] = optional_string_array(args, input)?;
                    }
                }
                value
            }
            _ => return Err(unknown_command("codex", &command, &commands)),
        };
        let method = match command.as_str() {
            "thread.read" => "thread/read",
            "thread.list" => "thread/list",
            _ => "thread/turns/list",
        };
        Ok(text_value(codex_app_server(
            &self.context.codex_bin,
            method,
            &params,
            Duration::from_millis(timeout),
        )?))
    }

    pub fn discord(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command = require_string(object, "command")?;
        if command == "help" {
            let nested = object.get("args").cloned().unwrap_or_else(|| json!({}));
            return facade_help("discord", require_object(&nested)?);
        }
        if command != "reply" {
            return Err(unknown_command("discord", &command, &["reply"]));
        }
        let nested = object.get("args").cloned().unwrap_or_else(|| json!({}));
        let args = require_object(&nested)?;
        let correlation_id = require_string(args, "correlationId")?;
        let text = require_string(args, "text")?;
        if correlation_id.len() < 20 || correlation_id.len() > 128 {
            return Err(ToolError::new(
                "correlationId length must be between 20 and 128",
            ));
        }
        if text.len() > 18_000 {
            return Err(ToolError::new("text must be at most 18000 characters"));
        }
        let endpoint = std::env::var("NEO_DISCORD_REPLY_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:43118/discord/reply".to_string());
        if !(endpoint.starts_with("http://127.0.0.1/")
            || endpoint.starts_with("http://localhost/")
            || endpoint.starts_with("http://[::1]/"))
        {
            return Err(ToolError::new(
                "Discord delivery endpoint must be local loopback",
            ));
        }
        let body = json!({"correlationId":correlation_id,"text":text}).to_string();
        let mut command = Command::new("/usr/bin/curl");
        command
            .arg("--max-time")
            .arg("12")
            .arg("--silent")
            .arg("--show-error")
            .arg("--fail")
            .arg("-H")
            .arg("content-type: application/json")
            .arg("--data-binary")
            .arg("@-")
            .arg(&endpoint);
        let (_, stdout, _) =
            run_with_timeout(&mut command, Some(body.as_bytes()), Duration::from_secs(15))?;
        let result: Value = serde_json::from_slice(&stdout)
            .map_err(|_| ToolError::new("Discord endpoint returned invalid JSON"))?;
        if result["ok"].as_bool() != Some(true)
            || result["messageId"]
                .as_str()
                .map(str::is_empty)
                .unwrap_or(true)
        {
            return Err(ToolError::new(
                result["error"]
                    .as_str()
                    .unwrap_or("Discord delivery failed")
                    .to_string(),
            ));
        }
        Ok(result)
    }

    pub fn chatgpt(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command = require_string(object, "command")?;
        let args = object.get("args").cloned().unwrap_or_else(|| json!({}));
        if command == "help" {
            return facade_help("chatgpt", require_object(&args)?);
        }
        if command != "turn" && command != "thread" {
            return Err(unknown_command("chatgpt", &command, &["turn", "thread"]));
        }
        let args = require_object(&args)?;
        let message = require_string(args, "message")?;
        if message.len() > 64_000 {
            return Err(ToolError::new("message is too large"));
        }
        let project_id = optional_string(args, "project_id", "")?;
        if !project_id.is_empty() && !valid_identifier(&project_id, "g-p-", 8, 128) {
            return Err(ToolError::new("project_id is invalid"));
        }
        let source_thread_id = optional_string(args, "source_thread_id", "")?;
        if !source_thread_id.is_empty() && !valid_identifier(&source_thread_id, "", 8, 160) {
            return Err(ToolError::new("source_thread_id is invalid"));
        }
        let temporary = optional_bool(args, "temporary", false)?;
        if command == "thread" && temporary && !project_id.is_empty() {
            return Err(ToolError::new(
                "temporary=true cannot be combined with project_id",
            ));
        }
        let reason = optional_string(args, "reason", "")?;
        let reason = if reason.trim().is_empty() {
            Value::Null
        } else {
            json!(reason.trim().chars().take(2_000).collect::<String>())
        };
        let mut config = json!({"message":message,"temporary":temporary,"reason":reason});
        if !project_id.is_empty() {
            config["project_id"] = json!(project_id);
        }
        if !source_thread_id.is_empty() {
            config["source_thread_id"] = json!(source_thread_id);
        }
        let mode;
        if command == "turn" {
            let thread_id = require_string(args, "thread_id")?;
            if !valid_identifier(&thread_id, "", 8, 160) {
                return Err(ToolError::new("thread_id is invalid"));
            }
            mode = optional_string(args, "mode", "async")?;
            if mode != "async" && mode != "sync" {
                return Err(ToolError::new("mode must be async or sync"));
            }
            let mergeable = optional_bool(args, "mergeable", false)?;
            if mergeable && mode != "async" {
                return Err(ToolError::new("mergeable requires async mode"));
            }
            match mode.as_str() {
                "sync" if optional_string(args, "session_id", "")?.trim().is_empty() => {
                    return Err(ToolError::new("mode sync requires caller-owned session_id"));
                }
                "async" if args.contains_key("session_id") => {
                    return Err(ToolError::new("mode async does not accept session_id"));
                }
                _ => {}
            }
            config["thread_id"] = json!(thread_id);
            config["mode"] = json!(mode);
            config["mergeable"] = json!(mergeable);
        }
        let directory = self.context.data_dir.join(format!(
            "chatgpt-{}-{}-{}",
            std::process::id(),
            unix_ms(),
            FILE_WRITE_TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&directory).map_err(|error| ToolError::new(error.to_string()))?;
        set_private_directory(&directory);
        let config_path = directory.join("config.json");
        let mut config_file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&config_path)
            .map_err(|error| ToolError::new(error.to_string()))?;
        config_file
            .write_all(config.to_string().as_bytes())
            .map_err(|error| ToolError::new(error.to_string()))?;
        drop(config_file);
        let action = if command == "turn" {
            "new-turn"
        } else {
            "new-thread"
        };
        let mut cli =
            Command::new(std::env::var("WEBHELM_CLI").unwrap_or_else(|_| "npx".to_string()));
        if std::env::var_os("WEBHELM_CLI").is_none() {
            cli.arg("--yes").arg("webhelm@latest");
        }
        cli.arg("platform")
            .arg("run")
            .arg("chatgpt")
            .arg(action)
            .arg(if command == "thread" {
                "--auto-session"
            } else {
                "--mode"
            });
        if command == "turn" {
            if optional_string(args, "mode", "async")? == "sync" {
                cli.arg("sync")
                    .arg("--session-id")
                    .arg(require_string(args, "session_id")?);
            } else {
                cli.arg("async");
            }
        }
        cli.arg("--config").arg(&config_path);
        let timeout =
            Duration::from_millis(optional_u64(args, "timeout_ms", 600_000, 1_000, 1_800_000)?);
        let result = run_with_timeout(&mut cli, None, timeout);
        let _ = std::fs::remove_dir_all(&directory);
        let (code, stdout, stderr) = result?;
        if code != 0 {
            return Err(ToolError::new(format!(
                "Browser Workspace action failed (code={code}): {}",
                String::from_utf8_lossy(&stderr)
            )));
        }
        let envelope: Value = serde_json::from_slice(&stdout)
            .map_err(|_| ToolError::new("Browser Workspace did not return JSON"))?;
        let raw = envelope.get("result").unwrap_or(&envelope);
        let receipt_text = raw["stdout"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| raw.to_string());
        let receipt: Value = serde_json::from_str(receipt_text.trim()).map_err(|_| {
            ToolError::new("Browser Workspace returned no machine-readable receipt")
        })?;
        let expected_receipt_mode = if command == "turn" {
            "new-turn"
        } else {
            "new-thread"
        };
        if receipt["status"].as_str() != Some("submitted")
            || receipt["mode"].as_str() != Some(expected_receipt_mode)
        {
            return Err(ToolError::new(
                "Browser Workspace did not verify submission",
            ));
        }
        if command == "thread"
            && !temporary
            && (!receipt["thread_id"]
                .as_str()
                .is_some_and(|value| valid_identifier(value, "", 8, 160))
                || !receipt["thread_url"]
                    .as_str()
                    .is_some_and(|value| value.starts_with("https://chatgpt.com/c/")))
        {
            return Err(ToolError::new(
                "Browser Workspace did not return a durable ChatGPT thread ID and URL",
            ));
        }
        Ok(receipt)
    }

    pub fn terminal(&self, arguments: &Value) -> ToolResult {
        self.require_unlocked()?;
        let object = require_object(arguments)?;
        let command = require_string(object, "command")?;
        let nested = object.get("args").cloned().unwrap_or_else(|| json!({}));
        let args = require_object(&nested)?;
        let commands = ["close", "read", "resize", "signal", "start", "write"];
        if command == "help" {
            return facade_help("terminal", args);
        }
        match command.as_str() {
            "start" => {
                let executable = require_string(args, "command")?;
                let vector: Vec<String> = match args.get("args") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(values)) => values
                        .iter()
                        .map(|value| {
                            value
                                .as_str()
                                .map(str::to_string)
                                .ok_or_else(|| ToolError::new("args must contain only strings"))
                        })
                        .collect::<Result<_, _>>()?,
                    Some(_) => return Err(ToolError::new("args must be an array of strings")),
                };
                if vector.len() > 256 {
                    return Err(ToolError::new("args must contain at most 256 entries"));
                }
                let cwd = self
                    .context
                    .resolve_path(&optional_string(args, "cwd", ".")?);
                let env: BTreeMap<String, Option<String>> = match args.get("env") {
                    None | Some(Value::Null) => BTreeMap::new(),
                    Some(Value::Object(values)) => {
                        if values.len() > 64 {
                            return Err(ToolError::new("env must contain at most 64 properties"));
                        }
                        values
                            .iter()
                            .map(|(key, value)| {
                                if !valid_env_key(key) {
                                    return Err(ToolError::new(format!("Invalid environment variable name: {key}")));
                                }
                                let normalized = match value {
                                    Value::Null => None,
                                    Value::String(text) => Some(text.clone()),
                                    Value::Bool(value) => Some(value.to_string()),
                                    Value::Number(value) => Some(value.to_string()),
                                    _ => return Err(ToolError::new(format!("Environment value for '{key}' must be string, number, boolean, or null"))),
                                };
                                Ok((key.clone(), normalized))
                            })
                            .collect::<Result<_, _>>()?
                    }
                    Some(_) => return Err(ToolError::new("env must be an object")),
                };
                let cols = optional_u64(args, "cols", 120, 20, 500)? as u16;
                let rows = optional_u64(args, "rows", 30, 5, 200)? as u16;
                let term = optional_string(args, "term", "xterm-256color")?;
                if !["xterm-256color", "xterm", "vt100", "dumb"].contains(&term.as_str()) {
                    return Err(ToolError::new(
                        "term must be xterm-256color, xterm, vt100, or dumb",
                    ));
                }
                let idle_timeout_ms = if args.contains_key("idle_timeout_ms") {
                    optional_u64(
                        args,
                        "idle_timeout_ms",
                        self.ptys.idle_timeout_ms,
                        30_000,
                        3_600_000,
                    )?
                } else {
                    self.ptys.idle_timeout_ms
                };
                self.ptys.start(
                    executable,
                    vector,
                    cwd,
                    env,
                    cols,
                    rows,
                    term,
                    idle_timeout_ms,
                )
            }
            "read" => self.ptys.read(
                &require_string(args, "session_id")?,
                optional_u64(args, "cursor", 0, 0, u64::MAX)?,
                optional_u64(args, "max_bytes", 65_536, 1_024, 1_000_000)? as usize,
                optional_bool(args, "strip_ansi", true)?,
                optional_bool(args, "collapse_carriage_returns", true)?,
                optional_u64(args, "wait_ms", 0, 0, 30_000)?,
            ),
            "write" => self.ptys.write(
                &require_string(args, "session_id")?,
                args.get("data")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::new("data must be a string"))?
                    .to_string(),
            ),
            "resize" => self.ptys.resize(
                &require_string(args, "session_id")?,
                optional_u64(args, "cols", 120, 20, 500)? as u16,
                optional_u64(args, "rows", 30, 5, 200)? as u16,
            ),
            "signal" => self.ptys.signal(
                &require_string(args, "session_id")?,
                &optional_string(args, "signal", "TERM")?,
            ),
            "close" => self.ptys.close(&require_string(args, "session_id")?),
            _ => Err(unknown_command("terminal", &command, &commands)),
        }
    }
}

fn permissions(metadata: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o7777
}

fn search_binary(context: &Context, name: &str) -> Result<String, ToolError> {
    let _guard = SEARCH_DOWNLOAD_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| ToolError::new("search-tool installation lock poisoned"))?;
    let cached = context.data_dir.join("tools").join(name);
    if executable_works(&cached) {
        return Ok(cached.to_string_lossy().into_owned());
    }
    if let Some(path) = crate::pty::find_in_path(name) {
        if executable_works(Path::new(&path)) {
            return Ok(path);
        }
    }
    if std::env::var("NEO_CORE_OFFLINE").as_deref() == Ok("1") {
        return Err(ToolError::new(format!(
            "{name} is unavailable while NEO_CORE_OFFLINE=1"
        )));
    }
    download_search_binary(context, name).map(|path| path.to_string_lossy().into_owned())
}

fn executable_works(path: &Path) -> bool {
    if !path.is_file()
        || permissions(&match fs::metadata(path) {
            Ok(value) => value,
            Err(_) => return false,
        }) & 0o111
            == 0
    {
        return false;
    }
    Command::new(path)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn search_asset(name: &str) -> Option<(&'static str, &'static str)> {
    let arm = std::env::consts::ARCH == "aarch64";
    match (name, std::env::consts::OS, arm) {
        ("rg", "macos", true) => Some(("https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz", "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4")),
        ("rg", "macos", false) if std::env::consts::ARCH == "x86_64" => Some(("https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-apple-darwin.tar.gz", "af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1")),
        ("fd", "macos", true) => Some(("https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz", "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12")),
        ("fd", "macos", false) if std::env::consts::ARCH == "x86_64" => Some(("https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-apple-darwin.tar.gz", "7e31028c62c6955877735d0406807aa484c2a5e6f86235a59e26c29c301da590")),
        _ => None,
    }
}

fn download_search_binary(context: &Context, name: &str) -> Result<std::path::PathBuf, ToolError> {
    let (url, expected_sha256) = search_asset(name).ok_or_else(|| {
        ToolError::new(format!(
            "{name} auto-install is unsupported on this platform/architecture"
        ))
    })?;
    let tools_dir = context.data_dir.join("tools");
    fs::create_dir_all(&tools_dir).map_err(|error| ToolError::new(error.to_string()))?;
    fs::set_permissions(&tools_dir, fs::Permissions::from_mode(0o700))
        .map_err(|error| ToolError::new(error.to_string()))?;
    let unique = FILE_WRITE_TEMP_ID.fetch_add(1, Ordering::Relaxed);
    let temp = tools_dir.join(format!(".{name}-{}-{unique}", std::process::id()));
    fs::create_dir(&temp).map_err(|error| ToolError::new(error.to_string()))?;
    let result = (|| {
        let archive = temp.join("tool.tar.gz");
        let download = Command::new("/usr/bin/curl")
            .args([
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--max-time",
                "120",
                "--output",
            ])
            .arg(&archive)
            .arg(url)
            .output()
            .map_err(|error| ToolError::new(error.to_string()))?;
        if !download.status.success() {
            return Err(ToolError::new(
                String::from_utf8_lossy(&download.stderr).trim().to_string(),
            ));
        }
        if sha256_file(&archive)? != expected_sha256 {
            return Err(ToolError::code(
                format!("SHA-256 mismatch for {name}"),
                "SEARCH_TOOL_CHECKSUM_MISMATCH",
            ));
        }
        let listing = Command::new("/usr/bin/tar")
            .arg("-tzf")
            .arg(&archive)
            .output()
            .map_err(|error| ToolError::new(error.to_string()))?;
        if !listing.status.success() {
            return Err(ToolError::new("search-tool archive could not be listed"));
        }
        for entry in String::from_utf8_lossy(&listing.stdout).lines() {
            let path = Path::new(entry);
            if path.is_absolute()
                || path
                    .components()
                    .any(|part| matches!(part, std::path::Component::ParentDir))
            {
                return Err(ToolError::code(
                    "search-tool archive contains an unsafe path",
                    "SEARCH_TOOL_ARCHIVE_UNSAFE",
                ));
            }
        }
        let extracted = temp.join("extract");
        fs::create_dir(&extracted).map_err(|error| ToolError::new(error.to_string()))?;
        let unpack = Command::new("/usr/bin/tar")
            .arg("-xzf")
            .arg(&archive)
            .arg("-C")
            .arg(&extracted)
            .output()
            .map_err(|error| ToolError::new(error.to_string()))?;
        if !unpack.status.success() {
            return Err(ToolError::new("search-tool archive extraction failed"));
        }
        let staged = find_named_file(&extracted, name)
            .ok_or_else(|| ToolError::new(format!("{name} not found in downloaded archive")))?;
        let destination = tools_dir.join(name);
        let temporary = tools_dir.join(format!(".{name}.{}.tmp", std::process::id()));
        fs::copy(staged, &temporary).map_err(|error| ToolError::new(error.to_string()))?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o755))
            .map_err(|error| ToolError::new(error.to_string()))?;
        fs::rename(&temporary, &destination).map_err(|error| ToolError::new(error.to_string()))?;
        if !executable_works(&destination) {
            let _ = fs::remove_file(&destination);
            return Err(ToolError::code(
                format!("downloaded {name} failed its version check"),
                "SEARCH_TOOL_INVALID_BINARY",
            ));
        }
        Ok(destination)
    })();
    let _ = fs::remove_dir_all(&temp);
    result
}

fn sha256_file(path: &Path) -> Result<String, ToolError> {
    let digest = Command::new("/usr/bin/shasum")
        .arg("-a")
        .arg("256")
        .arg(path)
        .output()
        .map_err(|error| ToolError::new(error.to_string()))?;
    if !digest.status.success() {
        return Err(ToolError::new(
            "shasum failed to hash downloaded search tool",
        ));
    }
    Ok(String::from_utf8_lossy(&digest.stdout)
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string())
}

fn find_named_file(root: &Path, name: &str) -> Option<std::path::PathBuf> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory).ok()? {
            let entry = entry.ok()?;
            let path = entry.path();
            if entry.file_type().ok()?.is_dir() {
                pending.push(path);
            } else if entry.file_name() == name {
                return Some(path);
            }
        }
    }
    None
}

fn truncate_search_line(line: &str) -> (String, bool) {
    let mut chars = line.chars();
    let prefix: String = chars.by_ref().take(500).collect();
    if chars.next().is_some() {
        (format!("{prefix}... [truncated]"), true)
    } else {
        (prefix, false)
    }
}

fn hostname() -> String {
    let mut buffer = [0_u8; 256];
    if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0 {
        let end = buffer
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(buffer.len());
        String::from_utf8_lossy(&buffer[..end]).into_owned()
    } else {
        "unknown".to_string()
    }
}

const BASE64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(data: &[u8]) -> String {
    let mut output = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let bytes = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let value = ((bytes[0] as u32) << 16) | ((bytes[1] as u32) << 8) | bytes[2] as u32;
        output.push(BASE64[(value >> 18) as usize & 63] as char);
        output.push(BASE64[(value >> 12) as usize & 63] as char);
        output.push(if chunk.len() > 1 {
            BASE64[(value >> 6) as usize & 63] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            BASE64[value as usize & 63] as char
        } else {
            '='
        });
    }
    output
}

fn base64_decode(data: &[u8]) -> Result<Vec<u8>, String> {
    let filtered: Vec<u8> = data
        .iter()
        .cloned()
        .filter(|byte| !byte.is_ascii_whitespace() && *byte != b'=')
        .collect();
    filtered
        .chunks(4)
        .map(|chunk| {
            if chunk.len() < 2 {
                return Err("invalid base64".to_string());
            }
            let mut value = 0_u32;
            for byte in chunk {
                let index = BASE64
                    .iter()
                    .position(|candidate| candidate == byte)
                    .ok_or("invalid base64 character")? as u32;
                value = (value << 6) | index;
            }
            value <<= 6 * (4 - chunk.len()) as u32;
            let bytes = value.to_be_bytes();
            Ok(bytes[1..chunk.len()].to_vec())
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| parts.concat())
}

fn codex_app_server(binary: &str, method: &str, params: &Value, timeout: Duration) -> ToolResult {
    let child = Command::new(binary)
        .arg("app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| ToolError::new(error.to_string()))?;
    let mut child = KillChildOnDrop(child);
    let mut stdin = child
        .0
        .stdin
        .take()
        .ok_or_else(|| ToolError::new("Codex stdin unavailable"))?;
    let stdout = child
        .0
        .stdout
        .take()
        .ok_or_else(|| ToolError::new("Codex stdout unavailable"))?;
    let stderr_reader = child.0.stderr.take().map(|mut stderr| {
        std::thread::spawn(move || {
            use std::io::Read;
            let mut scratch = [0_u8; 8_192];
            while stderr.read(&mut scratch).unwrap_or(0) > 0 {}
        })
    });
    let outcome = (|| {
        let initialize = json!({"id":0,"method":"initialize","params":{"clientInfo":{"name":crate::context::SERVER_NAME,"title":crate::context::SERVER_TITLE,"version":crate::context::CORE_VERSION},"capabilities":{"experimentalApi":true}}});
        writeln!(stdin, "{initialize}").map_err(|error| ToolError::new(error.to_string()))?;
        let mut reader = CodexLineReader {
            reader: stdout,
            pending: Vec::new(),
        };
        let started = Instant::now();
        let mut initialized = false;
        while started.elapsed() < timeout {
            let remaining = timeout.saturating_sub(started.elapsed());
            let line = reader.read_line(remaining.min(Duration::from_millis(1_000)))?;
            let message: Value = match serde_json::from_str(&line) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if !initialized && message["id"].as_i64() == Some(0) {
                writeln!(stdin, "{}", json!({"method":"initialized","params":{}}))
                    .map_err(|error| ToolError::new(error.to_string()))?;
                writeln!(stdin, "{}", json!({"id":1,"method":method,"params":params}))
                    .map_err(|error| ToolError::new(error.to_string()))?;
                initialized = true;
            } else if initialized && message["id"].as_i64() == Some(1) {
                if let Some(error) = message.get("error") {
                    return Err(ToolError::new(format!(
                        "Codex app-server error {}: {}",
                        error["code"], error["message"]
                    )));
                }
                return Ok(message["result"].clone());
            }
        }
        Err(ToolError::code(
            "Timed out waiting for Codex app-server",
            "CODEX_TIMEOUT",
        ))
    })();
    drop(child);
    if let Some(reader) = stderr_reader {
        let _ = reader.join();
    }
    outcome
}

struct KillChildOnDrop(std::process::Child);

impl Drop for KillChildOnDrop {
    fn drop(&mut self) {
        let pid = self.0.id() as libc::pid_t;
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_millis(250);
        while Instant::now() < deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct CodexLineReader {
    reader: std::process::ChildStdout,
    pending: Vec<u8>,
}

impl CodexLineReader {
    fn read_line(&mut self, budget: Duration) -> Result<String, ToolError> {
        use std::io::Read;
        use std::os::unix::io::AsRawFd;

        const MAX_LINE_BYTES: usize = 8 * 1024 * 1024;
        let fd = self.reader.as_raw_fd();
        let deadline = Instant::now() + budget;
        loop {
            if let Some(position) = self.pending.iter().position(|byte| *byte == b'\n') {
                let remainder = self.pending.split_off(position + 1);
                let line = std::mem::replace(&mut self.pending, remainder);
                return Ok(String::from_utf8_lossy(&line[..position]).into_owned());
            }
            if self.pending.len() >= MAX_LINE_BYTES {
                return Err(ToolError::new(
                    "Codex app-server response line is too large",
                ));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let milliseconds = remaining.as_millis().min(1_000) as i32;
            if milliseconds <= 0 {
                return Err(ToolError::code(
                    "Timed out waiting for Codex app-server",
                    "CODEX_TIMEOUT",
                ));
            }
            let mut poll_fd = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut poll_fd, 1, milliseconds) };
            if ready < 0 {
                return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
            }
            if ready == 0 {
                return Err(ToolError::code(
                    "Timed out waiting for Codex app-server",
                    "CODEX_TIMEOUT",
                ));
            }
            let mut bytes = [0_u8; 4_096];
            let count = self
                .reader
                .read(&mut bytes)
                .map_err(|error| ToolError::new(error.to_string()))?;
            if count == 0 {
                return Err(ToolError::new("Codex app-server closed stdout"));
            }
            self.pending.extend_from_slice(&bytes[..count]);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_tool_manifest_and_archive_checksum_are_verified() {
        let (url, expected) = search_asset("rg").expect("rg is supported on this macOS target");
        assert!(url.starts_with("https://github.com/BurntSushi/ripgrep/releases/download/"));
        assert_eq!(expected.len(), 64);
        let path = std::env::temp_dir().join(format!("neoy-rust-sha256-{}", std::process::id()));
        fs::write(&path, b"abc").unwrap();
        assert_eq!(
            sha256_file(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn base64_round_trip() {
        assert_eq!(base64_encode(b"abc"), "YWJj");
        assert_eq!(base64_decode(b"YWJj").unwrap(), b"abc");
    }

    #[test]
    fn child_output_is_drained_concurrently_and_timeout_kills_group() {
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            "head -c 131072 /dev/zero; head -c 131072 /dev/zero >&2",
        ]);
        let (code, stdout, stderr) =
            run_with_timeout(&mut command, None, Duration::from_secs(5)).unwrap();
        assert_eq!(code, 0);
        assert_eq!(stdout.len(), 131_072);
        assert_eq!(stderr.len(), 131_072);

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & exit 0"]);
        let started = Instant::now();
        let (code, _, _) = run_with_timeout(&mut command, None, Duration::from_secs(5)).unwrap();
        assert_eq!(code, 0);
        assert!(started.elapsed() < Duration::from_secs(3));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "trap '' TERM; sleep 30 & exit 0"]);
        let started = Instant::now();
        let (code, _, _) = run_with_timeout(&mut command, None, Duration::from_secs(5)).unwrap();
        assert_eq!(code, 0);
        assert!(started.elapsed() < Duration::from_secs(3));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & wait"]);
        let started = Instant::now();
        let error = run_with_timeout(&mut command, None, Duration::from_millis(100)).unwrap_err();
        assert_eq!(error.code.as_deref(), Some("CHILD_TIMEOUT"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn child_output_capture_is_bounded_and_drains_overflow() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "head -c 4194304 /dev/zero"]);
        let (_, stdout, _) = run_with_timeout(&mut command, None, Duration::from_secs(5)).unwrap();
        assert_eq!(stdout.len(), MAX_CHILD_CAPTURE_BYTES);

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "head -c 4194305 /dev/zero"]);
        let error = run_with_timeout(&mut command, None, Duration::from_secs(5)).unwrap_err();
        assert_eq!(error.code.as_deref(), Some("CHILD_OUTPUT_LIMIT"));
    }
}
