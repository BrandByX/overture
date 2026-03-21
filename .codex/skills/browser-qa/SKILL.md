---
name: browser-qa
description:
  Use the repo-owned isolated browser QA contract for ticket-selected
  browser-visible evidence and publish deterministic PR evidence through one
  persistent QA comment.
---

# Browser QA

## Goal

Overture-managed repos must use one browser QA path: isolated PinchTab +
Chromium + Xvfb inside Docker, with framebuffer captures as the only valid
browser evidence source. Repos provide a reusable browser QA catalog; the issue
workpad selects which evidence targets are required for the current ticket.

## Required repo surfaces

- `.codex/skills/browser-qa/SKILL.md`
- `scripts/<repo-namespace>/browser-qa.sh`
- `scripts/<repo-namespace>/browser-auth.sh`
- `scripts/<repo-namespace>/browser-qa.catalog.json`
- optional `scripts/<repo-namespace>/browser-qa-scenarios.mjs`

## Contract

- Browser QA is required only when the issue workpad `### Browser QA Plan`
  says `Status: Required`.
- Required PNGs always come from the isolated container display.
- Optional MP4s are generated only for selected named scenarios.
- Browser QA must not use host-browser screenshots, environment screenshot
  capture, or page-only CDP screenshots as final evidence.
- Publish evidence through one persistent PR comment headed
  `## Manual QA Evidence`.

## Usage

When a repo ships the required surfaces, follow the repo-local instructions in
its `browser-qa` skill and scripts, and capture only the stills/videos selected
for the current ticket. If the repo does not yet implement this contract, stop
and surface the missing surface as a blocker instead of falling back to
host-browser capture.
