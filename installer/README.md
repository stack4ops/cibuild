# cibuild Local Lab

A self-contained local development and testing environment for cibuild. It reproduces a full CI build pipeline on your machine — including a private registry, Docker-in-Docker, a k3d Kubernetes cluster, a remote BuildKit daemon, a Nix binary cache (Attic), and cosign signing — all pre-wired and ready to use.

The lab uses the **local CI adapter** (`cibuild.local.env`) and is the recommended way to develop and test cibuild itself or to explore all build modes before rolling them out in a real CI environment.

---

## What the Lab Provides

| Component | Details |
|-----------|---------|
| **cibuilder container** | The cibuild runner image, launched via Docker Compose |
| **Docker-in-Docker (DinD)** | A privileged `docker:dind` container at `tcp://docker:2375` — required for `buildx` builds and the `test-docker` run |
| **Local registry** | TLS-enabled private registry at `localregistry.example.com:5000` with htpasswd auth (`admin` / `password`), pre-trusted by DinD and k3d |
| **Registry browser** | Web UI at `http://localhost:<REGISTRY_BROWSER_PORT>` |
| **k3d cluster** | Lightweight k3s Kubernetes cluster named `cibuilder`, connected to `cibuilder-net` |
| **BuildKit remote** (`buildkitr`) | Rootless BuildKit in the `buildkitr` namespace, exposed as NodePort `k3d-cibuilder-server-0:31234`. mTLS certificates generated automatically |
| **BuildKit kubernetes driver** (`buildkitk`) | Service account + RBAC for the `docker buildx` Kubernetes driver |
| **Test stage service account** (`teststage`) | Minimal RBAC for the cibuild test run (create/delete pods, port-forward, logs) |
| **Attic Nix binary cache** | Local Nix binary cache at `http://cibuilder-attic:8080` — started when `NIX_ENABLED=1` |
| **cosign key pair** | Generated once during install, stored in `installer/signing/`, written as base64 into `.env` |

Every supported build mode is available out of the box:

| `CIBUILD_BUILD_CLIENT` | cibuilder Image | Requires | Works in lab |
|------------------------|-----------------|----------|-------------|
| `buildctl` (daemonless) | `build-buildctl` | rootlesskit in cibuilder | ✓ |
| `buildctl` (remote) | `build-buildctl` | BuildKit in k3d (`buildkitr`) | ✓ |
| `buildx` — `dockercontainer` | `build-buildx` | DinD | ✓ |
| `buildx` — `remote` | `build-buildx` | BuildKit in k3d (`buildkitr`) | ✓ |
| `buildx` — `kubernetes` | `build-buildx` | k3d + `buildkitk` service account | ✓ |
| `kaniko` | `build-kaniko` | runs as root in cibuilder, no DinD needed | ✓ |
| `nix` | `build-nix` | nix + optional Attic cache | ✓ |

> **Using `build-kaniko`** — kaniko runs as root. In `.env`:
>
> ```sh
> CIBUILDER_IMAGE=localhost/cibuilder
> CIBUILDER_REF=build-kaniko
> CIBUILDER_ROOTLESS_KIT=0
> CIBUILDER_USER="0:$(id -g)"
> CIBUILDER_PRIVILEGED=0
> ```
>
> **Using `build-nix`** — no rootlesskit needed. In `.env`:
>
> ```sh
> CIBUILDER_IMAGE=localhost/cibuilder
> CIBUILDER_REF=build-nix
> CIBUILDER_ROOTLESS_KIT=0
> CIBUILDER_USER="1000:$(id -g)"
> CIBUILDER_PRIVILEGED=0
> ```

The test stage works with both `TEST_BACKEND=docker` (via DinD, `cibuilder:test-docker`) and `TEST_BACKEND=kubernetes` (via `teststage` service account, `cibuilder:test-k8s`).

---

## Prerequisites

- **Docker** with Compose plugin
- **Linux** (x86_64 or arm64)

The following tools are downloaded automatically by `install.sh` if not already present:

- `k3d` — Kubernetes-in-Docker
- `kubectl` — placed locally in `installer/kubectl`
- `mkcert` — for generating self-signed mTLS certificates for BuildKit
- `cosign` — placed locally in `installer/cosign`

---

## Quick Start

```sh
cd installer
./install.sh
```

`install.sh` is idempotent — it skips steps that are already done and is safe to re-run after a partial install or after pulling updates.

After installation, the cibuild wrapper is at `~/.local/bin/cibuild`. Make sure `~/.local/bin` is in your `PATH`.

To run a full build pipeline in any repository:

```sh
cd /path/to/your/repo
cibuild -r all
```

The wrapper picks up lab configuration from `~/.config/cibuild/.env` automatically.

---

## Building cibuilder Images Locally

