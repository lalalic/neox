//! Preview-only proxy selection. Preserve the requested media's time axis:
//! exact, unsampled normalized sources may be reused; clips and unmatched
//! files get their own small, cached H.264 preview. The original stays intact.
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Clip {
    pub start: f64,
    pub duration: f64,
}

/// A clip is a time slice of its source, not a byte range. Keep it explicit.
pub fn parse_clip(query: &str) -> Result<Option<Clip>, ()> {
    if query.is_empty() {
        return Ok(None);
    }
    let mut start = None;
    let mut duration = None;
    let mut version_seen = false;
    for field in query.split('&') {
        let (key, value) = field.split_once('=').ok_or(())?;
        if key == "pv" {
            if version_seen || value.len() != 16 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(());
            }
            version_seen = true;
            continue;
        }
        let value = value.parse::<f64>().map_err(|_| ())?;
        if !value.is_finite() {
            return Err(());
        }
        match key {
            "startSeconds" if start.is_none() && (0.0..=86400.0).contains(&value) => {
                start = Some(value)
            }
            "durationSeconds"
                if duration.is_none() && (0.0..=600.0).contains(&value) && value > 0.0 =>
            {
                duration = Some(value)
            }
            _ => return Err(()),
        }
    }
    match (start, duration) {
        (None, None) if version_seen => Ok(None),
        (Some(start), Some(duration)) if start + duration <= 86400.0 => {
            Ok(Some(Clip { start, duration }))
        }
        _ => Err(()),
    }
}

pub fn cache_dir(mounts: &Path) -> Option<PathBuf> {
    Some(mounts.parent()?.join("preview-media-cache"))
}

