# NeoY local bridge provenance

This directory contains the minimal execution subset derived from
`alexanderradahl/mac-developer-bridge` at commit
`fea70d1a3c5524164f2159f6063ba685fef91324`.

Kept: the stdio entry point, its direct runtime modules, the PTY helper, and
the upstream MIT license. Excluded: installers, launchd files, browser assets,
documentation, package metadata, HTTP entry points, and upstream tests. NeoY
owns launch, authorization, and lifecycle supervision.
