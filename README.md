# cibuild — Documentation

> Version 0.8.0 · POSIX shell · GitLab CI · GitHub Actions · Local

---

## Table of Contents

1. [Overview](#overview)
2. [Pipeline Stages](#pipeline-stages)
3. [Configuration](#configuration)
   - [Config Files](#config-files)
   - [Environment Variable Naming](#environment-variable-naming)
4. [Environment Variable Reference](#environment-variable-reference)
   - [Global](#global)
   - [Check Stage](#check-stage)
   - [Build Stage](#build-stage)
   - [Test Stage](#test-stage)
   - [Release Stage](#release-stage)
5. [Dynamic Variables (Secrets, Build Args, Cosign Annotations)](#dynamic-variables)
6. [CI Adapter Variables](#ci-adapter-variables)
7. [Tag Templates](#tag-templates)
8. [Registry Configuration](#registry-configuration)
9. [Mirror Registries](#mirror-registries)
10. [Test Assertions](#test-assertions)
11. [Logging](#logging)

---

## Overview

`cibuild` is a single-binary CI tool for building, testing, releasing and signing OCI container images. It is written in POSIX shell and runs inside a container image provided by the cibuilder project.

The tool is invoked as:

```sh
cibuild -r <command>
# command: check | build | test | release | all
```

CI platform detection is automatic (GitLab CI, GitHub Actions, local). Each platform has an adapter that maps native CI variables to cibuild's internal interface.

---

## Pipeline Stages

| Stage | Description |
|-------|-------------|
| `check` | Compares base image layers of the current build against the last built image. Cancels the pipeline if nothing changed (skips unnecessary rebuilds). Only runs on scheduled or manually triggered pipelines. |
| `build` | Builds per-platform OCI images and pushes them to the target registry. Supports `buildctl` (default), `buildx`, and `kaniko`. |
| `test` | Runs a test script and/or JSON-defined assertions against the freshly built image using Docker or Kubernetes. |
| `release` | Assembles a clean multi-platform OCI image index from the per-platform images, optionally adds Docker attestation manifests, signs with cosign, copies additional tags, and mirrors to other registries. |

Each stage can be individually enabled or disabled and supports `pre_script` / `post_script` hooks.

---

## Configuration

### Config Files

cibuild loads configuration from files in the repository root, in the following order:

1. `cibuild.env` — generic config, loaded for all CI environments
2. `cibuild.<env>.env` — adapter-specific config (e.g. `cibuild.gitlab.env`, `cibuild.github.env`, `cibuild.local.env`)

Both files are plain shell files sourced with `set -a` (all variables exported). You can use them to set any `CIBUILD_*` variable.

### Environment Variable Naming

All settings are controlled via environment variables with the prefix `CIBUILD_`. The mapping to internal config keys follows a simple rule: strip the prefix and lowercase.

```
CIBUILD_BUILD_PLATFORMS  →  build_platforms
CIBUILD_RELEASE_ENABLED  →  release_enabled
```

Variables set directly in the environment always take precedence over values in config files, which take precedence over the built-in defaults documented below.

---

## Environment Variable Reference

### Global

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_VERSION` | `0.8.0` | cibuild version (read-only, informational) |
| `CIBUILD_PIPELINE_ENV` | *(auto-detected)* | Force a specific CI adapter: `gitlab`, `github`, or `local`. Normally auto-detected from CI environment variables. |
| `CIBUILD_DOCKER_HOST` | `tcp://docker:2375` | Docker daemon address used by build and test stages when a Docker socket is required. |

---

### Check Stage

The check stage compares the layer digests of the base image (extracted from the last `FROM` line of the Containerfile) against the layers of the previously built target image. If the base image has not changed, the pipeline is canceled to save resources.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_CHECK_ENABLED` | `0` | Set to `1` to enable the check stage. |
| `CIBUILD_CHECK_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the check. |
| `CIBUILD_CHECK_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the check. |

Additional variable used by the check stage (not in `_CIBUILD_DEFAULTS`, set externally):

| Variable | Description |
|----------|-------------|
| `CIBUILD_BUILD_FORCE` | Set to `1` to prevent pipeline cancellation even when the base image is unchanged. |

---

### Build Stage

The build stage builds one OCI image per platform and pushes the result to the target registry. The build tag for each platform image follows the pattern `<build_tag>-<platform_name>` (e.g. `main-linux-amd64`).

#### General Build Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_ENABLED` | `1` | Set to `0` to skip the build stage entirely. |
| `CIBUILD_BUILD_TAG` | *(CI ref / branch name)* | Override the image tag. Defaults to the current branch or ref as provided by the CI adapter. |
| `CIBUILD_BUILD_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the build. |
| `CIBUILD_BUILD_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the build. |
| `CIBUILD_BUILD_CLIENT` | `buildctl` | Build client to use. Supported values: `buildctl`, `buildx`, `kaniko`. |
| `CIBUILD_BUILD_PLATFORMS` | `linux/amd64,linux/arm64` | Comma-separated list of OCI platforms to build. |
| `CIBUILD_BUILD_NATIVE` | `0` | Set to `1` to build only for the architecture of the runner (ignores `BUILD_PLATFORMS`). |
| `CIBUILD_BUILD_OPTS` | *(empty)* | Extra options passed verbatim to the build client command. |
| `CIBUILD_BUILD_ARGS` | *(empty)* | Space-separated list of `KEY=VALUE` build arguments passed to the build. |

#### Cache Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_USE_CACHE` | `1` | Set to `0` to disable layer caching (`--no-cache`). |
| `CIBUILD_BUILD_CACHE_MODE` | *(CI-adapter default)* | Cache storage mode. `repo` stores cache as a separate repository (`<image>-cache:<tag>-<arch>`). `tag` stores cache as a tag suffix (`<image>:<tag>-<arch>-cache`). GitLab defaults to `tag`, GitHub to `repo`. |
| `CIBUILD_BUILD_EXPORT_CACHE` | *(CI-adapter default)* | Where to push the build cache. Accepts `ci_registry`, `target_registry`, or a full cache reference. Defaults to `target_registry` on GitLab and `ci_registry` on GitHub. |
| `CIBUILD_BUILD_EXPORT_CACHE_MODE` | `max` | BuildKit cache export mode: `max` (all layers) or `min` (only final layer). |
| `CIBUILD_BUILD_IMPORT_CACHE` | *(same as export)* | Where to pull the build cache from. Same accepted values as `EXPORT_CACHE`. |

#### Attestation Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_SBOM` | `1` | Set to `0` to disable SBOM attestation generation. Passed as `--sbom=true` (buildx) or `--opt attest:sbom=` (buildctl). |
| `CIBUILD_BUILD_PROVENANCE` | `1` | Set to `0` to disable SLSA provenance attestation generation. |
| `CIBUILD_BUILD_PROVENANCE_MODE` | `max` | Provenance detail level: `max` or `min`. |

#### BuildKit / Buildx Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_BUILDX_DRIVER` | `dockercontainer` | The buildx builder driver to use when `BUILD_CLIENT=buildx`. Supported: `dockercontainer`, `remote`, `kubernetes`. |
| `CIBUILD_BUILD_REMOTE_BUILDKIT` | `0` | Set to `1` to connect to a remote BuildKit daemon instead of running a local one. Requires `BUILD_BUILDKIT_HOST`. |
| `CIBUILD_BUILD_BUILDKIT_HOST` | `tcp://buildkit:1234` | Address of the BuildKit daemon for remote connections (`buildctl`) or the remote buildx driver. |
| `CIBUILD_BUILD_BUILDKIT_TLS` | `1` | Set to `0` to disable TLS when connecting to a remote BuildKit daemon. When TLS is enabled the cert variables below are required. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_CA` | *(required for TLS)* | Base64-encoded CA certificate for mTLS to BuildKit. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_CERT` | *(required for TLS)* | Base64-encoded client certificate for mTLS to BuildKit. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_KEY` | *(required for TLS)* | Base64-encoded client private key for mTLS to BuildKit. |
| `CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT` | *(empty)* | Base64-encoded kubeconfig used when the `kubernetes` buildx driver is selected. |
| `CIBUILD_BUILD_KUBERNETES_REPLICAS` | `1` | Number of BuildKit pod replicas when using the `kubernetes` buildx driver. |

---

### Test Stage

The test stage runs the freshly built image through user-defined tests. Two test modes are supported: a custom shell script and a declarative JSON assertion file.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_TEST_ENABLED` | `0` | Set to `1` to enable the test stage. |
| `CIBUILD_TEST_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the tests. |
| `CIBUILD_TEST_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the tests. |
| `CIBUILD_TEST_SCRIPT_FILE` | `cibuild.test.sh` | Path (relative to the repo root) to a shell test script that is sourced during the test run. Must be executable. |
| `CIBUILD_TEST_ASSERT_FILE` | `cibuild.test.json` | Path (relative to repo root) to a JSON file defining declarative test assertions. |
| `CIBUILD_TEST_BACKEND` | `docker` | Test backend: `docker` or `kubernetes`. |
| `CIBUILD_TEST_SERVICE_ACCOUNT` | *(empty)* | Base64-encoded kubeconfig used when `TEST_BACKEND=kubernetes`. |
| `CIBUILD_TEST_RUN_TIMEOUT` | `60` | Seconds to wait for the test container to reach running state. |
| `CIBUILD_TEST_LOG_TIMEOUT` | `5` | Seconds to wait for expected log output when running `assert_log` assertions. |

---

### Release Stage

The release stage assembles the final multi-platform OCI image index from the per-platform build artifacts, signs it with cosign, and copies it to additional tags and optional mirror registries.

#### General Release Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_ENABLED` | `1` | Set to `0` to skip the release stage. |
| `CIBUILD_RELEASE_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the release. |
| `CIBUILD_RELEASE_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the release. |

#### Image Tags

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_IMAGE_TAGS` | *(empty)* | Comma- or semicolon-separated list of additional tags to assign to the released image. Supports [tag templates](#tag-templates) including `__MINORTAG__`. |
| `CIBUILD_RELEASE_MINOR_TAG_REGEX` | *(empty)* | Regular expression matched against the base image's tag list to discover a "minor" version tag (e.g. `^3\.12$` to find the minor Python tag when the base image is `3.12.7`). Required when `__MINORTAG__` is used in `RELEASE_IMAGE_TAGS`. |
| `CIBUILD_RELEASE_MINOR_TAG_PAGING_LIMIT` | `10000` | Maximum number of tags to retrieve per page when searching for the minor tag. |

#### Docker Attestation

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_DOCKER_ATTESTATION_AUTODETECT` | `1` | Automatically enable Docker attestation manifest when the target registry is `docker.io`. |
| `CIBUILD_RELEASE_DOCKER_ATTESTATION_MANIFEST` | `0` | Force-enable the Docker attestation manifest regardless of the target registry. Required for Docker Hub UI to show "Signed" status. |

#### Cosign Signing

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_COSIGN_SIGNATURE` | `1` | Set to `0` to disable cosign signing entirely. |
| `CIBUILD_RELEASE_COSIGN_SIGNING_MODE` | `keyless` | Signing mode: `keyless` (Sigstore OIDC) or `key` (static key pair). |
| `CIBUILD_RELEASE_COSIGN_NEW_BUNDLE_FORMAT` | `1` | Use the OCI 1.1 referrers API for storing signatures. Set to `0` for the legacy `.sig` tag format (required for Harbor UI compatibility). |
| `CIBUILD_RELEASE_COSIGN_SIGNING_RECURSIVE` | `0` | Set to `1` to sign platform images individually in addition to the image index. |
| `CIBUILD_RELEASE_COSIGN_VERIFY` | `1` | Set to `0` to skip cosign verification after signing. |
| `CIBUILD_RELEASE_COSIGN_SIGNING_CONFIG` | *(empty)* | Base64-encoded cosign signing config JSON. When empty, keyless mode uses cosign's default Sigstore config; key mode uses an empty config (no Rekor, no Fulcio). |
| `CIBUILD_RELEASE_COSIGN_PRIVATE_KEY` | *(required for key mode)* | Base64-encoded cosign private key (`cosign.key`). |
| `CIBUILD_RELEASE_COSIGN_PUBLIC_KEY` | *(optional for key mode)* | Base64-encoded cosign public key. Falls back to `cosign.pub` in the repo root. |
| `CIBUILD_RELEASE_REMOVE_OLD_SIGNATURES` | `1` | Remove previously stored signature tags and OCI 1.1 referrer entries before signing. Prevents accumulation of stale signatures. |

#### Cleanup

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_KEEP_PLATFORM_TAGS` | `0` | Set to `1` to retain the per-platform build tags (e.g. `main-linux-amd64`) after the release index is assembled. |
| `CIBUILD_RELEASE_KEEP_IDX_TAG` | `0` | Set to `1` to retain the temporary `<tag>-cibuild-idx` tag created during index assembly. |

---

## Dynamic Variables

Several categories of variables are discovered dynamically by scanning the process environment, rather than being named individually.

### Build Secrets

Variables matching `CIBUILD_BUILD_SECRET_<NAME>` are forwarded to the build as `--secret id=<NAME>,env=CIBUILD_BUILD_SECRET_<NAME>`. This allows passing secrets (e.g. npm tokens) as BuildKit secret mounts without leaking them into the image layers. Kaniko does not support secret mounts; use `CIBUILD_BUILD_ARG_*` for kaniko instead.

```sh
CIBUILD_BUILD_SECRET_NPM_TOKEN=s3cr3t
# → --secret id=NPM_TOKEN,env=CIBUILD_BUILD_SECRET_NPM_TOKEN
```

### Build Arguments

Variables matching `CIBUILD_BUILD_ARG_<NAME>` are forwarded as build arguments.

```sh
CIBUILD_BUILD_ARG_NODE_VERSION=20
# buildctl: --opt build-arg:NODE_VERSION=20
# buildx:   --build-arg NODE_VERSION=20
```

### Cosign Annotations

Variables matching `CIBUILD_RELEASE_COSIGN_ANNOTATION_<KEY>` are added as cosign signature annotations. The key is lowercased and `___` is replaced with `-`, `__` with `.`:

```sh
CIBUILD_RELEASE_COSIGN_ANNOTATION_ORG__OPENCONTAINERS__IMAGE___TITLE=myapp
# → -a org.opencontainers.image.title=myapp
```

In addition, each CI adapter automatically adds the following OCI image annotations:
- `org.opencontainers.image.source` — repository URL
- `org.opencontainers.image.revision` — commit SHA
- `org.opencontainers.image.version` — tag or branch name

### Mirror Registries

See [Mirror Registries](#mirror-registries) below.

---

## CI Adapter Variables

These variables are read by the CI adapters and are not part of the `_CIBUILD_DEFAULTS` block. They are typically set as CI/CD project secrets.

### Common (all adapters)

| Variable | Description |
|----------|-------------|
| `CIBUILD_CI_TOKEN` | API token used to cancel the pipeline (check stage). On GitLab defaults to the job token; on GitHub defaults to `GITHUB_TOKEN`. |
| `CIBUILD_CI_REGISTRY` | Override the CI-native registry URL. |
| `CIBUILD_CI_REGISTRY_AUTH` | Set to `0` to disable CI registry authentication. Default: `1`. |
| `CIBUILD_CI_REGISTRY_USER` | Username for the CI registry. |
| `CIBUILD_CI_REGISTRY_PASS` | Password for the CI registry. |
| `CIBUILD_CI_IMAGE_PATH` | Override the image path within the CI registry. Defaults to the project path. |
| `CIBUILD_BASE_REGISTRY_AUTH` | Set to `1` to enable authentication for pulling the base image. Default: `0`. |
| `CIBUILD_BASE_REGISTRY_USER` | Username for the base image registry. |
| `CIBUILD_BASE_REGISTRY_PASS` | Password for the base image registry. |
| `CIBUILD_TARGET_REGISTRY` | Registry to push built images to. Defaults to the CI registry. |
| `CIBUILD_TARGET_REGISTRY_AUTH` | Set to `0` to disable target registry authentication. Default: `1`. |
| `CIBUILD_TARGET_REGISTRY_USER` | Username for the target registry. |
| `CIBUILD_TARGET_REGISTRY_PASS` | Password for the target registry. |
| `CIBUILD_TARGET_IMAGE_PATH` | Image path within the target registry. Defaults to the project path. |
| `CIBUILD_RELEASE_REGISTRY` | Registry to push the final released image to (separate from the build target). |
| `CIBUILD_RELEASE_REGISTRY_AUTH` | Set to `0` to disable release registry authentication. Default: `1`. |
| `CIBUILD_RELEASE_REGISTRY_USER` | Username for the release registry. |
| `CIBUILD_RELEASE_REGISTRY_PASS` | Password for the release registry. |
| `CIBUILD_RELEASE_IMAGE_PATH` | Image path within the release registry. |

### Base Image Override

When using multi-stage Dockerfiles, the base image is extracted from the last `FROM` line. To check a specific stage instead, set all three of these:

| Variable | Description |
|----------|-------------|
| `CIBUILD_BASE_REGISTRY` | Registry of the base image to use for the check stage. |
| `CIBUILD_BASE_IMAGE_PATH` | Image path of the base image. |
| `CIBUILD_BASE_TAG` | Tag of the base image. |

---

## Tag Templates

The `CIBUILD_RELEASE_IMAGE_TAGS` value and the minor tag feature support template placeholders that are resolved at release time:

| Placeholder | Replaced with |
|-------------|--------------|
| `__DATE__` | Current date in `YYYY-MM-DD` format |
| `__DATETIME__` | Current date and time in `YYYY-MM-DD_HH-MM-SS` format |
| `__COMMIT__` | Full commit SHA |
| `__REF__` | Branch or tag name |
| `__MINORTAG__` | The minor version tag discovered via `RELEASE_MINOR_TAG_REGEX` |

Example: build a Python base image and tag the release with both the exact version and the minor version:

```sh
CIBUILD_RELEASE_IMAGE_TAGS="latest,__MINORTAG__"
CIBUILD_RELEASE_MINOR_TAG_REGEX="^3\.[0-9]+$"
# If base image is python:3.12.7, the released image gets tags:
#   main, latest, 3.12
```

---

## Registry Configuration

cibuild automatically creates Docker and `regctl` auth configurations from the registry variables above. Three registry roles are distinguished internally:

- **CI registry** — used for build cache and intermediate images
- **Target registry** — where per-platform build artifacts are pushed
- **Release registry** — where the final signed image index lands (may be the same as target)

For each role, authentication is configured only when the corresponding `*_AUTH` variable is set to `1`.

---

## Mirror Registries

After release, the image index can be copied to one or more additional registries. Each mirror is configured via a group of variables using the naming pattern `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_*`, where `<ID>` is an arbitrary uppercase identifier.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>` | *(required)* | Registry hostname of the mirror (e.g. `quay.io`). |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_USER` | *(empty)* | Username for the mirror registry. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_PASS` | *(empty)* | Password for the mirror registry. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_IMAGE_PATH` | *(target image path)* | Image path in the mirror. Defaults to the target image path. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_KEEP_BUILD_TAG` | `1` | Copy the build tag to the mirror. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_KEEP_IMAGE_TAGS` | `1` | Copy the additional image tags (from `RELEASE_IMAGE_TAGS`) to the mirror. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_IMAGE_TAGS` | *(empty)* | Custom tag list for this mirror only. Used when `KEEP_IMAGE_TAGS=0`. |

At least one of `KEEP_BUILD_TAG=1`, `KEEP_IMAGE_TAGS=1`, or a non-empty `IMAGE_TAGS` must be set per mirror.

Signatures (OCI referrers and digest-tags) are copied along with the image via `regctl image copy --referrers --digest-tags`.

---

## Test Assertions

When `CIBUILD_TEST_ASSERT_FILE` exists (default: `cibuild.test.json`), each entry in the JSON array is executed as a test assertion. Two assertion types are supported:

**`log`** — start the container and check its log output:

```json
[
  {
    "type": "log",
    "assert": "Server started",
    "entrypoint": "keep",
    "cmd": []
  }
]
```

**`response`** — start the container, wait for a port, and assert the HTTP response body:

```json
[
  {
    "type": "response",
    "assert": "Hello World",
    "port": 8080,
    "entrypoint": "keep",
    "cmd": []
  }
]
```

The `entrypoint` field controls how the container is started:
- `"keep"` (default) — use the image's own entrypoint
- `""` (empty string) — clear the entrypoint (`--entrypoint=''`)
- any other string — use it as the entrypoint

`cmd` is an optional array of command arguments. Timeouts are controlled by `CIBUILD_TEST_RUN_TIMEOUT` and `CIBUILD_TEST_LOG_TIMEOUT`.

The same assertions can be called from a custom test script (`CIBUILD_TEST_SCRIPT_FILE`) using the shell functions `assert_log` and `assert_response`, which are sourced from the cibuild lib.

---

## Logging

Log output is controlled by two variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_LOG_LEVEL` | `1` | Verbosity level: `0`=error only, `1`=info (default), `2`=debug, `3`=dump (all internal state). |
| `CIBUILD_LOG_COLOR` | `1` | Set to `0` to disable ANSI color output. |

Log levels and their colors:

| Level | Name | Color |
|-------|------|-------|
| 0 | `error` | red |
| 1 | `info` | yellow |
| 2 | `debug` | blue |
| 3 | `dump` | magenta |

Secret values (variables ending in `_pass`, `_password`, `_key`, `_service_account`) are automatically masked with `*` in dump output.