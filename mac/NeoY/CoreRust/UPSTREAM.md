# Neo Core tools provenance

This directory contains the minimal execution subset derived from
`alexanderradahl/mac-developer-bridge` at commit
`fea70d1a3c5524164f2159f6063ba685fef91324`.

Kept: the Core stdio implementation, PTY helper, and upstream MIT license. Excluded:
the upstream child-MCP federation layer, installers, launchd files, browser
assets and tools, documentation, package metadata, HTTP entry points, and
upstream tests. NeoY owns MCP federation, launch, authorization, and lifecycle
supervision.

## Post-migration note (2026-11)

The files above describe the historical origin of the retired JavaScript Core.
The maintained executable is now `CoreRust`, implemented in native Rust with
its own compiled tools and independent tests. Retain upstream MIT notices for
ported behaviors even though the Node Core source itself has been retired.
