# shared-github-actions

Reusable GitHub Actions shared across multiple repositories.

## Actions

### `setup-doppler`

Installs the `doppler-export` shell script on `$PATH`. Consumers then pipe its output into the next command.

```yaml
- uses: remotebrowser/shared-github-actions/setup-doppler@v1

- shell: bash
  env:
    DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN }}
  run: doppler-export flyfleet github | flyctl secrets import --app flyfleet --stage
```

`doppler-export <project> [config] [--format=dotenv|shell|json]`:
- `dotenv` (default) — `KEY="VALUE"` per line. Pipes into `flyctl secrets import`, `docker --env-file <(...)`, or `>.env`.
- `shell` — `export KEY='VALUE'` with single-quote escape. For `source <(doppler-export ... --format=shell)`.
- `json` — single JSON object. For bespoke `jq` piping.

**Stderr output:**
- One line per downloaded key name (for easy visual confirmation / piping to `grep`).
- `::add-mask::` directives for values whose key matches (case-insensitive) `KEY`, `TOKEN`, `PASSWORD`, `PASSWD`, or `PWD`. Keys without those substrings (e.g. `LOG_LEVEL`, `ENVIRONMENT`) are not masked so they remain readable in workflow logs.

**Security notes:**
- Never redirect stderr. `::add-mask::` directives go there, and suppressing them defeats GitHub log redaction.
- Values shorter than 4 characters are silently not masked by GitHub. The script warns on stderr and names such keys.
- Token comes from `DOPPLER_TOKEN` in the step's `env:`, not from `$GITHUB_ENV`.
- Refuses to run under `pull_request_target` unless `ALLOW_PULL_REQUEST_TARGET=1`.
- For multiline values (certs, SSH keys) prefer `--format=shell` or `--format=json`; dotenv output quotes them but downstream parsers vary.
- If you store a genuine secret in a key whose name doesn't match the heuristic (e.g. `API` without `_KEY`), rename it to include one of the recognized substrings — the script will not mask it otherwise.

### `deploy-fly`

Deploy a Fly app. Fetches Doppler secrets, imports them via `flyctl secrets import`, then `flyctl deploy`.

```yaml
- uses: remotebrowser/shared-github-actions/deploy-fly@v1
  with:
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: flyfleet
    doppler-config: github
    fly-api-token: ${{ secrets.FLY_API_TOKEN }}
    app-name: flyfleet
```

See `deploy-fly/action.yml` for the full input list.

### `test-on-fly`

Deploy a throwaway Fly app, wait for a result marker file written by the container, pull logs back as an artifact, destroy the app.

```yaml
- uses: remotebrowser/shared-github-actions/test-on-fly@v1
  with:
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: flyfleet
    doppler-config: github
    fly-api-token: ${{ secrets.FLY_API_TOKEN }}
    app-name-prefix: test-flyfleet-direct
    fly-toml: fly.test.toml
    dockerfile: Dockerfile.test
```

A random hex suffix is appended to `app-name-prefix` to keep concurrent runs isolated.

See `test-on-fly/action.yml` for the full input list.

## Versioning

- Pin to `@v1` for auto-patch updates, or to a full commit SHA for strict supply-chain posture.
- Breaking changes bump to `v2` (and get a new moving `v2` tag).
