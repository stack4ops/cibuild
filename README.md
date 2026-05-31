![Version](https://img.shields.io/badge/version-0.9.0-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-lightgrey?logo=gnu-bash)
![GitLab CI](https://img.shields.io/badge/GitLab%20CI-supported-FC6D26?logo=gitlab)
![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-supported-2088FF?logo=github-actions)

# cibuild — Documentation

> **English** · [Deutsch](README.de.md)

> Version 0.9.0 · POSIX shell · GitLab CI · GitHub Actions · Local

> **cibuild follows a security-first supply chain model** — every artifact is
> bound to an immutable digest, signed, and verifiable at any point in time.
> See the [Security Model](docs/SECURITY-MODEL.md) ([Deutsch](docs/SECURITY-MODEL.de.md)).

---

## Table of Contents

1. [Overview](#overview)
2. [Design Rationale](#design-rationale)
   - [Security model](#security-model)
   - [Digital sovereignty](#digital-sovereignty)
3. [Artifact Lock Files](#artifact-lock-files)
   - [Manual Verification and Auditing](#manual-verification-and-auditing)
4. [Runs and Pipeline Jobs](#runs-and-pipeline-jobs)
   - [cibuilder Image Variants](#cibuilder-image-variants)
   - [Build Clients](#build-clients)
   - [Single job vs. split jobs](#single-job-vs-split-jobs)
5. [Configuration Reference](#configuration-reference)

For the complete configuration reference — all environment variables, CI adapter
variables, tag templates, registry and mirror configuration, test assertions, and
logging — see **[REFERENCE.md](REFERENCE.md)**.

## Overview

`cibuild` is a CI tool for building, testing, and releasing OCI container images. It is written in POSIX shell and runs inside a container image provided by the [cibuilder](https://github.com/stack4ops/cibuilder) project.

The tool is invoked as:

```sh
cibuild -r <command>
# command: check | build | test | release | update-caches | all
```

CI platform detection is automatic (GitLab CI, GitHub Actions, local). Each platform has an adapter that maps native CI variables to cibuild's internal interface.

To explore all build modes locally or to develop cibuild itself, the `installer/` directory provides a complete self-contained lab environment — see [`installer/README.md`](installer/README.md).

---

## Design Rationale

cibuild exists to demonstrate two convictions about how software should be built
and released — one technical, one strategic. Both are documented in full:

### Security model

cibuild is built around a **security-first** supply chain model: cryptographic traceability is the structural foundation, not an afterthought. Every artifact is tied to an immutable digest, every digest is signed, and the entire chain is verifiable by anyone, at any time, from any location.

The full model — the commit as cryptographic anchor, the artifact lock file, the two cryptographic scopes (static-key build and keyless release), the OCI referrer attestations, and the compliance governance gate — is documented separately:

- **[Security Model](docs/SECURITY-MODEL.md)** (English)
- **[Sicherheitsmodell](docs/SECURITY-MODEL.de.md)** (Deutsch)

### Digital sovereignty

cibuild keeps every integration point — the CI platform, the build engine, the registry, the test backend — behind a thin, replaceable abstraction. The freedom to leave a tool without rebuilding everything is treated as a precondition of digital sovereignty, not an afterthought, and the hands-on lab is part of building the expertise that makes such choices possible.

- **[Digital Sovereignty and the Freedom to Leave](docs/SOVEREIGNTY.md)** (English)
- **[Digitale Souveränität und die Freiheit zu gehen](docs/SOVEREIGNTY.de.md)** (Deutsch)

---

## Artifact Lock Files

After each platform build, cibuild writes an `artifact-lock.<platform_name>.json` file (e.g. `artifact-lock.linux-amd64.json`) to the repository root and commits it back to the branch via the CI adapter.

The lock file records the exact digests of the platform image and all its supply chain referrers — SBOM, vulnerability report, and provenance — along with the cosign signature digest. This creates a **cryptographic anchor**: every artifact is tied to the immutable image digest, and because the image is signed, the entire chain is provably intact at any point in time.

```json
{
  "platform":      "linux/amd64",
  "platform_name": "linux-amd64",
  "image":         "registry.example.com/myorg/myapp",
  "build_tag":     "main",
  "image_digest":  "sha256:abc123...",
  "referrers": {
    "sbom":        "sha256:def456...",
    "vuln":        "sha256:ghi789...",
    "provenance":  "sha256:jkl012..."
  },
  "build_client":  "buildctl",
  "source_commit": "a1b2c3d4...",
  "built_at":      "2024-11-15T10:30:00Z"
}
```

### Usage across runs

**Test run** — before executing any test, the test run reads the platform digest from the lock file and verifies the cosign signature against it. Tests always run against the exact digest that was built and signed — not against a tag that could have been overwritten. This can be disabled with `CIBUILD_TEST_COSIGN_VERIFY_BUILD_ARTIFACTS=0`.

**Release run** — the release run reads platform digests from the lock files to assemble the multi-platform index, and re-verifies all cosign signatures before proceeding. This can be disabled with `CIBUILD_RELEASE_COSIGN_VERIFY_BUILD_ARTIFACTS=0`.

Both runs resolve the image by digest — independently of tag state in the registry — so the entire pipeline is tamper-evident across jobs.

> For the architectural reasoning behind artifact locks, cryptographic scopes, and the verification model, see the [Security Model](docs/SECURITY-MODEL.md).

### Compliance tooling

The lock file is a plain JSON file committed to the repository, making all artifact digests available to external tools without registry access. Compliance pipelines and audit tools can consume it directly:

- **SBOM consumers** (OWASP Dependency-Track, DevGuard) — use `referrers.sbom` to fetch the CycloneDX SBOM by digest from the registry
- **CVE / VEX pipelines** — use `referrers.vuln` to fetch the trivy vulnerability report and feed it into VEX generation tools
- **SARIF / audit dashboards** — combine `image_digest`, `source_commit`, and `built_at` to correlate image versions with source commits and scan results

Lock files are committed to the repository with a `[skip ci]` commit message to avoid triggering a new pipeline. In the local adapter, they are committed locally without a push.

### Manual Verification and Auditing

Because the lock file records every digest and the image is signed, anyone can verify and audit an artifact from anywhere — no access to the pipeline, the CI system, or the build logs is required. Only the committed lock file, the public key, and read access to the registry.

**Verify the signature.** Read the image digest from the lock file and verify it against the public key:

```sh
DIGEST=$(jq -r .image_digest artifact-lock.linux-amd64.json)
cosign verify --key cosign.pub registry.example.com/myorg/myapp@"$DIGEST"
```

The image is resolved by digest, not by tag — so the verification holds even if the tag was later moved or removed.

**Audit the attestations.** Each referrer digest is in the lock file. Pull any of them directly from the registry and inspect them:

```sh
# CycloneDX SBOM
SBOM=$(jq -r .referrers.sbom artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$SBOM" | jq .

# CVE vulnerability report
VULN=$(jq -r .referrers.vuln artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$VULN" | jq .

# SLSA provenance
PROV=$(jq -r .referrers.provenance artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$PROV" | jq .
```

**Discover the full referrer tree.** List every attestation attached to the image digest directly from the registry:

```sh
regctl artifact list registry.example.com/myorg/myapp@"$DIGEST"
```

This is the core of the security-first model in practice: the artifact carries its own provenance, and that provenance is independently verifiable by anyone, at any time, from any location.

---

## Runs and Pipeline Jobs

cibuild has five runs that can be invoked individually or all at once:

| Run | cibuilder Image | Description |
|-----|-----------------|-------------|
| `check` | `cibuilder:check` | Compares base image layers against the last built image. Cancels the pipeline if nothing changed. Only runs on scheduled or manually triggered pipelines. |
| `build` | `cibuilder:build-buildctl` / `build-nix` / `build-kaniko` / `build-buildx` | Builds per-platform OCI images, generates SBOM and CVE report as OCI referrers, signs with cosign, and pushes everything to the target registry. |
| `test` | `cibuilder:test-docker` / `test-k8s` | Runs test script and/or JSON assertions against the freshly built image. |
| `release` | `cibuilder:release` | Assembles a clean multi-platform index, generates SBOM (SPDX + CycloneDX) from the existing CycloneDX referrer, signs with cosign, copies additional tags, mirrors to other registries. |
| `update-caches` | `cibuilder:update-caches` | Refreshes external caches (trivy vulnerability DB). Intended for scheduled pipelines — no build, no release. |

Each run can be individually enabled or disabled and supports `pre_script` / `post_script` hooks.

For simple setups, `-r all` runs all steps sequentially in a single job — no artifact transfer between jobs, minimal runner configuration. Split runs are only needed for native multi-arch builds or job-level isolation.

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

update-caches:
  image: ghcr.io/stack4ops/cibuilder:update-caches
  script: [/bin/true]
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
```

For local development and testing, `cibuilder:all` combines all variants and accepts `CIBUILD_RUN_CMD` as an override.

### Build Clients

The build run supports four clients, selected via `CIBUILD_BUILD_CLIENT`:

| Client | Image Variant | Description |
|--------|---------------|-------------|
| `buildctl` *(default)* | `build-buildctl` | Daemonless BuildKit via rootlesskit. Runs everywhere — no Docker daemon required. |
| `buildx` | `build-buildx` | Docker buildx with three driver options: `dockercontainer`, `remote`, `kubernetes`. |
| `kaniko` | `build-kaniko` | Rootless Kubernetes-native builds. Runs as root, no daemon. |
| `nix` | `build-nix` | Declarative, reproducible builds via Nix flakes. No Dockerfile required. Output is a content-addressed OCI tar. |

#### Nix Build Client

The `nix` client builds OCI images from a `flake.nix` in the repository root using `nixpkgs.dockerTools`. The result is a fully reproducible, distroless-style image — identical byte-for-byte on every build given the same inputs.

```sh
# cibuild.env
CIBUILD_BUILD_CLIENT=nix
CIBUILD_NIX_FLAKE_ATTR=default        # packages.<system>.default in flake.nix
CIBUILD_NIX_CACHE_URL=https://attic.example.com/mycache   # optional Attic/Cachix
CIBUILD_NIX_CACHE_TOKEN=...           # optional cache auth token
```

The `build-nix` cibuilder variant ships a single-user Nix installation with flakes enabled. Sandbox mode is auto-detected at runtime. No `--privileged` flag required.

For the nix client, SBOM and CVE reports are generated by the nix build itself (via `bombon` and `vulnxscan`) and passed directly as OCI referrers. The trivy-based SBOM/vuln generation in the build run is skipped for `build_client=nix`.

### Single job vs. split jobs

**`-r all` — single job (recommended default)**

```sh
cibuild -r all
```

All runs execute sequentially inside a single CI job. No intermediate artifacts need to be transferred between jobs. This is the simplest setup and works well for the majority of projects — including production CI pipelines where native multi-arch builds or job-level isolation are not required.

**Split runs — multiple CI jobs**

Splitting is useful when:

- **Native multi-platform builds** — `CIBUILD_BUILD_NATIVE=1` requires one runner per architecture. Each runner runs its own build job; the release job assembles the index.
- **Different build backends** — e.g. `build-nix` on one runner, `build-buildctl` on another.
- **Visibility and control** — separate jobs allow retrying individual steps and attaching environment-specific secrets to specific jobs only.
- **DinD isolation** — `test-docker` requires a Docker-in-Docker service that you may not want running during build or release.

Use `CIBUILD_*_ENABLED` variables to disable irrelevant runs per job (e.g. `CIBUILD_RELEASE_ENABLED=0` on build jobs).

---


## Configuration Reference

All runtime behaviour is controlled through `CIBUILD_*` environment variables,
set either in config files (`cibuild.env`, `cibuild.<env>.env`) or as CI
variables. The complete reference is maintained separately:

**→ [REFERENCE.md](REFERENCE.md)**

It covers configuration files and variable naming, the full environment variable
reference for every run (check, build, test, release, update-caches), shared
cosign settings, dynamic variables (build secrets, build args, cosign
annotations), CI adapter variables, tag templates, registry configuration,
mirror registries, test assertions, and logging.