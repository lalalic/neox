mod context;
mod error;
mod gc;
mod gui;
mod handlers;
mod jobs;
mod pty;
mod tools;

use context::Context;
use handlers::Handlers;
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::{
    atomic::{AtomicI32, AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

const MAX_IN_FLIGHT_CALLS: usize = 32;
static SHUTDOWN_SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_shutdown_signal(signal: libc::c_int) {
    SHUTDOWN_SIGNAL.store(signal, Ordering::SeqCst);
}

fn cleanup(handlers: &Handlers) {
    handlers::kill_in_flight_commands();
    // Durable shell jobs deliberately survive transport shutdown, as in Node.
    handlers.ptys.teardown_all();
}

fn main() {
    // Native upgrade/bootstrap identity; no npm manifest or Node runtime.
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let context = match Context::from_env() {
        Ok(context) => context,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    };
    let handlers = Arc::new(Handlers::new(context.clone()));
    unsafe {
        libc::signal(
            libc::SIGTERM,
            on_shutdown_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            on_shutdown_signal as *const () as libc::sighandler_t,
        );
    }
    stderr_line(&format!(
        "{} {} started (pid {})",
        context::SERVER_NAME,
        context::CORE_VERSION,
        std::process::id()
    ));

    let watcher = handlers.clone();
    std::thread::spawn(move || {
        let mut last_sweep = std::time::Instant::now();
        loop {
            watcher.ptys.pump_output(20);
            if SHUTDOWN_SIGNAL.load(Ordering::SeqCst) != 0 {
                cleanup(&watcher);
                std::process::exit(0);
            }
            if last_sweep.elapsed() < Duration::from_secs(3) {
                continue;
            }
            last_sweep = std::time::Instant::now();
            watcher.ptys.expire_sessions();
            if !watcher.context.unlocked() {
                handlers::kill_in_flight_commands();
                jobs::kill_in_flight_exec_groups();
                watcher.ptys.teardown_all();
                eprintln!(
                    "Full-access unlock revoked ({}); reclaiming PTY sessions and exiting.",
                    watcher.context.unlock_file.display()
                );
                std::process::exit(78);
            }
        }
    });

    // The GC runs outside the request path; its bounded one-hour sweep does not
    // signal active jobs or change any MCP contract.
    let garbage_dir = context.job_dir.clone();
    std::thread::spawn(move || loop {
        if let Err(error) = gc::sweep(&garbage_dir, gc::MAX_SWEEP_DELETES) {
            eprintln!("Core job GC sweep failed: {error}");
        }
        std::thread::sleep(gc::GC_INTERVAL);
    });

    let stdin = std::io::stdin();
    let stdout = Arc::new(Mutex::new(()));
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut calls: Vec<std::thread::JoinHandle<()>> = Vec::new();
    let mut initialized_legacy = false;
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let message: Value = match serde_json::from_str(trimmed) {
            Ok(message) => message,
            Err(error) => {
                let response = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": {"code": -32700, "message": "Parse error", "data": {"detail": error.to_string()}}
                });
                write_line(&stdout, &response);
                continue;
            }
        };
        if !message.get("method").is_some_and(Value::is_string) {
            if let Some(id) = message.get("id") {
                send_error(&stdout, id.clone(), -32600, "Invalid Request", None);
            }
            continue;
        }
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let id = message.get("id").cloned();
        if method != "initialize"
            && method != "notifications/initialized"
            && method != "initialized"
            && !modern(&message)
            && method != "ping"
            && !initialized_legacy
        {
            if let Some(id) = id.clone() {
                send_error(&stdout, id, -32002, "Server not initialized", None);
            }
            continue;
        }
        match method.as_str() {
            "notifications/initialized" | "initialized" => initialized_legacy = true,
            "notifications/cancelled" | "notifications/cancelled_request" => {}
            "server/discover" => {
                let result = json!({
                    "resultType": "complete",
                    "supportedVersions": [context::MODERN_PROTOCOL, "2025-11-25", "2025-06-18"],
                    "capabilities": {"tools": {"listChanged": false}},
                    "instructions": "This Core runtime has unrestricted access under the host macOS user. Prefer codex history tools over model turns. Browser work belongs to Browser Workspace.",
                    "ttlMs": 3_600_000,
                    "cacheScope": "private",
                    "_meta": meta()
                });
                send_result(&stdout, id, result);
            }
            "initialize" => {
                let requested = message
                    .pointer("/params/protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or("2025-11-25");
                let negotiated = if context::LEGACY_PROTOCOLS.contains(&requested) {
                    requested
                } else {
                    "2025-11-25"
                };
                let result = json!({
                    "protocolVersion": negotiated,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {
                        "name": context::SERVER_NAME,
                        "title": context::SERVER_TITLE,
                        "version": context::CORE_VERSION,
                        "description": "Unrestricted local shell, filesystem, process, patch, and Codex-history access on the host Mac."
                    },
                    "instructions": "This Core runtime runs without a filesystem sandbox or command allowlist. Effective permissions equal the macOS user running it. Browser work belongs to Browser Workspace."
                });
                send_result(&stdout, id, result);
            }
            "ping" => send_result(&stdout, id, complete(json!({}), modern(&message), None)),
            "tools/list" => {
                let cache = if modern(&message) {
                    Some((300_000_u64, "private"))
                } else {
                    None
                };
                send_result(
                    &stdout,
                    id,
                    complete(
                        json!({"tools": tools::tools(handlers.ptys.available())}),
                        modern(&message),
                        cache,
                    ),
                );
            }
            "tools/call" => {
                let mut pending = Vec::with_capacity(calls.len());
                for call in calls.drain(..) {
                    if call.is_finished() {
                        let _ = call.join();
                    } else {
                        pending.push(call);
                    }
                }
                calls = pending;
                let name = message
                    .pointer("/params/name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let arguments = message
                    .pointer("/params/arguments")
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                if name.is_empty() {
                    if let Some(id) = id.clone() {
                        send_error(
                            &stdout,
                            id,
                            -32602,
                            "Invalid params: tool name is required",
                            None,
                        );
                    }
                    continue;
                }
                if !tools::tools(handlers.ptys.available())
                    .iter()
                    .any(|tool| tool["name"].as_str() == Some(name.as_str()))
                {
                    if let Some(id) = id.clone() {
                        send_error(&stdout, id, -32601, format!("Unknown tool: {name}"), None);
                    }
                    continue;
                }
                let advertised = tools::tools(handlers.ptys.available());
                let schema = advertised
                    .iter()
                    .find(|tool| tool["name"].as_str() == Some(name.as_str()))
                    .map(|tool| &tool["inputSchema"]);
                if name == "apply_file_patch" {
                    let missing: Vec<_> = schema
                        .and_then(|s| s["required"].as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .filter(|key| {
                            !arguments
                                .get(*key)
                                .and_then(Value::as_str)
                                .is_some_and(|value| !value.trim().is_empty())
                        })
                        .collect();
                    if !missing.is_empty() {
                        if let Some(id) = id.clone() {
                            let required =
                                schema.map(|s| s["required"].clone()).unwrap_or(Value::Null);
                            send_error(&stdout, id, -32602,
                                format!("Invalid arguments for {name}: required non-empty parameter(s): {}", missing.join(", ")),
                                Some(json!({"missing":missing,"required":required})));
                        }
                        continue;
                    }
                }
                if let (Some(schema), Some(args)) = (schema, arguments.as_object()) {
                    if schema["additionalProperties"] == false {
                        let declared = schema["properties"].as_object();
                        let unknown: Vec<_> = args
                            .keys()
                            .filter(|key| !declared.is_some_and(|props| props.contains_key(*key)))
                            .map(String::as_str)
                            .collect();
                        if !unknown.is_empty() {
                            if let Some(id) = id.clone() {
                                let allowed: Vec<_> = declared
                                    .into_iter()
                                    .flat_map(|props| props.keys().map(String::as_str))
                                    .collect();
                                send_error(&stdout, id, -32602,
                                    format!("Invalid arguments for {name}: unknown parameter(s): {}. Allowed: {}", unknown.join(", "), allowed.join(", ")),
                                    Some(json!({"unknown":unknown,"allowed":allowed})));
                            }
                            continue;
                        }
                    }
                }
                if in_flight.fetch_add(1, Ordering::AcqRel) >= MAX_IN_FLIGHT_CALLS {
                    in_flight.fetch_sub(1, Ordering::AcqRel);
                    if let Some(id) = id.clone() {
                        send_error(&stdout, id, -32000, "Too many in-flight tool calls", None);
                    }
                    continue;
                }
                let modern_request = modern(&message);
                let call_handlers = handlers.clone();
                let call_stdout = stdout.clone();
                let call_in_flight = in_flight.clone();
                calls.push(std::thread::spawn(move || {
                    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        dispatch(&call_handlers, &name, &arguments)
                    }))
                    .unwrap_or_else(|_| Err(error::ToolError::new("internal tool panic")));
                    let result = match outcome {
                        Ok(value) => {
                            let is_error = name == "apply_file_patch"
                                && value
                                    .get("exitCode")
                                    .and_then(Value::as_i64)
                                    .is_some_and(|code| code != 0);
                            text_result(value, is_error, modern_request)
                        }
                        Err(tool_error) => text_result(tool_error.payload(), true, modern_request),
                    };
                    send_result(&call_stdout, id, result);
                    call_in_flight.fetch_sub(1, Ordering::AcqRel);
                }));
            }
            _ => {
                if let Some(id) = id.clone() {
                    send_error(
                        &stdout,
                        id,
                        -32601,
                        format!("Method not found: {method}"),
                        None,
                    );
                }
            }
        }
    }
    // Do not wait for an unbounded tool call: Node exits on transport close.
    drop(calls);
    cleanup(&handlers);
    std::process::exit(0);
}

