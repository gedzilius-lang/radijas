@"
Hard constraint:
- Use only information present in this repository.
- Do not assume VPS state, services, or paths unless they are written in this repo.
- If information is missing, implement safe defaults and document assumptions in code comments.
- All outputs must be commit-ready changes inside the repo (install/, nginx/, systemd/, scripts/).
- Prefer idempotent, non-interactive deployment scripts.

Deliverable style:
- When asked for a deploy script, create/update install/deploy.sh in the repo rather than printing long prose.
"@ | Set-Content -Encoding UTF8 .\CLAUDE.md
