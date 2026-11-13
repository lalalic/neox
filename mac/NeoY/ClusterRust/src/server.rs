use crate::{
    config::Config,
    sessions::{resolve_cwd, Sessions},
};
use actix_web::{web, App, HttpResponse, HttpServer};
use serde_json::{json, Value};
use std::{fs, io, path::PathBuf, process::Command, sync::Arc};
const MAX_OUTPUT: usize = 4 * 1024 * 1024;

pub struct State {
    pub config: Config,
    pub sessions: Sessions,
}
fn field<'a>(v: &'a Value, key: &str, default: &'a str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or(default)
}
fn number(v: &Value, key: &str, default: u64) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(default)
}

fn tools(node: &str) -> Value {
    let p = |properties: Value, required: Vec<&str>| json!({"type":"object","properties":properties,"required":required});
    let names = vec![
        (
            "shell_exec",
            "Run a shell command.",
            p(
                json!({"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"integer"}}),
                vec!["command"],
            ),
        ),
        (
            "fs_read",
            "Read a UTF-8 file.",
            p(
                json!({"path":{"type":"string"},"max_bytes":{"type":"integer"}}),
                vec!["path"],
            ),
        ),
        (
            "fs_write",
            "Write a UTF-8 file.",
            p(
                json!({"path":{"type":"string"},"content":{"type":"string"},"append":{"type":"boolean"}}),
                vec!["path", "content"],
            ),
        ),
        (
            "fs_list",
            "List a directory.",
            p(
                json!({"path":{"type":"string"},"limit":{"type":"integer"}}),
                vec![],
            ),
        ),
        (
            "process_list",
            "List processes.",
            p(
                json!({"query":{"type":"string"},"limit":{"type":"integer"}}),
                vec![],
            ),
        ),
        (
            "shell_start",
            "Start a long-running shell command.",
            p(
                json!({"command":{"type":"string"},"cwd":{"type":"string"}}),
                vec!["command"],
            ),
        ),
        (
            "shell_poll",
            "Poll a shell session.",
            p(
                json!({"session_id":{"type":"string"},"wait_ms":{"type":"integer"}}),
                vec!["session_id"],
            ),
        ),
    ];
    json!(names.into_iter().map(|(name,description,input)|json!({"name":name,"description":format!("{description} Node: {node}."),"inputSchema":input})).collect::<Vec<_>>())
}
fn require<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing {key}"))
}
fn path(v: &str) -> PathBuf {
    resolve_cwd(v)
}
fn fs_read(v: &Value) -> Result<Value, String> {
    use std::io::Read;
    let p = path(require(v, "path")?);
    let limit = number(v, "max_bytes", MAX_OUTPUT as u64).clamp(1, MAX_OUTPUT as u64) as usize;
    let file = fs::File::open(&p).map_err(|e| e.to_string())?;
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    // Never buffer an unbounded media file to answer a bounded fs_read.
    let mut bytes = Vec::with_capacity(limit.min(8192));
    file.take(limit as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    Ok(json!({"path":p,"size":size,"truncated":size>limit as u64,
        "content":String::from_utf8_lossy(&bytes)}))
}

fn fs_write(v: &Value) -> Result<Value, String> {
    let p = path(require(v, "path")?);
    let content = require(v, "content")?;
    if let Some(parent) = p.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if v.get("append").and_then(Value::as_bool).unwrap_or(false) {
        use std::io::Write;
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&p)
            .map_err(|e| e.to_string())?;
        f.write_all(content.as_bytes()).map_err(|e| e.to_string())?;
    } else {
        let temp = p.with_extension(format!(
            "neo-temp-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::write(&temp, content.as_bytes()).map_err(|e| e.to_string())?;
        fs::rename(&temp, &p).map_err(|e| e.to_string())?;
    }
    Ok(
        json!({"path":p,"bytesWritten":content.len(),"append":v.get("append").and_then(Value::as_bool).unwrap_or(false)}),
    )
}
fn fs_list(v: &Value) -> Result<Value, String> {
    let p = path(field(v, "path", "~"));
    let limit = number(v, "limit", 500).clamp(1, 2000) as usize;
    let entries: Vec<_> = fs::read_dir(&p)
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    let out = entries
        .iter()
        .take(limit)
        .map(|e| {
            let t = e.file_type().ok();
            let kind = if t.as_ref().is_some_and(|x| x.is_dir()) {
                "directory"
            } else if t.as_ref().is_some_and(|x| x.is_file()) {
                "file"
            } else if t.as_ref().is_some_and(|x| x.is_symlink()) {
                "symlink"
            } else {
                "other"
            };
            json!({"name":e.file_name().to_string_lossy(),"type":kind})
        })
        .collect::<Vec<_>>();
    Ok(json!({"path":p,"entries":out,"truncated":entries.len()>limit}))
}
fn processes(v: &Value) -> Result<Value, String> {
    let result = Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid=,user=,stat=,%cpu=,%mem=,etime=,command="])
        .output()
        .map_err(|e| e.to_string())?;
    let query = field(v, "query", "").to_lowercase();
    let limit = number(v, "limit", 200).clamp(1, 1000) as usize;
    let rows = String::from_utf8_lossy(&result.stdout)
        .lines()
        .filter(|s| !s.is_empty() && (query.is_empty() || s.to_lowercase().contains(&query)))
        .take(limit + 1)
        .map(str::trim)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    Ok(
        json!({"processes":rows.iter().take(limit).collect::<Vec<_>>(),"truncated":rows.len()>=limit}),
    )
}
async fn call(state: &State, name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "shell_exec" => {
            state
                .sessions
                .exec(
                    require(args, "command")?,
                    field(args, "cwd", "~"),
                    number(args, "timeout_ms", 120_000),
                )
                .await
        }
        "shell_start" => state
            .sessions
            .start(require(args, "command")?, field(args, "cwd", "~")),
        "shell_poll" => {
            state
                .sessions
                .poll(require(args, "session_id")?, number(args, "wait_ms", 0))
                .await
        }
        "fs_read" => fs_read(args),
        "fs_write" => fs_write(args),
        "fs_list" => fs_list(args),
        "process_list" => processes(args),
        _ => Err(format!("unknown tool: {name}")),
    }
}
async fn mcp(body: web::Bytes, state: web::Data<Arc<State>>) -> HttpResponse {
    if body.len() > MAX_OUTPUT {
        return HttpResponse::PayloadTooLarge().finish();
    }
    let parsed: Value =
        match serde_json::from_slice(&body) {
            Ok(p) => p,
            Err(e) => return HttpResponse::BadRequest().json(
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":e.to_string()}}),
            ),
        };
    let id = parsed.get("id").cloned().unwrap_or(Value::Null);
    let method = parsed.get("method").and_then(Value::as_str).unwrap_or("");
    if method == "notifications/initialized" {
        return HttpResponse::Accepted().json(json!({}));
    }
    let result = match method {
        "initialize" => Ok(
            json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":format!("{}-neo-node",state.config.node_name),"version":"1.0.0"}}),
        ),
        "tools/list" => Ok(json!({"tools":tools(&state.config.node_name)})),
        "tools/call" => {
            let params = parsed.get("params").cloned().unwrap_or(Value::Null);
            let name = field(&params, "name", "");
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            call(&state,name,&args).await.map(|value|json!({"content":[{"type":"text","text":serde_json::to_string_pretty(&value).unwrap_or_default()}],"isError":false}))
        }
        _ => return HttpResponse::Ok().json(
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}),
        ),
    };
    match result {
        Ok(value) => HttpResponse::Ok().json(json!({"jsonrpc":"2.0","id":id,"result":value})),
        Err(message) => HttpResponse::InternalServerError()
            .json(json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":message}})),
    }
}
async fn health(state: web::Data<Arc<State>>) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(format!("ok {}\n", state.config.node_name))
}
pub async fn launch(state: Arc<State>) -> io::Result<actix_web::dev::Server> {
    let port = state.config.local_mcp_port;
    let server = HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(state.clone()))
            .app_data(web::PayloadConfig::new(MAX_OUTPUT))
            .route("/healthz", web::get().to(health))
            .route("/mcp", web::post().to(mcp))
    })
    .workers(2)
    .bind(("127.0.0.1", port))?
    .run();
    Ok(server)
}
pub async fn is_healthy(port: u16) -> bool {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    if let Ok(Ok(mut stream)) = tokio::time::timeout(
        std::time::Duration::from_millis(800),
        tokio::net::TcpStream::connect(("127.0.0.1", port)),
    )
    .await
    {
        if stream
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .await
            .is_ok()
        {
            let mut buf = [0u8; 128];
            if let Ok(Ok(n)) =
                tokio::time::timeout(std::time::Duration::from_millis(800), stream.read(&mut buf))
                    .await
            {
                return String::from_utf8_lossy(&buf[..n]).contains("200 OK");
            }
        }
    }
    false
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_seven_tools() {
        assert_eq!(tools("test").as_array().unwrap().len(), 7);
    }
}
