# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

`ai-harness` — a personalized AI harness for Claude Code. Early stage: no
application source exists yet beyond scaffolding.

## Status

Fresh repository. Tracked files: `README.md`, `.gitignore`, `CLAUDE.md`, and
`ollama-dev.sample.json`. There is no application source package, tests, build
config, or dependency manifest yet.

## Config

`ollama-dev.sample.json` is a sample config: a list of Ollama `instances`, each
with a `url` (e.g. `http://localhost:11434`) and a `model`. Implies the harness
targets one or more Ollama backends, possibly load-balanced across hosts. Copy
to a real (gitignored) config when implementing.

## Environment

- Recommended: use the VS Code Dev Container in `.devcontainer/` (Linux, Node 20 base).
- Local OS/IDE setup is developer-specific; keep `.venv/` and `.idea/` untracked via `.gitignore`.

## Conventions

- The `.gitignore` is the standard Python template — keep `.venv/`, `__pycache__/`,
  build artifacts, and IDE files out of commits.

## Notes for future updates

Once real code lands, expand this file with: package layout, how to run/build,
how to run tests and lint, and any architecture worth knowing before editing.
