use crate::error::{ToolError, ToolResult};
use serde_json::json;
use std::collections::BTreeMap;
use std::collections::HashMap;
use std::ffi::{CString, OsStr};
use std::io::Read;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::io::RawFd;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct Session {
    pub master: RawFd,
    pub pid: i32,
    pub command: String,
    pub args: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub output: Vec<u8>,
    pub output_base: u64,
    pub total_output_bytes: u64,
    pub exited: bool,
    pub exit_code: Option<i32>,
    pub signal: Option<String>,
    pub last_activity_ms: u64,
    pub created_at_ms: u64,
    pub idle_timeout_ms: u64,
    pub canonical_pending_bytes: usize,
    pub tty_path: Option<String>,
    pub tty_targets: HashMap<i32, String>,
    pub tty_last_scan_ms: u64,
}

impl Drop for Session {
    fn drop(&mut self) {
        if self.master >= 0 {
            unsafe {
                libc::close(self.master);
            }
        }
    }
}

#[derive(Debug, Clone)]
struct SessionSnapshot {
    command: String,
    cols: u16,
    rows: u16,
    output: Vec<u8>,
    output_base: u64,
    total_output_bytes: u64,
    exited: bool,
    exit_code: Option<i32>,
    signal: Option<String>,
    last_activity_ms: u64,
}

#[derive(Debug, Clone)]
pub struct PtyManager {
    sessions: Arc<Mutex<HashMap<String, Session>>>,
    max_sessions: usize,
    pub idle_timeout_ms: u64,
    max_lifetime_ms: u64,
    max_output_bytes: usize,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn canonical_runs(bytes: &[u8]) -> (usize, usize, usize, bool) {
    let mut first = 0;
    let mut current = 0;
    let mut longest = 0;
    let mut has_terminator = false;
    for byte in bytes {
        if matches!(byte, b'\r' | b'\n') {
            if !has_terminator {
                first = current;
                has_terminator = true;
            }
            longest = longest.max(current);
            current = 0;
        } else {
            current += 1;
        }
    }
    if !has_terminator {
        first = current;
    }
    longest = longest.max(current);
    (first, longest, current, has_terminator)
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

// Node Core tracks background terminal members in other process groups; a
// leader-group kill alone cannot contain e.g. "nohup sleep &". Keep a bounded
// start-time-qualified membership record before the PTY device disappears.
fn tty_path(fd: RawFd) -> Option<String> {
    let mut bytes = [0_i8; 256];
    if unsafe { libc::ttyname_r(fd, bytes.as_mut_ptr(), bytes.len()) } != 0 {
        return None;
    }
    let cstr = unsafe { std::ffi::CStr::from_ptr(bytes.as_ptr()) };
    let path = cstr.to_str().ok()?;
    let name = path.strip_prefix("/dev/tty")?;
    if (1..=12).contains(&name.len())
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    {
        Some(path.to_string())
    } else {
        None
    }
}

fn ps_rows(args: &[&str]) -> HashMap<i32, String> {
    let mut child = match Command::new("/bin/ps")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return HashMap::new(),
    };
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return HashMap::new();
            }
        }
    }
    let mut raw = Vec::new();
    if let Some(output) = child.stdout.take() {
        let _ = output.take(1_000_000).read_to_end(&mut raw);
    }
    let mut rows = HashMap::new();
    for line in String::from_utf8_lossy(&raw).lines() {
        let line = line.trim();
        if let Some(pos) = line.find(char::is_whitespace) {
            if let Ok(pid) = line[..pos].parse::<i32>() {
                if pid > 1 {
                    rows.insert(pid, line[pos..].trim().to_string());
                }
            }
        }
    }
    rows
}

