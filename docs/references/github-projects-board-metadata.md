# GitHub Projects Board Metadata

Created: 2026-03-13

## Purpose

Capture the live GitHub Projects board metadata that future runtime and smoke-test tickets need
without mixing those environment-specific values into the generic runtime contract docs.

## Owner and repository

- owner login: `BrandByX`
- repository: `BrandByX/overture`
- owner type for runtime config: `organization`

## Delivery board

- board name: `Overture Delivery`
- board number: `6`
- board URL: <https://github.com/orgs/BrandByX/projects/6>
- board node ID: `PVT_kwDOCZhNHc4BRmMe`
- purpose: canonical implementation tracking board for Overture work

### Delivery Status field

- field name: `Status`
- field type: `ProjectV2SingleSelectField`
- field node ID: `PVTSSF_lADOCZhNHc4BRmMezg_YP7A`

### Delivery Status options

- `Backlog` -> `9e04ac26`
- `Todo` -> `ec18a1c6`
- `In Progress` -> `cdb65b21`
- `Human Review` -> `e9d11d04`
- `Rework` -> `867a2bb7`
- `Merging` -> `7a93fdf1`
- `Done` -> `01fb8d27`
- `Cancelled` -> `d671fce9`
- `Duplicate` -> `7b773efb`

## Sandbox board

- board name: `Overture Sandbox`
- board number: `5`
- board URL: <https://github.com/orgs/BrandByX/projects/5>
- board node ID: `PVT_kwDOCZhNHc4BRmMf`
- purpose: dogfooding board for live validation and smoke-test runs

### Sandbox Status field

- field name: `Status`
- field type: `ProjectV2SingleSelectField`
- field node ID: `PVTSSF_lADOCZhNHc4BRmMfzg_YP7E`

### Sandbox Status options

- `Backlog` -> `6362c745`
- `Todo` -> `4c006868`
- `In Progress` -> `357fccd6`
- `Human Review` -> `0208e9a5`
- `Rework` -> `86458504`
- `Merging` -> `57d0f6cc`
- `Done` -> `099b1125`
- `Cancelled` -> `1dda1f75`
- `Duplicate` -> `67952265`

### Sandbox Priority prerequisite

The parity live-smoke path now expects `Overture Sandbox` to expose a numeric `Priority` field for
priority-ordering validation.

- expected field name: `Priority`
- expected field type: `ProjectV2Field` with `dataType == NUMBER`

If that field is missing, the opt-in priority smoke scenario should fail clearly instead of
silently skipping.

## Workflow semantics

- non-active holding state:
  - `Backlog`
- active states:
  - `Todo`
  - `In Progress`
  - `Human Review`
  - `Rework`
  - `Merging`
- terminal states:
  - `Done`
  - `Cancelled`
  - `Duplicate`

These semantics must stay aligned with the runtime contract in
`docs/product-specs/github-projects-runtime-contract.md`.

## Board intake policy

The current board intake policy is explicit rather than implicit.

- `Overture Delivery` is the canonical location for implementation tickets.
- `Overture Sandbox` is reserved for dogfooding and live validation.
- New repository issues should be added to `Overture Delivery` intentionally.
- Sandbox issues should be added to `Overture Sandbox` intentionally.

## Workflow automation state

Observed GitHub Project workflows as of 2026-03-13:

### Overture Delivery

- `Auto-add sub-issues to project` -> `PWF_lADOCZhNHc4BRmMezgT9Ab0` (enabled)
- `Auto-close issue` -> `PWF_lADOCZhNHc4BRmMezgT9Abs` (disabled)
- `Item added to project` -> `PWF_lADOCZhNHc4BRmMezgT9AcE` (disabled)
- `Item closed` -> `PWF_lADOCZhNHc4BRmMezgT9Abk` (disabled)
- `Pull request linked to issue` -> `PWF_lADOCZhNHc4BRmMezgT9Ab8` (disabled)
- `Pull request merged` -> `PWF_lADOCZhNHc4BRmMezgT9Abo` (disabled)

### Overture Sandbox

- `Auto-add sub-issues to project` -> `PWF_lADOCZhNHc4BRmMfzgT9AcI` (enabled)
- `Auto-close issue` -> `PWF_lADOCZhNHc4BRmMfzgT9AcA` (disabled)
- `Item added to project` -> `PWF_lADOCZhNHc4BRmMfzgT9AcQ` (disabled)
- `Item closed` -> `PWF_lADOCZhNHc4BRmMfzgT9Abw` (disabled)
- `Pull request linked to issue` -> `PWF_lADOCZhNHc4BRmMfzgT9AcM` (disabled)
- `Pull request merged` -> `PWF_lADOCZhNHc4BRmMfzgT9Ab4` (disabled)

## Operational note

This ticket did not verify a native GitHub workflow that automatically places every new
`BrandByX/overture` issue onto `Overture Delivery`. Because that behavior is not currently
documented or exposed through a clearly configured project automation here, the supported policy is
explicit add rather than assumed auto-add.

If a native auto-add rule is later enabled and verified, update this document and the surrounding
harness docs in the same change.
