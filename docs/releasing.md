# Releasing

The pinned upstream releases are the four `ARG` lines at the top of `Dockerfile`:

    ARG FS_UAE_VERSION=v3.2.35
    ARG FS_UAE_SHA256=f3d3cb8d...
    ARG FS_UAE_LAUNCHER_VERSION=v3.2.35
    ARG FS_UAE_LAUNCHER_SHA256=cdfd74cd...

`FS_UAE_VERSION` is the single source of truth for the image release version, and names the
upstream emulator source release. The launcher is a separate upstream project on its own
release schedule — 3.2.35 of the launcher landed eleven days after the emulator — so it has
its own pin, and the image version follows the emulator. A launcher only bump therefore
refreshes the images at the current emulator version rather than creating a new one. Both
source tarballs are verified against their `SHA256` at build time, as is the launcher's one
PyPI dependency in `requirements-launcher.txt` (`--require-hashes`).

## Workflows

| Workflow | Trigger | Action |
| --- | --- | --- |
| `ci` | pull request, push to main | hadolint, shellcheck, actionlint, build, `tests/smoke.sh` |
| `release` | push to main touching `Dockerfile`, `entrypoint.sh` or `requirements-launcher.txt`, manual | build, smoke test, push images, create GitHub release |
| `upstream-bump` | daily 04:23 UTC, manual | open a PR bumping both pins to the latest FS-UAE and Launcher releases |

`upstream-bump` reads the release asset digests from the GitHub API, so it does not download
the tarballs. It uses `releases/latest` for each project, which skips prereleases, so FS-UAE
5 alpha builds are ignored until upstream marks one stable. It opens one PR covering both
projects, and builds and smoke tests the new pins before opening it, because pull requests
opened with `GITHUB_TOKEN` do not start workflow runs; the PR body links the run that tested
it. Dependabot covers the Debian base image, the actions used here and
`requirements-launcher.txt`; it cannot track upstream GitHub releases, which is what
`upstream-bump` exists for.

Merging a bump PR publishes `vX.Y.Z`, `X.Y.Z` and `latest`, and creates the matching GitHub
release. Re-running `release` for an existing version refreshes the images (for example after
a base image update, a launcher only bump, or an `entrypoint.sh` change) and leaves the
existing GitHub release alone.

## Secrets and variables

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `GITHUB_TOKEN` | built in | yes | GHCR push, release creation |
| `DOCKERHUB_USERNAME` | secret | no | Docker Hub push |
| `DOCKERHUB_TOKEN` | secret | no | Docker Hub access token; absent disables Docker Hub push |
| `DOCKERHUB_IMAGE` | variable | no | Docker Hub repository, default `anarkiwi/fs-uae` |

No personal access token is needed. Until `DOCKERHUB_TOKEN` is set, `release` pushes to GHCR
only and skips the Docker Hub login and tags.

## Manual release

Edit the `ARG` lines and merge to main, or run the `release` workflow by hand
(`workflow_dispatch`) to rebuild the currently pinned versions.
