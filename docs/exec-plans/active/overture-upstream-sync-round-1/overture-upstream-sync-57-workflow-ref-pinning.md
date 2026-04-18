# Overture Upstream Sync `#57`: Workflow Ref Pinning

Created: 2026-04-17
Updated: 2026-04-17

## Goal

Port upstream Symphony PR `#57` so Overture pins external GitHub Actions workflow references to
immutable SHAs.

## Current state

- Overture still uses floating refs in `.github/workflows/make-all.yml`
- Overture still uses floating refs in `.github/workflows/pr-description-lint.yml`

## Target state

- third-party workflow `uses:` refs are pinned to immutable SHAs
- pinned refs keep the upstream version comments for readability
- workflow triggers, job names, cache behavior, and command steps stay unchanged
- the pinned refs match upstream `9e89dd9` exactly:
  - `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4`
  - `jdx/mise-action@5228313ee0372e111a38da051671ca30fc5a96db # v3`
  - `actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4`

## Implementation notes

- touch only:
  - `.github/workflows/make-all.yml`
  - `.github/workflows/pr-description-lint.yml`
- replace floating external action refs with these exact upstream-pinned SHAs and preserve the
  version comments:
  - `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4`
  - `jdx/mise-action@5228313ee0372e111a38da051671ca30fc5a96db # v3`
  - `actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4`
- do not modify local actions, job structure, cache keys, run steps, or workflow triggers

## Acceptance criteria

- no floating external action refs remain in those two workflows
- `git diff --check` passes after the workflow edit
- the resulting workflow YAML differs only in `uses:` pinning lines

## Validation

Run:

```bash
rg -n --pcre2 "uses:\\s*(?!\\./)(?!docker://)[^#\\n]+@(?![0-9a-f]{40}(?:\\s+#.*)?$)\\S+" .github/workflows
git diff --check
```
