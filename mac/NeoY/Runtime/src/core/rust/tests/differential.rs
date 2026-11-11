use serde_json::{json, Value};
use std::env;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Barrier, Mutex,
};
use std::thread;
use std::time::Duration;

struct Server {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl Server {
    fn start(authorized: bool) -> Self {
        let temp = std::env::temp_dir().join(format!(
            "neoy-rust-e2e-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        Self::start_with_data_dir(authorized, temp)
    }

    fn start_with_data_dir(authorized: bool, temp: std::path::PathBuf) -> Self {
        Self::start_with_idle_timeout(authorized, temp, None)
    }

    fn start_with_idle_timeout(
        authorized: bool,
        temp: std::path::PathBuf,
        idle_timeout_ms: Option<u64>,
    ) -> Self {
        Self::start_with_webhelm_cli(authorized, temp, idle_timeout_ms, None)
    }

    fn start_with_webhelm_cli(
        authorized: bool,
        temp: std::path::PathBuf,
        idle_timeout_ms: Option<u64>,
        webhelm_cli: Option<&std::path::Path>,
    ) -> Self {
        Self::start_with_runtime_commands(
            authorized,
            temp,
            idle_timeout_ms,
            webhelm_cli,
            None,
            None,
            None,
            None,
        )
    }

    fn start_with_codex_bin(
        authorized: bool,
        temp: std::path::PathBuf,
        codex_bin: &std::path::Path,
    ) -> Self {
        Self::start_with_runtime_commands(
            authorized,
            temp,
            None,
            None,
            Some(codex_bin),
            None,
            None,
            None,
        )
    }

    fn start_with_discord_url(
        authorized: bool,
        temp: std::path::PathBuf,
        discord_url: &str,
    ) -> Self {
        Self::start_with_runtime_commands(
            authorized,
            temp,
            None,
            None,
            None,
            Some(discord_url),
            None,
            None,
        )
    }

    fn start_with_ring_bytes(authorized: bool, temp: std::path::PathBuf, ring_bytes: u64) -> Self {
        Self::start_with_runtime_commands(
            authorized,
            temp,
            None,
            None,
            None,
            None,
            Some(ring_bytes),
            None,
        )
    }

    fn start_with_max_lifetime(
        authorized: bool,
        temp: std::path::PathBuf,
        lifetime_ms: u64,
    ) -> Self {
        Self::start_with_runtime_commands(
            authorized,
            temp,
            None,
            None,
            None,
            None,
            None,
            Some(lifetime_ms),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn start_with_runtime_commands(
        authorized: bool,
        temp: std::path::PathBuf,
        idle_timeout_ms: Option<u64>,
        webhelm_cli: Option<&std::path::Path>,
        codex_bin: Option<&std::path::Path>,
        discord_url: Option<&str>,
        ring_bytes: Option<u64>,
        max_lifetime_ms: Option<u64>,
    ) -> Self {
        std::fs::create_dir_all(&temp).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_neoy-core-rust"));
        command.env("NEO_CORE_DATA_DIR", &temp);
        if let Some(timeout) = idle_timeout_ms {
            command.env("NEO_CORE_PTY_IDLE_TIMEOUT_MS", timeout.to_string());
        }
        if let Some(size) = ring_bytes {
            command.env("NEO_CORE_PTY_RING_BYTES", size.to_string());
        }
        if let Some(lifetime) = max_lifetime_ms {
            command.env("NEO_CORE_PTY_MAX_LIFETIME_MS", lifetime.to_string());
        }
        if authorized {
            command.env(
                "NEO_CORE_FULL_ACCESS_ACK",
                "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
            );
        }
        if let Some(cli) = webhelm_cli {
            command.env("WEBHELM_CLI", cli);
        }
        if let Some(binary) = codex_bin {
            command.env("CODEX_BIN", binary);
        }
        if let Some(endpoint) = discord_url {
            command.env("NEO_DISCORD_REPLY_URL", endpoint);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn request(&mut self, id: u64, method: &str, params: Value) -> Value {
        let message = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        writeln!(self.stdin, "{message}").unwrap();
        self.stdin.flush().unwrap();
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    fn initialize(&mut self) {
        let initialize = self.request(1, "initialize", json!({"protocolVersion":"2025-11-25"}));
        assert_eq!(initialize["result"]["serverInfo"]["name"], "neo-core-tools");
        writeln!(
            self.stdin,
            "{}",
            json!({"jsonrpc":"2.0","method":"notifications/initialized"})
        )
        .unwrap();
        self.stdin.flush().unwrap();
    }

    fn call(&mut self, id: u64, name: &str, arguments: Value) -> Value {
        self.request(id, "tools/call", json!({"name":name,"arguments":arguments}))
    }
}

#[test]
fn chatgpt_lifecycle_validates_and_verifies_submission_receipts() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-chatgpt-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&temp).unwrap();
    let cli = temp.join("fake-webhelm");
    std::fs::write(
        &cli,
        r#"#!/bin/sh
for arg do config=$arg; done
[ "$(/usr/bin/stat -f '%Lp' "$config")" = 600 ] || exit 20
[ "$(/usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$config")")" = 700 ] || exit 21
case "$*" in
  *new-thread*) mode=new-thread; thread=',"thread_id":"thread123","thread_url":"https://chatgpt.com/c/thread123"' ;;
  *new-turn*) mode=new-turn; thread='' ;;
  *) exit 22 ;;
esac
if grep -q 'reject-receipt' "$config"; then printf '{"status":"rejected","mode":"%s"}\n' "$mode"; exit 0; fi
if grep -q 'provider-failure' "$config"; then echo provider-failure >&2; exit 7; fi
printf '{"status":"submitted","mode":"%s"%s}\n' "$mode" "$thread"
"#,
    )
    .unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o700)).unwrap();

