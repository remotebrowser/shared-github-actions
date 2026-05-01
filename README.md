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

Deploy a Fly app. Builds a single dotenv stream of secrets and imports it with one `flyctl secrets import`, then `flyctl deploy --strategy bluegreen --env GIT_REV=<github.sha>`. The stream is, in order:

1. **Doppler** — every key from the configured Doppler project/config.
2. **`extra-secrets`** input (optional) — additional `KEY=VALUE` lines from the workflow. Applied last, so a key here overrides the same key from Doppler.

`GIT_REV` is passed as a plain Fly env var (not a secret) via `flyctl deploy --env`, so the running app can self-report its deployed commit and the Machines API exposes it in `config.env` for status dashboards.

```yaml
- uses: remotebrowser/shared-github-actions/deploy-fly@v1
  with:
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: flyfleet
    doppler-config: github
    # fly-api-token is optional when Doppler holds a FLY_API_TOKEN secret.
    # Pass it explicitly to override the Doppler value.
    app-name: flyfleet
    extra-secrets: |   # optional
      FEATURE_FLAG_X=enabled
      DEPLOY_ENV=${{ github.ref_name }}
```

`fly-api-token` resolution order: explicit input wins, otherwise pulled from Doppler under the key `FLY_API_TOKEN`. If both are set and disagree, the input is used and a `::warning::` is logged. If neither is available, the action fails before any `flyctl` call.

`extra-secrets` values are not auto-masked in workflow logs — pass them via `${{ secrets.* }}` if they're sensitive. Stale-secret cleanup runs only when `doppler-token` is set, and operates against the full union of Doppler keys + `extra-secrets` keys, so none of these are ever flagged as stale. (Apps that used the previous behavior — where `GIT_REV` was a Fly secret — will see the stale `GIT_REV` secret cleaned up on the next deploy and replaced by the env var.)

See `deploy-fly/action.yml` for the full input list.

### `test-on-fly`

Deploy a throwaway Fly app, wait for a result marker file written by the container, pull logs back as an artifact, destroy the app. Secrets are staged the same way as `deploy-fly`: Doppler → `extra-secrets`, last write wins on duplicate keys. `GIT_REV` is passed as a plain env var via `flyctl deploy --env`. No stale-cleanup pass since the test app is freshly created.

```yaml
- uses: remotebrowser/shared-github-actions/test-on-fly@v1
  with:
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: flyfleet
    doppler-config: github
    # fly-api-token optional — same resolution rules as deploy-fly.
    app-name-prefix: test-flyfleet-direct
    fly-toml: fly.test.toml
    dockerfile: Dockerfile.test
    extra-secrets: |   # optional
      MODE=direct
      CONTAINER_IMAGE=registry.fly.io/keep-chrome-live-ci:latest
```

A random hex suffix is appended to `app-name-prefix` to keep concurrent runs isolated. The deployed test container can read its commit SHA from the `GIT_REV` env var.

See `test-on-fly/action.yml` for the full input list.

### `container-health-check`

Build a Docker image, run it as a detached container, poll an HTTP endpoint until it returns the expected substring, dump the container logs, and remove the container. Optionally loads every key from a Doppler config and forwards them into the container — secrets stay in memory only (no `--env-file` on disk, no `$GITHUB_ENV` write).

Replaces the typical `docker build / docker run -e VAR1 -e VAR2 / curl loop / docker logs / docker rm` recipe with a single composite step.

```yaml
jobs:
  container:
    runs-on: ubuntu-22.04
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: remotebrowser/shared-github-actions/container-health-check@v1
        with:
          doppler-token: ${{ secrets.DOPPLER_TOKEN }}
          doppler-project: flyfleet
          doppler-config: github
          image-name: flyfleet
          port-mapping: 8300:8300
          health-url: http://localhost:8300/health
          health-match: OK
```

When `doppler-token` is set, **every** Doppler key is forwarded to the container as `-e KEY` (value inherited from the step shell). Prune the Doppler config itself if any key shouldn't reach the container. Without `doppler-token`, the container runs with no extra env — use `extra-config` (below) to pass `-e KEY=VALUE` flags directly.