/// Invoked only for a mounted, capability-checked source with a video extension.
/// False/failed conversions are never cached; the caller serves the original.
pub fn cached_proxy(
    source: &Path,
    root: &Path,
    cache: &Path,
    clip: Option<Clip>,
) -> Option<PathBuf> {
    let canonical_root = fs::canonicalize(root).ok()?;
    let canonical_source = fs::canonicalize(source).ok()?;
    if !canonical_source.starts_with(&canonical_root) || canonical_source == canonical_root {
        return None;
    }
    let ext = canonical_source.extension()?.to_str()?.to_ascii_lowercase();
    if !["mp4", "mov", "m4v", "webm"].contains(&ext.as_str()) {
        return None;
    }
    let metadata = fs::metadata(&canonical_source).ok()?;
    if !metadata.is_file() || (clip.is_none() && metadata.len() < 3 * 1024 * 1024) {
        return None;
    }
    let mut hasher = DefaultHasher::new();
    canonical_source.hash(&mut hasher);
    metadata.len().hash(&mut hasher);
    metadata
        .modified()
        .ok()?
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()?
        .as_nanos()
        .hash(&mut hasher);
    clip.map(|c| (c.start.to_bits(), c.duration.to_bits()))
        .hash(&mut hasher);
    let name = format!("{:016x}.mp4", hasher.finish());
    let target = cache.join(name);
    if target.metadata().is_ok_and(|m| m.is_file() && m.len() > 0) {
        return Some(target);
    }
    fs::create_dir_all(cache).ok()?;
    fs::set_permissions(cache, fs::Permissions::from_mode(0o700)).ok()?;
    let lock = target.with_extension("lock");
    if lock
        .metadata()
        .ok()
        .and_then(|m| m.modified().ok())
        .is_some_and(|t| t.elapsed().is_ok_and(|age| age > Duration::from_secs(180)))
    {
        let _ = fs::remove_file(&lock);
    }
    let locked = OpenOptions::new().write(true).create_new(true).open(&lock);
    if locked.is_err() {
        // A concurrent preview may already be preparing the same immutable file.
        for _ in 0..60 {
            if target.metadata().is_ok_and(|m| m.is_file() && m.len() > 0) {
                return Some(target);
            }
            if !lock.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        // Never serve a partial conversion or block the user's original indefinitely.
        return None;
    }
    let staging = target.with_extension("partial.mp4");
    let result = (|| {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .into_iter()
            .find(|p| Path::new(p).is_file())?;
        let mut command = Command::new(ffmpeg);
        command
            .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i"])
            .arg(&canonical_source);
        if let Some(clip) = clip {
            // Accurate output trim, not approximate keyframe seeking.
            command.args([
                "-ss",
                &clip.start.to_string(),
                "-t",
                &clip.duration.to_string(),
            ]);
        }
        command
            .args([
                "-map",
                "0:v:0",
                "-map",
                "0:a:0?",
                "-vf",
                "scale=720:720:force_original_aspect_ratio=decrease:force_divisible_by=2",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "27",
                "-maxrate",
                "1800k",
                "-bufsize",
                "3600k",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "96k",
                "-movflags",
                "+faststart",
                "-f",
                "mp4",
            ])
            .arg(&staging)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = command.spawn().ok()?;
        let started = std::time::Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(result)) => break result,
                Ok(None) if started.elapsed() < Duration::from_secs(120) => {
                    std::thread::sleep(Duration::from_millis(100))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
            }
        };
        if !status.success() || !staging.metadata().is_ok_and(|m| m.len() > 0) {
            return None;
        }
        fs::rename(&staging, &target).ok()?;
        Some(target)
    })();
    let _ = fs::remove_file(staging);
    let _ = fs::remove_file(lock);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shrinks_an_exact_video_segment_without_changing_the_original() {
        if !Path::new("/opt/homebrew/bin/ffmpeg").exists()
            && !Path::new("/usr/local/bin/ffmpeg").exists()
        {
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let source = tmp.path().join("source.mp4");
        let status = Command::new("/opt/homebrew/bin/ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=1280x720:rate=24",
                "-t",
                "4",
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-y",
            ])
            .arg(&source)
            .status()
            .unwrap();
        assert!(status.success());
        let clip = Clip {
            start: 1.0,
            duration: 1.5,
        };
        let proxy =
            cached_proxy(&source, tmp.path(), &tmp.path().join("cache"), Some(clip)).unwrap();
        assert!(proxy.metadata().unwrap().len() > 1000);
        assert!(proxy.metadata().unwrap().len() < source.metadata().unwrap().len());
        assert_eq!(
            cached_proxy(&source, tmp.path(), &tmp.path().join("cache"), Some(clip)),
            Some(proxy.clone())
        );
        let probe = Command::new("/opt/homebrew/bin/ffprobe")
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
            ])
            .arg(proxy)
            .output()
            .unwrap();
        let duration: f64 = String::from_utf8(probe.stdout)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(
            (duration - 1.5).abs() < 0.15,
            "segment duration was {duration}"
        );
    }

    #[test]
    fn validates_clip_ranges_and_rejects_unknown_arguments() {
        assert_eq!(parse_clip(""), Ok(None));
        assert_eq!(parse_clip("pv=1234567890abcdef"), Ok(None));
        assert_eq!(
            parse_clip("pv=1234567890abcdef&startSeconds=1&durationSeconds=2"),
            Ok(Some(Clip {
                start: 1.0,
                duration: 2.0
            }))
        );
        assert_eq!(
            parse_clip("startSeconds=12.5&durationSeconds=4"),
            Ok(Some(Clip {
                start: 12.5,
                duration: 4.0
            }))
        );
        for bad in [
            "startSeconds=4",
            "durationSeconds=5",
            "startSeconds=-1&durationSeconds=5",
            "startSeconds=0&durationSeconds=0",
            "startSeconds=0&durationSeconds=NaN",
            "startSeconds=0&durationSeconds=600&x=1",
            "startSeconds=0&startSeconds=1&durationSeconds=5",
            "pv=nothex",
            "pv=1234567890abcdef&pv=1234567890abcdef",
        ] {
            assert!(parse_clip(bad).is_err(), "{bad}");
        }
    }
}