    let mut server = Server::start_with_webhelm_cli(true, temp.clone(), None, Some(&cli));
    server.initialize();
    let invalid = server.call(
        2,
        "chatgpt",
        json!({"command":"thread","args":{"message":"hello","project_id":"bad","temporary":true}}),
    );
    assert_eq!(invalid["result"]["isError"], true, "{invalid}");
    let thread = server.call(
        3,
        "chatgpt",
        json!({"command":"thread","args":{"message":"hello"}}),
    );
    assert_eq!(
        thread["result"]["structuredContent"]["thread_id"], "thread123",
        "{thread}"
    );
    let turn = server.call(
        6,
        "chatgpt",
        json!({"command":"turn","args":{"thread_id":"thread123","message":"continue"}}),
    );
    assert_eq!(
        turn["result"]["structuredContent"]["mode"], "new-turn",
        "{turn}"
    );
    let rejected = server.call(
        7,
        "chatgpt",
        json!({"command":"thread","args":{"message":"reject-receipt"}}),
    );
    assert_eq!(rejected["result"]["isError"], true, "{rejected}");
    assert!(
        rejected["result"]["structuredContent"]["error"]
            .as_str()
            .unwrap()
            .contains("did not verify submission"),
        "{rejected}"
    );
    let failed = server.call(
        8,
        "chatgpt",
        json!({"command":"thread","args":{"message":"provider-failure"}}),
    );
    assert_eq!(failed["result"]["isError"], true, "{failed}");
    assert!(
        failed["result"]["structuredContent"]["error"]
            .as_str()
            .unwrap()
            .contains("code=7"),
        "{failed}"
    );
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn codex_app_server_preserves_coalesced_lines_and_reaps_child() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-codex-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&temp).unwrap();
    let pid_file = temp.join("codex.pid");
    let cli = temp.join("fake-codex");
    std::fs::write(
        &cli,
        format!(
            "#!/bin/sh\necho $$ > '{}'\nprintf '{{\\\"id\\\":0,\\\"result\\\":{{}}}}\\n{{\\\"method\\\":\\\"notice\\\"}}\\n'\nread -r initialized\nread -r request\nprintf '{{\\\"id\\\":1,\\\"result\\\":{{\\\"echo\\\":\\\"ok\\\"}}}}\\n'\nexec /bin/sleep 30\n",
            pid_file.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o700)).unwrap();

    let mut server = Server::start_with_codex_bin(true, temp.clone(), &cli);
    server.initialize();
    let response = server.call(
        2,
        "codex",
        json!({"command":"thread.read","args":{"thread_id":"thread123","include_turns":false}}),
    );
    assert_eq!(
        response["result"]["structuredContent"]["echo"], "ok",
        "{response}"
    );
    let pid: i32 = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert_ne!(
        unsafe { libc::kill(pid, 0) },
        0,
        "Codex app-server child survived completed request"
    );
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn malformed_protocol_and_tool_arguments_return_errors_without_crashing() {
    let mut server = Server::start(true);
    server.initialize();
    writeln!(server.stdin, "{{ malformed json").unwrap();
    server.stdin.flush().unwrap();
    let mut line = String::new();
    server.stdout.read_line(&mut line).unwrap();
    let parse_error: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(parse_error["error"]["code"], -32700, "{parse_error}");

    let invalid = server.call(2, "fs", json!({"command":"read","args":{"path":1}}));
    assert_eq!(invalid["result"]["isError"], true, "{invalid}");
    let unknown = server.call(3, "missing", json!({}));
    assert_eq!(unknown["error"]["code"], -32601, "{unknown}");
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn command_facades_reject_unknown_nested_commands_and_invalid_arguments() {
    let mut server = Server::start(true);
    server.initialize();
    for (id, tool) in ["shell", "fs", "terminal", "codex", "discord", "chatgpt"]
        .into_iter()
        .enumerate()
    {
        let response = server.call(
            100 + id as u64,
            tool,
            json!({"command":"__unknown_nested_command__","args":{}}),
        );
        assert_eq!(response["result"]["isError"], true, "{tool}: {response}");
        assert!(
            response["result"]["structuredContent"]["error"].is_string(),
            "{tool}: {response}"
        );
    }
    let invalid = server.call(200, "fs", json!({"command":"grep","args":{"pattern":""}}));
    assert_eq!(invalid["result"]["isError"], true, "{invalid}");
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn discord_rejects_non_loopback_delivery_endpoint() {
    let endpoint = "https://example.com/discord/reply";
    let temp = std::env::temp_dir().join(format!("neoy-rust-discord-{}", std::process::id()));
    let mut server = Server::start_with_discord_url(true, temp.clone(), endpoint);
    server.initialize();
    let arguments = json!({"command":"reply","args":{"correlationId":"correlation-identifier-123","text":"reply"}});
    let rust = server.call(2, "discord", arguments.clone());
    assert_eq!(rust["result"]["isError"], true, "{rust}");
    assert!(rust.to_string().contains("loopback"), "{rust}");
    if let Some(node) = node_tool_call_with_env(
        "discord",
        arguments,
        Some(("NEO_DISCORD_REPLY_URL", endpoint)),
    ) {
        assert!(node.to_string().contains("loopback"), "{node}");
    }
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}

fn node_tools() -> Option<Vec<Value>> {
    let node_core = std::env::var("NEOY_NODE_CORE").ok()?;
    let temp = std::env::temp_dir().join(format!("neoy-node-diff-{}", std::process::id()));
    std::fs::create_dir_all(&temp).unwrap();
    let mut child = Command::new("node")
        .arg(node_core)
        .env("NEO_CORE_DATA_DIR", temp)
        .env(
            "NEO_CORE_FULL_ACCESS_ACK",
            "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let messages = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}),
    ];
    for message in messages {
        writeln!(stdin, "{message}").unwrap();
    }
    stdin.flush().unwrap();
    let mut response = None;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        let mut line = String::new();
        if stdout.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        if let Ok(message) = serde_json::from_str::<Value>(&line) {
            if message["id"].as_u64() == Some(2) {
                response = Some(message);
                break;
            }
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let response = response?;
    Some(response.pointer("/result/tools")?.as_array()?.clone())
}

fn node_facade_help(facade: &str) -> Option<Value> {
    let node_core = std::env::var("NEOY_NODE_CORE").ok()?;
    let temp =
        std::env::temp_dir().join(format!("neoy-node-help-{}-{}", std::process::id(), facade));
    std::fs::create_dir_all(&temp).ok()?;
    let mut child = Command::new("node")
        .arg(node_core)
        .env("NEO_CORE_DATA_DIR", &temp)
        .env(
            "NEO_CORE_FULL_ACCESS_ACK",
            "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take()?;
    let mut stdout = BufReader::new(child.stdout.take()?);
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}})).ok()?;
    stdin.flush().ok()?;
    let mut line = String::new();
    stdout.read_line(&mut line).ok()?;
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","method":"notifications/initialized"})
    )
    .ok()?;
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":facade,"arguments":{"command":"help"}}})).ok()?;
    stdin.flush().ok()?;
    line.clear();
    let response = if stdout.read_line(&mut line).ok()? == 0 {
        None
    } else {
        serde_json::from_str::<Value>(&line)
            .ok()?
            .pointer("/result/structuredContent")
            .cloned()
    };
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(temp);
    response
}

