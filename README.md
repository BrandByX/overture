# Overture

Overture is BrandByX's GitHub Projects-focused fork of Symphony. It turns project work into
isolated, autonomous implementation runs while the fork is being migrated from the upstream
Linear-oriented baseline.

[![Overture demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_This [demo video](.github/media/symphony-demo.mp4) shows the upstream Symphony orchestration model
that Overture starts from. The current fork is being adapted from that baseline toward GitHub
Projects-backed work execution._

> [!WARNING]
> Overture is a low-key engineering preview fork for testing in trusted environments.

## Running Overture

### Requirements

Overture works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). It is the next step after
managing coding agents: managing the work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Overture in a programming language of your choice:

> Implement Overture according to the following spec:
> https://github.com/BrandByX/overture/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Overture implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Overture for my repository based on
> https://github.com/BrandByX/overture/blob/main/elixir/README.md

## v1 baseline

Overture currently ships the upstream Symphony Elixir implementation as its starting point.

- Public-facing repo and documentation identity now use `Overture`.
- Internal runtime identifiers such as `SymphonyElixir`, `:symphony_elixir`, and `./bin/symphony`
  remain unchanged in v1.
- The `upstream` remote should remain configured so future upstream changes can be reviewed and
  cherry-picked selectively.
- The GitHub Projects tracker migration is planned work, not completed baseline behavior.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
