mod context;
mod error;
mod handlers;
mod jobs;
mod pty;
mod tools;

use context::Context;
use handlers::Handlers;
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

const MAX_IN_FLIGHT_CALLS: usize = 32;

fn main() {
    let context = match Context::from_env() {
        Ok(context) => context,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    };
    let handlers = Arc::new(Handlers::new(context.clone()));
    stderr_line(&format!(
        "{} {} started (pid {})",
        context::SERVER_NAME,
        context::CORE_VERSION,
        std::process::id()
    ));

    let watcher = handlers.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(3));
        watcher.ptys.expire_sessions();
        if !watcher.context.unlocked() {
            handlers::kill_in_flight_commands();
            jobs::kill_in_flight_exec_groups();
            watcher.ptys.teardown_all();
            eprintln!(
                "Full-access unlock revoked ({}); reclaiming PTY sessions and exiting.",
                watcher.context.unlock_file.display()
            );
            std::process::exit(0);
        }
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
                    "error": {"code": -32700, "message": "Parse error", "data": error.to_string()}
                });
                write_line(&stdout, &response);
                continue;
            }
        };
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
                    complete(json!({"tools": tools::tools()}), modern(&message), cache),
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
                if !tools::tools()
                    .iter()
                    .any(|tool| tool["name"].as_str() == Some(name.as_str()))
                {
                    if let Some(id) = id.clone() {
                        send_error(&stdout, id, -32601, format!("Unknown tool: {name}"), None);
                    }
                    continue;
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
                        Ok(value) => text_result(value, false, modern_request),
                        Err(tool_error) => text_result(tool_error.payload(), true, modern_request),
                    };
                    if id.is_some() {
                        send_result(&call_stdout, id, result);
                    }
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
    for call in calls {
        let _ = call.join();
    }
    handlers.ptys.teardown_all();
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
        .pointer("/params/_meta/io.modelcontextprotocol/protocolVersion")
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
    let text = serde_json::to_string_pretty(&value)
        .unwrap_or_else(|_| "\"serialization error\"".to_string());
    let content = json!({"content":[{"type":"text","text":text}],"structuredContent":value,"isError":is_error});
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
