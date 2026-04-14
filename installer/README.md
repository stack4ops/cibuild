# cibuild Local Lab

A self-contained local development and testing environment for cibuild. It reproduces a full CI build pipeline on your machine — including a private registry, Docker-in-Docker, a k3d Kubernetes cluster, remote BuildKit, and cosign signing — all pre-wired and ready to use.

The lab uses the **local CI adapter** (`cibuild.local.env`) and is the recommended way to develop and test cibuild itself or to explore all build modes before rolling them out in a real CI environment.

---

## What the Lab Provides

| Component | Details |
|-----------|---------|
| **cibuilder container** | The cibuild runner image, launched via Docker Compose |
| **Docker-in-Docker (DinD)** | A privileged `docker:dind` container accessible as `tcp://docker:2375` — required for `buildx` and `kaniko` builds and for the test stage |
| **Local registry** | A TLS-enabled private registry at `localregistry.example.com:5000` with htpasswd auth (`admin` / `password`), pre-trusted by DinD and k3d |
| **Registry browser** | Web UI at `http://localhost:<REGISTRY_BROWSER_PORT>` for inspecting pushed images |
| **k3d cluster** | A lightweight k3s Kubernetes cluster named `cibuilder`, connected to the same Docker network |
| **BuildKit remote** (`buildkitr`) | A rootless BuildKit deployment in the `buildkitr` namespace, exposed as a NodePort service on `k3d-cibuilder-server-0:31234`. mTLS certificates are generated automatically by `mkcert` and written into `.env` |
| **BuildKit kubernetes driver** (`buildkitk`) | A dedicated service account and RBAC role in the `buildkitk` namespace, allowing the `docker buildx` Kubernetes driver to spawn BuildKit pods. The kubeconfig is generated and written into `.env` automatically |
| **Test stage service account** (`teststage`) | A service account in the `teststage` namespace with the minimal RBAC permissions needed for the cibuild test run (create/delete pods, port-forward, logs) |
| **cosign key pair** | Generated once during install, stored in `installer/signing/`, and written as base64 into `.env` |

This means every supported build mode is available out of the box:

| `CIBUILD_BUILD_CLIENT` | Requires | Works in lab |
|------------------------|----------|-------------|
| `buildctl` (daemonless) | rootlesskit in cibuilder | ✓ |
| `buildctl` (remote) | BuildKit in k3d (`buildkitr`) | ✓ |
| `buildx` — `dockercontainer` driver | DinD | ✓ |
| `buildx` — `remote` driver | BuildKit in k3d (`buildkitr`) | ✓ |
| `buildx` — `kubernetes` driver | k3d + `buildkitk` service account | ✓ |
| `kaniko` | runs directly in cibuilder as root, no DinD or k3d needed | ✓ |

> **Using kaniko** requires switching the cibuilder container from rootless to root mode. In `.env`, comment out the default block and uncomment the kaniko block:
>
> ```sh
> # default (all other build clients)
> #CIBUILDER_ROOTLESS_KIT=1
> #CIBUILDER_USER="1000:$(id -g)"
> #CIBUILDER_PRIVILEGED=1
>
> # for kaniko
> CIBUILDER_ROOTLESS_KIT=0
> CIBUILDER_USER="0:$(id -g)"
> CIBUILDER_PRIVILEGED=0
> ```
>
> Kaniko executes the `/kaniko/executor` binary directly inside the cibuilder container and pushes the result straight to the registry — no Docker daemon and no Kubernetes cluster are involved. `CIBUILDER_PRIVILEGED=0` is intentional: kaniko runs as root but does not need a privileged container.

The test stage works with both `TEST_BACKEND=docker` (via DinD) and `TEST_BACKEND=kubernetes` (via the `teststage` service account in k3d).

---

## Prerequisites

- **Docker** with Compose plugin
- **Linux** (x86_64 or arm64)
- `nc` (netcat) — only needed when `FIND_FREE_PORTS=1`

The following tools are downloaded automatically by `install.sh` if not already present:

- `k3d` — Kubernetes-in-Docker
- `kubectl` — placed locally in `installer/kubectl`, not installed system-wide
- `mkcert` — for generating self-signed mTLS certificates for BuildKit
- `cosign` — placed locally in `installer/cosign`

---

## Quick Start

```sh
cd installer
./install.sh
```

`install.sh` is idempotent — it skips steps that are already done (cluster exists, namespaces exist, certs already generated, etc.) and is safe to re-run after a partial install or after pulling updates.

After installation, the cibuild wrapper is available at `~/.local/bin/cibuild`. Make sure `~/.local/bin` is in your `PATH`.

To run a full build pipeline in any repository:

```sh
cd /path/to/your/repo
cibuild -r all
```

The wrapper picks up the lab configuration from `~/.config/cibuild/.env` automatically.

---

## What `install.sh` Does Step by Step

