//! Private Core job metadata/log retention, matching tools/job-gc.mjs.
//! Never signals/kills a process. Jobs with uncertain identities are protected.
use crate::context::unix_ms;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const MAX_COMPLETED_AGE_MS: u64 = 72 * 60 * 60 * 1000;
pub const MAX_COMPLETED: usize = 2_000;
pub const MAX_SWEEP_DELETES: usize = 1_000;
pub const GC_INTERVAL: Duration = Duration::from_secs(60 * 60);
const PTY_MAX_AGE_MS: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Debug, Default)]
pub struct GcReport {
    pub scanned: usize,
    pub eligible: usize,
    pub verified: usize,
    pub invalid: usize,
}

fn iso_ms(value: &Value) -> Option<u64> {
    if let Some(number) = value.as_u64() {
        return Some(number);
    } // pre-parity Rust
    let input = value.as_str()?;
    let (date, time) = input.split_once('T')?;
    let components: Vec<_> = date.split('-').collect();
    if components.len() != 3 {
        return None;
    }
    let time = time.strip_suffix('Z')?;
    let (clock, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let parts: Vec<_> = clock.split(':').collect();
    if parts.len() != 3 {
        return None;
    }
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = components[0].parse::<i32>().ok()? - 1900;
    tm.tm_mon = components[1].parse::<i32>().ok()? - 1;
    tm.tm_mday = components[2].parse::<i32>().ok()?;
    tm.tm_hour = parts[0].parse().ok()?;
    tm.tm_min = parts[1].parse().ok()?;
    tm.tm_sec = parts[2].parse().ok()?;
    if !(0..12).contains(&tm.tm_mon)
        || !(1..=31).contains(&tm.tm_mday)
        || !(0..24).contains(&tm.tm_hour)
        || !(0..60).contains(&tm.tm_min)
        || !(0..60).contains(&tm.tm_sec)
        || fraction.len() > 3
        || !fraction.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let milliseconds = format!("{fraction:0<3}").parse::<u64>().ok()?;
    let seconds = unsafe { libc::timegm(&mut tm) };
    if seconds < 0 {
        return None;
    }
    (seconds as u64)
        .checked_mul(1000)?
        .checked_add(milliseconds)
}

fn elapsed_seconds(raw: &str) -> Option<u64> {
    let (days, clock) = raw.split_once('-').unwrap_or(("0", raw));
    let pieces: Vec<_> = clock.split(':').collect();
    if !(2..=3).contains(&pieces.len()) {
        return None;
    }
    let mut seconds: u64 = 0;
    for p in pieces {
        seconds = seconds
            .checked_mul(60)?
            .checked_add(p.parse::<u64>().ok()?)?;
    }
    seconds.checked_add(days.parse::<u64>().ok()?.checked_mul(86_400)?)
}

struct ProcessSnapshot {
    starts: HashMap<i32, u64>,
    // None: orphan descendants without their leader; Some: leader start time.
    groups: HashMap<i32, Option<u64>>,
}

fn process_start_times(now: u64) -> Option<ProcessSnapshot> {
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,pgid=,etime="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut processes = ProcessSnapshot {
        starts: HashMap::new(),
        groups: HashMap::new(),
    };
    for line in stdout.lines() {
        let mut fields = line.split_whitespace();
        let (Some(pid), Some(pgid), Some(elapsed)) = (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let (Ok(pid), Ok(pgid), Some(elapsed)) = (
            pid.parse::<i32>(),
            pgid.parse::<i32>(),
            elapsed_seconds(elapsed),
        ) else {
            continue;
        };
        if pid > 1 {
            processes
                .starts
                .insert(pid, now.saturating_sub(elapsed.saturating_mul(1000)));
            if pgid > 1 {
                processes.groups.entry(pgid).or_insert(None);
                if pgid == pid {
                    processes
                        .groups
                        .insert(pgid, Some(now.saturating_sub(elapsed.saturating_mul(1000))));
                }
            }
        }
    }
    if processes.starts.contains_key(&(std::process::id() as i32)) {
        Some(processes)
    } else {
        None
    }
}

fn original_alive(document: &Value, process_starts: Option<&ProcessSnapshot>) -> bool {
    let Some(starts) = process_starts else {
        return true;
    }; // fail closed
    let Some(pid) = document["pid"].as_i64().and_then(|p| i32::try_from(p).ok()) else {
        return true;
    };
    let Some(start) = iso_ms(&document["startedAt"]) else {
        return true;
    };
    if pid <= 1 {
        return true;
    }
    // Preserve orphan descendants. But a present PGID leader whose creation
    // timestamp differs from the job proves the PGID has been recycled.
    if let Some(pgid) = document["processGroupId"]
        .as_i64()
        .and_then(|p| i32::try_from(p).ok())
    {
        if pgid > 1 {
            if let Some(leader_start) = starts.groups.get(&pgid) {
                if leader_start.is_none_or(|at| at.abs_diff(start) < 120_000) {
                    return true;
                }
            }
        }
    }
    starts
        .starts
        .get(&pid)
        .is_some_and(|actual| actual.abs_diff(start) < 120_000)
}

fn validate_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

#[derive(Clone)]
struct Candidate {
    id: String,
    file: String,
    source: Value,
    age: u64,
    pty: bool,
}

fn expected_log(root: &Path, id: &str, value: &Value, suffix: &str) -> Option<PathBuf> {
    let expected = root.join(format!("{id}.{suffix}"));
    (value.as_str()? == expected.to_string_lossy()).then_some(expected)
}

fn remove_regular(file: &Path) {
    if fs::symlink_metadata(file).is_ok_and(|m| m.file_type().is_file()) {
        let _ = fs::remove_file(file);
    }
}

fn remove_candidate(
    root: &Path,
    candidate: &Candidate,
    now: u64,
    process_starts: Option<&ProcessSnapshot>,
) -> bool {
    let path = root.join(&candidate.file);
    let Ok(before) = fs::symlink_metadata(&path) else {
        return false;
    };
    if !before.file_type().is_file() {
        return false;
    };
    let Ok(raw) = fs::read_to_string(&path) else {
        return false;
    };
    let Ok(doc): Result<Value, _> = serde_json::from_str(&raw) else {
        return false;
    };
    if doc != candidate.source || doc["id"].as_str() != Some(&candidate.id) {
        return false;
    };
    if candidate.pty {
        if doc["kind"] != "pty"
            || now.saturating_sub(iso_ms(&doc["startedAt"]).unwrap_or(now)) < PTY_MAX_AGE_MS
            || original_alive(&doc, process_starts)
        {
            return false;
        };
        if doc["helperPid"].as_i64().is_some() {
            let helper = serde_json::json!({"pid":doc["helperPid"],"startedAt":doc["startedAt"]});
            if original_alive(&helper, process_starts) {
                return false;
            };
        }
    } else if doc["finishedAt"].is_null() {
        if original_alive(&doc, process_starts)
            || now.saturating_sub(iso_ms(&doc["startedAt"]).unwrap_or(now)) < MAX_COMPLETED_AGE_MS
        {
            return false;
        }
    } else if original_alive(&doc, process_starts) {
        return false;
    }

    let temp = root.join(format!(
        ".gc-{}-{}-{}",
        candidate.id,
        std::process::id(),
        unix_ms()
    ));
    if fs::rename(&path, &temp).is_err() {
        return false;
    };
    let valid = fs::symlink_metadata(&temp).is_ok_and(|after| {
        after.file_type().is_file() && before.ino() == after.ino() && before.dev() == after.dev()
    });
    if !valid {
        let _ = fs::rename(&temp, &path);
        return false;
    }
    for (field, suffix) in [("stdoutPath", "stdout.log"), ("stderrPath", "stderr.log")] {
        if let Some(log) = expected_log(root, &candidate.id, &doc[field], suffix) {
            remove_regular(&log)
        }
    }
    remove_regular(&root.join(format!("{}.stdin", candidate.id)));
    let _ = fs::remove_file(temp);
    true
}

// Bounded hourly sweeps; use the Node CLI for an explicitly approved one-time
// backlog cleanup. All filesystem operations are internal to the Core owner.
pub fn sweep(root: &Path, max_deletes: usize) -> Result<GcReport, String> {
    if !root.is_absolute() {
        return Err("job directory must be absolute".into());
    }
    let now = unix_ms();
    let process_starts = process_start_times(now);
    let mut report = GcReport::default();
    let mut completed = Vec::new();
    let mut unfinished = Vec::new();
    let mut ptys = Vec::new();
    let entries = fs::read_dir(root).map_err(|e| e.to_string())?;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        let Some(id) = name.strip_suffix(".json") else {
            continue;
        };
        if !validate_id(id) {
            continue;
        };
        let pty = name.starts_with("pty_");
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if !metadata.file_type().is_file()
            || fs::symlink_metadata(entry.path()).is_ok_and(|m| m.file_type().is_symlink())
        {
            report.invalid += 1;
            continue;
        }
        let Ok(content) = fs::read_to_string(entry.path()) else {
            report.invalid += 1;
            continue;
        };
        let Ok(doc): Result<Value, _> = serde_json::from_str(&content) else {
            report.invalid += 1;
            continue;
        };
        if doc["id"].as_str() != Some(id) || doc["pid"].as_i64().is_none() {
            report.invalid += 1;
            continue;
        };
        if pty {
            if doc["kind"] != "pty" {
                report.invalid += 1;
                continue;
            };
            let Some(start) = iso_ms(&doc["startedAt"]) else {
                report.invalid += 1;
                continue;
            };
            ptys.push(Candidate {
                id: id.to_string(),
                file: name,
                source: doc,
                age: start,
                pty: true,
            });
        } else if doc["finishedAt"].is_null() {
            let Some(start) = iso_ms(&doc["startedAt"]) else {
                report.invalid += 1;
                continue;
            };
            unfinished.push(Candidate {
                id: id.to_string(),
                file: name,
                source: doc,
                age: start,
                pty: false,
            });
        } else if let Some(finish) = iso_ms(&doc["finishedAt"]) {
            completed.push(Candidate {
                id: id.to_string(),
                file: name,
                source: doc,
                age: finish,
                pty: false,
            });
        } else {
            report.invalid += 1;
        }
    }
    report.scanned = completed.len() + unfinished.len() + ptys.len();
    completed.sort_by(|a, b| b.age.cmp(&a.age).then_with(|| a.id.cmp(&b.id)));
    let mut candidates = Vec::new();
    for (index, entry) in completed.into_iter().enumerate() {
        if index >= MAX_COMPLETED || now.saturating_sub(entry.age) >= MAX_COMPLETED_AGE_MS {
            candidates.push(entry);
        }
    }
    for entry in unfinished {
        if now.saturating_sub(entry.age) >= MAX_COMPLETED_AGE_MS
            && !original_alive(&entry.source, process_starts.as_ref())
        {
            candidates.push(entry);
        }
    }
    for entry in ptys {
        if now.saturating_sub(entry.age) >= PTY_MAX_AGE_MS {
            candidates.push(entry)
        }
    }
    report.eligible = candidates.len();
    candidates.sort_by_key(|candidate| candidate.age);
    for candidate in candidates.iter().take(max_deletes) {
        if remove_candidate(root, candidate, now, process_starts.as_ref()) {
            report.verified += 1;
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn elapsed_parser_accepts_darwin_ps_formats() {
        assert_eq!(elapsed_seconds("01:02"), Some(62));
        assert_eq!(elapsed_seconds("03:04:05"), Some(11_045));
        assert_eq!(elapsed_seconds("2-03:04:05"), Some(183_845));
        assert_eq!(elapsed_seconds("bad"), None);
    }
    #[test]
    fn iso_timestamp_matches_utc_epoch() {
        assert_eq!(
            iso_ms(&serde_json::json!("1970-01-01T00:00:01.234Z")),
            Some(1234)
        );
        assert_eq!(iso_ms(&serde_json::json!("invalid")), None);
    }
}

#[cfg(test)]
mod integration {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "neoy-rust-gc-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn add(&self, id: &str, pid: i32, started: u64, finished: Option<u64>, kind: Option<&str>) {
            let mut data = serde_json::json!({"id":id,"pid":pid,"processGroupId":pid,
                "startedAt":started,"finishedAt":finished,"command":"true","cwd":self.0,
                "stdoutPath":self.0.join(format!("{id}.stdout.log")),
                "stderrPath":self.0.join(format!("{id}.stderr.log"))});
            if let Some(kind) = kind {
                data["kind"] = serde_json::json!(kind);
            }
            fs::write(self.0.join(format!("{id}.json")), data.to_string()).unwrap();
            fs::write(self.0.join(format!("{id}.stdout.log")), "out").unwrap();
            fs::write(self.0.join(format!("{id}.stderr.log")), "err").unwrap();
        }
        fn exists(&self, id: &str) -> bool {
            self.0.join(format!("{id}.json")).exists()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn gc_bounds_recent_history_to_two_thousand_and_removes_owned_logs() {
        let fixture = Fixture::new();
        let now = unix_ms();
        for i in 0..2005 {
            fixture.add(
                &format!("job-{i:05}"),
                999_999_999,
                now - 2000,
                Some(now - i * 1000),
                None,
            );
        }
        fixture.add(
            "ancient",
            999_999_999,
            now - 4 * MAX_COMPLETED_AGE_MS,
            Some(now - MAX_COMPLETED_AGE_MS - 5000),
            None,
        );
        let report = sweep(&fixture.0, 10000).unwrap();
        assert_eq!(report.scanned, 2006);
        assert_eq!(report.eligible, 6);
        assert_eq!(report.verified, 6);
        assert!(!fixture.exists("ancient"));
        assert!(!fixture.0.join("ancient.stdout.log").exists());
        let kept = fs::read_dir(&fixture.0)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "json"))
            .count();
        assert_eq!(kept, MAX_COMPLETED);
    }

    #[test]
    fn gc_protects_live_process_and_young_unfinished_but_reaps_stale_and_old_pty() {
        let fixture = Fixture::new();
        let now = unix_ms();
        let starts = process_start_times(now).unwrap();
        let current = starts.starts[&(std::process::id() as i32)];
        fixture.add("active", std::process::id() as i32, current, None, None);
        fixture.add(
            "stale",
            999_999_999,
            now - 4 * MAX_COMPLETED_AGE_MS,
            None,
            None,
        );
        fixture.add("young", 999_999_999, now - 60_000, None, None);
        fixture.add(
            "pty_old",
            999_999_999,
            now - 8 * 24 * 3600 * 1000,
            None,
            Some("pty"),
        );
        fixture.add(
            "pty_young",
            999_999_999,
            now - 2 * 24 * 3600 * 1000,
            None,
            Some("pty"),
        );
        let report = sweep(&fixture.0, 20).unwrap();
        assert_eq!(report.verified, 2);
        assert!(fixture.exists("active"));
        assert!(fixture.exists("young"));
        assert!(fixture.exists("pty_young"));
        assert!(!fixture.exists("stale"));
        assert!(!fixture.exists("pty_old"));
    }

    #[test]
    fn gc_never_follows_symlinks_or_deletes_external_log_path() {
        let fixture = Fixture::new();
        let foreign = Fixture::new();
        let now = unix_ms();
        let id = "old-log-guard";
        fixture.add(
            id,
            999_999_999,
            now - 4 * MAX_COMPLETED_AGE_MS,
            Some(now - MAX_COMPLETED_AGE_MS - 5000),
            None,
        );
        let external = foreign.0.join("external.txt");
        fs::write(&external, "preserve").unwrap();
        let metadata = fixture.0.join(format!("{id}.json"));
        let mut doc: Value = serde_json::from_str(&fs::read_to_string(&metadata).unwrap()).unwrap();
        doc["stdoutPath"] = serde_json::json!(external);
        fs::write(&metadata, doc.to_string()).unwrap();
        let target = foreign.0.join("secret.json");
        fs::write(&target, "secret").unwrap();
        std::os::unix::fs::symlink(&target, fixture.0.join("symlink.json")).unwrap();
        let report = sweep(&fixture.0, 5).unwrap();
        assert_eq!(report.verified, 1);
        assert!(fixture.0.join("symlink.json").exists());
        assert_eq!(fs::read_to_string(external).unwrap(), "preserve");
        assert!(!metadata.exists());
    }
}

#[cfg(test)]
mod recycled_group_regression {
    use super::*;
    #[test]
    fn protects_orphaned_group_but_not_recycled_leader() {
        let original = unix_ms() - 10 * 24 * 3600 * 1000;
        let job = serde_json::json!({"pid":431000,"processGroupId":431000,"startedAt":original});
        let mut snapshot = ProcessSnapshot {
            starts: HashMap::new(),
            groups: HashMap::new(),
        };
        snapshot
            .starts
            .insert(431000, original + 9 * 24 * 3600 * 1000);
        snapshot
            .groups
            .insert(431000, Some(original + 9 * 24 * 3600 * 1000));
        assert!(
            !original_alive(&job, Some(&snapshot)),
            "recycled group leader cannot preserve old job forever"
        );
        snapshot.groups.insert(431000, None);
        assert!(
            original_alive(&job, Some(&snapshot)),
            "orphan descendants must remain protected"
        );
        snapshot.groups.insert(431000, Some(original));
        assert!(
            original_alive(&job, Some(&snapshot)),
            "same-original leader must remain protected"
        );
    }
}
