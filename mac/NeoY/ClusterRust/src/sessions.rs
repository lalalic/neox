use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
    sync::Notify,
    time,
};
const MAX_OUTPUT: usize = 4 * 1024 * 1024;

fn tail(dest: &mut Vec<u8>, input: &[u8]) {
    if input.len() >= MAX_OUTPUT {
        dest.clear();
        dest.extend_from_slice(&input[input.len() - MAX_OUTPUT..]);
        return;
    }
    let extra = dest.len() + input.len();
    if extra > MAX_OUTPUT {
        dest.drain(..extra - MAX_OUTPUT);
    }
    dest.extend_from_slice(input);
}

#[derive(Default)]
struct Output {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    exit_code: Option<i32>,
    signal: Option<i32>,
    done: bool,
}
struct Session {
    pid: u32,
    cwd: PathBuf,
    data: Mutex<Output>,
    notify: Notify,
}
#[derive(Clone, Default)]
pub struct Sessions {
    active: Arc<Mutex<HashMap<String, Arc<Session>>>>,
}

async fn drain<R: AsyncRead + Unpin>(mut stream: R, session: Arc<Session>, stderr: bool) {
    let mut buf = [0u8; 8192];
    while let Ok(n) = stream.read(&mut buf).await {
        if n == 0 {
            break;
        }
        let mut data = session.data.lock().unwrap();
        if stderr {
            tail(&mut data.stderr, &buf[..n])
        } else {
            tail(&mut data.stdout, &buf[..n])
        }
    }
}
fn spawn_command(cmd: &str, cwd: &PathBuf) -> Result<tokio::process::Child, String> {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let mut c = Command::new(shell);
    c.args(["-lc", cmd])
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(false);
    c.spawn().map_err(|e| format!("unable to start shell: {e}"))
}
pub fn resolve_cwd(s: &str) -> PathBuf {
    let path = crate::config::expand_path(s);
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join(path)
    }
}
fn new_session(cmd: &str, cwd: PathBuf) -> Result<(Arc<Session>, tokio::process::Child), String> {
    let child = spawn_command(cmd, &cwd)?;
    let pid = child.id().ok_or("shell process has no PID")?;
    let s = Arc::new(Session {
        pid,
        cwd,
        data: Mutex::new(Output::default()),
        notify: Notify::new(),
    });
    Ok((s, child))
}

fn signal_name(signal: i32) -> String {
    match signal {
        libc::SIGTERM => "SIGTERM".into(),
        libc::SIGKILL => "SIGKILL".into(),
        libc::SIGINT => "SIGINT".into(),
        libc::SIGPIPE => "SIGPIPE".into(),
        libc::SIGHUP => "SIGHUP".into(),
        libc::SIGABRT => "SIGABRT".into(),
        _ => format!("SIG{signal}"),
    }
}

fn send_group(pid: u32, signal: i32) {
    // Every spawned shell is its own process-group leader. Never fall back to
    // killing arbitrary matching processes from a process listing.
    unsafe {
        libc::kill(-(pid as i32), signal);
    }
}

async fn await_completion(s: Arc<Session>, mut child: tokio::process::Child) {
    let a = child
        .stdout
        .take()
        .map(|x| tokio::spawn(drain(x, s.clone(), false)));
    let b = child
        .stderr
        .take()
        .map(|x| tokio::spawn(drain(x, s.clone(), true)));
    let status = child.wait().await;
    if let Some(a) = a {
        let _ = a.await;
    }
    if let Some(b) = b {
        let _ = b.await;
    }
    let mut d = s.data.lock().unwrap();
    match status {
        Ok(st) => {
            d.exit_code = st.code();
            use std::os::unix::process::ExitStatusExt;
            d.signal = st.signal();
        }
        Err(e) => tail(&mut d.stderr, e.to_string().as_bytes()),
    }
    d.done = true;
    drop(d);
    s.notify.notify_waiters();
}

