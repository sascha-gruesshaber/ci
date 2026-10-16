# ci

Shared GitHub Actions building blocks and the CI standard for the Node projects of
sascha-gruesshaber. Tests stay in each project because they are project-specific.
Building, deploying and applying updates come from here, so that all projects work the
same way.

## The flow in every project

```
pull request ──► check ──► e2e                     (check only, build nothing)
push main    ──► check ──► e2e ──► build ──► deploy (build image, deploy to Coolify)
```

- There is **one** environment: `main` is live.
- Changes only arrive through pull requests and **squash merges**. The pull request
  title becomes the commit title, the description becomes the commit message, and the
  branch is deleted afterwards.
- Images are built **only on `main`**, never in pull requests. If the build fails,
  nothing is deployed and the running version stays in place.

## The standard

### Workflow file

Every project has exactly one pipeline: `.github/workflows/ci.yml`.

```yaml
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  # A new push to a pull request cancels the old run, on main never.
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Jobs with exactly these names (if a project does not need one, it is left out):

| Job | When | Content |
|---|---|---|
| `check` | always | Lint, types, unit tests, migration checks. Project-specific. |
| `e2e` | always | Playwright or similar. Project-specific. |
| `build` | push to `main` only | `uses: sascha-gruesshaber/ci/.github/workflows/docker-image.yml@v1` |
| `deploy` | push to `main` only | `uses: sascha-gruesshaber/ci/.github/workflows/coolify-deploy.yml@v1` |
| `automerge` | Dependabot pull requests only | `uses: sascha-gruesshaber/ci/.github/workflows/dependabot-automerge.yml@v1` |

Further rules:

- Every job has `timeout-minutes`.
- Node 24, `actions/setup-node` with the package manager cache.
- Actions on their current major version. Dependabot keeps them up to date.
- No tag triggers (`v*`), no releases, no second environment.

### Images

| | Name | Tags |
|---|---|---|
| Project with one app | `ghcr.io/<owner>/<repo>` | `main`, `sha-<12 characters>` |
| Project with several apps | `ghcr.io/<owner>/<repo>/<app>` | `main`, `sha-<12 characters>` |

Coolify always follows the `main` tag. Images are built for `linux/amd64`, without a
provenance attestation (a plain image, not an index with "unknown/unknown"). Every image
gets the build arguments `APP_REVISION` (full commit SHA) and `APP_BUILT_AT` (ISO time,
UTC) as well as the OCI labels `org.opencontainers.image.revision`, `.created` and
`.source`.

### Revision

Every deployed app with an HTTP endpoint reports which commit is running. Its health
endpoint (or `/version`) contains exactly this in its JSON body:

```json
"revision":"<full 40-character commit SHA>"
```

The value comes from `APP_REVISION`. That is the only way `deploy` can tell that the new
commit is really running and not the old container still answering. For a purely static
app, a `/version.json` generated at build time with the same field is enough.

### Coolify

- Secret `COOLIFY_API_TOKEN` in the project repository.
- UUIDs of the Coolify *applications* as repository variables: `COOLIFY_UUID` for one
  app, `COOLIFY_UUID_<APP>` (uppercase, `-` becomes `_`) for several.
- GitHub environment `production` with the public URL.

### Dependabot

`.github/dependabot.yml` following the template in
[`templates/dependabot.yml`](templates/dependabot.yml): the package manager and
`github-actions`, weekly on Mondays at 05:00 Berlin time, a 7-day cooldown after a
release, all minor and patch updates in one pull request, major versions separately.
`automerge` merges minor and patch updates itself once CI is green; major versions wait
for a human to review them.

## The building blocks

Always call them with `@v1`. `v1` is a moving tag on the latest `v1.x.y`. Incompatible
changes only ship as `v2`.

### `docker-image.yml`: build and push an image

```yaml
build:
  needs: [check, e2e]
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  permissions:
    contents: read
    packages: write
  uses: sascha-gruesshaber/ci/.github/workflows/docker-image.yml@v1
  with:
    image: ghcr.io/${{ github.repository }}   # without a tag
    # dockerfile: Dockerfile                  # default
    # context: .                              # default
    # target: api-runner                      # multi-stage target, optional
    # build-args: |                           # additional build arguments, optional
    #   VITE_API_URL=https://api.example.org
    # smoke-test: ./scripts/smoke-test.sh     # optional, see below