fn node_tool_call(name: &str, arguments: Value) -> Option<Value> {
    node_tool_call_with_env(name, arguments, None)
}

fn node_tool_call_with_env(
    name: &str,
    arguments: Value,
    environment: Option<(&str, &str)>,
) -> Option<Value> {
    let node_core = std::env::var("NEOY_NODE_CORE").ok()?;
    let temp = std::env::temp_dir().join(format!(
        "neoy-node-call-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_nanos()
    ));
    std::fs::create_dir_all(&temp).ok()?;
    let mut command = Command::new("node");
    command.arg(node_core).env("NEO_CORE_DATA_DIR", &temp).env(
        "NEO_CORE_FULL_ACCESS_ACK",
        "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
    );
    if let Some((key, value)) = environment {
        command.env(key, value);
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let response = (|| {
        let mut stdin = child.stdin.take()?;
        let mut stdout = BufReader::new(child.stdout.take()?);
        writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}})).ok()?;
        stdin.flush().ok()?;
        let mut line = String::new();
        stdout.read_line(&mut line).ok()?;
        writeln!(
            stdin,
            "{}",
            json!({"jsonrpc":"2.0","method":"notifications/initialized"})
        )
        .ok()?;
        writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":name,"arguments":arguments}})).ok()?;
        stdin.flush().ok()?;
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            if std::time::Instant::now() >= deadline {
                return None;
            }
            line.clear();
            if stdout.read_line(&mut line).ok()? == 0 {
                return None;
            }
            let message = serde_json::from_str::<Value>(&line).ok()?;
            if message["id"].as_u64() == Some(2) {
                return message.pointer("/result/structuredContent").cloned();
            }
        }
    })();
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(temp);
    response
}

fn tool_contract(tool: &Value) -> Value {
    tool.clone()
}

#[test]
fn unauthorized_startup_writes_no_stdout() {
    let mut server = Server::start(false);
    let _ = server.child.kill();
    let status = server.child.wait().unwrap();
    assert!(!status.success());
}