fn dispatch(handlers: &Handlers, name: &str, arguments: &Value) -> error::ToolResult {
    match name {
        "status" => handlers.status(),
        "shell" => handlers.shell(arguments),
        "fs" => handlers.filesystem(arguments),
        "apply_file_patch" => handlers.patch(arguments),
        "codex" => handlers.codex(arguments),
        "discord" => handlers.discord(arguments),
        "chatgpt" => handlers.chatgpt(arguments),
        "terminal" => handlers.terminal(arguments),
        _ => Err(error::ToolError::new(format!("Unknown tool: {name}"))),
    }
}

fn modern(message: &Value) -> bool {
    message
        .get("params")
        .and_then(|params| params.get("_meta"))
        .and_then(|meta| meta.get("io.modelcontextprotocol/protocolVersion"))
        .and_then(Value::as_str)
        == Some(context::MODERN_PROTOCOL)
        || message.get("method").and_then(Value::as_str) == Some("server/discover")
}

fn meta() -> Value {
    json!({
        "io.modelcontextprotocol/serverInfo": {
            "name": context::SERVER_NAME,
            "title": context::SERVER_TITLE,
            "version": context::CORE_VERSION,
            "description": "Unrestricted local shell, filesystem, process, patch, and Codex-history access on the host Mac."
        }
    })
}

