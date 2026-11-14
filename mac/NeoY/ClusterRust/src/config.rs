use std::{
    collections::HashMap,
    env, fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct Config {
    pub node_name: String,
    pub mode: String,
    pub hub_target: String,
    pub hub_port: u16,
    pub hub_mcp_port: u16,
    pub local_mcp_port: u16,
    pub node_root: PathBuf,
    pub ssh_key: Option<PathBuf>,
    pub ssh_bin: PathBuf,
    pub config_file: PathBuf,
}

fn home() -> PathBuf {
    PathBuf::from(env::var_os("HOME").unwrap_or_else(|| "/tmp".into()))
}

impl Config {
    pub fn load() -> Result<Self, String> {
        let config_file = env::var_os("NEO_NODE_CONFIG")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".config/neo-node/node.env"));
        let mut values: HashMap<String, String> = env::vars().collect();
        // Preserve old Node behavior: remote config takes precedence over ambient env.
        if config_file.exists() {
            let content = fs::read_to_string(&config_file).map_err(|e| e.to_string())?;
            for raw in content.lines() {
                let raw = raw.trim();
                if raw.is_empty() || raw.starts_with('#') {
                    continue;
                }
                if let Some((k, v)) = raw.split_once('=') {
                    values.insert(k.to_owned(), v.to_owned());
                }
            }
        }
        let get = |key: &str, fallback: &str| -> String {
            values
                .get(key)
                .filter(|s| !s.is_empty())
                .cloned()
                .unwrap_or_else(|| fallback.into())
        };
        let port = |name: &str, fallback: &str| -> Result<u16, String> {
            get(name, fallback)
                .parse::<u16>()
                .map_err(|_| format!("invalid {name}"))
        };
        let root = get("NODE_ROOT", "");
        let root = if root.is_empty() {
            home().join(".local/share/neo-node")
        } else {
            PathBuf::from(root)
        };
        let node_name = get("NODE_NAME", "node");
        if node_name.is_empty()
            || node_name.len() > 64
            || !node_name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        {
            return Err(
                "invalid NODE_NAME: use 1-64 ASCII letters, digits, dash or underscore".into(),
            );
        }
        let mode = get("NODE_MODE", "session");
        if mode != "persistent" && mode != "session" {
            return Err("invalid NODE_MODE".into());
        }
        if !root.is_absolute() {
            return Err("NODE_ROOT must be absolute".into());
        }
        let ssh_key = get("NODE_SSH_KEY", "");
        let ssh_bin = get("SSH_BIN", "/usr/bin/ssh");
        let hub_target = get("HUB_SSH_TARGET", "");
        if !hub_target.is_empty()
            && (!hub_target.contains('@') || hub_target.chars().any(char::is_whitespace))
        {
            return Err("HUB_SSH_TARGET must be a single SSH user@host target".into());
        }
        Ok(Self {
            node_name,
            mode,
            hub_target,
            hub_port: port("HUB_SSH_PORT", "22")?,
            hub_mcp_port: port("HUB_MCP_PORT", "0")?,
            local_mcp_port: port("LOCAL_MCP_PORT", "8789")?,
            node_root: root,
            ssh_key: if ssh_key.is_empty() {
                None
            } else {
                Some(PathBuf::from(ssh_key))
            },
            ssh_bin: PathBuf::from(ssh_bin),
            config_file,
        })
    }
    pub fn run_dir(&self) -> PathBuf {
        self.node_root.join("run")
    }
    pub fn log_dir(&self) -> PathBuf {
        self.node_root.join("logs")
    }
    pub fn pid_file(&self) -> PathBuf {
        self.run_dir().join("supervisor.pid")
    }
    pub fn plist(&self) -> PathBuf {
        home()
            .join("Library/LaunchAgents")
            .join(format!("com.neo.node.{}.plist", self.node_name))
    }
    pub fn cli(&self) -> PathBuf {
        home().join(".local/bin/neo-node")
    }
    pub fn binary_dest(&self) -> PathBuf {
        self.node_root.join("neo-cluster-rust")
    }
    pub fn ensure_dirs(&self) -> std::io::Result<()> {
        fs::create_dir_all(self.run_dir())?;
        fs::create_dir_all(self.log_dir())
    }
    pub fn ssh_args(&self) -> Vec<String> {
        let mut a = vec![
            "-N",
            "-o",
            "BatchMode=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=20",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-p",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        a.push(self.hub_port.to_string());
        if let Some(ref path) = self.ssh_key {
            if path.is_file() {
                a.extend(["-i".to_owned(), path.display().to_string()]);
            }
        }
        a.push("-R".into());
        a.push(format!(
            "127.0.0.1:{}:127.0.0.1:{}",
            self.hub_mcp_port, self.local_mcp_port
        ));
        a.push(self.hub_target.clone());
        a
    }
}

pub fn expand_path(s: &str) -> PathBuf {
    if s == "~" {
        home()
    } else if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(s)
    }
}
pub fn ensure_file_mode(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn expands_home_paths() {
        assert_eq!(expand_path("~/abc"), home().join("abc"));
    }
}
