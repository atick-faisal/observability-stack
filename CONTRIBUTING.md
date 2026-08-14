# Contributing

Thanks for thinking about this. Issues, bug reports and pull requests are all welcome.

For anything non-trivial, open an issue or start a
[discussion](https://github.com/atick-faisal/observability-stack/discussions) first. This
stack is deployed as a unit, so a change that looks small in one file often has to be
matched in a compose file, a dashboard and a doc page — agreeing on the shape first saves
rework.

## The bar

From [`docs/local-dev.md`](docs/local-dev.md):

> Every verification script in this repo is written against that local run. If a change
> cannot be demonstrated here, it is not finished.

So the local stack is where a change gets proven, not CI.

## Code contribution

1. Open an issue describing the change.
2. Fork and branch off `main`, naming the branch `<type>/<slug>` — `feat/alloy-retry`,
   `docs/operations-backup`.
3. Make the change, and run the checks below.
4. Open the PR with a description of what changed and how you verified it.

## Before you open the PR

```bash
make lint            # type-check and lint the SDK and the demo
make test            # the SDK test suite
make verify-config   # render both deployed compose shapes and check they resolve
```

Then prove it end to end:

```bash
make demo-up
make verify-signals
make verify-dashboards
make demo-down
```

If your change touches the edge or the agent's buffering, the matching targets are
`make demo-up EDGE=1 && make verify-ingest` and
`make demo-up SECOND_AGENT=1 && make verify-resilience`. The latter simulates a real
15-minute outage, so give it time.

Scripts under `scripts/` are checked with `shellcheck --severity=warning`, and workflow
files with `actionlint`. CI runs all of the above.

## Commit messages

Gitmoji followed by a Conventional Commits type, then a lowercase subject. No scopes.

```
✨ feat: cap every container's memory with mem_limit
🐛 fix: wait for enough pre-outage history in verify-resilience
👷 ci: move the nightly checks to a weekly schedule
```

| Emoji | Type | For |
| --- | --- | --- |
| ✨ | `feat` | new capability |
| 🐛 | `fix` | bug fix |
| 📝 | `docs` | documentation |
| ✅ | `test` | tests and verification scripts |
| 👷 | `ci` | workflows |
| 🔧 | `refactor` | restructuring without behaviour change |
| 🔧 | `config` | configuration changes |
| 📌 | `build` | pinned versions and build setup |
| ⚡️ | `perf` | performance |

## Bumping a pinned image

Read [`docs/operations.md` §5](docs/operations.md) first. In short: take a backup, change
the tag **and** the digest together, run `make verify-config`, then bring the stack up with
`--build`. GlitchTip is the one to be careful with — its migrations do not run backwards.

Renovate opens these PRs automatically, grouped by ecosystem. GlitchTip is deliberately
excluded from that and waits for approval on the dependency dashboard; `postgres` is
excluded entirely, because its major is a deliberate choice rather than an update.

## Documentation

The site is MkDocs Material. Preview locally with `make docs`, and check for broken links
with `make docs-build`, which fails on any. Note that `docs/index.md`, `docs/agent.md` and
`docs/sdk.md` are generated at build time by `scripts/assemble-docs.sh` — edit `README.md`,
`agent/README.md` and `sdk/obstack/README.md` instead.
