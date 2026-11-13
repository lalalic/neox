//! NeoY's private static file-serving sidecar. Only the signed Swift gateway
//! exposes public URLs. Authentication/mount configuration stay with NeoY.
mod preview_media;

use actix_files::NamedFile;
use actix_web::{http::header, web, App, HttpRequest, HttpResponse, HttpServer};
use cap_std::ambient_authority;
use cap_std::fs::Dir;
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

// The only proxy index is Markcut's source-folder metadata.json.
type MediaMetadata = HashMap<String, serde_json::Value>;

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

fn load_metadata(dir: &Dir, path: &Path) -> Option<MediaMetadata> {
    let file = dir.open(path).ok()?;
    if file.metadata().ok()?.len() > 4 * 1024 * 1024 {
        return None;
    }
    let mut json = String::new();
    file.take(4 * 1024 * 1024).read_to_string(&mut json).ok()?;
    serde_json::from_str(&json).ok()
}

fn segment_base<'a>(name: &str, metadata: &'a MediaMetadata) -> Option<&'a str> {
    // Editor convention: <raw filename>-<startMs>to<endMs>.mp4.
    // The source extension is retained so filenames cannot collide.
    for filename in metadata.keys() {
        if !name.starts_with(&format!("{filename}-")) || !name.ends_with(".mp4") {
            continue;
        }
        let range = &name[filename.len() + 1..name.len() - 4];
        if let Some((start, end)) = range.split_once("to") {
            if let (Ok(start), Ok(end)) = (start.parse::<u64>(), end.parse::<u64>()) {
                if end > start {
                    return Some(filename.as_str());
                }
            }
        }
    }
    None
}