1. **Copies `.env.template` → `.env`** on first run (only if `.env` does not yet exist). Sets `LIB_PATH` to the `bin/` directory of the checked-out repo.
2. **Starts Docker Compose** — either `docker-compose.dind.yaml` (when `DIND_ENABLED=1`, default) or `docker-compose.min.yaml` (registry only, no DinD).
3. **Installs k3d** if not present, then **creates the k3d cluster** `cibuilder` attached to the `cibuilder-net` Docker network, with the local registry pre-configured as a mirror.
4. **Creates the `teststage` namespace** with its service account and RBAC role. Generates a scoped kubeconfig and writes it base64-encoded into `.env` as `CIBUILD_TEST_SERVICE_ACCOUNT`.
5. **Creates the `buildkitr` namespace** — deploys rootless BuildKit with mTLS, generates daemon and client certificates via `mkcert`, creates Kubernetes secrets, and writes the client certs base64-encoded into `.env` as `CIBUILD_BUILD_BUILDKIT_CLIENT_CA/CERT/KEY`.
6. **Creates the `buildkitk` namespace** with the service account for the Kubernetes buildx driver. Generates a scoped kubeconfig (1-year token) and writes it into `.env` as `CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT`.
7. **Generates a cosign key pair** (empty password) and stores it in `installer/signing/`. Writes both keys base64-encoded into `.env` as `CIBUILD_RELEASE_COSIGN_PRIVATE_KEY` / `CIBUILD_RELEASE_COSIGN_PUBLIC_KEY`.
8. **Installs the cibuild wrapper** to `~/.local/bin/cibuild`.
9. **Copies `.env` to `~/.config/cibuild/.env`** — this is the config file the wrapper reads.

---

## Configuration (`.env`)

`.env` is created from `.env.template` on first install. The most relevant options:

| Variable | Default | Description |
|----------|---------|-------------|
| `DIND_ENABLED` | `1` | Start Docker-in-Docker. Set to `0` for a registry-only setup (no DinD, no Docker-based build or test). |
| `FIND_FREE_PORTS` | `0` | Automatically find free ports for the registry and k3d API. Useful when the defaults conflict with other local services. |
| `REGISTRY_PORT` | `5000` | Host port for the local registry (mapped to `127.0.0.1`). |
| `REGISTRY_BROWSER_PORT` | `5001` | Host port for the registry browser web UI. |
| `API_PORT` | `6445` | Host port for the k3d API server. |
| `USE_REPO_LIBS` | `1` | Use the cibuild shell libs from the checked-out repo (`../bin/lib`) instead of the libs embedded in the cibuilder image. Set to `0` to test against the released image libs. |
| `USE_REPO_ENTRYPOINT` | `1` | Use the entrypoint script from the repo. Set to `0` to use the one embedded in the image. |
| `CIBUILDER_LOCKED` | `1` | Mount `/tmp/cibuilder.locked` into the container, which blocks execution of pre/post scripts and test scripts. Set to `0` to allow script execution. |
| `CIBUILDER_ROOTLESS_KIT` | `1` | Run cibuilder with rootlesskit (required for the embedded daemonless BuildKit). Set to `0` for kaniko (which needs root). |
| `CIBUILD_LOG_LEVEL` | `3` | Log verbosity in the lab defaults to `3` (dump) — all internal state is printed. |

The auto-generated sections at the bottom of `.env` (certs, service accounts, cosign keys) are overwritten on each relevant install step and should not be edited by hand.

---

## Network and Registry

All containers (cibuilder, DinD, local registry, k3d nodes) share the Docker network `cibuilder-net`. The local registry is reachable inside this network as `localregistry.example.com:5000`.

The registry uses TLS with the pre-generated self-signed certificates in `installer/localregistry/certs/`. DinD trusts it via `daemon.json` (`insecure-registries`). k3d trusts it via `registry.yaml` (configured at cluster creation time).

To pull built images to your **host** Docker environment, add to `/etc/hosts`:

```
127.0.0.1  localregistry.example.com
```

And to `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["localregistry.example.com:5000"]
}
```

Then:

```sh
docker pull localregistry.example.com:5000/<project-path>:<tag>
```

---

## Kubernetes Namespaces

| Namespace | Purpose | Service Account |
|-----------|---------|-----------------|
| `buildkitr` | Remote BuildKit daemon (rootless, mTLS, NodePort 31234) | — |
| `buildkitk` | BuildKit pods spawned by the `buildx` Kubernetes driver | `buildkit-sa` |
| `teststage` | Test containers spawned by the cibuild test run | `teststage-sa` |

The service account kubeconfigs use the internal cluster API endpoint `https://k3d-cibuilder-serverlb:6443` (reachable from within `cibuilder-net`). To access the cluster from the host for debugging, change the server to `https://127.0.0.1:<API_PORT>` in the generated kubeconfig files.

A local `kubectl` wrapper is available for convenience:

```sh
cd installer
./kc.sh get pods -n buildkitr
./kc.sh get pods -n teststage
```

---

## Uninstall

Stop containers and remove the k3d cluster, kubeconfigs, and generated certs — but **keep registry data volumes**:

```sh
./uninstall.sh
```

Full teardown including registry and DinD volumes, cosign keys, and all generated files:

```sh
./uninstall.sh --all
```