# Browser QA Contract
**Created:** 2026-03-14

## Purpose

This document defines the shared browser QA contract for Overture-managed repos.

All app-touching browser QA must run through an isolated PinchTab + Chromium +
Xvfb container flow. Final browser evidence comes from the container
framebuffer only, not from the operator desktop, host browser, or page-only CDP
captures.

## Required repo surfaces

- `.codex/skills/browser-qa/SKILL.md`
- `scripts/<repo-namespace>/browser-qa.sh`
- `scripts/<repo-namespace>/browser-qa.plan.json`
- `scripts/<repo-namespace>/browser-auth.sh`
- optional `scripts/<repo-namespace>/browser-qa-scenarios.mjs`

## CLI contract

- `scripts/<repo-namespace>/browser-qa.sh capture [--video-scenario <name> ...]`
- `scripts/<repo-namespace>/browser-qa.sh publish`
- `scripts/<repo-namespace>/browser-auth.sh resolve --profile <name> --app-url <container-url>`

## Artifact contract

Committed artifacts live under `docs/generated/browser-qa/<branch-slug>/`.

Required PNG naming:
- `<name>.png`

Optional video naming:
- `<name>.mp4`
- `<name>-poster.png`

Runtime-only manifests and logs live under `.symphony/runtime/browser-qa/<run-id>/`
or an equivalent repo-local runtime directory.

## Guardrails

- Do not use host-browser screenshots as browser QA evidence.
- Do not use environment screenshot tooling as a browser QA fallback.
- Do not use page-only CDP screenshots as final QA evidence.
- Keep one persistent PR comment headed `## Manual QA Evidence`.