fn resolve_preview(dir: &Dir, relative: &str) -> Option<String> {
    let components = public_components(relative)?;
    let name = *components.last()?;
    for depth in (0..components.len()).rev() {
        let prefix = components[..depth].join("/");
        // Metadata lives beside original media; extracted clips may live elsewhere in a run.
        for media_dir in [
            prefix.clone(),
            if prefix.is_empty() {
                "input/media".into()
            } else {
                format!("{prefix}/input/media")
            },
        ] {
            let path = PathBuf::from(&media_dir).join("metadata.json");
            let Some(metadata) = load_metadata(dir, &path) else {
                continue;
            };
            let (source_name, derived) = if metadata.contains_key(name) {
                (name, false)
            } else if let Some(raw) = segment_base(name, &metadata) {
                (raw, true)
            } else {
                continue;
            };
            let entry = metadata.get(source_name)?;
            let proxy = if derived {
                // Do not trim or transcode here. Only an existing, same-range
                // normalized segment is valid for an extracted Editor clip.
                let full = entry.get("normalized")?.as_str()?;
                if !full.starts_with(".normalized/") {
                    continue;
                }
                format!("{media_dir}/.normalized/{name}")
            } else {
                // Only direct sources in this media folder can use this entry.
                if relative != format!("{media_dir}/{name}")
                    && !(media_dir.is_empty() && relative == name)
                {
                    continue;
                }
                let path = entry.get("normalized")?.as_str()?;
                if !path.starts_with(".normalized/") {
                    continue;
                }
                format!("{media_dir}/{path}")
            };
            let normalized_rel = proxy
                .strip_prefix(&format!("{media_dir}/"))
                .unwrap_or(&proxy);
            let parts: Vec<_> = normalized_rel.split('/').collect();
            if parts.len() != 2
                || parts[0] != ".normalized"
                || parts[1].is_empty()
                || parts[1].starts_with('.')
                || parts[1].contains('\\')
                || parts[1].contains('\0')
                || parts[1] == ".."
            {
                continue;
            }
            if let Ok(handle) = dir.open(&proxy) {
                if handle
                    .metadata()
                    .ok()
                    .is_some_and(|m| m.is_file() && m.len() > 0)
                {
                    return Some(proxy);
                }
            }
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
        } else if route == "preview"
            && components.len() >= 5
            && components[0] == "_neoy"
            && components[1] == "markcut"
            && components[2] == "generated"
        {
            // Markcut snapshots media under the existing public export root,
            // not under a user mount. Only generated media may use this route.
            (state.static_root.clone(), decoded.to_string())
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
    if route == "preview" {
        // An explicit time slice cannot be served without conversion. The
        // Editor creates named clips; callers must seek locally for raw files.
        match preview_media::parse_clip(req.uri().query().unwrap_or("")) {
            Ok(None) => (),
            _ => return denied(actix_web::http::StatusCode::BAD_REQUEST),
        }
    }
    let selected = if route == "preview" {
        resolve_preview(&dir, &rel).unwrap_or_else(|| rel.clone())
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
    // Read-only lookup: no transcoding, slicing, file writes, or hidden cache.
    // Missing normalized files fall back to the exact requested source.
    let selected_file = file.into_std();
    // NamedFile::from_file serves an already opened file descriptor. In the
    // proxy case the cache is private and not inside any exposed file mount.
    match NamedFile::from_file(selected_file, &selected) {
        Ok(named) => {
            let length = named.file().metadata().ok().map(|m| m.len());
            let mut response = named
                .set_content_type(mimetype(&selected))
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
            if route == "preview" {
                // Preview URLs can change their target when Visioner normalizes
                // media or a new proxy is created. Never let CDN cache a stale
                // original under the same video path.
                response.headers_mut().insert(
                    header::CACHE_CONTROL,
                    header::HeaderValue::from_static("no-store, max-age=0"),
                );
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
        fs::write(mount.join("run/input/media/photo.heic"), b"raw-heic").unwrap();
        fs::write(
            mount.join("run/input/media/.normalized/photo.heic_384.jpg"),
            b"normalized-jpeg",
        )
        .unwrap();
        fs::create_dir_all(mount.join("run/assets/clips")).unwrap();
        fs::write(
            mount.join("run/assets/clips/original.mp4-1000to2500.mp4"),
            b"segment-original",
        )
        .unwrap();
        fs::write(
            mount.join("run/input/media/.normalized/original.mp4-1000to2500.mp4"),
            b"segment-proxy",
        )
        .unwrap();
        fs::write(static_root.join("public.txt"), b"public-static-content").unwrap();
        let exported = static_root.join("_neoy/markcut/generated/fixture");
        fs::create_dir_all(&exported).unwrap();
        fs::write(exported.join("clip.mp4"), b"exported-preview-source").unwrap();
        fs::write(mount.join("run/input/media/metadata.json"),
            r#"{"original.mp4":{"normalized":".normalized/proxy.mp4"},"photo.heic":{"normalized":".normalized/photo.heic_384.jpg"}}"#).unwrap();
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
    async fn supports_markcut_generated_preview_with_strict_namespace() {
        let (_temp, state) = fixture();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let token = "testsecret123456789012345678901234";
        let original = "/files/_neoy/markcut/generated/fixture/clip.mp4";
        let preview = "/preview-files/_neoy/markcut/generated/fixture/clip.mp4?pv=1234567890abcdef";
        for path in [original, preview] {
            let req = test::TestRequest::get()
                .uri(path)
                .insert_header(("x-neo-file-token", token))
                .to_request();
            let res = test::call_service(&app, req).await;
            assert_eq!(res.status(), StatusCode::OK, "{path}");
            if path == preview {
                assert!(res
                    .headers()
                    .get(header::CACHE_CONTROL)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .contains("no-store"));
            }
            assert_eq!(&test::read_body(res).await[..], b"exported-preview-source");
        }
        for path in [
            "/preview-files/_neoy/markcut/player/sneaky.mp4",
            "/preview-files/_neoy/markcut/cache/sneaky.mp4",
            "/preview-files/_neoy/other/fixture/clip.mp4",
            "/preview-files/_neoy/markcut/generated/fixture/%2e%2e/clip.mp4",
        ] {
            let req = test::TestRequest::get()
                .uri(path)
                .insert_header(("x-neo-file-token", token))
                .to_request();
            let res = test::call_service(&app, req).await;
            assert!(res.status().is_client_error(), "{path}: {}", res.status());
        }
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
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/assets/clips/original.mp4-1000to2500.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(&test::read_body(res).await[..], b"segment-proxy");
        fs::remove_file(
            Path::new(&root).join("run/input/media/.normalized/original.mp4-1000to2500.mp4"),
        )
        .unwrap();
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/assets/clips/original.mp4-1000to2500.mp4")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(&test::read_body(res).await[..], b"segment-original");
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
    async fn preview_does_not_transcode_or_trim_on_query_range() {
        let (_temp, state) = fixture();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/original.mp4?startSeconds=1&durationSeconds=2")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn preview_maps_images_without_converting() {
        let (_temp, state) = fixture();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(state))
                .default_service(web::to(handle)),
        )
        .await;
        let req = test::TestRequest::get()
            .uri("/preview-files/media/run/input/media/photo.heic")
            .insert_header(("x-neo-file-token", "testsecret123456789012345678901234"))
            .to_request();
        let res = test::call_service(&app, req).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(
            res.headers().get(header::CONTENT_TYPE).unwrap(),
            "image/jpeg"
        );
        assert_eq!(&test::read_body(res).await[..], b"normalized-jpeg");
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
