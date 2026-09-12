# Capability evals

`cases.yaml` is designed for deterministic grading. A harness can run each prompt against a live Neox endpoint, a stubbed `tools/list`, or a planning-only agent and assert the listed fields. Harnesses may adapt transport and result formatting, but should preserve case IDs and assertion meaning. No API-key-backed LLM judge is required when the expected action or rejection is deterministic.