fn complete(mut payload: Value, modern_request: bool, cache: Option<(u64, &str)>) -> Value {
    if !modern_request {
        return payload;
    }
    let mut object = serde_json::Map::new();
    object.insert("resultType".to_string(), json!("complete"));
    if let Value::Object(fields) = &mut payload {
        for (key, value) in fields.iter() {
            object.insert(key.clone(), value.clone());
        }
    }
    if let Some((ttl, scope)) = cache {
        object.insert("ttlMs".to_string(), json!(ttl));
        object.insert("cacheScope".to_string(), json!(scope));
    }
    object.insert("_meta".to_string(), meta());
    Value::Object(object)
}

fn text_result(value: Value, is_error: bool, modern_request: bool) -> Value {
    let (text, structured) = match value {
        Value::String(text) => (text.clone(), json!({"text":text})),
        value => (
            serde_json::to_string_pretty(&value)
                .unwrap_or_else(|_| "\"serialization error\"".to_string()),
            value,
        ),
    };
    let content = json!({"content":[{"type":"text","text":text}],"structuredContent":structured,"isError":is_error});
    complete(content, modern_request, None)
}

fn send_result(stdout: &Arc<Mutex<()>>, id: Option<Value>, result: Value) {
    write_line(
        stdout,
        &json!({"jsonrpc":"2.0","id":id.unwrap_or(Value::Null),"result":result}),
    );
}

fn send_error(
    stdout: &Arc<Mutex<()>>,
    id: Value,
    code: i64,
    message: impl Into<String>,
    data: Option<Value>,
) {
    let mut error = json!({"code":code,"message":message.into()});
    if let Some(data) = data {
        error["data"] = data;
    }
    write_line(stdout, &json!({"jsonrpc":"2.0","id":id,"error":error}));
}

fn write_line(stdout: &Arc<Mutex<()>>, value: &Value) {
    let _guard = stdout
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut handle = std::io::stdout().lock();
    let _ = writeln!(handle, "{value}");
    let _ = handle.flush();
}

fn stderr_line(message: &str) {
    let mut handle = std::io::stderr().lock();
    let _ = writeln!(handle, "{message}");
}
