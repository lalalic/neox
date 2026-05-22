# xhs-creator — moved

This orchestrator agent now lives in the bullx project template, renamed to
`orchestrator` so each bootstrapped project uses it as its main agent:

  bullx/.github/templates/nlm-xhs/.github/agents/orchestrator.agent.md

A project bootstrapped from the `nlm-xhs` template (via `POST /api/templates/bootstrap`)
gets the agent copied into `<project>/.github/agents/orchestrator.agent.md`
automatically and registered as the project's main agent via
`package.json -> neo.selectedAgents`.
