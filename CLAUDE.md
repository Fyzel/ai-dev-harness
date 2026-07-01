# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

`ai-harness` — a personalized AI harness for Claude Code. Early stage: no
application source exists yet beyond scaffolding.

## Status

Fresh repository. Tracked files are `README.md` and `.gitignore` only. A Python
3.14 virtualenv (`.venv/`) and a PyCharm project (`.idea/`) exist locally but are
untracked/ignored. There is no source package, tests, build config, or
dependency manifest yet.

## Environment

- Python 3.14 (CPython), managed via a local `.venv/`.
- Activate: `.venv\Scripts\Activate.ps1` (PowerShell) or `source .venv/Scripts/activate` (bash).
- Platform: Windows. Shell is PowerShell (primary); a POSIX Bash tool is also available.

## Conventions

- The `.gitignore` is the standard Python template — keep `.venv/`, `__pycache__/`,
  build artifacts, and IDE files out of commits.

## Notes for future updates

Once real code lands, expand this file with: package layout, how to run/build,
how to run tests and lint, and any architecture worth knowing before editing.