impl Sessions {
    pub async fn exec(&self, cmd: &str, cwd: &str, timeout_ms: u64) -> Result<Value, String> {
        let (s, child) = new_session(cmd, resolve_cwd(cwd))?;
        let handle = tokio::spawn(await_completion(s.clone(), child));
        let mut timed_out = false;
        if time::timeout(
            Duration::from_millis(timeout_ms.clamp(1000, 900_000)),
            handle,
        )
        .await
        .is_err()
        {
            timed_out = true;
            send_group(s.pid, libc::SIGTERM);
            time::sleep(Duration::from_millis(650)).await;
            let still_alive = {
                let d = s.data.lock().unwrap();
                !d.done
            };
            if still_alive {
                send_group(s.pid, libc::SIGKILL)
            }
            time::timeout(Duration::from_secs(3), s.notify.notified())
                .await
                .ok();
        }
        let d = s.data.lock().unwrap();
        Ok(
            json!({"exitCode":d.exit_code,"signal":d.signal.map(signal_name),"timedOut":timed_out,
            "stdout":String::from_utf8_lossy(&d.stdout),"stderr":String::from_utf8_lossy(&d.stderr)}),
        )
    }
    pub fn start(&self, cmd: &str, cwd: &str) -> Result<Value, String> {
        let mut active = self.active.lock().unwrap();
        // Bound retained completed session output and reject excess live jobs
        // *before* spawning an unmanaged process.
        if active.len() >= 512 {
            active.retain(|_, session| !session.data.lock().unwrap().done);
        }
        if active.len() >= 512 {
            return Err("too many live shell sessions".into());
        }
        let (s, child) = new_session(cmd, resolve_cwd(cwd))?;
        let id = format!(
            "{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            s.pid
        );
        active.insert(id.clone(), s.clone());
        drop(active);
        tokio::spawn(await_completion(s.clone(), child));
        Ok(json!({"session_id":id,"pid":s.pid,"command":cmd,"cwd":s.cwd.display().to_string()}))
    }
    pub async fn poll(&self, id: &str, wait_ms: u64) -> Result<Value, String> {
        let s = self
            .active
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| format!("unknown shell session: {id}"))?;
        if !s.data.lock().unwrap().done && wait_ms > 0 {
            let notified = s.notify.notified();
            if !s.data.lock().unwrap().done {
                let _ = time::timeout(Duration::from_millis(wait_ms.min(30_000)), notified).await;
            }
        }
        let d = s.data.lock().unwrap();
        if !d.done {
            return Ok(json!({"session_id":id,"running":true,"pid":s.pid,"stdout":"","stderr":""}));
        }
        let response = json!({"session_id":id,"running":false,"pid":s.pid,"exitCode":d.exit_code,
            "stdout":String::from_utf8_lossy(&d.stdout),"stderr":String::from_utf8_lossy(&d.stderr)});
        drop(d);
        self.active.lock().unwrap().remove(id);
        Ok(response)
    }
    pub fn stop_all(&self) {
        for s in self.active.lock().unwrap().values() {
            if !s.data.lock().unwrap().done {
                send_group(s.pid, libc::SIGTERM);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn posix_signal_names_match_node_convention() {
        assert_eq!(signal_name(libc::SIGTERM), "SIGTERM");
    }
    #[test]
    fn bounded_tail() {
        let mut a = vec![b'a'; MAX_OUTPUT];
        tail(&mut a, b"123");
        assert_eq!(a.len(), MAX_OUTPUT);
        assert_eq!(&a[MAX_OUTPUT - 3..], b"123");
    }
    #[actix_web::test]
    async fn exec_captures_output_and_exit() {
        let s = Sessions::default();
        let r = s
            .exec("printf example; printf warning >&2; exit 7", "~", 3000)
            .await
            .unwrap();
        assert_eq!(r["exitCode"], 7);
        assert_eq!(r["stdout"], "example");
        assert_eq!(r["stderr"], "warning");
    }
    #[actix_web::test]
    async fn async_session_poll() {
        let s = Sessions::default();
        let started = s.start("printf session-complete", "~").unwrap();
        let r = s
            .poll(started["session_id"].as_str().unwrap(), 3000)
            .await
            .unwrap();
        assert_eq!(r["running"], false);
        assert_eq!(r["stdout"], "session-complete");
    }
    #[actix_web::test]
    async fn timeout_reports_true() {
        let s = Sessions::default();
        let r = s.exec("sleep 6", "~", 1000).await.unwrap();
        assert_eq!(r["timedOut"], true);
    }
}
