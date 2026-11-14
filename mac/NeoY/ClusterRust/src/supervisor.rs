use crate::{
    config::{ensure_file_mode, Config},
    server::{self, State},
    sessions::Sessions,
};
use std::{
    env, fs,
    os::unix::{fs::symlink, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    time::Duration,
};
use tokio::{process::Command as TokioCommand, sync::watch, time};

fn quoted(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
fn pid_file(cfg: &Config, role: &str) -> PathBuf {
    cfg.run_dir().join(format!("{role}.pid"))
}
fn pid_read(path: &Path) -> Option<i32> {
    fs::read_to_string(path)
        .ok()?
        .trim()
        .parse::<i32>()
        .ok()
        .filter(|p| *p > 1)
}
fn pid_write(path: &Path, pid: i32) -> Result<(), String> {
    fs::write(path, pid.to_string()).map_err(|e| e.to_string())?;
    ensure_file_mode(path).map_err(|e| e.to_string())
}
fn pid_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}
fn is_our_server(pid: i32, cfg: &Config) -> bool {
    if !pid_alive(pid) {
        return false;
    }
    let out = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output();
    match out {
        Ok(out) => {
            let cmd = String::from_utf8_lossy(&out.stdout);
            cmd.contains("neo-cluster-rust")
                && cmd.contains(" run")
                && cmd.contains(&cfg.node_root.display().to_string())
        }
        Err(_) => false,
    }
}
fn is_our_tunnel(pid: i32, cfg: &Config) -> bool {
    if !pid_alive(pid) {
        return false;
    }
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output();
    let Ok(output) = output else { return false };
    let command = String::from_utf8_lossy(&output.stdout);
    // Never signal a PID based on a stale file alone. Require the complete
    // expected reverse-forward endpoint, SSH executable, and hub target.
    command.contains(&cfg.ssh_bin.to_string_lossy().to_string())
        && command.contains(&format!(
            "127.0.0.1:{}:127.0.0.1:{}",
            cfg.hub_mcp_port, cfg.local_mcp_port
        ))
        && command.contains(&cfg.hub_target)
}

fn tunnel_ready(cfg: &Config) -> bool {
    if cfg.hub_target.is_empty() {
        return true;
    }
    let pid = pid_read(&pid_file(cfg, "tunnel"));
    pid.is_some()
        && pid == pid_read(&cfg.run_dir().join("tunnel.ready"))
        && pid.is_some_and(|p| is_our_tunnel(p, cfg))
}

async fn clean_orphan_tunnel(cfg: &Config) {
    let file = pid_file(cfg, "tunnel");
    if let Some(pid) = pid_read(&file) {
        if is_our_tunnel(pid, cfg) {
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
            for _ in 0..15 {
                if !is_our_tunnel(pid, cfg) {
                    break;
                }
                time::sleep(Duration::from_millis(100)).await;
            }
            if is_our_tunnel(pid, cfg) {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
    }
    let _ = fs::remove_file(file);
    let _ = fs::remove_file(cfg.run_dir().join("tunnel.ready"));
}

fn is_alive_run(cfg: &Config) -> bool {
    pid_read(&cfg.pid_file()).is_some_and(|p| is_our_server(p, cfg))
}
fn binary() -> Result<PathBuf, String> {
    env::current_exe().map_err(|e| e.to_string())
}

fn install(cfg: &Config) -> Result<(), String> {
    cfg.ensure_dirs().map_err(|e| e.to_string())?;
    let src = binary()?;
    let dest = cfg.binary_dest();
    if src != dest {
        // Never overwrite the Mach-O backing a still-running process.
        // Complete and verify the staged executable before atomic replacement.
        let staged = dest.with_extension(format!("install-{}.tmp", std::process::id()));
        let staged_result = (|| -> std::io::Result<()> {
            fs::copy(&src, &staged)?;
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&staged, fs::Permissions::from_mode(0o755))?;
            fs::rename(&staged, &dest)
        })();
        if staged_result.is_err() {
            let _ = fs::remove_file(&staged);
        }
        staged_result.map_err(|e| e.to_string())?;
    }
    if let Some(parent) = cfg.cli().parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let _ = fs::remove_file(cfg.cli());
    symlink(&dest, cfg.cli()).map_err(|e| e.to_string())?;
    if cfg.mode != "persistent" {
        return Ok(());
    }
    let plist = cfg.plist();
    if let Some(parent) = plist.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let label = format!("com.neo.node.{}", cfg.node_name);
    let xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{}</string>
<key>ProgramArguments</key><array><string>{}</string><string>run</string></array>
<key>EnvironmentVariables</key><dict><key>NEO_NODE_CONFIG</key><string>{}</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>{}</string>
<key>StandardErrorPath</key><string>{}</string>
</dict></plist>"#,
        quoted(&label),
        quoted(&dest.display().to_string()),
        quoted(&cfg.config_file.display().to_string()),
        quoted(&cfg.log_dir().join("launchd.out.log").display().to_string()),
        quoted(&cfg.log_dir().join("launchd.err.log").display().to_string())
    );
    fs::write(&plist, xml).map_err(|e| e.to_string())?;
    let owner = format!("gui/{}", unsafe { libc::getuid() });
    // launchd owns persistent node supervision. start() can also activate it.
    let _ = Command::new("/bin/launchctl")
        .args(["bootout", &format!("{owner}/{label}")])
        .status();
    let output = Command::new("/bin/launchctl")
        .args(["bootstrap", &owner, &plist.display().to_string()])
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "launchd bootstrap: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}
fn uninstall(cfg: &Config) -> Result<(), String> {
    let label = format!("com.neo.node.{}", cfg.node_name);
    let _ = Command::new("/bin/launchctl")
        .args([
            "bootout",
            &format!("gui/{}/{label}", unsafe { libc::getuid() }),
        ])
        .status();
    let _ = fs::remove_file(cfg.plist());
    Ok(())
}
fn signal_our_run(cfg: &Config) -> bool {
    if let Some(pid) = pid_read(&cfg.pid_file()) {
        if is_our_server(pid, cfg) {
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
            return true;
        }
    }
    false
}
async fn stop(cfg: &Config) {
    // launchd KeepAlive would otherwise immediately restart the process.
    if cfg.mode == "persistent" && cfg.plist().exists() {
        let label = format!(
            "gui/{}/com.neo.node.{}",
            unsafe { libc::getuid() },
            cfg.node_name
        );
        let _ = Command::new("/bin/launchctl")
            .args(["bootout", &label])
            .status();
    }
    signal_our_run(cfg);
    for _ in 0..40 {
        if !is_alive_run(cfg) {
            return;
        }
        time::sleep(Duration::from_millis(100)).await;
    }
}

async fn start(cfg: &Config) -> Result<(), String> {
    if is_alive_run(cfg) {
        for _ in 0..40 {
            if server::is_healthy(cfg.local_mcp_port).await && tunnel_ready(cfg) {
                return Ok(());
            }
            time::sleep(Duration::from_millis(250)).await;
        }
        return Err("MCP running but reverse SSH tunnel is not ready".into());
    }
    for _ in 0..20 {
        if !is_alive_run(cfg) {
            break;
        }
        time::sleep(Duration::from_millis(100)).await;
    }
    if is_alive_run(cfg) {
        return Err("previous neo-node process has not exited".into());
    }
    if cfg.mode == "persistent" && cfg.plist().exists() {
        let owner = format!("gui/{}", unsafe { libc::getuid() });
        let label = format!("com.neo.node.{}", cfg.node_name);
        let _ = Command::new("/bin/launchctl")
            .args(["bootstrap", &owner, &cfg.plist().display().to_string()])
            .output();
        let _ = Command::new("/bin/launchctl")
            .args(["kickstart", &format!("{owner}/{label}")])
            .output();
    } else {
        let stdout = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(cfg.log_dir().join("supervisor.log"))
            .map_err(|e| e.to_string())?;
        let stderr = stdout.try_clone().map_err(|e| e.to_string())?;
        let mut child = Command::new(cfg.binary_dest());
        child
            .arg("run")
            .env("NEO_NODE_CONFIG", &cfg.config_file)
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .process_group(0);
        child.spawn().map_err(|e| e.to_string())?;
    }
    for _ in 0..40 {
        if is_alive_run(cfg) && server::is_healthy(cfg.local_mcp_port).await && tunnel_ready(cfg) {
            return Ok(());
        }
        time::sleep(Duration::from_millis(250)).await;
    }
    Err("cluster node MCP/SSH tunnel did not become healthy".into())
}
fn status(cfg: &Config) -> Result<(), String> {
    println!("node: {}", cfg.node_name);
    println!("mode: {}", cfg.mode);
    println!("root: {}", cfg.node_root.display());
    for role in ["supervisor", "server", "tunnel"] {
        let pid = if role == "server" {
            pid_read(&cfg.pid_file())
        } else {
            pid_read(&pid_file(cfg, role))
        };
        let alive = pid.is_some_and(|p| {
            if role == "tunnel" {
                tunnel_ready(cfg)
            } else {
                is_our_server(p, cfg)
            }
        });
        println!(
            "{role} pid: {} ({})",
            pid.map(|n| n.to_string())
                .unwrap_or_else(|| "missing".into()),
            if alive { "alive" } else { "missing/stale" }
        );
    }
    println!(
        "launchd plist: {}",
        if cfg.plist().exists() {
            "present"
        } else {
            "absent"
        }
    );
    Ok(())
}
async fn monitor_tunnel(cfg: Config, mut stop: watch::Receiver<bool>) {
    if cfg.hub_target.is_empty() {
        return;
    }
    let mut backoff = Duration::from_secs(1);
    loop {
        if *stop.borrow() {
            break;
        }
        let ready_marker = cfg.run_dir().join("tunnel.ready");
        let _ = fs::remove_file(&ready_marker);
        let stdout = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(cfg.log_dir().join("tunnel.log"));
        let child = stdout.and_then(|file| {
            let err = file.try_clone()?;
            TokioCommand::new(&cfg.ssh_bin)
                .args(cfg.ssh_args())
                .stdin(Stdio::null())
                .stdout(Stdio::from(file))
                .stderr(Stdio::from(err))
                .kill_on_drop(true)
                .spawn()
        });
        match child {
            Ok(mut child) => {
                let pid = child.id().unwrap_or_default();
                let _ = pid_write(&pid_file(&cfg, "tunnel"), pid as i32);
                let settling = time::sleep(Duration::from_millis(1_000));
                tokio::pin!(settling);
                tokio::select! {
                    _=child.wait()=>{},
                    _=stop.changed()=>{let _=child.start_kill();let _=child.wait().await;},
                    _=&mut settling=>{
                        if matches!(child.try_wait(),Ok(None)) {
                            let _=pid_write(&ready_marker,pid as i32);
                        }
                        tokio::select!{
                            _=child.wait()=>{},
                            _=stop.changed()=>{let _=child.start_kill();let _=child.wait().await;}
                        }
                    }
                }
                let _ = fs::remove_file(&ready_marker);
                let _ = fs::remove_file(pid_file(&cfg, "tunnel"));
                if *stop.borrow() {
                    break;
                }
            }
            Err(e) => eprintln!("neo-node SSH tunnel launch failed: {e}"),
        }
        tokio::select! {_ = time::sleep(backoff)=>{},_=stop.changed()=>{break}}
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}
async fn run(cfg: Config) -> Result<(), String> {
    cfg.ensure_dirs().map_err(|e| e.to_string())?;
    if is_alive_run(&cfg) {
        return Err("neo-node is already running".into());
    }
    clean_orphan_tunnel(&cfg).await;
    let sessions = Sessions::default();
    let state = Arc::new(State {
        config: cfg.clone(),
        sessions: sessions.clone(),
    });
    let server = server::launch(state)
        .await
        .map_err(|e| format!("node MCP bind failed: {e}"))?;
    pid_write(&cfg.pid_file(), std::process::id() as i32)?;
    let (sender, receiver) = watch::channel(false);
    let tunnel = tokio::spawn(monitor_tunnel(cfg.clone(), receiver));
    let handle = server.handle();
    let server_task = tokio::spawn(server);
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut term = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
        tokio::select! {_ = term.recv()=>{}, _=tokio::signal::ctrl_c()=>{}, _=async{let _=&server_task.await;}=>{}}
    }
    let _ = sender.send(true);
    sessions.signal_all(libc::SIGTERM);
    time::sleep(Duration::from_millis(650)).await;
    sessions.signal_all(libc::SIGKILL);
    if time::timeout(Duration::from_secs(3), handle.stop(true))
        .await
        .is_err()
    {
        handle.stop(false).await;
    }
    let _ = time::timeout(Duration::from_secs(3), tunnel).await;
    if pid_read(&cfg.pid_file()) == Some(std::process::id() as i32) {
        let _ = fs::remove_file(cfg.pid_file());
    }
    Ok(())
}

pub async fn main_cli() -> Result<(), String> {
    let cfg = Config::load()?;
    let cmd = env::args().nth(1).unwrap_or_else(|| "status".into());
    match cmd.as_str(){
        "run" | "serve" =>run(cfg).await,
        "install"=>install(&cfg),
        "uninstall-persistence"=>uninstall(&cfg),
        "start"=>{cfg.ensure_dirs().map_err(|e|e.to_string())?;start(&cfg).await},
        "stop"=>{stop(&cfg).await;Ok(())},
        "restart"=>{stop(&cfg).await;start(&cfg).await},
        "status"=>{status(&cfg)?;println!("local MCP: {}",if server::is_healthy(cfg.local_mcp_port).await{"healthy"}else{"unavailable"});Ok(())},
        "doctor"=>{
            println!("neo-node doctor\nnode={} mode={}",cfg.node_name,cfg.mode);
            println!("{} file {}",if cfg.config_file.is_file(){"ok"}else{"missing"},cfg.config_file.display());
            println!("{} ssh {}",if cfg.ssh_bin.is_file(){"ok"}else{"missing"},cfg.ssh_bin.display());
            println!("{} local MCP health",if server::is_healthy(cfg.local_mcp_port).await{"ok"}else{"info"});Ok(())
        },
        "--version"|"version"=>{println!("{}",env!("CARGO_PKG_VERSION"));Ok(())},
        _=>Err("usage: neo-node [install|run|start|stop|restart|status|doctor|uninstall-persistence|serve]".into())
    }
}
