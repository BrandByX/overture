# Overture Upstream Sync `#50`: Codex Stream Parsing

Created: 2026-04-17
Updated: 2026-04-17

## Goal

Port upstream Symphony PR `#50` so Overture stops treating ordinary stderr noise as malformed
Codex protocol output.

## Current state

- Overture emits `:malformed` for any non-JSON line after logging it
- the stderr-noise regression only confirms logging and does not assert malformed-event suppression

## Target state

- only JSON-like protocol frames that fail to decode emit `:malformed`
- ordinary stderr noise is still logged for diagnostics
- ordinary stderr noise no longer creates false malformed UI noise
- existing dashboard wording and Codex event types remain unchanged

## Implementation notes

- update the Codex app-server receive loop in `elixir/lib/symphony_elixir/codex/app_server.ex`
- add the same protocol-frame candidate guard used upstream before emitting `:malformed`
- preserve existing `log_non_json_stream_line` behavior
- extend `elixir/test/symphony_elixir/app_server_test.exs` so the stderr-noise path asserts:
  - the warning is still logged
  - no `:malformed` event is emitted
- add a regression for truncated JSON-like protocol frames so malformed protocol output still
  surfaces as `:malformed`

## Acceptance criteria

- stderr noise is still logged
- stderr noise does not emit `:malformed`
- truncated JSON-like frames still emit `:malformed`
- normal turn completion behavior remains unchanged

## Validation

Run:

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/app_server_test.exs
cd elixir && mise exec -- make all
```