The lab uses locally built cibuilder images by default. Build all variants with:

```sh
cd /path/to/cibuilder
./build-local.sh
```

Or build a single target:

```sh
./build-local.sh release
./build-local.sh build-nix
```

Images are tagged as `localhost/cibuilder:<target>` and loaded directly into the local Docker image store — no registry push needed.

Set in `~/.config/cibuild/.env`:

```sh
CIBUILDER_IMAGE=localhost/cibuilder
CIBUILDER_REF=all    # or the specific run variant: build-buildctl, release, etc.
```

---

## What `install.sh` Does Step by Step

1. **Copies `.env.template` → `.env`** on first run. Sets `LIB_PATH` to the `bin/` directory of the checked-out repo.
2. **Starts Docker Compose** — `docker-compose.dind.yaml` (when `DIND_ENABLED=1`) or `docker-compose.min.yaml` (registry only).
3. **Starts Attic** (when `NIX_ENABLED=1`) — `docker-compose.attic.yaml`. Generates a token via `atticadm make-token`, creates the `nixpkgs` cache, writes `CIBUILD_NIX_CACHE_URL` and `CIBUILD_NIX_CACHE_TOKEN` into `.env`.
4. **Installs k3d** if not present, then **creates the k3d cluster** `cibuilder` attached to `cibuilder-net` with the local registry pre-configured.
5. **Creates the `teststage` namespace** with service account and RBAC. Writes kubeconfig base64 into `.env` as `CIBUILD_TEST_SERVICE_ACCOUNT`.
6. **Creates the `buildkitr` namespace** — deploys rootless BuildKit with mTLS, generates certs via `mkcert`, writes client certs into `.env`.
7. **Creates the `buildkitk` namespace** with the service account for the Kubernetes buildx driver. Writes kubeconfig into `.env` as `CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT`.
8. **Generates a cosign key pair** and stores it in `installer/signing/`. Writes keys base64-encoded into `.env`.
9. **Installs the cibuild wrapper** to `~/.local/bin/cibuild`.
10. **Copies `.env` to `~/.config/cibuild/.env`**.

---

## Configuration (`.env`)

`.env` is created from `.env.template` on first install.

| Variable | Default | Description |
|----------|---------|-------------|
| `CIBUILDER_IMAGE` | `localhost/cibuilder` | cibuilder image to use |
| `CIBUILDER_REF` | `all` | Image tag — use a specific run variant or `all` for lab |
| `DIND_ENABLED` | `1` | Start Docker-in-Docker. Set to `0` for registry-only. |
| `NIX_ENABLED` | `1` | Start Attic Nix binary cache. |
| `ATTIC_PORT` | `5002` | Host port for Attic. |
| `CIBUILD_NIX_CACHE_URL` | *(written by install.sh)* | Attic cache URL for `build-nix` runs. |
| `CIBUILD_NIX_CACHE_TOKEN` | *(written by install.sh)* | Attic auth token. |
| `REGISTRY_PORT` | `5000` | Host port for the local registry. |
| `REGISTRY_BROWSER_PORT` | `5001` | Host port for the registry browser. |
| `USE_REPO_LIBS` | `1` | Use cibuild libs from the checked-out repo instead of the image. |
| `USE_REPO_ENTRYPOINT` | `1` | Use entrypoint script from the repo. |
| `CIBUILDER_LOCKED` | `1` | Block pre/post and test script execution. Set to `0` to allow. |
| `CIBUILDER_ROOTLESS_KIT` | `1` | Run with rootlesskit (required for buildctl daemonless). |
| `CIBUILD_LOG_LEVEL` | `3` | Log verbosity in the lab defaults to `3` (dump). |

---

## Network and Registry

All containers share the Docker network `cibuilder-net`. The local registry is reachable inside the network as `localregistry.example.com:5000`.

To pull images to your **host** Docker, add to `/etc/hosts`:

```
127.0.0.1  localregistry.example.com
```

And to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["localregistry.example.com:5000"]
}
```

---

## Kubernetes Namespaces

| Namespace | Purpose | Service Account |
|-----------|---------|-----------------|
| `buildkitr` | Remote BuildKit daemon (rootless, mTLS, NodePort 31234) | — |
| `buildkitk` | BuildKit pods for `buildx` Kubernetes driver | `buildkit-sa` |
| `teststage` | Test containers for cibuild test run | `teststage-sa` |

Local kubectl wrapper:

```sh
cd installer
./kc.sh get pods -n buildkitr
./kc.sh get pods -n teststage
```

---

## Uninstall

Stop containers and remove cluster, kubeconfigs, and certs — **keeps registry and Attic data volumes**:

```sh
./uninstall.sh
```

Full teardown including all volumes, cosign keys, and generated files:

```sh
./uninstall.sh --all
```