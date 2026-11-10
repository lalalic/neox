use crate::context::{unix_ms, Context};
use crate::error::{ToolError, ToolResult, UnitResult};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

static IN_FLIGHT_EXEC_GROUPS: OnceLock<Mutex<HashSet<libc::pid_t>>> = OnceLock::new();

struct InFlightExecGroup(libc::pid_t);

impl Drop for InFlightExecGroup {
    fn drop(&mut self) {
        if let Some(groups) = IN_FLIGHT_EXEC_GROUPS.get() {
            if let Ok(mut groups) = groups.lock() {
                groups.remove(&self.0);
            }
        }
    }
}

pub(crate) fn kill_in_flight_exec_groups() {
    if let Some(groups) = IN_FLIGHT_EXEC_GROUPS.get() {
        if let Ok(groups) = groups.lock() {
            for pgid in groups.iter().copied().filter(|pgid| *pgid > 1) {
                unsafe {
                    libc::killpg(pgid, libc::SIGKILL);
                }
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    #[serde(rename = "jobId")]
    pub job_id: String,
    pub command: String,
    pub label: String,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    pub pid: i32,
    #[serde(rename = "processGroupId")]
    pub process_group_id: i32,
    #[serde(rename = "startedAt")]
    pub started_at: u64,
    #[serde(rename = "finishedAt")]
    pub finished_at: Option<u64>,
    #[serde(rename = "exitCode")]
    pub exit_code: Option<i32>,
    pub signal: Option<String>,
    #[serde(rename = "stdoutPath")]
    pub stdout_path: String,
    #[serde(rename = "stderrPath")]
    pub stderr_path: String,
}

#[derive(Debug)]
pub struct JobManager {
    context: Context,
    jobs: Arc<Mutex<BTreeMap<String, Job>>>,
}

fn child_env(
    context: &Context,
    overrides: &Value,
) -> Result<Vec<(String, Option<String>)>, ToolError> {
    let mut values = Vec::new();
    if !overrides.is_null() {
        let object = overrides
            .as_object()
            .ok_or_else(|| ToolError::new("env must be an object"))?;
        for (key, value) in object {
            let mut characters = key.chars();
            let valid_key = matches!(characters.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
                && characters
                    .all(|character| character == '_' || character.is_ascii_alphanumeric());
            if !valid_key {
                return Err(ToolError::new(
                    "environment variable names must use ASCII letters, digits, and underscores and cannot start with a digit",
                ));
            }
            if value.is_null() {
                values.push((key.clone(), None));
            } else if let Some(text) = value.as_str() {
                values.push((key.clone(), Some(text.to_string())));
            } else if let Some(number) = value.as_i64() {
                values.push((key.clone(), Some(number.to_string())));
            } else if let Some(number) = value.as_u64() {
                values.push((key.clone(), Some(number.to_string())));
            } else if let Some(number) = value.as_f64() {
                values.push((key.clone(), Some(number.to_string())));
            } else if let Some(boolean) = value.as_bool() {
                values.push((key.clone(), Some(boolean.to_string())));
            } else {
                return Err(ToolError::new(
                    "environment values must be string, number, boolean, or null",
                ));
            }
        }
    }
    for secret in ["NEO_CORE_FULL_ACCESS_ACK", "CONTROL_PLANE_API_KEY"] {
        values.push((secret.to_string(), None));
    }
    let _ = context;
    Ok(values)
}

fn random_id() -> String {
    let mut bytes = [0_u8; 8];
    let mut random_source =
        std::fs::File::open("/dev/urandom").expect("macOS provides /dev/urandom");
    random_source
        .read_exact(&mut bytes)
        .expect("read random bytes");
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn tail(path: &str, max_bytes: u64) -> Value {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => return json!({ "text": "", "size": 0, "returnedBytes": 0, "truncated": false }),
    };
    let size = metadata.len();
    let returned = size.min(max_bytes);
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(_) => {
            return json!({ "text": "", "size": size, "returnedBytes": 0, "truncated": false })
        }
    };
    let _ = file.seek(SeekFrom::Start(size - returned));
    let mut bytes = Vec::with_capacity(returned as usize);
    let _ = file.take(returned).read_to_end(&mut bytes);
    json!({
        "text": String::from_utf8_lossy(&bytes),
        "size": size,
        "returnedBytes": returned,
        "truncated": size > max_bytes
    })
}

fn output_snapshot(path: &str, max_bytes: u64) -> ToolResult {
    let metadata = std::fs::metadata(path).map_err(|error| ToolError::new(error.to_string()))?;
    let size = metadata.len();
    let returned = size.min(max_bytes);
    let file = File::open(path).map_err(|error| ToolError::new(error.to_string()))?;
    let mut bytes = Vec::with_capacity(returned as usize);
    file.take(returned)
        .read_to_end(&mut bytes)
        .map_err(|error| ToolError::new(error.to_string()))?;
    Ok(json!({
        "text": String::from_utf8_lossy(&bytes),
        "file": if size > max_bytes { Value::String(path.to_string()) } else { Value::Null },
        "bytes": size
    }))
}

fn write_job_metadata(path: &std::path::Path, job: &Job) -> Result<(), ToolError> {
    let temporary = path.with_extension("json.tmp");
    let encoded =
        serde_json::to_string_pretty(job).map_err(|error| ToolError::new(error.to_string()))?;
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| ToolError::new(error.to_string()))?;
    file.write_all(encoded.as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|error| ToolError::new(error.to_string()))?;
    std::fs::rename(temporary, path).map_err(|error| ToolError::new(error.to_string()))
}

impl JobManager {
    pub fn new(context: Context) -> Self {
        Self {
            context,
            jobs: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn spawn(
        &self,
        command: String,
        cwd: Option<String>,
        env: Value,
        label: Option<String>,
    ) -> ToolResult {
        self.spawn_with_input(command, cwd, env, label, None, false)
    }

    fn spawn_with_input(
        &self,
        command: String,
        cwd: Option<String>,
        env: Value,
        label: Option<String>,
        stdin: Option<String>,
        track_as_foreground: bool,
    ) -> ToolResult {
        let job_id = random_id();
        let directory = self.context.job_dir.clone();
        let effective_cwd = self.context.resolve_path(cwd.as_deref().unwrap_or("."));
        if !effective_cwd.is_dir() {
            return Err(ToolError::new(format!(
                "Working directory '{}' is unusable",
                effective_cwd.display()
            )));
        }
        let env_values = child_env(&self.context, &env)?;
        let stdout_path = directory.join(format!("{job_id}.stdout.log"));
        let stderr_path = directory.join(format!("{job_id}.stderr.log"));
        let stdout = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&stdout_path)
            .map_err(|error| ToolError::new(error.to_string()))?;
        let stderr = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&stderr_path)
            .map_err(|error| ToolError::new(error.to_string()))?;
        let stdin = if let Some(input) = stdin {
            let path = directory.join(format!("{job_id}.stdin"));
            let mut file = OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .mode(0o600)
                .open(&path)
                .map_err(|error| ToolError::new(error.to_string()))?;
            file.write_all(input.as_bytes())
                .and_then(|_| file.seek(SeekFrom::Start(0)))
                .map_err(|error| ToolError::new(error.to_string()))?;
            std::fs::remove_file(path).map_err(|error| ToolError::new(error.to_string()))?;
            Stdio::from(file)
        } else {
            Stdio::null()
        };
        let mut child = Command::new(&self.context.shell);
        child
            .arg("-lc")
            .arg(&command)
            .current_dir(&effective_cwd)
            .stdin(stdin)
            .stdout(stdout)
            .stderr(stderr)
            .env_clear();
        unsafe {
            child.pre_exec(|| {
                if libc::setpgid(0, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        for (key, value) in std::env::vars_os() {
            if key != "NEO_CORE_FULL_ACCESS_ACK" && key != "CONTROL_PLANE_API_KEY" {
                child.env(key, value);
            }
        }
        for (key, value) in env_values {
            match value {
                Some(value) => {
                    child.env(key, value);
                }
                None => {
                    child.env_remove(key);
                }
            }
        }
        let mut exec_gate = if track_as_foreground {
            Some(
                IN_FLIGHT_EXEC_GROUPS
                    .get_or_init(|| Mutex::new(HashSet::new()))
                    .lock()
                    .map_err(|_| ToolError::new("in-flight shell job lock poisoned"))?,
            )
        } else {
            None
        };
        let mut child = child
            .spawn()
            .map_err(|error| ToolError::new(error.to_string()))?;
        let metadata = Job {
            job_id: job_id.clone(),
            command,
            label: label.unwrap_or_else(|| "background-job".to_string()),
            cwd: effective_cwd.to_string_lossy().into_owned(),
            env: BTreeMap::new(),
            pid: child.id() as i32,
            process_group_id: child.id() as i32,
            started_at: unix_ms(),
            finished_at: None,
            exit_code: None,
            signal: None,
            stdout_path: stdout_path.to_string_lossy().into_owned(),
            stderr_path: stderr_path.to_string_lossy().into_owned(),
        };
        if let Err(error) = self.write_metadata(&metadata) {
            unsafe {
                libc::killpg(metadata.process_group_id, libc::SIGKILL);
            }
            let _ = child.wait();
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            return Err(ToolError::new(format!(
                "Could not record job metadata; the child was killed: {error}"
            )));
        }
        if track_as_foreground {
            if let Some(groups) = exec_gate.as_mut() {
                groups.insert(metadata.process_group_id);
            }
        }
        drop(exec_gate);
        std::mem::forget(child);
        self.jobs
            .lock()
            .unwrap()
            .insert(job_id.clone(), metadata.clone());
        let shared_jobs = self.jobs.clone();
        let data_dir = self.context.job_dir.clone();
        let watched = metadata.clone();
        std::thread::spawn(move || {
            let mut status = std::mem::MaybeUninit::<libc::c_int>::uninit();
            let result = loop {
                let result = unsafe { libc::waitpid(watched.pid, status.as_mut_ptr(), 0) };
                if result < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
                {
                    continue;
                }
                break result;
            };
            if result != watched.pid {
                return;
            }
            let status = unsafe { status.assume_init() };
            let mut finished = watched;
            if libc::WIFEXITED(status) {
                finished.exit_code = Some(libc::WEXITSTATUS(status));
            } else if libc::WIFSIGNALED(status) {
                finished.signal = Some(libc::WTERMSIG(status).to_string());
                finished.exit_code = Some(128 + libc::WTERMSIG(status));
            }
            finished.finished_at = Some(unix_ms());
            let path = data_dir.join(format!("{}.json", finished.job_id));
            if let Err(error) = write_job_metadata(&path, &finished) {
                eprintln!("could not persist completed shell job metadata: {error}");
            }
            shared_jobs
                .lock()
                .unwrap()
                .insert(finished.job_id.clone(), finished);
        });
        Ok(serde_json::to_value(metadata).expect("metadata serializes"))
    }

    pub fn exec(
        &self,
        command: String,
        cwd: Option<String>,
        env: Value,
        stdin: Option<String>,
        timeout_ms: u64,
        max_output_bytes: u64,
    ) -> ToolResult {
        let job = self.spawn_with_input(
            command.clone(),
            cwd,
            env,
            Some("exec".to_string()),
            stdin,
            true,
        )?;
        let job_id = job["jobId"]
            .as_str()
            .ok_or_else(|| ToolError::new("spawned shell job did not return a jobId"))?;
        let pgid = job["processGroupId"].as_i64().unwrap_or_default() as libc::pid_t;
        let _registration = InFlightExecGroup(pgid);
        let stdout_path = job["stdoutPath"]
            .as_str()
            .ok_or_else(|| ToolError::new("spawned shell job did not return a stdoutPath"))?;
        let stderr_path = job["stderrPath"]
            .as_str()
            .ok_or_else(|| ToolError::new("spawned shell job did not return a stderrPath"))?;
        let started = Instant::now();
        let wait_ms = if timeout_ms == 0 {
            0
        } else {
            timeout_ms.min(300_000)
        };
        loop {
            let state = self.refresh(job_id)?;
            if state["running"] == false {
                let stdout = output_snapshot(stdout_path, max_output_bytes)?;
                let stderr = output_snapshot(stderr_path, max_output_bytes)?;
                return Ok(json!({
                    "command": command,
                    "shell": self.context.shell,
                    "cwd": job["cwd"],
                    "exitCode": state["exitCode"],
                    "signal": state["signal"],
                    "timedOut": false,
                    "durationMs": started.elapsed().as_millis(),
                    "stdout": stdout["text"],
                    "stderr": stderr["text"],
                    "stdoutFile": stdout["file"],
                    "stderrFile": stderr["file"],
                    "stdoutTruncated": false,
                    "stderrTruncated": false,
                    "capturedStdoutBytes": stdout["bytes"],
                    "capturedStderrBytes": stderr["bytes"]
                }));
            }
            if started.elapsed() >= Duration::from_millis(wait_ms) {
                return Ok(json!({
                    "status": "running",
                    "jobId": job_id,
                    "pid": job["pid"],
                    "processGroupId": job["processGroupId"],
                    "durationMs": started.elapsed().as_millis(),
                    "stdoutFile": stdout_path,
                    "stderrFile": stderr_path
                }));
            } else {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }

    fn metadata_path(&self, job_id: &str) -> std::path::PathBuf {
        self.context.job_dir.join(format!("{job_id}.json"))
    }

    fn validate_job_id(job_id: &str) -> UnitResult {
        if job_id.is_empty()
            || job_id.len() > 128
            || !job_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(ToolError::new("Invalid job_id"));
        }
        Ok(())
    }

    fn write_metadata(&self, job: &Job) -> Result<(), ToolError> {
        write_job_metadata(&self.metadata_path(&job.job_id), job)
    }

    fn read_job_metadata(&self, job_id: &str) -> Result<Job, ToolError> {
        Self::validate_job_id(job_id)?;
        let raw = std::fs::read_to_string(self.metadata_path(job_id))
            .map_err(|_| ToolError::code(format!("Unknown job ID: {job_id}"), "ENOENT"))?;
        serde_json::from_str(&raw).map_err(|error| ToolError::new(error.to_string()))
    }

    pub fn refresh(&self, job_id: &str) -> ToolResult {
        Self::validate_job_id(job_id)?;
        let in_memory = {
            let jobs = self.jobs.lock().unwrap();
            jobs.get(job_id).cloned()
        };
        if let Some(job) = in_memory {
            let mut value =
                serde_json::to_value(&job).map_err(|error| ToolError::new(error.to_string()))?;
            value["running"] = json!(job.finished_at.is_none());
            return Ok(value);
        }
        let mut job = self.read_job_metadata(job_id)?;
        if job.finished_at.is_none() {
            let mut status = std::mem::MaybeUninit::<libc::c_int>::uninit();
            let result = unsafe { libc::waitpid(job.pid, status.as_mut_ptr(), libc::WNOHANG) };
            if result == job.pid {
                let code = unsafe { status.assume_init() };
                if libc::WIFEXITED(code) {
                    job.exit_code = Some(libc::WEXITSTATUS(code));
                } else if libc::WIFSIGNALED(code) {
                    job.signal = Some(libc::WTERMSIG(code).to_string());
                    job.exit_code = Some(128 + libc::WTERMSIG(code));
                }
                job.finished_at = Some(unix_ms());
                self.write_metadata(&job)?;
                self.jobs
                    .lock()
                    .unwrap()
                    .insert(job_id.to_string(), job.clone());
            } else if result == -1
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD)
            {
                let running = unsafe { libc::kill(job.pid, 0) == 0 }
                    || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
                if !running {
                    job.finished_at = Some(unix_ms());
                    self.write_metadata(&job)?;
                }
            }
        }
        let mut value =
            serde_json::to_value(&job).map_err(|error| ToolError::new(error.to_string()))?;
        value["running"] = json!(job.finished_at.is_none());
        self.jobs.lock().unwrap().insert(job_id.to_string(), job);
        Ok(value)
    }

    pub fn status(&self, job_id: &str, max_log_bytes: u64) -> ToolResult {
        let mut value = self.refresh(job_id)?;
        value["stdout"] = tail(
            value["stdoutPath"].as_str().unwrap_or_default(),
            max_log_bytes,
        );
        value["stderr"] = tail(
            value["stderrPath"].as_str().unwrap_or_default(),
            max_log_bytes,
        );
        Ok(value)
    }

    pub fn list(&self) -> ToolResult {
        let mut jobs = Vec::new();
        let entries = std::fs::read_dir(&self.context.job_dir)
            .map_err(|error| ToolError::new(error.to_string()))?;
        let mut files: Vec<_> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
            .collect();
        files.sort();
        for path in files.into_iter().rev().take(1_000) {
            match std::fs::read_to_string(&path).ok().and_then(|raw| serde_json::from_str::<Job>(&raw).ok()) {
                Some(job) => {
                    let running = job.finished_at.is_none() && self.refresh(&job.job_id).is_ok_and(|value| value["running"].as_bool() == Some(true));
                    let mut value = serde_json::to_value(&job).map_err(|error| ToolError::new(error.to_string()))?;
                    value["running"] = json!(running);
                    jobs.push(value);
                }
                None => jobs.push(json!({ "metadataFile": path.file_name().unwrap().to_string_lossy(), "error": "invalid metadata" })),
            }
        }
        Ok(json!({ "jobs": jobs }))
    }

    pub fn kill(&self, job_id: &str, signal_name: &str) -> ToolResult {
        let job = self.refresh(job_id)?;
        let signal = match signal_name {
            "SIGTERM" => libc::SIGTERM,
            "SIGKILL" => libc::SIGKILL,
            "SIGINT" => libc::SIGINT,
            "SIGHUP" => libc::SIGHUP,
            _ => {
                return Err(ToolError::new(
                    "signal must be SIGTERM, SIGKILL, SIGINT, or SIGHUP",
                ))
            }
        };
        let pgid = job["processGroupId"].as_i64().unwrap_or_default() as libc::pid_t;
        let killed = unsafe { libc::killpg(pgid, signal) == 0 };
        let mut result = job;
        result["jobId"] = json!(job_id);
        result["signal"] = json!(signal_name);
        result["killed"] = json!(killed);
        Ok(result)
    }
}
