# nodeble-web

Static content for **nodeble.app** — hosted on Cloudflare Pages,
auto-deployed from this GitHub repo on every push to `main`.

## Files

| File | Purpose | URL once deployed |
|---|---|---|
| `index.html` | Landing page (placeholder until designer mockup) | `https://nodeble.app/` |
| `bootstrap.sh` | One-line install script for customer VPS | `https://nodeble.app/bootstrap.sh` |
| `releases.json` | Release manifest (strategy version metadata) | `https://nodeble.app/releases.json` |

## Deployment

Cloudflare Pages auto-deploys on every `git push origin main`.
- Deploy preview: `https://<commit-sha>.nodeble-web.pages.dev`
- Production: `https://nodeble.app`

## Phase status

- **Phase A (now)**: placeholder content, domain wired up, SSL active
- **Phase B (~Week 7)**: real `bootstrap.sh` ships, Mac app SSH + curl pipeline tested
- **Phase D (~Week 5-7)**: 4 module `deploy.sh` refactor lands, install-via-bootstrap functional
- **Phase F (~Week 9)**: full integration test pass

See `~/projects/cto/reviews/2026-04-26-phase-4.1-backend-contract-freeze.md`
+ `~/projects/ceo/plans/2026-04-24-gui-install-backend-plan.md` for context.

## Maintenance

- `releases.json` is updated by Backend Director each strategy module release
- `bootstrap.sh` is iterated through Phase B-D as deploy.sh refactor lands
- `index.html` is replaced by designer mockup (Phase 5+ landing page)

## Owner

Backend Director (协作总监 / GUI v1 Backend persona) — same agent as CTO + Tower coordinator + M3.x api-server maintainer per `feedback_cto_persona_consolidation.md`.
