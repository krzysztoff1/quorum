## What and why


## Checklist

The rules are in [docs/architecture/pr-checklist.md](../docs/architecture/pr-checklist.md).

- [ ] CI green (`engine`, `e2e`, `test`)
- [ ] Engine run path, prompts, protocol, schema or catalog touched? Canary result pasted below (`scripts/canary.sh`)
- [ ] User-visible change? Screenshot of the installed app attached (`scripts/install.sh --open`)
- [ ] Fixtures changed? Re-recorded on purpose with `bun run fixtures:update`, diff reviewed
- [ ] Version bumped (protocol, record schema, catalog)? Fixtures re-recorded

## Canary


## Screenshot