```

| Input | Required | Default | Meaning |
|---|---|---|---|
| `image` | yes | | Image name without a tag |
| `dockerfile` | | `Dockerfile` | Path to the Dockerfile, relative to the repository root (like `docker build -f`), not to the `context` |
| `context` | | `.` | Build context |
| `target` | | empty | Multi-stage target |
| `build-args` | | empty | Additional build arguments, one per line |
| `smoke-test` | | empty | Command run against the image after the build |

Output `image`: the built reference with the `sha-…` tag.

`smoke-test` runs in the checked-out repository with the environment variable `IMAGE`
set, before anything is pushed. If it fails, nothing is pushed.

Several apps: call the job with `strategy.matrix`, one matrix row per app.

### `coolify-deploy.yml`: deploy and verify

```yaml
deploy:
  needs: build
  uses: sascha-gruesshaber/ci/.github/workflows/coolify-deploy.yml@v1
  with:
    uuids: ${{ vars.COOLIFY_UUID }}
    revision-urls: https://example.org/version
    environment-url: https://example.org
  secrets:
    COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
```

| Input | Required | Default | Meaning |
|---|---|---|---|
| `uuids` | yes | | UUIDs of the Coolify applications, separated by spaces or newlines |
| `revision-urls` | | empty | URLs whose body must contain `"revision":"<github.sha>"` |
| `urls` | | empty | URLs that only need to answer with HTTP 2xx |
| `environment` | | `production` | GitHub environment |
| `environment-url` | | empty | URL GitHub shows on the environment |
| `coolify-url` | | `https://coolify.gruesshaber.eu` | |
| `wait-minutes` | | `10` | How long to wait for the new revision, at most 55 (the job has 60 minutes) |

Triggers each application with `POST /api/v1/deploy?uuid=…&force=false`. If Coolify
rejects one, the run turns red. Then every URL is polled until it reports the new
revision or answers, respectively. There is no fixed waiting time. If the old commit is
still running after `wait-minutes`, the run turns red.

Deployments of a repository run one after another, and a running one is never
cancelled, because the containers migrate on startup. If several new ones arrive during
a deployment, only the newest waits; the ones in between are dropped (that is how
GitHub's `concurrency` works). That does no harm, since they all deploy the `main` tag
anyway.

An empty `uuids` list is an error ("repository variable missing?"). When several
variables are joined into one list, a single missing one goes unnoticed; it disappears
in the whitespace. In that case at most the matching `revision-url` reports the old
revision.

Important for several apps with a path filter: `revision-urls` must only contain the
apps that were actually built in this run. An app that was not rebuilt rightly reports
the old revision.

### `dependabot-automerge.yml`: apply updates

```yaml
automerge:
  needs: [check, e2e]
  if: github.event_name == 'pull_request' && github.event.pull_request.user.login == 'dependabot[bot]'
  permissions:
    contents: write
    pull-requests: write
    actions: write
  uses: sascha-gruesshaber/ci/.github/workflows/dependabot-automerge.yml@v1
```

| Input | Required | Default | Meaning |
|---|---|---|---|
| `workflow` | | `ci.yml` | Workflow file triggered on `main` via `workflow_dispatch` after the merge |

Squash-merges minor and patch updates, but not major versions. Then it starts
`workflow` on `main` via `workflow_dispatch`. That is necessary because a merge made
with `GITHUB_TOKEN` does not trigger a push workflow, and the update would otherwise
never be deployed.

## Publishing a new version

1. Change via pull request to `main`. CI checks with `actionlint` and runs
   `test/coolify-deploy.test.sh`, the deploy logic against a dummy server. Locally the
   same: `bash test/coolify-deploy.test.sh`.
2. On `main`, start the `selftest` workflow by hand (`gh workflow run selftest.yml`).
   It builds `test/Dockerfile` with a smoke test through `docker-image.yml`, pushes to
   `ghcr.io/sascha-gruesshaber/ci/selftest` and checks the tags and labels in the
   registry.
3. If it is green, set a new `v1.x.y` tag and move `v1` to the same commit
   (`git push -f origin v1`).

## Access

This repository is public. While it was private, Dependabot in the projects could not
read its tags: the weekly `github-actions` run failed with
`git_dependencies_not_reachable`. A personal account (as opposed to an organization)
has no setting that grants Dependabot access to other private repositories.

So nothing belongs here that is secret or specific to one project: no secrets, no
internal addresses, no Coolify UUIDs. Those stay as secrets and variables in the project
repositories.

The scripts still live directly in the workflows and not in separate files. Otherwise
every call would also have to check out this repository, at exactly the commit of `@v1`.