fn process_present(pid: i32) -> bool {
    pid > 1
        && (unsafe { libc::kill(pid, 0) } == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
}

fn snapshot_tty_targets(session: &mut Session, force: bool) {
    if session.exited {
        return;
    }
    let Some(path) = session.tty_path.as_deref() else {
        return;
    };
    let now = now_ms();
    if !force && now.saturating_sub(session.tty_last_scan_ms) < 150 {
        return;
    }
    session.tty_last_scan_ms = now;
    session.tty_targets.retain(|pid, _| process_present(*pid));
    for (pid, lstart) in ps_rows(&["-t", path, "-o", "pid=,lstart="]) {
        if pid == session.pid
            || pid == std::process::id() as i32
            || pid == unsafe { libc::getppid() }
        {
            continue;
        }
        if session.tty_targets.len() >= 64 {
            break;
        }
        session.tty_targets.entry(pid).or_insert(lstart);
    }
}

fn kill_tty_stragglers(session: &Session) {
    let candidates: Vec<_> = session
        .tty_targets
        .iter()
        .filter(|(pid, _)| process_present(**pid))
        .map(|(pid, _)| *pid)
        .collect();
    if candidates.is_empty() {
        return;
    }
    let pids = candidates
        .iter()
        .map(i32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let current = ps_rows(&["-o", "pid=,lstart=", "-p", &pids]);
    for pid in candidates {
        if current.get(&pid) == session.tty_targets.get(&pid) && process_present(pid) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

impl PtyManager {
    pub fn available(&self) -> bool {
        static AVAILABLE: OnceLock<bool> = OnceLock::new();
        *AVAILABLE.get_or_init(|| {
            let mut master: libc::c_int = -1;
            let mut slave: libc::c_int = -1;
            let ok = unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            } == 0;
            if master >= 0 {
                unsafe {
                    libc::close(master);
                }
            }
            if slave >= 0 {
                unsafe {
                    libc::close(slave);
                }
            }
            ok
        })
    }

    pub fn status(&self) -> (serde_json::Value, serde_json::Value) {
        let limits = json!({
            "maxSessions":self.max_sessions,
            "ringBytesPerSession":self.max_output_bytes,
            "ringBytesGlobal":self.max_output_bytes * self.max_sessions,
            "idleTimeoutMs":self.idle_timeout_ms,
            "maxLifetimeMs":self.max_lifetime_ms,
            "writeMaxBytes":65536
        });
        let now = now_ms();
        let sessions: Vec<_> = self.sessions.lock().unwrap().iter().map(|(id, session)| json!({
            "id":id,"command":session.command,"args":session.args,"leaderPid":session.pid,
            "pts":session.tty_path,"cols":session.cols,"rows":session.rows,
            "totalBytes":session.total_output_bytes,"idleTimeoutMs":session.idle_timeout_ms,
            "idleMs":now.saturating_sub(session.last_activity_ms),
            "exited":session.exited,"exitCode":session.exit_code,"exitSignal":session.signal,
            "closeReason":null
        })).collect();
        (limits, json!(sessions))
    }

    pub fn new() -> Self {
        let max_sessions = std::env::var("NEO_CORE_PTY_MAX_SESSIONS")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(8)
            .clamp(1, 64);
        let idle_timeout_ms = std::env::var("NEO_CORE_PTY_IDLE_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(900_000)
            .clamp(1_000, 3_600_000);
        let max_lifetime_ms = std::env::var("NEO_CORE_PTY_MAX_LIFETIME_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(28_800_000)
            .clamp(5_000, 86_400_000);
        let max_output_bytes = std::env::var("NEO_CORE_PTY_RING_BYTES")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(262_144)
            .clamp(4_096, 4_000_000);
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            max_sessions,
            idle_timeout_ms,
            max_lifetime_ms,
            max_output_bytes,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn start(
        &self,
        executable: String,
        arguments: Vec<String>,
        cwd: PathBuf,
        env: std::collections::BTreeMap<String, Option<String>>,
        cols: u16,
        rows: u16,
        term: String,
        idle_timeout_ms: u64,
    ) -> ToolResult {
        // Serialize starts while checking the cap so concurrent RPCs cannot
        // oversubscribe the process and PTY resource limit.
        let mut sessions = self.sessions.lock().unwrap();
        if sessions.len() >= self.max_sessions {
            return Err(ToolError::code(
                format!("PTY session limit reached ({})", self.max_sessions),
                "PTY_SESSION_LIMIT",
            ));
        }
        let program_path = if executable.contains('/') {
            PathBuf::from(&executable)
        } else {
            PathBuf::from(
                find_in_path(&executable)
                    .ok_or_else(|| ToolError::new(format!("Executable not found: {executable}")))?,
            )
        };
        let program = CString::new(program_path.to_string_lossy().as_bytes())
            .map_err(|_| ToolError::new("executable contains NUL"))?;
        let cwd = CString::new(cwd.to_string_lossy().as_bytes())
            .map_err(|_| ToolError::new("working directory contains NUL"))?;
        let env_for_child: Vec<(CString, Option<CString>)> = env
            .into_iter()
            .map(|(key, value)| {
                let key = CString::new(key).map_err(|_| ToolError::new("env key contains NUL"))?;
                let value = value
                    .map(CString::new)
                    .transpose()
                    .map_err(|_| ToolError::new("env value contains NUL"))?;
                Ok((key, value))
            })
            .collect::<Result<_, ToolError>>()?;
        let original_arguments = arguments.clone();
        let mut c_arguments = vec![program.clone()];
        for argument in arguments {
            c_arguments
                .push(CString::new(argument).map_err(|_| ToolError::new("argument contains NUL"))?);
        }
        c_arguments.push(CString::new("").map_err(|_| ToolError::new("argument contains NUL"))?);
        let mut argv: Vec<*const libc::c_char> = c_arguments[..c_arguments.len() - 1]
            .iter()
            .map(|value| value.as_ptr())
            .collect();
        argv.push(std::ptr::null());

        // A multithreaded MCP server forks while other threads may hold
        // allocator or process-environment locks. Mutating environ in a
        // forked child is therefore unsafe. Build and own the complete
        // envp before fork; fork/exec performs only async-signal-safe calls.
        let mut child_environment: BTreeMap<CString, CString> = std::env::vars_os()
            .filter(|(key, _)| {
                key.as_os_str() != OsStr::new("NEO_CORE_FULL_ACCESS_ACK")
                    && key.as_os_str() != OsStr::new("CONTROL_PLANE_API_KEY")
            })
            .map(|(key, value)| {
                let key = key.into_vec();
                let value = value.into_vec();
                let key = CString::new(key).map_err(|_| ToolError::new("env key contains NUL"))?;
                let value =
                    CString::new(value).map_err(|_| ToolError::new("env value contains NUL"))?;
                Ok((key, value))
            })
            .collect::<Result<_, ToolError>>()?;
        child_environment.insert(
            CString::new("TERM").expect("TERM has no NUL"),
            CString::new(term.clone()).map_err(|_| ToolError::new("TERM contains NUL"))?,
        );
        for (key, value) in &env_for_child {
            if key.as_bytes() == b"NEO_CORE_FULL_ACCESS_ACK"
                || key.as_bytes() == b"CONTROL_PLANE_API_KEY"
            {
                continue;
            }
            match value {
                Some(value) => {
                    child_environment.insert(key.clone(), value.clone());
                }
                None => {
                    child_environment.remove(key);
                }
            }
        }
        let owned_environment: Vec<CString> = child_environment
            .into_iter()
            .map(|(key, value)| {
                let mut entry = key.into_bytes();
                entry.push(b'=');
                entry.extend_from_slice(value.as_bytes());
                CString::new(entry).map_err(|_| ToolError::new("environment entry contains NUL"))
            })
            .collect::<Result<_, ToolError>>()?;
        let mut environment_pointers: Vec<*const libc::c_char> = owned_environment
            .iter()
            .map(|entry| entry.as_ptr())
            .collect();
        environment_pointers.push(std::ptr::null());

        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        let mut winsize = libc::winsize {
            ws_col: cols,
            ws_row: rows,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let result = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut winsize,
            )
        };
        if result != 0 {
            return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
        }
        let tty_path = tty_path(slave);
        let cwd_for_child = cwd;
        let pid = unsafe { libc::fork() };
        if pid < 0 {
            unsafe {
                libc::close(master);
                libc::close(slave);
            }
            return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
        }
        if pid == 0 {
            unsafe {
                libc::close(master);
                libc::dup2(slave, libc::STDIN_FILENO);
                libc::dup2(slave, libc::STDOUT_FILENO);
                libc::dup2(slave, libc::STDERR_FILENO);
                if slave > libc::STDERR_FILENO {
                    libc::close(slave);
                }
                if libc::setsid() < 0 {
                    libc::_exit(126);
                }
                if libc::ioctl(libc::STDIN_FILENO, libc::TIOCSCTTY.into(), 0) < 0 {
                    libc::_exit(126);
                }
                // setsid() already makes this process the session and process-group
                // leader. Calling setpgid() again fails with EPERM on Darwin.
                if libc::chdir(cwd_for_child.as_ptr()) != 0 {
                    libc::_exit(126);
                }
                libc::execve(
                    program.as_ptr(),
                    argv.as_ptr(),
                    environment_pointers.as_ptr(),
                );
                libc::_exit(127);
            }
        }
        unsafe {
            libc::close(slave);
        }
        make_nonblocking(master)?;
        let session_id = random_id();
        let now = now_ms();
        let session = Session {
            master,
            pid,
            command: executable.clone(),
            args: original_arguments,
            cols,
            rows,
            output: Vec::new(),
            output_base: 0,
            total_output_bytes: 0,
            exited: false,
            exit_code: None,
            signal: None,
            last_activity_ms: now,
            created_at_ms: now,
            idle_timeout_ms: idle_timeout_ms.min(self.idle_timeout_ms),
            canonical_pending_bytes: 0,
            tty_path,
            tty_targets: HashMap::new(),
            tty_last_scan_ms: 0,
        };
        sessions.insert(session_id.clone(), session);
        Ok(json!({
            "sessionId": session_id,
            "pid": pid,
            "command": executable,
            "cols": cols,
            "rows": rows,
            "cursor": 0,
            "output": "",
            "running": true
        }))
    }

    fn refresh(&self, session_id: &str) -> Result<SessionSnapshot, ToolError> {
        let mut sessions = self.sessions.lock().unwrap();
        let session = sessions.get_mut(session_id).ok_or_else(|| {
            ToolError::code(format!("Unknown PTY session: {session_id}"), "ENOENT")
        })?;
        snapshot_tty_targets(session, false);
        let was_exited = session.exited;
        let mut buffer = [0_u8; 65_536];
        loop {
            let count =
                unsafe { libc::read(session.master, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count > 0 {
                session.output.extend_from_slice(&buffer[..count as usize]);
                session.total_output_bytes =
                    session.total_output_bytes.saturating_add(count as u64);
                if session.output.len() > self.max_output_bytes {
                    let excess = session.output.len() - self.max_output_bytes;
                    session.output.drain(..excess);
                    session.output_base = session.output_base.saturating_add(excess as u64);
                }
            } else if count == 0 {
                session.exited = true;
                break;
            } else {
                let errno = unsafe { *libc::__error() };
                if errno == libc::EAGAIN || errno == libc::EWOULDBLOCK {
                    break;
                }
                // Darwin reports EIO on a PTY master after the last slave closes.
                // Treat it as EOF so bytes already read remain available to callers.
                if errno == libc::EIO {
                    session.exited = true;
                    break;
                }
                return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
            }
            if count < buffer.len() as isize {
                break;
            }
        }
        // Darwin's PTY master may return EIO/EOF *before* waitpid has been
        // called. Reap even after terminal closure or the leader's exit code is
        // permanently lost (and the process becomes a zombie).
        if session.exit_code.is_none() && session.signal.is_none() {
            let mut status = std::mem::MaybeUninit::<libc::c_int>::uninit();
            let result = unsafe { libc::waitpid(session.pid, status.as_mut_ptr(), libc::WNOHANG) };
            if result == session.pid {
                let code = unsafe { status.assume_init() };
                if libc::WIFEXITED(code) {
                    session.exit_code = Some(libc::WEXITSTATUS(code));
                }
                if libc::WIFSIGNALED(code) {
                    session.signal = Some(signal_name(libc::WTERMSIG(code)));
                    session.exit_code = Some(128 + libc::WTERMSIG(code));
                }
                session.exited = true;
            }
        }
        if session.exited && !was_exited {
            kill_tty_stragglers(session);
        }
        Ok(SessionSnapshot {
            command: session.command.clone(),
            cols: session.cols,
            rows: session.rows,
            output: session.output.clone(),
            output_base: session.output_base,
            total_output_bytes: session.total_output_bytes,
            exited: session.exited,
            exit_code: session.exit_code,
            signal: session.signal.clone(),
            last_activity_ms: session.last_activity_ms,
        })
    }

    pub fn read(
        &self,
        session_id: &str,
        cursor: u64,
        max_bytes: usize,
        strip_ansi: bool,
        collapse_carriage_returns: bool,
        wait_ms: u64,
    ) -> ToolResult {
        let started = Instant::now();
        let mut state = self.refresh(session_id)?;
        while state.total_output_bytes <= cursor
            && !state.exited
            && started.elapsed() < Duration::from_millis(wait_ms.min(30_000))
        {
            std::thread::sleep(Duration::from_millis(10));
            state = self.refresh(session_id)?;
        }
        let session = state;
        let start_absolute = cursor
            .max(session.output_base)
            .min(session.total_output_bytes);
        let lost_bytes = session.output_base.saturating_sub(cursor);
        let offset = start_absolute.saturating_sub(session.output_base) as usize;
        let end = offset
            .saturating_add(max_bytes.min(1_000_000))
            .min(session.output.len());
        let raw = &session.output[offset..end];
        let trim_start = if lost_bytes > 0 {
            align_utf8_start(raw, 0)
        } else {
            0
        };
        let mut trim_end = raw.len();
        if start_absolute + (raw.len() as u64) < session.total_output_bytes || !session.exited {
            trim_end = align_utf8_end(raw, trim_end);
            if strip_ansi {
                trim_end = trim_partial_ansi(raw, trim_start, trim_end);
            }
            if trim_end > trim_start && raw[trim_end - 1] == b'\r' {
                trim_end -= 1;
            }
        }
        if trim_end <= trim_start
            && !raw.is_empty()
            && start_absolute + (raw.len() as u64) < session.total_output_bytes
        {
            trim_end = raw.len();
        }
        let next_cursor = start_absolute + trim_end as u64;
        let mut text = String::from_utf8_lossy(&raw[trim_start..trim_end]).into_owned();
        if strip_ansi {
            text = strip_ansi_sequences(&text);
        }
        if collapse_carriage_returns {
            text = collapse_terminal_carriage_returns(&text);
        }
        let idle_ms = now_ms().saturating_sub(session.last_activity_ms);
        if let Ok(mut sessions) = self.sessions.lock() {
            if let Some(current) = sessions.get_mut(session_id) {
                current.last_activity_ms = now_ms();
            }
        }
        Ok(json!({
            "sessionId": session_id,
            "cursor": cursor,
            "nextCursor": next_cursor,
            "output": text,
            "command": session.command,
            "bytesAvailable": session.total_output_bytes.saturating_sub(start_absolute),
            "lostBytes": lost_bytes,
            "truncated": next_cursor < session.total_output_bytes,
            "totalBytes": session.total_output_bytes,
            "retainedBytes": session.output.len(),
            "running": !session.exited,
            "exitCode": session.exit_code,
            "signal": session.signal,
            "cols": session.cols,
            "rows": session.rows,
            "idleMs": idle_ms
        }))
    }

    pub fn write(&self, session_id: &str, data: String) -> ToolResult {
        let bytes = data.into_bytes();
        if bytes.len() > 65_536 {
            return Err(ToolError::code(
                format!("data is {} bytes; the limit is 65536", bytes.len()),
                "PTY_WRITE_TOO_LARGE",
            ));
        }
        let sessions = self.sessions.lock().unwrap();
        let mut sessions = sessions;
        let session = sessions.get_mut(session_id).ok_or_else(|| {
            ToolError::code(format!("Unknown PTY session: {session_id}"), "ENOENT")
        })?;
        if session.exited {
            return Err(ToolError::code(
                format!("PTY session '{session_id}' has finished"),
                "PTY_EXITED",
            ));
        }
        let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
        let canonical_mode = if !bytes.is_empty() {
            if unsafe { libc::tcgetattr(session.master, termios.as_mut_ptr()) } == 0 {
                Some(unsafe { termios.assume_init().c_lflag & libc::ICANON != 0 })
            } else if session.canonical_pending_bytes.saturating_add(bytes.len()) >= 1_024 {
                return Err(ToolError::code(
                    "could not read terminal line discipline state",
                    "PTY_WRITE_MODE_UNKNOWN",
                ));
            } else {
                None
            }
        } else {
            None
        };
        let (first_run, longest_run, trailing_run, has_terminator) = canonical_runs(&bytes);
        let longest_line = session
            .canonical_pending_bytes
            .saturating_add(first_run)
            .max(longest_run);
        if longest_line >= 1_024 && canonical_mode == Some(true) {
            return Err(ToolError::code(
                format!("canonical terminal input lines must be shorter than 1024 bytes (got {longest_line})"),
                "PTY_WRITE_CANON_LIMIT",
            ));
        }
        let mut offset = 0;
        while offset < bytes.len() {
            let count = unsafe {
                libc::write(
                    session.master,
                    bytes.as_ptr().add(offset).cast(),
                    bytes.len() - offset,
                )
            };
            if count <= 0 {
                return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
            }
            offset += count as usize;
        }
        if bytes.contains(&b'\r') || bytes.contains(&b'\n') {
            std::thread::sleep(Duration::from_millis(15));
            snapshot_tty_targets(session, true);
        }
        session.canonical_pending_bytes = if canonical_mode == Some(false) {
            0
        } else if has_terminator {
            trailing_run
        } else {
            session.canonical_pending_bytes.saturating_add(bytes.len())
        };
        session.last_activity_ms = now_ms();
        Ok(
            json!({"sessionId":session_id,"bytesWritten":bytes.len(),"canonicalMode":canonical_mode,"pendingLineBytes":longest_line}),
        )
    }

    pub fn resize(&self, session_id: &str, cols: u16, rows: u16) -> ToolResult {
        let sessions = self.sessions.lock().unwrap();
        let mut sessions = sessions;
        let session = sessions.get_mut(session_id).ok_or_else(|| {
            ToolError::code(format!("Unknown PTY session: {session_id}"), "ENOENT")
        })?;
        let winsize = libc::winsize {
            ws_col: cols,
            ws_row: rows,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if unsafe { libc::ioctl(session.master, libc::TIOCSWINSZ, &winsize) } != 0 {
            return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
        }
        let mut confirmed = std::mem::MaybeUninit::<libc::winsize>::uninit();
        if unsafe { libc::ioctl(session.master, libc::TIOCGWINSZ, confirmed.as_mut_ptr()) } != 0 {
            return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
        }
        let confirmed = unsafe { confirmed.assume_init() };
        if confirmed.ws_col != cols || confirmed.ws_row != rows {
            return Err(ToolError::code(
                format!(
                    "resize to {cols}x{rows} was not confirmed; terminal reports {}x{}",
                    confirmed.ws_col, confirmed.ws_row
                ),
                "PTY_RESIZE_UNCONFIRMED",
            ));
        }
        session.cols = confirmed.ws_col;
        session.rows = confirmed.ws_row;
        session.last_activity_ms = now_ms();
        Ok(json!({"sessionId":session_id,"cols":session.cols,"rows":session.rows}))
    }

    pub fn signal(&self, session_id: &str, signal_name: &str) -> ToolResult {
        let signal = signal_number(signal_name)?;
        let mut sessions = self.sessions.lock().unwrap();
        let session = sessions.get_mut(session_id).ok_or_else(|| {
            ToolError::code(format!("Unknown PTY session: {session_id}"), "ENOENT")
        })?;
        let delivered = unsafe { libc::killpg(session.pid, signal) == 0 };
        if !delivered {
            return Err(ToolError::code(
                format!(
                    "could not confirm delivery of {signal_name} to process group {}",
                    session.pid
                ),
                "PTY_SIGNAL_UNCONFIRMED",
            ));
        }
        session.last_activity_ms = now_ms();
        Ok(json!({"sessionId":session_id,"signal":signal_name,"delivered":true}))
    }

    pub fn close(&self, session_id: &str) -> ToolResult {
        let mut session = {
            let mut sessions = self.sessions.lock().unwrap();
            sessions.remove(session_id).ok_or_else(|| {
                ToolError::code(format!("Unknown PTY session: {session_id}"), "ENOENT")
            })?
        };
        snapshot_tty_targets(&mut session, true);
        unsafe {
            libc::killpg(session.pid, libc::SIGHUP);
            libc::killpg(session.pid, libc::SIGTERM);
        }
        kill_tty_stragglers(&session);
        unsafe {
            libc::close(session.master);
            session.master = -1;
            let mut status = std::mem::MaybeUninit::<libc::c_int>::uninit();
            let deadline = Instant::now() + Duration::from_secs(2);
            let mut leader_done = false;
            loop {
                if !leader_done {
                    let result = libc::waitpid(session.pid, status.as_mut_ptr(), libc::WNOHANG);
                    leader_done = result == session.pid
                        || (result < 0
                            && std::io::Error::last_os_error().raw_os_error()
                                == Some(libc::ECHILD));
                    if result < 0
                        && !leader_done
                        && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR)
                    {
                        libc::killpg(session.pid, libc::SIGKILL);
                        break;
                    }
                }
                let group_alive = libc::killpg(session.pid, 0) == 0
                    || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
                if leader_done && !group_alive {
                    break;
                }
                if Instant::now() >= deadline {
                    libc::killpg(session.pid, libc::SIGKILL);
                    if !leader_done {
                        while libc::waitpid(session.pid, status.as_mut_ptr(), 0) < 0
                            && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
                        {
                        }
                    }
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        Ok(json!({"sessionId":session_id,"closed":true}))
    }

    pub fn teardown_all(&self) {
        let ids: Vec<String> = self.sessions.lock().unwrap().keys().cloned().collect();
        for id in ids {
            let _ = self.close(&id);
        }
    }

    pub fn expire_sessions(&self) {
        // A natural shell exit also revokes its controlling terminal. Refresh
        // without a client read so detached terminal members are reclaimed.
        let ids: Vec<_> = self.sessions.lock().unwrap().keys().cloned().collect();
        for id in ids {
            let _ = self.refresh(&id);
        }
        let now = now_ms();
        let expired: Vec<String> = self
            .sessions
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, session)| {
                now.saturating_sub(session.last_activity_ms) > session.idle_timeout_ms
                    || now.saturating_sub(session.created_at_ms) > self.max_lifetime_ms
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            let _ = self.close(&id);
        }
    }
}

fn signal_name(number: libc::c_int) -> String {
    match number {
        libc::SIGTERM => "SIGTERM",
        libc::SIGKILL => "SIGKILL",
        libc::SIGINT => "SIGINT",
        libc::SIGHUP => "SIGHUP",
        libc::SIGQUIT => "SIGQUIT",
        _ => return number.to_string(),
    }
    .to_string()
}

fn signal_number(name: &str) -> Result<libc::c_int, ToolError> {
    match name {
        "TERM" | "SIGTERM" => Ok(libc::SIGTERM),
        "KILL" | "SIGKILL" => Ok(libc::SIGKILL),
        "INT" | "SIGINT" => Ok(libc::SIGINT),
        "HUP" | "SIGHUP" => Ok(libc::SIGHUP),
        "QUIT" | "SIGQUIT" => Ok(libc::SIGQUIT),
        "USR1" | "SIGUSR1" => Ok(libc::SIGUSR1),
        "USR2" | "SIGUSR2" => Ok(libc::SIGUSR2),
        "WINCH" | "SIGWINCH" => Ok(libc::SIGWINCH),
        "TSTP" | "SIGTSTP" => Ok(libc::SIGTSTP),
        "CONT" | "SIGCONT" => Ok(libc::SIGCONT),
        _ => Err(ToolError::new("unsupported signal")),
    }
}

fn align_utf8_start(bytes: &[u8], mut start: usize) -> usize {
    while start < bytes.len() && bytes[start] & 0xc0 == 0x80 {
        start += 1;
    }
    start
}

fn align_utf8_end(bytes: &[u8], end: usize) -> usize {
    if end == 0 {
        return 0;
    }
    let mut start = end - 1;
    while start > 0 && bytes[start] & 0xc0 == 0x80 {
        start -= 1;
    }
    let lead = bytes[start];
    let need = if lead >= 0xf0 {
        4
    } else if lead >= 0xe0 {
        3
    } else if lead >= 0xc0 {
        2
    } else {
        1
    };
    if need > end - start {
        start
    } else {
        end
    }
}

fn trim_partial_ansi(bytes: &[u8], start: usize, end: usize) -> usize {
    let Some(index) = bytes[start..end].iter().rposition(|byte| *byte == 0x1b) else {
        return end;
    };
    let index = start + index;
    if index + 1 >= end {
        return index;
    }
    match bytes[index + 1] {
        b'[' => {
            if bytes[index + 2..end]
                .iter()
                .any(|byte| (0x40..=0x7e).contains(byte))
            {
                end
            } else {
                index
            }
        }
        b']' => {
            if bytes[index + 2..end].contains(&0x07)
                || bytes[index + 2..end]
                    .windows(2)
                    .any(|pair| pair == b"\x1b\\")
            {
                end
            } else {
                index
            }
        }
        _ => end,
    }
}

fn strip_ansi_sequences(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != 0x1b {
            output.push(bytes[i]);
            i += 1;
            continue;
        }
        if i + 1 >= bytes.len() {
            break;
        }
        match bytes[i + 1] {
            b'[' => {
                i += 2;
                while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                    i += 1;
                }
                if i < bytes.len() {
                    i += 1;
                }
            }
            b']' => {
                i += 2;
                while i < bytes.len() {
                    if bytes[i] == 0x07 {
                        i += 1;
                        break;
                    }
                    if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            }
            _ => i += 2,
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn collapse_terminal_carriage_returns(text: &str) -> String {
    text.replace("\r\n", "\n")
        .split('\n')
        .map(|line| line.rsplit('\r').next().unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

fn make_nonblocking(fd: RawFd) -> Result<(), ToolError> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(ToolError::new(std::io::Error::last_os_error().to_string()));
    }
    Ok(())
}

pub(crate) fn find_in_path(executable: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(executable))
        .find(|candidate| candidate.is_file())
        .map(|candidate| candidate.to_string_lossy().into_owned())
}
