use serde_json::Value;

/// Stable Core MCP contracts are native Rust fixture data. Neither
/// installation nor execution needs Node.js or an npm Core package.
pub fn tools(pty_available: bool) -> Vec<Value> {
    let mut tools: Vec<Value> = serde_json::from_str(include_str!("../fixtures/core-tools.json"))
        .expect("checked-in Rust Core MCP contract fixture must be valid JSON");
    if !pty_available {
        tools.retain(|tool| tool["name"] != "terminal");
    }
    tools
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inventory_is_stable() {
        let names: Vec<String> = tools(true)
            .into_iter()
            .map(|tool| tool["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            names,
            [
                "status",
                "shell",
                "fs",
                "apply_file_patch",
                "codex",
                "discord",
                "chatgpt",
                "terminal"
            ]
        );
    }
}
