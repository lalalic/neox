//! Matches the Node Core's operator-controlled foreground GUI approval gate.
use crate::context::Context;
use crate::error::{ToolError, UnitResult};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

static APPROVAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn word(command: &str, wanted: &str) -> bool {
    command.match_indices(wanted).any(|(at, _)| {
        let before = command[..at].chars().last();
        let after = command[at + wanted.len()..].chars().next();
        let boundary =
            |c: Option<char>| c.is_none_or(|c| c.is_whitespace() || ";&|()<>".contains(c));
        boundary(before) && boundary(after)
    })
}

fn quoted_target(text: &str, start: usize) -> Option<String> {
    let remainder = text.get(start..)?.trim_start();
    let quote = remainder.chars().next()?;
    if quote != '\'' && quote != '"' {
        return None;
    }
    let rest = &remainder[1..];
    let end = rest.find(quote)?;
    let target = rest[..end].trim();
    if target.is_empty() {
        None
    } else {
        Some(target.to_string())
    }
}

// Treat runs of shell/AppleScript whitespace like Node's \s+ patterns.
fn after_phrases(original: &str, phrase: &str) -> Vec<String> {
    let text = original.to_ascii_lowercase();
    let words: Vec<&str> = phrase.split_whitespace().collect();
    let mut result = Vec::new();
    for (start, _) in text.match_indices(words[0]) {
        if start > 0 && (text.as_bytes()[start - 1] as char).is_ascii_alphanumeric() {
            continue;
        }
        let mut at = start + words[0].len();
        let mut matched = true;
        for word in words.iter().skip(1) {
            let mut spaced = false;
            while text.as_bytes().get(at).is_some_and(u8::is_ascii_whitespace) {
                at += 1;
                spaced = true;
            }
            if !spaced || !text[at..].starts_with(word) {
                matched = false;
                break;
            }
            at += word.len();
        }
        if !matched || !text.as_bytes().get(at).is_some_and(u8::is_ascii_whitespace) {
            continue;
        }
        if let Some(target) = quoted_target(original, at) {
            if !result
                .iter()
                .any(|s: &String| s.eq_ignore_ascii_case(&target))
            {
                result.push(target);
            }
        }
    }
    result
}

fn gui_focus_risk(command: &str) -> Option<(String, Vec<String>)> {
    let lower = command.to_ascii_lowercase();
    let osascript = word(&lower, "osascript") || word(&lower, "/usr/bin/osascript");
    let mut apps = after_phrases(command, "tell application ");
    apps.extend(after_phrases(command, "tell process "));
    let mut search_start = 0;
    while let Some(at) = command[search_start..].find("Application") {
        let pos = search_start + at + "Application".len();
        let rest = &command[pos..];
        if let Some(after_paren) = rest.trim_start().strip_prefix('(') {
            let start = command.len() - after_paren.len();
            if let Some(target) = quoted_target(command, start) {
                if !apps.iter().any(|a| a.eq_ignore_ascii_case(&target)) {
                    apps.push(target);
                }
            }
        }
        search_start = pos;
    }
    let external: Vec<_> = apps
        .iter()
        .filter(|app| !app.eq_ignore_ascii_case("System Events"))
        .cloned()
        .collect();
    if (osascript || command.contains("Application")) && !external.is_empty() {
        return Some(("apple-events-app-control".to_string(), external));
    }
    if osascript
        && (lower.contains("activate")
            || lower.contains("frontmost")
            || lower.contains("axraise")
            || lower.contains("keystroke")
            || lower.contains("key code"))
    {
        return Some((
            "apple-events-focus-action".to_string(),
            if apps.is_empty() {
                vec!["System Events".to_string()]
            } else {
                apps
            },
        ));
    }
    if (word(&lower, "open") || word(&lower, "/usr/bin/open")) && !word(&lower, "-g") {
        let matches = after_phrases(command, "-a ");
        return Some((
            "macos-open-foreground".to_string(),
            if matches.is_empty() {
                vec!["open".to_string()]
            } else {
                matches
            },
        ));
    }
    None
}

fn setting_path(context: &Context, env_name: &str, default: &str) -> PathBuf {
    std::env::var_os(env_name)
        .map(PathBuf::from)
        .unwrap_or_else(|| context.data_dir.join(default))
}

pub fn operator_settings(context: &Context) -> Result<Value, ToolError> {
    let path = setting_path(context, "NEO_CORE_SETTINGS_FILE", "settings.json");
    let value = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(serde_json::json!({"strictApprovals":false}))
        }
        Err(error) => return Err(ToolError::new(error.to_string())),
    };
    let json: Value = match serde_json::from_str(&value) {
        Ok(json) => json,
        Err(_) => {
            return Ok(serde_json::json!({"strictApprovals":true,"settingsError":"invalid-json"}))
        }
    };
    if !json.is_object() {
        return Ok(serde_json::json!({"strictApprovals":true,"settingsError":"invalid-shape"}));
    }
    Ok(
        serde_json::json!({"strictApprovals": json.get("strictApprovals").and_then(Value::as_bool).unwrap_or(false)}),
    )
}

