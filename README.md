![Version](https://img.shields.io/badge/version-0.9.0-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-lightgrey?logo=gnu-bash)
![GitLab CI](https://img.shields.io/badge/GitLab%20CI-supported-FC6D26?logo=gitlab)
![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-supported-2088FF?logo=github-actions)

# cibuild — Documentation

> Version 0.9.0 · POSIX shell · GitLab CI · GitHub Actions · Local

---

## Table of Contents

1. [Overview](#overview)
2. [Runs and Pipeline Jobs](#runs-and-pipeline-jobs)
3. [Configuration](#configuration)
   - [Config Files](#config-files)
   - [Environment Variable Naming](#environment-variable-naming)
4. [Environment Variable Reference](#environment-variable-reference)
   - [Global](#global)
   - [Check Run](#check-run)
   - [Build Run](#build-run)
   - [Test Run](#test-run)
   - [Release Run](#release-run)
5. [Dynamic Variables (Secrets, Build Args, Cosign Annotations)](#dynamic-variables)
6. [CI Adapter Variables](#ci-adapter-variables)
7. [Tag Templates](#tag-templates)
8. [Registry Configuration](#registry-configuration)
9. [Mirror Registries](#mirror-registries)
10. [Test Assertions](#test-assertions)
11. [Logging](#logging)

---

## Overview

`cibuild` is a CI tool for building, testing, and releasing OCI container images. It is written in POSIX shell and runs inside a container image provided by the [cibuilder](https://github.com/stack4ops/cibuilder) project.

The tool is invoked as:

```sh
cibuild -r <command>
# command: check | build | test | release | all
```

CI platform detection is automatic (GitLab CI, GitHub Actions, local). Each platform has an adapter that maps native CI variables to cibuild's internal interface.

To explore all build modes locally or to develop cibuild itself, the `installer/` directory provides a complete self-contained lab environment — see [`installer/README.md`](installer/README.md).

---

## Runs and Pipeline Jobs

cibuild has four runs that can be invoked individually or all at once:

| Run | cibuilder Image | Description |
|-----|-----------------|-------------|
| `check` | `cibuilder:check` | Compares base image layers against the last built image. Cancels the pipeline if nothing changed. Only runs on scheduled or manually triggered pipelines. |
| `build` | `cibuilder:build-buildctl` / `build-nix` / `build-kaniko` / `build-buildx` | Builds per-platform OCI images and pushes them to the target registry. |
| `test` | `cibuilder:test-docker` / `test-k8s` | Runs test script and/or JSON assertions against the freshly built image. |
| `release` | `cibuilder:release` | Assembles a clean multi-platform index, generates SBOM (SPDX + CycloneDX), runs CVE scan, signs with cosign, copies additional tags, mirrors to other registries. |

Each run can be individually enabled or disabled and supports `pre_script` / `post_script` hooks.

### cibuilder Image Variants

Each cibuild run has a matching cibuilder image variant with `CIBUILD_RUN_CMD` hardcoded — no configuration needed in CI:

```yaml
# GitLab CI — image tag determines what runs
check:
  image: ghcr.io/stack4ops/cibuilder:check
  script: [/bin/true]

build:
  image: ghcr.io/stack4ops/cibuilder:build-buildctl
  script: [/bin/true]

test:
  image: ghcr.io/stack4ops/cibuilder:test-docker
  script: [/bin/true]

release:
  image: ghcr.io/stack4ops/cibuilder:release
  script: [/bin/true]
```

For local development and testing, `cibuilder:all` combines all variants and accepts `CIBUILD_RUN_CMD` as an override.

### Single job vs. split jobs

**`-r all` — single job (recommended default)**

```sh
cibuild -r all
```

All four runs execute sequentially inside a single CI job. No intermediate artifacts need to be transferred between jobs. This is the simplest setup and works well for the majority of projects.

**Split runs — multiple CI jobs**

Splitting is useful when:

- **Native multi-platform builds** — `CIBUILD_BUILD_NATIVE=1` requires one runner per architecture. Each runner runs its own build job; the release job assembles the index.
- **Visibility and control** — separate jobs allow retrying individual steps and attaching environment-specific secrets to specific jobs only.

Use `CIBUILD_*_ENABLED` variables to disable irrelevant runs per job (e.g. `CIBUILD_RELEASE_ENABLED=0` on build jobs).

---

## Configuration

### Config Files

cibuild loads configuration from files in the repository root, in the following order:

1. `cibuild.env` — generic config, loaded for all CI environments
2. `cibuild.<env>.env` — adapter-specific config (e.g. `cibuild.gitlab.env`, `cibuild.github.env`, `cibuild.local.env`)

Both files are plain shell files sourced with `set -a`. You can use them to set any `CIBUILD_*` variable.

### Environment Variable Naming

All settings are controlled via environment variables with the prefix `CIBUILD_`. The mapping to internal config keys follows a simple rule: strip the prefix and lowercase.

```
CIBUILD_BUILD_PLATFORMS  →  build_platforms
CIBUILD_RELEASE_ENABLED  →  release_enabled
```

The precedence order is **config file > environment > built-in defaults** — config files win over environment variables. This is intentionally the reverse of the usual convention.

The reasoning: GitLab and GitHub inject many CI variables as environment variables, including global defaults set at the group or organization level. By letting the repo's config file take precedence, the effective configuration is always visible in the repository itself.

---

## Environment Variable Reference

### Global

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_VERSION` | `0.9.0` | cibuild version (read-only, informational) |
| `CIBUILD_PIPELINE_ENV` | *(auto-detected)* | Force a specific CI adapter: `gitlab`, `github`, or `local`. |
| `CIBUILD_DOCKER_HOST` | `tcp://docker:2375` | Docker daemon address used by build and test stages when a Docker socket is required. |

---

### Check Run

The check run compares the layer digests of the base image (extracted from the last `FROM` line of the Containerfile) against the layers of the previously built target image. If the base image has not changed, the pipeline is canceled to save resources.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_CHECK_ENABLED` | `0` | Set to `1` to enable the check stage. |
| `CIBUILD_CHECK_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the check. |
| `CIBUILD_CHECK_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the check. |
| `CIBUILD_BUILD_FORCE` | *(empty)* | Set to `1` to prevent pipeline cancellation even when the base image is unchanged. |

---

### Build Run

The build run builds one OCI image per platform and pushes the result to the target registry. The build tag for each platform image follows the pattern `<build_tag>-<platform_name>` (e.g. `main-linux-amd64`).

#### General Build Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_ENABLED` | `1` | Set to `0` to skip the build stage entirely. |
| `CIBUILD_BUILD_TAG` | *(CI ref / branch name)* | Override the image tag. |
| `CIBUILD_BUILD_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the build. |
| `CIBUILD_BUILD_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the build. |
| `CIBUILD_BUILD_CLIENT` | `buildctl` | Build client: `buildctl`, `buildx`, `kaniko`, `nix`. |
| `CIBUILD_BUILD_PLATFORMS` | `linux/amd64,linux/arm64` | Comma-separated list of OCI platforms to build. |
| `CIBUILD_BUILD_NATIVE` | `0` | Set to `1` to build only for the runner's own architecture. |
| `CIBUILD_BUILD_OPTS` | *(empty)* | Extra options passed verbatim to the build client. |
| `CIBUILD_BUILD_ARGS` | *(empty)* | Space-separated `KEY=VALUE` build arguments. |

#### Cache Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_USE_CACHE` | `1` | Set to `0` to disable layer caching (`--no-cache`). |
| `CIBUILD_BUILD_CACHE_MODE` | *(CI-adapter default)* | Cache storage mode: `repo` or `tag`. GitLab defaults to `tag`, GitHub to `repo`. |
| `CIBUILD_BUILD_EXPORT_CACHE` | *(CI-adapter default)* | Where to push the build cache: `ci_registry`, `target_registry`, or a full reference. |
| `CIBUILD_BUILD_EXPORT_CACHE_MODE` | `max` | BuildKit cache export mode: `max` or `min`. |
| `CIBUILD_BUILD_IMPORT_CACHE` | *(same as export)* | Where to pull the build cache from. |

#### Attestation / Provenance

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_PROVENANCE` | `1` | Generate SLSA provenance OCI attestation during build. Only meaningful with `build_client=buildctl` or `buildx`. Nix: tbd. Kaniko: not supported. |
| `CIBUILD_BUILD_PROVENANCE_MODE` | `max` | Provenance detail level: `max` or `min`. |

#### Nix Build Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_NIX_FLAKE_ATTR` | `default` | Nix flake attribute to build (`packages.<system>.<attr>`). |
| `CIBUILD_NIX_CACHE_URL` | *(empty)* | Attic or Cachix binary cache URL. |
| `CIBUILD_NIX_CACHE_TOKEN` | *(empty)* | Auth token for the Nix binary cache. |
| `CIBUILD_NIX_SANDBOX` | *(auto-detect)* | Override Nix sandbox mode: `true` or `false`. Auto-detected via `ROOTLESSKIT_PID`. |

#### BuildKit / Buildx Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_BUILD_BUILDX_DRIVER` | `dockercontainer` | The buildx builder driver: `dockercontainer`, `remote`, `kubernetes`. |
| `CIBUILD_BUILD_REMOTE_BUILDKIT` | `0` | Set to `1` to connect to a remote BuildKit daemon. |
| `CIBUILD_BUILD_BUILDKIT_HOST` | `tcp://buildkit:1234` | Address of the remote BuildKit daemon. |
| `CIBUILD_BUILD_BUILDKIT_TLS` | `1` | Set to `0` to disable mTLS. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_CA` | *(required for TLS)* | Base64-encoded CA certificate for mTLS. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_CERT` | *(required for TLS)* | Base64-encoded client certificate for mTLS. |
| `CIBUILD_BUILD_BUILDKIT_CLIENT_KEY` | *(required for TLS)* | Base64-encoded client private key for mTLS. |
| `CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT` | *(empty)* | Base64-encoded kubeconfig for the `kubernetes` buildx driver. |
| `CIBUILD_BUILD_KUBERNETES_REPLICAS` | `1` | Number of BuildKit pod replicas for the `kubernetes` driver. |

---

### Test Run

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_TEST_ENABLED` | `0` | Set to `1` to enable the test stage. |
| `CIBUILD_TEST_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the tests. |
| `CIBUILD_TEST_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the tests. |
| `CIBUILD_TEST_SCRIPT_FILE` | `cibuild.test.sh` | Path to a shell test script sourced during the test run. |
| `CIBUILD_TEST_ASSERT_FILE` | `cibuild.test.json` | Path to a JSON file defining declarative test assertions. |
| `CIBUILD_TEST_BACKEND` | `docker` | Test backend: `docker` or `kubernetes`. |
| `CIBUILD_TEST_SERVICE_ACCOUNT` | *(empty)* | Base64-encoded kubeconfig for `TEST_BACKEND=kubernetes`. |
| `CIBUILD_TEST_RUN_TIMEOUT` | `60` | Seconds to wait for the test container to reach running state. |
| `CIBUILD_TEST_LOG_TIMEOUT` | `5` | Seconds to wait for expected log output in `assert_log` assertions. |

---

### Release Run

#### General Release Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_ENABLED` | `1` | Set to `0` to skip the release stage. |
| `CIBUILD_RELEASE_PRE_SCRIPT` | *(empty)* | Path to an executable script to run before the release. |
| `CIBUILD_RELEASE_POST_SCRIPT` | *(empty)* | Path to an executable script to run after the release. |

#### SBOM and Vulnerability Scanning

SBOM generation and CVE scanning always happen in the release run via `trivy`. Both SPDX and CycloneDX formats are generated by default.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_SBOM` | `1` | Set to `0` to disable SBOM generation. |
| `CIBUILD_RELEASE_SBOM_FORMATS` | `spdx-json,cyclonedx` | Comma-separated list of SBOM formats. `spdx-json` → `.spdx.json`, `cyclonedx` → `.cdx.json`. |
| `CIBUILD_RELEASE_VULN` | `1` | Set to `0` to disable the CVE vulnerability report. |
| `CIBUILD_RELEASE_VULN_FORMAT` | `json` | Vulnerability report format (trivy `--format`). |

Release artifacts written to `$CIBUILD_OUTPUT_DIR`:

```
sbom-linux-amd64.spdx.json       # SPDX — GitHub, OpenChain, compliance tools
sbom-linux-amd64.cdx.json        # CycloneDX — OWASP Dependency-Track, DevGuard
sbom-linux-arm64.spdx.json
sbom-linux-arm64.cdx.json
vuln-linux-amd64.json             # CVE report
vuln-linux-arm64.json
provenance-linux-amd64.slsa.json  # SLSA provenance (buildctl/buildx only)
provenance-linux-arm64.slsa.json
digests.json                      # multi-platform image index digests
cert.json                         # cosign keyless certificate
```

#### Image Tags

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_IMAGE_TAGS` | *(empty)* | Comma- or semicolon-separated list of additional tags. Supports [tag templates](#tag-templates) including `__MINORTAG__`. |
| `CIBUILD_RELEASE_MINOR_TAG_REGEX` | *(empty)* | Regex matched against the base image's tag list to discover a minor version tag. Required when `__MINORTAG__` is used. |
| `CIBUILD_RELEASE_MINOR_TAG_PAGING_LIMIT` | `10000` | Maximum number of tags to retrieve when searching for the minor tag. |

#### Docker Attestation

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_DOCKER_ATTESTATION_AUTODETECT` | `1` | Automatically enable Docker attestation manifest when the target registry is `docker.io`. |
| `CIBUILD_RELEASE_DOCKER_ATTESTATION_MANIFEST` | `0` | Force-enable the Docker attestation manifest. Required for Docker Hub UI to show "Signed" status. |

#### Cosign Signing

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_COSIGN_SIGNATURE` | `1` | Set to `0` to disable cosign signing entirely. |
| `CIBUILD_RELEASE_COSIGN_SIGNING_MODE` | `keyless` | Signing mode: `keyless` (Sigstore OIDC) or `key` (static key pair). |
| `CIBUILD_RELEASE_COSIGN_NEW_BUNDLE_FORMAT` | `1` | Use the OCI 1.1 referrers API for storing signatures. Set to `0` for the legacy `.sig` tag format. |
| `CIBUILD_RELEASE_COSIGN_SIGNING_RECURSIVE` | `0` | Set to `1` to sign platform images individually in addition to the image index. |
| `CIBUILD_RELEASE_COSIGN_VERIFY` | `1` | Set to `0` to skip cosign verification after signing. |
| `CIBUILD_RELEASE_COSIGN_SIGNING_CONFIG` | *(empty)* | Base64-encoded cosign signing config JSON. |
| `CIBUILD_RELEASE_COSIGN_PRIVATE_KEY` | *(required for key mode)* | Base64-encoded cosign private key. |
| `CIBUILD_RELEASE_COSIGN_PUBLIC_KEY` | *(optional for key mode)* | Base64-encoded cosign public key. Falls back to `cosign.pub` in the repo root. |
| `CIBUILD_RELEASE_REMOVE_OLD_SIGNATURES` | `1` | Remove previously stored signatures before signing. |

#### Supply Chain Artifact Upload

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_UPLOAD_SUPPLY_CHAIN_ARTIFACTS` | *(empty)* | Set to `package` to upload SBOM, provenance, CVE report and digests to the CI platform's artifact store. Currently supported: `package` → GitLab Generic Package Registry. |

#### Cleanup

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_KEEP_PLATFORM_TAGS` | `0` | Retain per-platform build tags after index assembly. |
| `CIBUILD_RELEASE_KEEP_IDX_TAG` | `0` | Retain the temporary `<tag>-cibuild-idx` tag. |

---

## Dynamic Variables

### Build Secrets

Variables matching `CIBUILD_BUILD_SECRET_<NAME>` are forwarded to the build as `--secret id=<NAME>,env=...`. Kaniko does not support secret mounts — use `CIBUILD_BUILD_ARG_*` instead.

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

Variables matching `CIBUILD_RELEASE_COSIGN_ANNOTATION_<KEY>` are added as cosign signature annotations. `___` → `-`, `__` → `.`:

```sh
CIBUILD_RELEASE_COSIGN_ANNOTATION_ORG__OPENCONTAINERS__IMAGE___TITLE=myapp
# → -a org.opencontainers.image.title=myapp
```

---

## CI Adapter Variables

### Common (all adapters)

| Variable | Description |
|----------|-------------|
| `CIBUILD_CI_TOKEN` | API token for pipeline cancellation (check stage). |
| `CIBUILD_CI_REGISTRY` | Override the CI-native registry URL. |
| `CIBUILD_CI_REGISTRY_AUTH` | Set to `0` to disable CI registry authentication. Default: `1`. |
| `CIBUILD_CI_REGISTRY_USER` | Username for the CI registry. |
| `CIBUILD_CI_REGISTRY_PASS` | Password for the CI registry. |
| `CIBUILD_CI_IMAGE_PATH` | Override the image path within the CI registry. |
| `CIBUILD_BASE_REGISTRY_AUTH` | Set to `1` to enable authentication for pulling the base image. |
| `CIBUILD_BASE_REGISTRY_USER` | Username for the base image registry. |
| `CIBUILD_BASE_REGISTRY_PASS` | Password for the base image registry. |
| `CIBUILD_TARGET_REGISTRY` | Registry to push built images to. |
| `CIBUILD_TARGET_REGISTRY_AUTH` | Set to `0` to disable target registry authentication. Default: `1`. |
| `CIBUILD_TARGET_REGISTRY_USER` | Username for the target registry. |
| `CIBUILD_TARGET_REGISTRY_PASS` | Password for the target registry. |
| `CIBUILD_TARGET_IMAGE_PATH` | Image path within the target registry. |
| `CIBUILD_RELEASE_REGISTRY` | Registry to push the final released image to. |
| `CIBUILD_RELEASE_REGISTRY_AUTH` | Set to `0` to disable release registry authentication. Default: `1`. |
| `CIBUILD_RELEASE_REGISTRY_USER` | Username for the release registry. |
| `CIBUILD_RELEASE_REGISTRY_PASS` | Password for the release registry. |
| `CIBUILD_RELEASE_IMAGE_PATH` | Image path within the release registry. |

### Base Image Override

| Variable | Description |
|----------|-------------|
| `CIBUILD_BASE_REGISTRY` | Registry of the base image for the check stage. |
| `CIBUILD_BASE_IMAGE_PATH` | Image path of the base image. |
| `CIBUILD_BASE_TAG` | Tag of the base image. |

---

## Tag Templates

| Placeholder | Replaced with |
|-------------|--------------|
| `__DATE__` | Current date: `YYYY-MM-DD` |
| `__DATETIME__` | Current date and time: `YYYY-MM-DD_HH-MM-SS` |
| `__COMMIT__` | Full commit SHA |
| `__REF__` | Branch or tag name |
| `__MINORTAG__` | Minor version tag discovered via `RELEASE_MINOR_TAG_REGEX` |

Example:

```sh
CIBUILD_RELEASE_IMAGE_TAGS="latest,__MINORTAG__"
CIBUILD_RELEASE_MINOR_TAG_REGEX="^3\.[0-9]+$"
# base image python:3.12.7 → tags: main, latest, 3.12
```

---

## Registry Configuration

Three registry roles are distinguished internally:

- **CI registry** — build cache and intermediate images
- **Target registry** — per-platform build artifacts
- **Release registry** — final signed image index (may be the same as target)

Authentication is configured only when the corresponding `*_AUTH` variable is `1`.

---

## Mirror Registries

After release, the image index can be copied to additional registries. Each mirror uses the pattern `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_*`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>` | *(required)* | Registry hostname (e.g. `quay.io`). |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_USER` | *(empty)* | Username. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_PASS` | *(empty)* | Password. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_IMAGE_PATH` | *(target image path)* | Image path in the mirror. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_KEEP_BUILD_TAG` | `1` | Copy the build tag. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_KEEP_IMAGE_TAGS` | `1` | Copy additional image tags. |
| `CIBUILD_RELEASE_MIRROR_REGISTRY_<ID>_IMAGE_TAGS` | *(empty)* | Custom tag list for this mirror only. |

Signatures (OCI referrers and digest-tags) are copied along with the image via `regctl image copy --referrers --digest-tags`.

---

## Test Assertions

When `cibuild.test.json` exists, each entry is executed as a test assertion.

**`log`** — check container log output:

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

**`response`** — assert HTTP response body on a port:

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

`entrypoint`: `"keep"` = use image's own entrypoint, `""` = clear it, any other string = use as entrypoint.

The same assertions are available as shell functions `assert_log` and `assert_response` in custom test scripts.

---

## Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILD_LOG_LEVEL` | `1` | `0`=error, `1`=info, `2`=debug, `3`=dump |
| `CIBUILD_LOG_COLOR` | `1` | Set to `0` to disable ANSI color output. |

Secret values (variables ending in `_pass`, `_password`, `_key`, `_service_account`) are automatically masked in dump output.