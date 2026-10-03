# Neo Core tools provenance

This directory contains the minimal execution subset derived from
`alexanderradahl/mac-developer-bridge` at commit
`fea70d1a3c5524164f2159f6063ba685fef91324`.

Kept: the Core stdio implementation, PTY helper, and upstream MIT license. Excluded:
the upstream child-MCP federation layer, installers, launchd files, browser
assets and tools, documentation, package metadata, HTTP entry points, and
upstream tests. NeoY owns MCP federation, launch, authorization, and lifecycle
supervision.
