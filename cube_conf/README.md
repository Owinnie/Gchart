# Dynamic `public` flag injection (Docker only)

Cube model YAML in git stays free of `check_visibility(...)` flags. Injection
runs only inside the container (or image build), never against the bind-mounted
checkout.

## How it works

1. **Dockerfile** copies `cube_conf` into `/cube/conf` and runs
   `CUBE_INJECT_VISIBILITY=1 python3 python/generate_access_rules.py` so the
   image already has injected flags + `access_rules.yaml`.
2. **docker-compose** mounts `./cube_conf` **read-only** at `/cube/conf.src`
   (not at `/cube/conf`).
3. **start.sh** syncs `/cube/conf.src` → `/cube/conf`, then regenerates/injects
   only under `/cube/conf` (container-local writable layer).

Your host tree and `git status` stay clean.

## Local script usage

```bash
# Safe: writes access_rules.yaml only (no YAML injection)
cd cube_conf && python3 python/generate_access_rules.py

# Explicit inject (only do this on a throwaway copy, never the repo)
CUBE_INJECT_VISIBILITY=1 python3 python/generate_access_rules.py
```

## Apply in semantic-data-layer

Copy these changes into the real Cube project:

- Replace `start.sh`, `Dockerfile`, `docker-compose.yml` volume mount
- Gate injection in `generate_access_rules.py` with `CUBE_INJECT_VISIBILITY`
- Stop mounting `./cube_conf:/cube/conf` read-write
- Gitignore generated `access_rules.yaml` / `logs/`
