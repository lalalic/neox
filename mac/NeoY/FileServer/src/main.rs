//! NeoY's private static file-serving sidecar. Only the signed Swift gateway
//! exposes public URLs. Authentication/mount configuration stay with NeoY.
mod preview_media;

use actix_files::NamedFile;
use actix_web::{http::header, web, App, HttpRequest, HttpResponse, HttpServer};
use cap_std::ambient_authority;
use cap_std::fs::Dir;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Clone)]
struct State {
    token: String,
    mounts: PathBuf,
    static_root: Option<PathBuf>,
}

#[derive(Deserialize)]
struct Source {
    #[serde(rename = "originalPath")]
    original_path: String,
    #[serde(rename = "normalizedPath")]
    normalized_path: String,
    #[serde(default)]
    sampled: bool,
    #[serde(default, rename = "startSeconds")]
    start_seconds: Option<f64>,
    #[serde(default, rename = "durationSeconds")]
    duration_seconds: Option<f64>,
}

#[derive(Deserialize)]
struct Manifest {
    sources: Vec<Source>,
}

fn public_components(path: &str) -> Option<Vec<&str>> {
    if path.is_empty() || path.contains('\\') || path.contains('\0') || path.len() > 4096 {
        return None;
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts
        .iter()
        .any(|p| p.is_empty() || *p == "." || *p == ".." || p.starts_with('.'))
    {
        return None;
    }
    Some(parts)
}

fn proxy_components(path: &str) -> Option<Vec<&str>> {
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() < 4 || parts[0] != "input" || parts[1] != "media" || parts[2] != ".normalized" {
        return None;
    }
    if parts.iter().enumerate().any(|(i, p)| {
        p.is_empty()
            || *p == "."
            || *p == ".."
            || p.contains('\\')
            || p.contains('\0')
            || (p.starts_with('.') && i != 2)
    }) {
        return None;
    }
    Some(parts)
}

fn mounted_root(state: &State, mount: &str) -> Option<PathBuf> {
    if mount.is_empty()
        || mount.len() > 64
        || !mount
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        || mount == "_neoy"
    {
        return None;
    }
    let bytes = fs::read(&state.mounts).ok()?;
    if bytes.len() > 64 * 1024 {
        return None;
    }
    let mounts: HashMap<String, String> = serde_json::from_slice(&bytes).ok()?;
    let root = mounts.get(mount)?;
    if !root.starts_with('/') {
        return None;
    }
    Some(PathBuf::from(root))
}

fn load_manifest(dir: &Dir, path: &Path) -> Option<Manifest> {
    let file = dir.open(path).ok()?;
    if file.metadata().ok()?.len() > 2 * 1024 * 1024 {
        return None;
    }
    let mut json = String::new();
    file.take(2 * 1024 * 1024).read_to_string(&mut json).ok()?;
    serde_json::from_str(&json).ok()
}

fn resolve_preview(dir: &Dir, relative: &str, clip: Option<preview_media::Clip>) -> Option<String> {
    let components = public_components(relative)?;
    // Find the nearest run-root manifest, never walking above this mount.
    for depth in (0..components.len()).rev() {
        let directory = components[..depth].join("/");
        let manifest_path = if directory.is_empty() {
            PathBuf::from("vision-normalized-manifest.json")
        } else {
            PathBuf::from(&directory).join("vision-normalized-manifest.json")
        };
        if let Some(manifest) = load_manifest(dir, &manifest_path) {
            let original = components[depth..].join("/");
            let source = manifest
                .sources
                .into_iter()
                // Sampled Vision files are not timeline-faithful video proxies.
                .find(|s| {
                    if s.original_path != original || s.sampled {
                        return false;
                    }
                    match (clip, s.start_seconds, s.duration_seconds) {
                        (None, None, None) => true,
                        (Some(c), Some(start), Some(duration)) => {
                            (c.start - start).abs() < 0.01 && (c.duration - duration).abs() < 0.01
                        }
                        _ => false,
                    }
                })?;
            proxy_components(&source.normalized_path)?;
            let proxy = if directory.is_empty() {
                source.normalized_path
            } else {
                format!("{directory}/{}", source.normalized_path)
            };
            let handle = dir.open(&proxy).ok()?;
            if handle.metadata().ok()?.is_file() {
                return Some(proxy);
            }
            return None;
        }
    }
    None
}

fn mimetype(path: &str) -> mime::Mime {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let format = match ext.as_str() {
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "wav" => "audio/wav",
        "mp3" => "audio/mpeg",
        "m4a" | "aac" => "audio/mp4",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "heic" => "image/heic",
        "webp" => "image/webp",
        "json" => "application/json",
        "md" => "text/markdown; charset=utf-8",
        "svg" => "image/svg+xml",
        "srt" => "text/plain",
        "html" | "htm" => "text/html",
        "js" => "application/javascript",
        "css" => "text/css",
        _ => "application/octet-stream",
    };
    format.parse().expect("static MIME is valid")
}

fn denied(code: actix_web::http::StatusCode) -> HttpResponse {
    HttpResponse::build(code)
        .insert_header((header::ACCESS_CONTROL_ALLOW_ORIGIN, "*"))
        .insert_header(("Cross-Origin-Resource-Policy", "cross-origin"))
        .insert_header(("X-Content-Type-Options", "nosniff"))
        .finish()
}

async fn handle(req: HttpRequest, state: web::Data<State>) -> HttpResponse {
    if req
        .headers()
        .get("x-neo-file-token")
        .and_then(|v| v.to_str().ok())
        != Some(state.token.as_str())
    {
        return denied(actix_web::http::StatusCode::FORBIDDEN);
    }
    if req.path() == "/__health" {
        return HttpResponse::Ok().body("ready");
    }
    if req.method() != actix_web::http::Method::GET && req.method() != actix_web::http::Method::HEAD
    {
        return denied(actix_web::http::StatusCode::METHOD_NOT_ALLOWED);
    }
    let uri_path = req.uri().path();
    let (route, raw) = if let Some(v) = uri_path.strip_prefix("/preview-files/") {
        ("preview", v)
    } else if let Some(v) = uri_path.strip_prefix("/files/") {
        ("files", v)
    } else if let Some(v) = uri_path.strip_prefix("/public/") {
        ("public", v)
    } else {
        return denied(actix_web::http::StatusCode::NOT_FOUND);
    };
    let decoded = match percent_encoding::percent_decode_str(raw).decode_utf8() {
        Ok(s) => s,
        Err(_) => return denied(actix_web::http::StatusCode::FORBIDDEN),
    };
    let Some(components) = public_components(&decoded) else {
        return denied(actix_web::http::StatusCode::FORBIDDEN);
    };
    let (root, rel) = if route != "public" && components.len() >= 2 {
        if let Some(root) = mounted_root(&state, components[0]) {
            (Some(root), components[1..].join("/"))
        } else if route == "preview" {
            (None, String::new())
        } else {
            (state.static_root.clone(), decoded.to_string())
        }
    } else if route == "preview" {
        (None, String::new())
    } else {
        (state.static_root.clone(), decoded.to_string())
    };
    let Some(root) = root else {
        return denied(actix_web::http::StatusCode::NOT_FOUND);
    };
    let dir = match Dir::open_ambient_dir(&root, ambient_authority()) {
        Ok(d) => d,
        Err(_) => return denied(actix_web::http::StatusCode::NOT_FOUND),
    };
    let clip = if route == "preview" {
        match preview_media::parse_clip(req.uri().query().unwrap_or("")) {
            Ok(clip) => clip,
            Err(_) => return denied(actix_web::http::StatusCode::BAD_REQUEST),
        }
    } else {
        None
    };
    let selected = if route == "preview" {
        resolve_preview(&dir, &rel, clip).unwrap_or_else(|| rel.clone())
    } else {
        rel.clone()
    };
    // Only the manifest-selected proxy can contain the internal .normalized dir.
    if selected != rel && proxy_components(&selected).is_none() {
        let segs = selected.split('/').collect::<Vec<_>>();
        if segs.iter().filter(|s| **s == ".normalized").count() != 1 {
            return denied(actix_web::http::StatusCode::FORBIDDEN);
        }
    }
    let file = match dir.open(&selected) {
        Ok(f) => f,
        Err(_) => return denied(actix_web::http::StatusCode::NOT_FOUND),
    };
    if !file.metadata().is_ok_and(|m| m.is_file()) {
        return denied(actix_web::http::StatusCode::NOT_FOUND);
    }
    // Unknown sources or requested time slices get a bounded-bandwidth cached
    // preview. Clip output starts at 0; the client requested this interval as
    // its media source. If conversion fails, never substitute a wrong interval.
    let source = root.join(&rel);
    let candidate = if route == "preview" && selected == rel {
        if let Some(cache) = preview_media::cache_dir(&state.mounts) {
            let root_copy = root.clone();
            let work = actix_web::rt::task::spawn_blocking(move || {
                preview_media::cached_proxy(&source, &root_copy, &cache, clip)
            });
            work.await.ok().flatten()
        } else {
            None
        }
    } else {
        None
    };
    if clip.is_some() && selected == rel && candidate.is_none() {
        // Returning the entire original for a requested time slice would be incorrect.
        return denied(actix_web::http::StatusCode::SERVICE_UNAVAILABLE);
    }
    let proxy_used = candidate.is_some();
    let selected_file = candidate
        .and_then(|p| fs::File::open(p).ok())
        .unwrap_or_else(|| file.into_std());
    // NamedFile::from_file serves an already opened file descriptor. In the
    // proxy case the cache is private and not inside any exposed file mount.
    match NamedFile::from_file(selected_file, &selected) {
        Ok(named) => {
            let length = named.file().metadata().ok().map(|m| m.len());
            let mut response = named
                .set_content_type(if proxy_used {
                    mimetype("preview.mp4")
                } else {
                    mimetype(&selected)
                })
                .disable_content_disposition()
                .into_response(&req);
            if req.method() == actix_web::http::Method::HEAD
                && req.headers().get(header::RANGE).is_none()
                && !response.headers().contains_key(header::CONTENT_LENGTH)
            {
                if let Some(length) = length {
                    if let Ok(value) = header::HeaderValue::from_str(&length.to_string()) {
                        response.headers_mut().insert(header::CONTENT_LENGTH, value);
                    }
                }
            }
            response.headers_mut().insert(
                header::ACCESS_CONTROL_ALLOW_ORIGIN,
                header::HeaderValue::from_static("*"),
            );
            response.headers_mut().insert(
                header::HeaderName::from_static("cross-origin-resource-policy"),
                header::HeaderValue::from_static("cross-origin"),
            );
            response.headers_mut().insert(
                header::HeaderName::from_static("x-content-type-options"),
                header::HeaderValue::from_static("nosniff"),
            );
            response
        }
        Err(_) => denied(actix_web::http::StatusCode::INTERNAL_SERVER_ERROR),
    }
}

fn main_args() -> Result<(u16, PathBuf, Option<PathBuf>, String), String> {
    let args: Vec<String> = std::env::args().collect();
    let mut port = None;
    let mut mounts = None;
    let mut root = None;
    let mut i = 1;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--port" => port = args[i + 1].parse().ok(),
            "--mounts" => mounts = Some(PathBuf::from(&args[i + 1])),
            "--static-root" => root = Some(PathBuf::from(&args[i + 1])),
            _ => return Err("unexpected argument".into()),
        }
        i += 2;
    }
    let secret = std::env::var("NEOY_FILE_SERVER_TOKEN").map_err(|_| "missing private token")?;
    if secret.len() < 32 {
        return Err("invalid private token".into());
    }
    Ok((
        port.ok_or("--port missing")?,
        mounts.ok_or("--mounts missing")?,
        root,
        secret,
    ))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let (port, mounts, static_root, token) = main_args().map_err(std::io::Error::other)?;
    let state = State {
        token,
        mounts,
        static_root,
    };
    let parent = unsafe { libc::getppid() };
    actix_web::rt::spawn(async move {
        loop {
            actix_web::rt::time::sleep(std::time::Duration::from_secs(3)).await;
            if unsafe { libc::getppid() } != parent {
                std::process::exit(0)
            }
        }
    });
    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(state.clone()))
            .default_service(web::to(handle))
    })
    .workers(4)
    .disable_signals()
    .keep_alive(None)
    .bind(("127.0.0.1", port))?
    .run()
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::{http::StatusCode, test};
    use tempfile::TempDir;

    fn fixture() -> (TempDir, State) {
        let temp = tempfile::tempdir().unwrap();
        let mount = temp.path().join("mounted");
        let static_root = temp.path().join("public");
        fs::create_dir_all(mount.join("run/input/media/.normalized")).unwrap();
        fs::create_dir_all(&static_root).unwrap();
        fs::write(
            mount.join("run/input/media/original.mp4"),
            b"original-video-content",
        )
        .unwrap();
        fs::write(
            mount.join("run/input/media/.normalized/proxy.mp4"),
            b"proxy-video-content",
        )
        .unwrap();
        fs::write(static_root.join("public.txt"), b"public-static-content").unwrap();
        fs::write(mount.join("run/vision-normalized-manifest.json"),
            r#"{"sources":[{"originalPath":"input/media/original.mp4","normalizedPath":"input/media/.normalized/proxy.mp4"}]}"#).unwrap();
        let mounts = temp.path().join("mounts.json");
        fs::write(&mounts, serde_json::json!({"media":mount}).to_string()).unwrap();
        (
            temp,
            State {
                token: "testsecret123456789012345678901234".into(),
                mounts,
                static_root: Some(static_root),
            },
        )
    }

    #[actix_web::test]
    async fn supports_public_files_head_range_and_conditional_requests() {
        let (_temp, state) = fixture();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let req = test::TestRequest::get()
            .uri("/files/media/run/input/media/original.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .insert_header((header::RANGE, "bytes=2-9"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(
            res.headers().get(header::CONTENT_RANGE).unwrap(),
            "bytes 2-9/22"
        );
        let bytes = test::read_body(res).await;
        assert_eq!(&bytes[..], b"iginal-v");
        let req = test::TestRequest::get()
            .uri("/public/public.txt")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        let etag = res
            .headers()
            .get(header::ETAG)
            .unwrap()
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(
            res.headers()
                .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
                .unwrap(),
            "*"
        );
        let bytes = test::read_body(res).await;
        assert_eq!(&bytes[..], b"public-static-content");
        let req = test::TestRequest::get()
            .uri("/public/public.txt")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .insert_header((header::IF_NONE_MATCH, etag))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::NOT_MODIFIED);
        let req = test::TestRequest::default()
            .method(actix_web::http::Method::HEAD)
            .uri("/public/public.txt")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(res.headers().get(header::CONTENT_LENGTH).unwrap(), "21");
        // Actix's network transport suppresses HEAD body bytes at the wire.
        // This unit-level responder intentionally retains NamedFile's body size.
        let _ = res;
        let req = test::TestRequest::get()
            .uri("/public/public.txt")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .insert_header((header::RANGE, "bytes=9999-10000"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    }

    #[actix_web::test]
    async fn preview_selects_normalized_media_with_original_fallback() {
        let (_temp, state) = fixture();
        let root =
            serde_json::from_slice::<HashMap<String, String>>(&fs::read(&state.mounts).unwrap())
                .unwrap()["media"]
                .clone();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/original.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(&test::read_body(res).await[..], b"proxy-video-content");
        fs::remove_file(Path::new(&root).join("run/input/media/.normalized/proxy.mp4")).unwrap();
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/original.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(&test::read_body(res).await[..], b"original-video-content");
    }

    #[actix_web::test]
    async fn uses_only_an_exact_time_segment_and_avoids_sampled_proxies() {
        let (_temp, state) = fixture();
        let root =
            serde_json::from_slice::<HashMap<String, String>>(&fs::read(&state.mounts).unwrap())
                .unwrap()["media"]
                .clone();
        let base = Path::new(&root);
        fs::write(
            base.join("run/input/media/long.mp4"),
            b"unmodified-full-file",
        )
        .unwrap();
        fs::write(
            base.join("run/input/media/.normalized/segment.mp4"),
            b"exact-clip",
        )
        .unwrap();
        fs::write(
            base.join("run/input/media/.normalized/sample.mp4"),
            b"sampled-clip",
        )
        .unwrap();
        fs::write(base.join("run/vision-normalized-manifest.json"), r#"{"sources":[
            {"originalPath":"input/media/long.mp4","normalizedPath":"input/media/.normalized/segment.mp4","startSeconds":10,"durationSeconds":4},
            {"originalPath":"input/media/original.mp4","normalizedPath":"input/media/.normalized/sample.mp4","sampled":true}
        ]}"#).unwrap();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let uri = "/preview-files/media/run/input/media/long.mp4?startSeconds=10&durationSeconds=4";
        let req = test::TestRequest::get()
            .uri(uri)
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(&test::read_body(res).await[..], b"exact-clip");
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/long.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(&test::read_body(res).await[..], b"unmodified-full-file");
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/original.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(&test::read_body(res).await[..], b"original-video-content");
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/long.mp4?startSeconds=9&durationSeconds=4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[actix_web::test]
    async fn denies_traversal_hidden_files_symlinks_and_unauthorized_requests() {
        let (temp, state) = fixture();
        let foreign = temp.path().join("secret.txt");
        fs::write(&foreign, b"must-not-serve").unwrap();
        let root =
            serde_json::from_slice::<HashMap<String, String>>(&fs::read(&state.mounts).unwrap())
                .unwrap()["media"]
                .clone();
        std::os::unix::fs::symlink(&foreign, Path::new(&root).join("escape.txt")).unwrap();
        fs::write(Path::new(&root).join(".private"), b"private").unwrap();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        for uri in [
            "/files/media/../secret.txt",
            "/files/media/%2eprivate",
            "/files/media/escape.txt",
            "/preview-files/media/../../secret.txt",
            "/files/media/%5csecret.txt",
        ] {
            let req = test::TestRequest::get()
                .uri(uri)
                .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
                .to_request();
            let res = test::call_service(&app, req).await;
            assert!(
                res.status() == StatusCode::FORBIDDEN || res.status() == StatusCode::NOT_FOUND,
                "{uri}: {}",
                res.status()
            );
        }
        let req = test::TestRequest::get()
            .uri("/files/media/run/input/media/original.mp4")
            .to_request();
        assert_eq!(
            test::call_service(&app, req).await.status(),
            StatusCode::FORBIDDEN
        );
    }
}