For anything else `docker run` accepts (`--network`, `-v`, extra `-e`, etc.) use the `extra-config` input. One flag per line, shell-split so quoted values work. Applied after the Doppler-derived `-e` flags, so an `-e KEY=...` here overrides the same key from Doppler:

```yaml
- uses: remotebrowser/shared-github-actions/container-health-check@v1
  with:
    image-name: getgather
    health-url: http://localhost:23456/health
    extra-config: |
      --network host
      -e CHROMEFLEET_URL=http://localhost:8300
```

For multiple endpoints on the same container, use `health-checks` (one JSON object per line). Checks run sequentially, each gets the full `health-timeout-seconds` budget. **Don't** add a follow-up `curl` step in the calling workflow — the container is removed in this action's `always()` step, so external polling after it returns will fail:

```yaml
- uses: remotebrowser/shared-github-actions/container-health-check@v1
  with:
    image-name: getgather
    health-checks: |
      {"url": "http://localhost:23456/health"}
      {"url": "http://localhost:23456/extended-health"}
    extra-config: |
      --network host
      -e CHROMEFLEET_URL=http://localhost:8300
```

`match` defaults to `OK` per check; pass `{"url": "...", "match": "ready"}` to override. `health-checks` wins over `health-url` when both are set.

Each poll uses `curl -fs "$url" | grep -q "$match"` once per second until success or `health-timeout-seconds` is hit. The container is `docker rm -f`'d on every outcome (success, health-check failure, build failure).

See `container-health-check/action.yml` for the full input list.

### `push-fly-image`

Tag a local Docker image and push it to `registry.fly.io/<app-name>:<tag>`. Wraps `flyctl auth docker` + `docker tag` + `docker push` so callers don't carry the auth setup themselves.

```yaml
- uses: remotebrowser/shared-github-actions/push-fly-image@v1
  with:
    image: ghcr.io/remotebrowser/chrome-live:latest
    app-name: keep-chrome-live
    fly-api-token: ${{ secrets.FLY_API_TOKEN }}
```

The `image` input must be in the local Docker daemon when the action runs. Built locally (`docker build`, [`container-health-check`](#container-health-check)) it already is. For images on a remote registry (e.g. GHCR), set `pull: true` and the action will `docker pull` it for you — caller is still responsible for authenticating to the source registry first if it's private. The action exposes the pushed URI as `outputs.image-uri` (`registry.fly.io/<app-name>:<tag>`) so downstream steps can reference the exact tag.

**Single-target by design.** To publish the same image to multiple Fly apps — even across different orgs — fan out via `strategy.matrix`, one row per target with its own `fly-api-token`. Each row gets fresh docker credentials, so per-org tokens stay isolated:

```yaml
publish-fly:
  needs: publish
  runs-on: ubuntu-22.04
  strategy:
    fail-fast: false
    matrix:
      target:
        - app: keep-chrome-live
          token_secret: FLY_API_TOKEN_KEEP_ORG       # org A
        - app: chrome-live-staging
          token_secret: FLY_API_TOKEN_KEEP_ORG       # same org, different app
        - app: chrome-live-mirror
          token_secret: FLY_API_TOKEN_PARTNER_ORG    # different org, different token
  steps:
    - uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    - uses: remotebrowser/shared-github-actions/push-fly-image@v1
      with:
        image: ghcr.io/${{ github.repository }}:latest
        app-name: ${{ matrix.target.app }}
        fly-api-token: ${{ secrets[matrix.target.token_secret] }}
        pull: true   # docker pull --platform linux/amd64 first
```

`pull: true` makes the action `docker pull --platform linux/amd64 <image>` before tagging — saves the explicit pull step and also makes `act` on Apple Silicon work (the Fly registry is amd64-only, so the platform pin is always correct).

`${{ secrets[matrix.target.token_secret] }}` resolves the secret *name* from the matrix row to the actual secret *value* at step time — the YAML never holds a token. `fail-fast: false` keeps a failed push to one target from blocking the others.

For workflows that already use [`prepare-matrix`](#prepare-matrix), feed it `{app, token_secret}` entries and reference the output the same way.

See `push-fly-image/action.yml` for the full input list.

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