fn strict_approvals(context: &Context) -> Result<bool, ToolError> {
    Ok(operator_settings(context)?["strictApprovals"] == true)
}

pub fn foreground_approval_info(context: &Context) -> Value {
    let path = setting_path(
        context,
        "NEO_CORE_FOREGROUND_GUI_APPROVAL_FILE",
        "FOREGROUND_GUI_APPROVED",
    );
    match fs::metadata(&path) {
        Ok(_) => serde_json::json!({"present":true,"path":path}),
        Err(error) => serde_json::json!({"present":false,"path":path,"reason":
            if error.kind() == std::io::ErrorKind::NotFound {"ENOENT"} else {"UNREADABLE"}}),
    }
}

// The approval script writes Date.toISOString(), in UTC and with millisecond precision.
fn iso_millis(value: &str) -> Option<u64> {
    let (date, time) = value.split_once('T')?;
    let date: Vec<_> = date.split('-').collect();
    if date.len() != 3 {
        return None;
    }
    let time = time.strip_suffix('Z')?;
    let (hms, fraction) = time.split_once('.').unwrap_or((time, "0"));
    let hms: Vec<_> = hms.split(':').collect();
    if hms.len() != 3 {
        return None;
    }
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = date[0].parse::<i32>().ok()? - 1900;
    tm.tm_mon = date[1].parse::<i32>().ok()? - 1;
    tm.tm_mday = date[2].parse::<i32>().ok()?;
    tm.tm_hour = hms[0].parse().ok()?;
    tm.tm_min = hms[1].parse().ok()?;
    tm.tm_sec = hms[2].parse().ok()?;
    if !(0..12).contains(&tm.tm_mon)
        || !(1..=31).contains(&tm.tm_mday)
        || !(0..24).contains(&tm.tm_hour)
        || !(0..60).contains(&tm.tm_min)
        || !(0..60).contains(&tm.tm_sec)
    {
        return None;
    }
    if fraction.len() > 3 || !fraction.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let milli = format!("{fraction:0<3}").parse::<u64>().ok()?;
    let seconds = unsafe { libc::timegm(&mut tm) };
    if seconds < 0 {
        return None;
    }
    Some((seconds as u64) * 1000 + milli)
}

pub fn guard(context: &Context, command: &str) -> UnitResult {
    if std::env::var("NEO_CORE_GUI_FOCUS_POLICY").unwrap_or_else(|_| "background-first".into())
        != "background-first"
    {
        return Ok(());
    }
    let Some((reason, apps)) = gui_focus_risk(command) else {
        return Ok(());
    };
    if !strict_approvals(context)? {
        return Ok(());
    }
    let lock = APPROVAL_LOCK.get_or_init(|| Mutex::new(()));
    let _guard = lock
        .lock()
        .map_err(|_| ToolError::new("foreground approval lock poisoned"))?;
    let path = setting_path(
        context,
        "NEO_CORE_FOREGROUND_GUI_APPROVAL_FILE",
        "FOREGROUND_GUI_APPROVED",
    );
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(ToolError::code(format!("Desktop GUI automation is blocked because Strict approvals is enabled ({reason}; targets: {}). Approve a one-time foreground action first.", apps.join(", ")), "GUI_FOCUS_BLOCKED")),
        Err(error) => return Err(ToolError::new(error.to_string())),
    };
    let value: Value = serde_json::from_str(&raw).map_err(|_| {
        ToolError::code(
            "Foreground GUI approval file is invalid JSON",
            "GUI_FOREGROUND_APPROVAL_INVALID",
        )
    })?;
    let nonce = value["nonce"].as_str().unwrap_or("");
    let expiry = value["expiresAt"].as_str().and_then(iso_millis);
    let now = crate::context::unix_ms();
    if nonce.len() != 32
        || !nonce.bytes().all(|b| b.is_ascii_hexdigit())
        || !expiry.is_some_and(|at| at > now && at - now <= 300_000)
    {
        let _ = fs::remove_file(&path);
        return Err(ToolError::code(
            "Foreground GUI approval is missing, expired, or malformed",
            "GUI_FOREGROUND_APPROVAL_INVALID",
        ));
    }
    let allowed: Vec<_> = value["allowedApps"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|s| s.trim().to_ascii_lowercase())
        .collect();
    for app in apps {
        if !allowed
            .iter()
            .any(|name| name == &app.trim().to_ascii_lowercase())
        {
            return Err(ToolError::code(
                format!("Foreground GUI approval does not allow: {app}"),
                "GUI_FOREGROUND_APP_NOT_APPROVED",
            ));
        }
    }
    fs::remove_file(path).map_err(|error| ToolError::new(error.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foreground_risk_detector() {
        assert!(gui_focus_risk("osascript -e 'tell application \"Safari\" to activate'").is_some());
        assert!(gui_focus_risk("open -a \"Safari\"").is_some());
        assert!(gui_focus_risk("open -g -a \"Safari\"").is_none());
        assert!(gui_focus_risk("printf hello").is_none());
    }
    #[test]
    fn parses_approval_expiry() {
        assert_eq!(iso_millis("1970-01-01T00:00:01.234Z"), Some(1234));
        assert!(iso_millis("invalid").is_none());
    }
}