#[test]
fn file_unlock_revocation_terminates_child() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-unlock-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&temp).unwrap();
    let unlock_file = temp.join("FULL_ACCESS_ENABLED");
    std::fs::write(&unlock_file, "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n").unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_neoy-core-rust"))
        .env("NEO_CORE_DATA_DIR", &temp)
        .env("NEO_CORE_UNLOCK_FILE", &unlock_file)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}})).unwrap();
    stdin.flush().unwrap();
    let mut response = String::new();
    stdout.read_line(&mut response).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["id"], 1);

    std::fs::remove_file(&unlock_file).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "revocation exit status: {status}");
            break;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("child remained alive after unlock revocation");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(stdin);
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn unlock_revocation_racing_foreground_shell_reclaims_child_group() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-unlock-race-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&temp).unwrap();
    let unlock_file = temp.join("FULL_ACCESS_ENABLED");
    let pid_file = temp.join("foreground.pid");
    std::fs::write(&unlock_file, "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n").unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_neoy-core-rust"))
        .env("NEO_CORE_DATA_DIR", &temp)
        .env("NEO_CORE_UNLOCK_FILE", &unlock_file)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}})).unwrap();
    stdin.flush().unwrap();
    let mut response = String::new();
    stdout.read_line(&mut response).unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","method":"notifications/initialized"})
    )
    .unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shell","arguments":{"command":"exec","args":{"command":format!("echo $$ > {}; exec /bin/sleep 30",pid_file.display()),"timeout_ms":30_000}}}})).unwrap();
    stdin.flush().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !pid_file.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(pid_file.exists(), "foreground command never started");
    let pid: i32 = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    std::fs::remove_file(&unlock_file).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(6);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "revocation exit status: {status}");
            break;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
            panic!("core remained alive after unlock revocation");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let state = Command::new("/bin/ps")
        .args(["-o", "stat=", "-p"])
        .arg(pid.to_string())
        .output()
        .unwrap();
    let process_state = String::from_utf8_lossy(&state.stdout).trim().to_string();
    let alive = !process_state.is_empty() && !process_state.starts_with('Z');
    if alive {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    assert!(
        !alive,
        "foreground process group survived unlock revocation"
    );
    drop(stdin);
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn concurrent_calls_keep_response_ids_correlated() {
    let mut server = Server::start(true);
    server.initialize();
    let slow = json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shell","arguments":{"command":"exec","args":{"command":"sleep 1; printf slow","timeout":5000}}}});
    let fast = json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"shell","arguments":{"command":"exec","args":{"command":"printf fast","timeout":5000}}}});
    writeln!(server.stdin, "{slow}").unwrap();
    writeln!(server.stdin, "{fast}").unwrap();
    writeln!(server.stdin, "{}", json!({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"test"}})).unwrap();
    server.stdin.flush().unwrap();

    let mut responses = Vec::new();
    for _ in 0..2 {
        let mut line = String::new();
        server.stdout.read_line(&mut line).unwrap();
        responses.push(serde_json::from_str::<Value>(&line).unwrap());
    }
    assert_eq!(
        responses[0]["id"], 3,
        "fast response should not wait for slow call"
    );
    assert_eq!(
        responses[0]["result"]["structuredContent"]["stdout"],
        "fast"
    );
    assert_eq!(responses[1]["id"], 2);
    assert_eq!(
        responses[1]["result"]["structuredContent"]["stdout"],
        "slow"
    );
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn mcp_inventory_and_representative_calls() {
    let mut rust = Server::start(true);
    rust.initialize();
    let rust_tools = rust.request(2, "tools/list", json!({}))["result"]["tools"]
        .as_array()
        .unwrap()
        .clone();
    let names: Vec<String> = rust_tools
        .iter()
        .map(|tool| tool["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        names,
        [
            "status",
            "shell",
            "fs",
            "apply_file_patch",
            "codex",
            "discord",
            "chatgpt",
            "terminal"
        ]
    );
    let status = rust.call(3, "status", json!({}));
    assert_eq!(status["result"]["isError"], false);
    let shell = rust.call(
        4,
        "shell",
        json!({"command":"exec","args":{"command":"printf rust-ok","timeout":5000}}),
    );
    let result = shell["result"]["structuredContent"].clone();
    assert_eq!(result["exitCode"], 0);
    assert!(result["stdout"].as_str().unwrap().contains("rust-ok"));

    let start = rust.call(
        3,
        "shell",
        json!({"command":"start","args":{"command":"sleep 30","label":"e2e"}}),
    );
    let job_id = start["result"]["structuredContent"]["jobId"]
        .as_str()
        .unwrap()
        .to_string();
    let kill = rust.call(
        6,
        "shell",
        json!({"command":"job.kill","args":{"job_id":job_id,"signal":"SIGKILL"}}),
    );
    assert_eq!(kill["result"]["isError"], false);

    writeln!(rust.stdin, "{{not-json").unwrap();
    rust.stdin.flush().unwrap();
    let mut parse_line = String::new();
    rust.stdout.read_line(&mut parse_line).unwrap();
    let parse: Value = serde_json::from_str(&parse_line).unwrap();
    assert_eq!(parse["error"]["code"], -32700, "{parse}");
    let unknown = rust.call(8, "__missing__", json!({}));
    assert_eq!(unknown["error"]["code"], -32601);

    if let Some(expected) = node_tools() {
        let expected_names: Vec<String> = expected
            .iter()
            .map(|tool| tool["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(names, expected_names);
        for rust_tool in &rust_tools {
            let name = rust_tool["name"].as_str().unwrap();
            let node_tool = expected.iter().find(|tool| tool["name"] == name).unwrap();
            assert_eq!(
                tool_contract(rust_tool),
                tool_contract(node_tool),
                "tool contract mismatch for {name}"
            );
        }
        for facade in ["shell", "fs", "codex", "discord", "terminal", "chatgpt"] {
            let node_help = node_facade_help(facade).expect("Node facade help response");
            let rust_help = rust.call(20, facade, json!({"command":"help"}));
            assert_eq!(
                rust_help["result"]["structuredContent"], node_help,
                "help contract mismatch for {facade}"
            );
        }
    }
    let _ = rust.child.kill();
    let _ = rust.child.wait();
}

#[test]
fn modern_protocol_returns_completion_metadata() {
    let mut server = Server::start(true);
    server.initialize();
    let response = server.request(
        2,
        "tools/list",
        json!({"_meta":{"io.modelcontextprotocol":{"protocolVersion":"2026-07-28"}}}),
    );
    assert_eq!(response["result"]["resultType"], "complete", "{response}");
    assert_eq!(response["result"]["ttlMs"], 300_000, "{response}");
    assert_eq!(
        response["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "neo-core-tools",
        "{response}"
    );
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn shell_exec_stdin_output_limit_and_timeout() {
    let mut server = Server::start(true);
    server.initialize();
    let stdin = server.call(
        2,
        "shell",
        json!({"command":"exec","args":{"command":"cat","stdin":"input-from-caller","timeout":5000}}),
    );
    let result = &stdin["result"]["structuredContent"];
    assert_eq!(result["exitCode"], 0, "{stdin}");
    assert_eq!(result["stdout"], "input-from-caller", "{stdin}");

    let scrubbed = server.call(
        3,
        "shell",
        json!({"command":"exec","args":{"command":"printf '%s,%s' \"${NEO_CORE_FULL_ACCESS_ACK:-missing}\" \"${CONTROL_PLANE_API_KEY:-missing}\"","env":{"NEO_CORE_FULL_ACCESS_ACK":"I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS","CONTROL_PLANE_API_KEY":"secret"},"timeout":5000}}),
    );
    assert_eq!(
        scrubbed["result"]["structuredContent"]["stdout"], "missing,missing",
        "{scrubbed}"
    );

    let limited = server.call(
        4,
        "shell",
        json!({"command":"exec","args":{"command":"printf 123456789","timeout":5000,"max_output_bytes":4}}),
    );
    let result = &limited["result"]["structuredContent"];
    assert_eq!(result["stdout"], "1234", "{limited}");
    assert_eq!(result["stdoutTruncated"], false, "{limited}");
    let output_file = result["stdoutFile"].as_str().expect("large output file");
    assert_eq!(std::fs::read_to_string(output_file).unwrap(), "123456789");
    assert_eq!(
        std::fs::metadata(output_file).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let timed_out = server.call(
        5,
        "shell",
        json!({"command":"exec","args":{"command":"sleep 10","timeout":100}}),
    );
    let job_id = timed_out["result"]["structuredContent"]["jobId"]
        .as_str()
        .expect("running command returns its durable job ID");
    let status = server.call(
        6,
        "shell",
        json!({"command":"job.status","args":{"job_id":job_id}}),
    );
    assert_eq!(
        status["result"]["structuredContent"]["running"], true,
        "{status}"
    );
    let kill = server.call(
        7,
        "shell",
        json!({"command":"job.kill","args":{"job_id":job_id,"signal":"SIGTERM"}}),
    );
    assert_eq!(kill["result"]["isError"], false, "{kill}");
    let invalid_id = server.call(
        8,
        "shell",
        json!({"command":"job.status","args":{"job_id":"../../etc/passwd"}}),
    );
    assert_eq!(invalid_id["result"]["isError"], true, "{invalid_id}");

    let completed = server.call(
        9,
        "shell",
        json!({"command":"start","args":{"command":"printf background-ok"}}),
    );
    let completed_id = completed["result"]["structuredContent"]["jobId"]
        .as_str()
        .expect("background job id");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let status = server.call(
            10,
            "shell",
            json!({"command":"job.status","args":{"job_id":completed_id}}),
        );
        if status["result"]["structuredContent"]["running"] == false {
            assert_eq!(
                status["result"]["structuredContent"]["exitCode"], 0,
                "{status}"
            );
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "job did not complete: {status}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn background_job_metadata_survives_core_restart() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-job-restart-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut first = Server::start_with_data_dir(true, temp.clone());
    first.initialize();
    let started = first.call(
        2,
        "shell",
        json!({"command":"start","args":{"command":"sleep 30","label":"restart-test"}}),
    );
    let job_id = started["result"]["structuredContent"]["jobId"]
        .as_str()
        .expect("started job id")
        .to_string();
    let _ = first.child.kill();
    let _ = first.child.wait();

    let mut second = Server::start_with_data_dir(true, temp.clone());
    second.initialize();
    let status = second.call(
        2,
        "shell",
        json!({"command":"job.status","args":{"job_id":job_id}}),
    );
    assert_eq!(
        status["result"]["structuredContent"]["running"], true,
        "{status}"
    );
    let kill = second.call(
        3,
        "shell",
        json!({"command":"job.kill","args":{"job_id":job_id,"signal":"SIGKILL"}}),
    );
    assert_eq!(kill["result"]["isError"], false, "{kill}");
    let _ = second.child.kill();
    let _ = second.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn filesystem_and_patch_contracts() {
    let root = std::env::temp_dir().join(format!("neoy-rust-files-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("fixture.txt");
    std::fs::write(&path, b"native-core").unwrap();
    let nested = root.join("nested");
    std::fs::create_dir_all(&nested).unwrap();
    let searchable = nested.join("search.txt");
    std::fs::write(&searchable, "before\nNeedle one\nafter\nneedle two\n").unwrap();
    std::fs::write(root.join(".gitignore"), "*.skip\n").unwrap();
    std::fs::write(root.join("ignored.skip"), "needle must be ignored\n").unwrap();
    let mut server = Server::start(true);
    server.initialize();
    let grep_args = json!({"command":"grep","args":{"pattern":"needle","path":root,"ignore_case":true,"literal":true,"context":1}});
    let grep = server.call(20, "fs", grep_args.clone());
    assert_eq!(grep["result"]["isError"], false, "{grep}");
    let matches = grep["result"]["structuredContent"]["matches"]
        .as_array()
        .unwrap();
    assert_eq!(matches.len(), 2, "{grep}");
    assert_eq!(matches[0]["path"], "nested/search.txt", "{grep}");
    assert_eq!(matches[0]["before"][0]["text"], "before", "{grep}");
    assert_eq!(matches[0]["after"][0]["text"], "after", "{grep}");
    if let Some(node_grep) = node_tool_call("fs", grep_args) {
        assert_eq!(grep["result"]["structuredContent"], node_grep);
    }
    let find_args = json!({"command":"find","args":{"pattern":"search.txt","path":root}});
    let find = server.call(21, "fs", find_args.clone());
    assert_eq!(find["result"]["isError"], false, "{find}");
    assert_eq!(
        find["result"]["structuredContent"]["paths"][0], "nested/search.txt",
        "{find}"
    );
    if let Some(node_find) = node_tool_call("fs", find_args) {
        assert_eq!(find["result"]["structuredContent"], node_find);
    }
    let glob_grep = server.call(22, "fs", json!({"command":"grep","args":{"pattern":"needle","path":root,"ignore_case":true,"literal":true,"glob":"*.txt"}}));
    assert_eq!(glob_grep["result"]["isError"], false, "{glob_grep}");
    assert_eq!(
        glob_grep["result"]["structuredContent"]["count"], 2,
        "{glob_grep}"
    );
    let ignored_find = server.call(
        23,
        "fs",
        json!({"command":"find","args":{"pattern":"*.skip","path":root}}),
    );
    assert_eq!(ignored_find["result"]["isError"], false, "{ignored_find}");
    assert_eq!(
        ignored_find["result"]["structuredContent"]["count"], 0,
        "{ignored_find}"
    );
    let bad_glob = server.call(
        24,
        "fs",
        json!({"command":"grep","args":{"pattern":"needle","path":root,"glob":"["}}),
    );
    assert_eq!(bad_glob["result"]["isError"], true, "{bad_glob}");
    let write = server.call(
        2,
        "fs",
        json!({"command":"write","args":{"path":path,"content":"changed","mode":384}}),
    );
    assert_eq!(write["result"]["isError"], false);
    let read = server.call(3, "fs", json!({"command":"read","args":{"path":path}}));
    let payload = read["result"]["structuredContent"].clone();
    assert_eq!(payload["content"], "changed");
    let stat = server.call(13, "fs", json!({"command":"stat","args":{"path":path}}));
    assert_eq!(
        stat["result"]["structuredContent"]["type"], "file",
        "{stat}"
    );
    assert_eq!(stat["result"]["structuredContent"]["mode"], 384, "{stat}");
    assert!(stat["result"]["structuredContent"]["modifiedAt"]
        .as_str()
        .unwrap()
        .ends_with('Z'));
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let append = server.call(
        5,
        "fs",
        json!({"command":"write","args":{"path":path,"content":"-tail","append":true}}),
    );
    assert_eq!(append["result"]["isError"], false, "{append}");
    let read = server.call(6, "fs", json!({"command":"read","args":{"path":path}}));
    assert_eq!(
        read["result"]["structuredContent"]["content"],
        "changed-tail"
    );
    let no_parents = server.call(
        7,
        "fs",
        json!({"command":"write","args":{"path":root.join("missing/file.txt"),"content":"x","create_parents":false}}),
    );
    assert_eq!(no_parents["result"]["isError"], true, "{no_parents}");
    let lines_path = root.join("lines.txt");
    std::fs::write(&lines_path, "one\ntwo\nthree\n").unwrap();
    let line_read = server.call(
        8,
        "fs",
        json!({"command":"read","args":{"path":lines_path,"start_line":2,"endLine":3}}),
    );
    assert_eq!(
        line_read["result"]["structuredContent"]["content"], "two\nthree\n",
        "{line_read}"
    );
    let conflicting_aliases = server.call(
        9,
        "fs",
        json!({"command":"read","args":{"path":lines_path,"start_line":1,"startLine":1}}),
    );
    assert_eq!(
        conflicting_aliases["result"]["isError"], true,
        "{conflicting_aliases}"
    );
    std::fs::create_dir_all(root.join("z-dir")).unwrap();
    std::fs::write(root.join("z-dir/nested.txt"), "nested").unwrap();
    std::fs::write(root.join(".hidden"), "hidden").unwrap();
    let listed = server.call(
        11,
        "fs",
        json!({"command":"list","args":{"path":root,"recursive":true,"include_hidden":false,"max_entries":10}}),
    );
    let entries = listed["result"]["structuredContent"]["entries"]
        .as_array()
        .unwrap();
    assert_eq!(
        listed["result"]["structuredContent"]["count"], 7,
        "{listed}"
    );
    assert!(entries.iter().all(|entry| entry["name"] != ".hidden"));
    assert!(entries
        .iter()
        .any(|entry| entry["relativePath"] == "z-dir/nested.txt"));
    assert!(entries
        .iter()
        .all(|entry| entry["modifiedAt"].as_str().unwrap().ends_with('Z')));
    let limited_list = server.call(
        12,
        "fs",
        json!({"command":"list","args":{"path":root,"max_entries":2}}),
    );
    assert_eq!(
        limited_list["result"]["structuredContent"]["truncated"],
        true
    );
    let patch = server.call(
        10,
        "apply_file_patch",
        json!({"patch":"not-a-diff\n","cwd":root,"check_only":true}),
    );
    assert_eq!(patch["result"]["isError"], true);
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn terminal_session_contract() {
    let mut server = Server::start(true);
    server.initialize();
    let started = server.call(2, "terminal", json!({"command":"start","args":{"command":"/bin/echo","args":["ready"],"rows":5,"cols":20}}));
    let session_id = started["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("PTY failed to start: {started}"))
        .to_string();
    std::thread::sleep(Duration::from_millis(150));
    let read = server.call(
        3,
        "terminal",
        json!({"command":"read","args":{"session_id":session_id,"cursor":0,"max_bytes":1024,"strip_ansi":true,"collapse_carriage_returns":true,"wait_ms":1000}}),
    );
    let payload = read["result"]["structuredContent"].clone();
    assert!(
        payload["output"].as_str().unwrap_or("").contains("ready"),
        "PTY read response: {read}"
    );
    assert_eq!(payload["cursor"], 0, "{read}");
    assert!(payload["nextCursor"].as_u64().unwrap() > 0, "{read}");
    assert!(payload["totalBytes"].as_u64().unwrap() > 0, "{read}");
    assert_eq!(payload["cols"], 20, "{read}");
    assert!(payload["idleMs"].as_u64().unwrap() >= 100, "{read}");
    let resized = server.call(
        14,
        "terminal",
        json!({"command":"resize","args":{"session_id":session_id,"cols":80,"rows":24}}),
    );
    assert_eq!(
        resized["result"]["structuredContent"]["cols"], 80,
        "{resized}"
    );
    assert_eq!(
        resized["result"]["structuredContent"]["rows"], 24,
        "{resized}"
    );
    let _ = server.call(
        4,
        "terminal",
        json!({"command":"close","args":{"session_id":session_id}}),
    );
    let cat = server.call(
        8,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/cat"}}),
    );
    let cat_id = cat["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    let written = server.call(
        9,
        "terminal",
        json!({"command":"write","args":{"session_id":cat_id,"data":"hello\n"}}),
    );
    assert_eq!(
        written["result"]["structuredContent"]["bytesWritten"], 6,
        "{written}"
    );
    let continued = server.call(
        15,
        "terminal",
        json!({"command":"signal","args":{"session_id":cat_id,"signal":"CONT"}}),
    );
    assert_eq!(
        continued["result"]["structuredContent"]["delivered"], true,
        "{continued}"
    );
    let bad_signal = server.call(
        16,
        "terminal",
        json!({"command":"signal","args":{"session_id":cat_id,"signal":"BOGUS"}}),
    );
    assert_eq!(bad_signal["result"]["isError"], true, "{bad_signal}");
    let oversized_line = server.call(
        10,
        "terminal",
        json!({"command":"write","args":{"session_id":cat_id,"data":"x".repeat(1024)}}),
    );
    assert_eq!(
        oversized_line["result"]["isError"], true,
        "{oversized_line}"
    );
    assert_eq!(
        oversized_line["result"]["structuredContent"]["code"], "PTY_WRITE_CANON_LIMIT",
        "{oversized_line}"
    );
    let too_large = server.call(
        11,
        "terminal",
        json!({"command":"write","args":{"session_id":cat_id,"data":"x".repeat(65_537)}}),
    );
    assert_eq!(
        too_large["result"]["structuredContent"]["code"],
        "PTY_WRITE_TOO_LARGE"
    );
    let _ = server.call(
        12,
        "terminal",
        json!({"command":"close","args":{"session_id":cat_id}}),
    );
    let stopped = server.call(
        13,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sleep","args":["30"]}}),
    );
    let stopped_id = stopped["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    let _ = server.call(
        14,
        "terminal",
        json!({"command":"signal","args":{"session_id":stopped_id,"signal":"SIGSTOP"}}),
    );
    let close_started = std::time::Instant::now();
    let stopped_close = server.call(
        15,
        "terminal",
        json!({"command":"close","args":{"session_id":stopped_id}}),
    );
    assert_eq!(stopped_close["result"]["isError"], false, "{stopped_close}");
    assert!(close_started.elapsed() < Duration::from_secs(4));
    let descendant_pid_file = std::env::temp_dir().join(format!(
        "neoy-rust-pty-descendant-{}.pid",
        std::process::id()
    ));
    let descendant = server.call(
        16,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sh","args":["-c",format!("(trap '' HUP TERM; echo ready > {}; exec /bin/sleep 30) & wait",descendant_pid_file.display())]}}),
    );
    let descendant_id = descendant["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    let wait_deadline = std::time::Instant::now() + Duration::from_secs(1);
    while !descendant_pid_file.exists() && std::time::Instant::now() < wait_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        descendant_pid_file.exists(),
        "PTY descendant did not reach the signal-ignoring state"
    );
    let close_started = std::time::Instant::now();
    let descendant_close = server.call(
        17,
        "terminal",
        json!({"command":"close","args":{"session_id":descendant_id}}),
    );
    assert_eq!(
        descendant_close["result"]["isError"], false,
        "{descendant_close}"
    );
    assert!(close_started.elapsed() < Duration::from_secs(4));
    assert!(close_started.elapsed() >= Duration::from_secs(1));
    let _ = std::fs::remove_file(descendant_pid_file);
    let secret_probe = server.call(
        5,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sh","args":["-c","/usr/bin/env"],"env":{"NEO_CORE_FULL_ACCESS_ACK":"I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS","CONTROL_PLANE_API_KEY":"secret"}}}),
    );
    let secret_session = secret_probe["result"]["structuredContent"]["sessionId"]
        .as_str()
        .expect("PTY session starts");
    std::thread::sleep(Duration::from_millis(100));
    let secret_output = server.call(
        6,
        "terminal",
        json!({"command":"read","args":{"session_id":secret_session}}),
    );
    let output = secret_output["result"]["structuredContent"]["output"]
        .as_str()
        .unwrap_or_default();
    assert!(
        !output.contains("NEO_CORE_FULL_ACCESS_ACK"),
        "{secret_output}"
    );
    assert!(!output.contains("CONTROL_PLANE_API_KEY"), "{secret_output}");
    let _ = server.call(
        7,
        "terminal",
        json!({"command":"close","args":{"session_id":secret_session}}),
    );
    let shared_server = Arc::new(Mutex::new(server));
    let concurrent_start_receivers = Arc::new(Barrier::new(9));
    let mutator_active = Arc::new(AtomicBool::new(true));
    let completed_starts = Arc::new(AtomicUsize::new(0));
    let environment_mutator = {
        let receiver = Arc::clone(&concurrent_start_receivers);
        let active = Arc::clone(&mutator_active);
        thread::spawn(move || {
            receiver.wait();
            let mut round = 0;
            while active.load(Ordering::Acquire) {
                let label = format!("fork-safety-{round}");
                env::set_var("NEO_CORE_PTY_FORK_SAFETY", &label);
                env::remove_var("NEO_CORE_PTY_FORK_SAFETY");
                round += 1;
            }
        })
    };
    let mut concurrent_sessions = Vec::new();
    let concurrent_starts = (0..8)
        .map(|id| {
            let receiver = Arc::clone(&concurrent_start_receivers);
            let server = Arc::clone(&shared_server);
            let completions = Arc::clone(&completed_starts);
            let active = Arc::clone(&mutator_active);
            thread::spawn(move || {
                receiver.wait();
                let mut server = server.lock().unwrap();
                let response = server.call(
                    500 + id,
                    "terminal",
                json!({"command":"start","args":{"command":"/bin/echo","args":["fork-safety"]}}),
                );
                drop(server);
                if completions.fetch_add(1, Ordering::AcqRel) + 1 == 8 {
                    active.store(false, Ordering::Release);
                }
                response
            })
        })
        .collect::<Vec<_>>();
    for started in concurrent_starts {
        let response = started.join().expect("concurrent PTY start thread");
        assert_eq!(
            response["result"]["isError"], false,
            "fork-safe PTY startup failed under environment contention: {response}"
        );
        assert!(
            response["result"]["structuredContent"]["sessionId"]
                .as_str()
                .is_some(),
            "{response}"
        );
        concurrent_sessions.push(
            response["result"]["structuredContent"]["sessionId"]
                .as_str()
                .expect("PTY session id")
                .to_string(),
        );
    }
    for (id, session_id) in concurrent_sessions.iter().enumerate() {
        let _ = shared_server.lock().unwrap().call(
            600 + id as u64,
            "terminal",
            json!({"command":"close","args":{"session_id":session_id}}),
        );
    }
    environment_mutator.join().expect("environment mutator");
    env::remove_var("NEO_CORE_PTY_FORK_SAFETY");
    let mut server = match Arc::try_unwrap(shared_server) {
        Ok(server) => server.into_inner().unwrap(),
        Err(_) => unreachable!("concurrent PTY starts have completed"),
    };
    let mut sessions = Vec::new();
    for id in 0..8 {
        let started = server.call(
            10 + id,
            "terminal",
            json!({"command":"start","args":{"command":"/bin/sleep","args":["30"]}}),
        );
        sessions.push(
            started["result"]["structuredContent"]["sessionId"]
                .as_str()
                .expect("PTY session id")
                .to_string(),
        );
    }
    let limited = server.call(
        30,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sleep","args":["30"]}}),
    );
    assert_eq!(limited["result"]["isError"], true, "{limited}");
    assert_eq!(
        limited["result"]["structuredContent"]["code"], "PTY_SESSION_LIMIT",
        "{limited}"
    );
    for (index, session_id) in sessions.iter().enumerate() {
        let _ = server.call(
            40 + index as u64,
            "terminal",
            json!({"command":"close","args":{"session_id":session_id}}),
        );
    }
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn pty_cursor_ring_and_text_normalization_match_contract() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-pty-ring-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut server = Server::start_with_ring_bytes(true, temp, 4_096);
    server.initialize();
    let start = server.call(2, "terminal", json!({"command":"start","args":{"command":"/usr/bin/printf","args":["\\033[31mprogress\\033[0m\\rready\\n"]}}));
    let id = start["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    std::thread::sleep(Duration::from_millis(200));
    let normalized = server.call(3, "terminal", json!({"command":"read","args":{"session_id":id,"cursor":0,"max_bytes":1024,"wait_ms":1000}}));
    assert_eq!(
        normalized["result"]["structuredContent"]["output"], "ready\n",
        "{normalized}"
    );
    assert!(
        normalized["result"]["structuredContent"]["nextCursor"]
            .as_u64()
            .unwrap()
            > 0,
        "{normalized}"
    );
    let _ = server.call(
        4,
        "terminal",
        json!({"command":"close","args":{"session_id":id}}),
    );
    let start = server.call(5, "terminal", json!({"command":"start","args":{"command":"/bin/sh","args":["-c","/usr/bin/printf '%010000d' 0"]}}));
    let id = start["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    std::thread::sleep(Duration::from_millis(200));
    let mut read = server.call(6, "terminal", json!({"command":"read","args":{"session_id":id,"cursor":0,"max_bytes":1024,"wait_ms":1000}}));
    for _ in 0..100 {
        if read["result"]["structuredContent"]["totalBytes"]
            .as_u64()
            .unwrap_or(0)
            > 4096
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        read = server.call(7, "terminal", json!({"command":"read","args":{"session_id":id,"cursor":0,"max_bytes":1024,"wait_ms":10}}));
    }
    let content = &read["result"]["structuredContent"];
    assert!(content["lostBytes"].as_u64().unwrap() > 0, "{read}");
    assert_eq!(content["retainedBytes"], 4096, "{read}");
    assert!(content["truncated"].as_bool().unwrap(), "{read}");
    assert!(
        content["nextCursor"].as_u64().unwrap() > content["lostBytes"].as_u64().unwrap(),
        "{read}"
    );
    let _ = server.call(
        8,
        "terminal",
        json!({"command":"close","args":{"session_id":id}}),
    );
    let _ = server.child.kill();
    let _ = server.child.wait();
}

#[test]
fn idle_pty_session_is_reclaimed() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-pty-idle-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut server = Server::start_with_idle_timeout(true, temp.clone(), Some(1_000));
    server.initialize();
    let started = server.call(
        2,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sleep","args":["30"]}}),
    );
    let session_id = started["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("PTY failed to start: {started}"))
        .to_string();
    std::thread::sleep(Duration::from_millis(3_500));
    let read = server.call(
        3,
        "terminal",
        json!({"command":"read","args":{"session_id":session_id}}),
    );
    assert_eq!(read["result"]["isError"], true, "{read}");
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}

#[test]
fn pty_max_lifetime_expires_even_when_session_is_read() {
    let temp = std::env::temp_dir().join(format!(
        "neoy-rust-pty-lifetime-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut server = Server::start_with_max_lifetime(true, temp.clone(), 5_000);
    server.initialize();
    let started = server.call(
        2,
        "terminal",
        json!({"command":"start","args":{"command":"/bin/sleep","args":["30"]}}),
    );
    let id = started["result"]["structuredContent"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    for index in 0..7 {
        std::thread::sleep(Duration::from_millis(1_000));
        let read = server.call(
            3 + index,
            "terminal",
            json!({"command":"read","args":{"session_id":id,"wait_ms":0}}),
        );
        if read["result"]["isError"] == true {
            break;
        }
    }
    let final_read = server.call(
        12,
        "terminal",
        json!({"command":"read","args":{"session_id":id}}),
    );
    assert_eq!(final_read["result"]["isError"], true, "{final_read}");
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = std::fs::remove_dir_all(temp);
}
