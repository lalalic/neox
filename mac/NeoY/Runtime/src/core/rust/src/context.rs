use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub const FULL_ACCESS_ACK: &str = "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS";
pub const SERVER_NAME: &str = "neo-core-tools";
pub const SERVER_TITLE: &str = "Neo Core Tools";
pub const CORE_VERSION: &str = "0.2.4";
pub const MODERN_PROTOCOL: &str = "2026-07-28";
pub const LEGACY_PROTOCOLS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

#[derive(Debug, Clone)]
pub struct Context {
    pub home: PathBuf,
    pub data_dir: PathBuf,
    pub job_dir: PathBuf,
    pub unlock_file: PathBuf,
    startup_authorized: bool,
    pub shell: PathBuf,
    pub tunnel_key_was_present: bool,
    pub codex_bin: String,
    pub default_output_bytes: usize,
    pub max_output_bytes: usize,
}

fn bounded_env(name: &str, default: usize, minimum: usize, maximum: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|value| value.clamp(minimum, maximum))
        .unwrap_or(default)
}

impl Context {
    pub fn from_env() -> Result<Self, String> {
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME is required".to_string())?;
        let data_dir = env::var_os("NEO_CORE_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("Library/Application Support/NeoY/core"));
        let job_dir = data_dir.join("jobs");
        let unlock_file = env::var_os("NEO_CORE_UNLOCK_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| data_dir.join("FULL_ACCESS_ENABLED"));
        let shell = env::var_os("NEO_CORE_SHELL")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                ["/bin/zsh", "/bin/bash", "/bin/sh"]
                    .iter()
                    .map(PathBuf::from)
                    .find(|path| path.exists())
                    .expect("at least one POSIX shell is present on macOS")
            });

        let tunnel_key_was_present = env::var_os("CONTROL_PLANE_API_KEY").is_some();
        env::remove_var("CONTROL_PLANE_API_KEY");
        let env_unlock = env::var("NEO_CORE_FULL_ACCESS_ACK").ok();
        env::remove_var("NEO_CORE_FULL_ACCESS_ACK");
        let startup_authorized = env_unlock.as_deref() == Some(FULL_ACCESS_ACK);
        if !startup_authorized {
            let file_authorized =
                fs::read_to_string(&unlock_file).is_ok_and(|value| value.trim() == FULL_ACCESS_ACK);
            if !file_authorized {
                return Err(format!(
                "Refusing to start unrestricted Neo Core Tools. Create {} containing {}, or set NEO_CORE_FULL_ACCESS_ACK to that exact value.",
                unlock_file.display(),
                FULL_ACCESS_ACK
            ));
            }
        }

        fs::create_dir_all(&data_dir).map_err(|error| error.to_string())?;
        fs::create_dir_all(&job_dir).map_err(|error| error.to_string())?;
        set_private_dir(&data_dir);
        set_private_dir(&job_dir);

        Ok(Self {
            home,
            data_dir,
            job_dir,
            unlock_file,
            startup_authorized,
            shell,
            tunnel_key_was_present,
            codex_bin: env::var("CODEX_BIN").unwrap_or_else(|_| "codex".to_string()),
            default_output_bytes: bounded_env(
                "NEO_CORE_DEFAULT_OUTPUT_BYTES",
                1_000_000,
                1_024,
                8_000_000,
            ),
            max_output_bytes: bounded_env(
                "NEO_CORE_MAX_OUTPUT_BYTES",
                8_000_000,
                1_024,
                64_000_000,
            ),
        })
    }

    pub fn unlocked(&self) -> bool {
        if self.startup_authorized {
            return true;
        }
        match fs::read_to_string(&self.unlock_file) {
            Ok(value) => value.trim() == FULL_ACCESS_ACK,
            Err(_) => false,
        }
    }

    pub fn resolve_path(&self, path: &str) -> PathBuf {
        let input = if path == "~" {
            self.home.clone()
        } else if let Some(rest) = path.strip_prefix("~/") {
            self.home.join(rest)
        } else {
            let input = PathBuf::from(path);
            if input.is_absolute() {
                input
            } else {
                self.home.join(input)
            }
        };
        let mut resolved = PathBuf::new();
        for component in input.components() {
            match component {
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    if resolved.file_name().is_some() {
                        resolved.pop();
                    }
                }
                other => resolved.push(other.as_os_str()),
            }
        }
        resolved
    }
}

fn set_private_dir(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(metadata) = fs::metadata(path) {
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o700);
        let _ = fs::set_permissions(path, permissions);
    }
}

pub fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}
