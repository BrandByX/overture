# Browser QA Contract
**Created:** 2026-03-14

## Purpose

This document defines the shared browser QA contract for Overture-managed repos.

Browser-visible QA must run through an isolated PinchTab + Chromium + Xvfb
container flow. Final browser evidence comes from the container framebuffer
only, not from the operator desktop, host browser, or page-only CDP captures.
Repos provide reusable browser QA catalog entries; the issue workpad `### Browser
QA Plan` selects which artifacts are actually required for the current ticket.

## Required repo surfaces

- `.codex/skills/browser-qa/SKILL.md`
- `scripts/<repo-namespace>/browser-qa.sh`
- `scripts/<repo-namespace>/browser-qa.catalog.json`
- `scripts/<repo-namespace>/browser-auth.sh`
- optional `scripts/<repo-namespace>/browser-qa-scenarios.mjs`

## CLI contract

- `scripts/<repo-namespace>/browser-qa.sh capture --still <name> ... [--video-scenario <name> ...] [--request-file <path>]`
- `scripts/<repo-namespace>/browser-qa.sh publish [--manifest <path> | --not-applicable]`
- `scripts/<repo-namespace>/browser-qa.sh clean`
- `scripts/<repo-namespace>/browser-auth.sh resolve --profile <name> --app-url <container-url>`

## Artifact contract

Committed artifacts live under `docs/generated/browser-qa/<branch-slug>/`.

Selected PNG naming:
- `<name>.png`

Selected video naming:
- `<name>.mp4`
- `<name>-poster.png`

Runtime-only manifests and logs live under `.symphony/runtime/browser-qa/<run-id>/`
or an equivalent repo-local runtime directory. A latest-manifest pointer may
also live under the same runtime root.

## Guardrails

- Do not use host-browser screenshots as browser QA evidence.
- Do not use environment screenshot tooling as a browser QA fallback.
- Do not use page-only CDP screenshots as final QA evidence.
- Do not assume any repo-wide default screenshot set. Select evidence per
  ticket based on the changed behavior, using repo catalog entries only when
  they are a good reusable fit.
- Keep one persistent PR comment headed `## Manual QA Evidence`.
