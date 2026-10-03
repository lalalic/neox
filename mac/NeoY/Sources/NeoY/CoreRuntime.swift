import Foundation

enum NeoYCoreRuntime {
    static let version = "2.3.0"
    static let toolNames: Set<String> = [
        "setup",
        "apply_patch",
        "cluster",
        "bridge_status",
        "shell_exec", "shell_start", "shell_job_status", "shell_job_list", "shell_job_kill",
        "fs_read", "fs_write", "fs_list", "fs_stat", "fs_manage",
        "codex_thread_read", "codex_thread_list", "codex_thread_turns_list",
        "audit_tail",
        "pty_start", "pty_read", "pty_write", "pty_resize", "pty_signal", "pty_close"
    ]

    @MainActor
    static func register(
        on server: MCPServer,
        setup: NeoYSetupService,
        node: NeoYNodeService
    ) {
        server.register(tools: NeoYSetupTools.tools(service: setup), protected: true)
        server.register(tools: NeoYPatchTools.tools(), protected: true)
        server.register(tools: NeoYNodeTools.tools(service: node), protected: true)
    }
}
