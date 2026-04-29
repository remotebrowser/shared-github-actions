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

Deploy a Fly app. Builds a single dotenv stream of secrets and imports it with one `flyctl secrets import`, then `flyctl deploy --strategy bluegreen`. The stream is, in order:

1. **Doppler** — every key from the configured Doppler project/config.
2. **`GIT_REV`** — automatically set to `github.sha` of the calling workflow, so the running app can self-report its deployed commit.
3. **`extra-secrets`** input (optional) — additional `KEY=VALUE` lines from the workflow. Applied last, so a key here overrides the same key from Doppler.

```yaml
- uses: remotebrowser/shared-github-actions/deploy-fly@v1
  with:
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: flyfleet
    doppler-config: github
    fly-api-token: ${{ secrets.FLY_API_TOKEN }}
    app-name: flyfleet
    extra-secrets: |   # optional
      FEATURE_FLAG_X=enabled
      DEPLOY_ENV=${{ github.ref_name }}
```

`extra-secrets` values are not auto-masked in workflow logs — pass them via `${{ secrets.* }}` if they're sensitive. Stale-secret cleanup runs only when `doppler-token` is set, and operates against the full union of Doppler keys + `GIT_REV` + `extra-secrets` keys, so none of these are ever flagged as stale.

See `deploy-fly/action.yml` for the full input list.

### `test-on-fly`

Deploy a throwaway Fly app, wait for a result marker file written by the container, pull logs back as an artifact, destroy the app. Secrets are staged the same way as `deploy-fly`: Doppler → `GIT_REV` → `extra-secrets`, last write wins on duplicate keys. No stale-cleanup pass since the test app is freshly created.

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
    extra-secrets: |   # optional
      MODE=direct
      CONTAINER_IMAGE=registry.fly.io/keep-chrome-live-ci:latest
```

A random hex suffix is appended to `app-name-prefix` to keep concurrent runs isolated. The deployed test container can read its commit SHA from the `GIT_REV` env var.

See `test-on-fly/action.yml` for the full input list.

### `prepare-matrix`

Filter a JSON entry list down to user-selected items, or fall back to the full list when nothing is selected. Designed for a `prepare-matrix` job whose output feeds `strategy.matrix.include` (object array) or `strategy.matrix.<key>` (string array) via `fromJSON()`.

```yaml
jobs:
  prepare-matrix:
    runs-on: ubuntu-22.04
    outputs:
      matrix: ${{ steps.pm.outputs.matrix }}
    steps:
      - id: pm
        uses: remotebrowser/shared-github-actions/prepare-matrix@v1
        with:
          # One JSON value per line. Strings are quoted; objects use full JSON.
          # Add or remove an entry by adding/deleting a line — no commas, no brackets.
          entries: |
            { "env": "demo", "config": "fly", "app_name": "flyfleet"     }
            { "env": "dev",  "config": "dev", "app_name": "flyfleet-dev" }
          # Newline-separated list of selected keys. Each key is matched against
          # `key-field` of the entry (object array) or the entry value itself
          # (string array). Empty list → fall back to every entry, so on
          # push/pull_request triggers (where workflow_dispatch inputs are empty)
          # all entries run.
          selections: |
            ${{ inputs.demo && 'demo' || '' }}
            ${{ inputs.dev  && 'dev'  || '' }}
          key-field: env

  deploy:
    needs: prepare-matrix
    runs-on: ubuntu-22.04
    strategy:
      matrix:
        include: ${{ fromJSON(needs.prepare-matrix.outputs.matrix) }}
    steps:
      - run: echo "deploying ${{ matrix.app_name }} with config ${{ matrix.config }}"
```

For a string-array matrix, omit `key-field` and quote each entry:

```yaml
entries: |
  "direct"
  "pool"
selections: |
  ${{ inputs.direct && 'direct' || '' }}
  ${{ inputs.pool   && 'pool'   || '' }}
```

See `prepare-matrix/action.yml` for the full input list.

## Versioning

- Pin to `@v1` for auto-patch updates, or to a full commit SHA for strict supply-chain posture.
- Breaking changes bump to `v2` (and get a new moving `v2` tag).
