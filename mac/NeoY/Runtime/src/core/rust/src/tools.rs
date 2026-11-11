use serde_json::Value;

/// Tool definitions are captured from the authoritative Node Core by the
/// fixture updater. The Rust child remains independently executable; updating
/// this compile-time contract never launches or delegates to Node at runtime.
pub fn tools(pty_available: bool) -> Vec<Value> {
    let mut tools: Vec<Value> = serde_json::from_str(include_str!("../fixtures/node-tools.json"))
        .expect("checked-in Node Core tool contract fixture must be valid JSON");
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
