![Version](https://img.shields.io/badge/version-0.9.0-blue)
![License](https://img.shields.io/badge/license-Apache%202.0-green)
![Shell](https://img.shields.io/badge/shell-POSIX%20sh-lightgrey?logo=gnu-bash)
![GitLab CI](https://img.shields.io/badge/GitLab%20CI-supported-FC6D26?logo=gitlab)
![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-supported-2088FF?logo=github-actions)

# cibuild — Dokumentation

> [English](README.md) · **Deutsch**

> Version 0.9.0 · POSIX shell · GitLab CI · GitHub Actions · Local

> **cibuild folgt einem Security-First-Modell für die Software Supply Chain** —
> jedes Artefakt ist an einen unveränderlichen Digest gebunden, signiert und zu
> jeder Zeit überprüfbar.
> Siehe das [Sicherheitsmodell](docs/SECURITY-MODEL.de.md) ([English](docs/SECURITY-MODEL.md)).

---

## Inhaltsverzeichnis

1. [Überblick](#überblick)
2. [Designprinzipien](#designprinzipien)
   - [Sicherheitsmodell](#sicherheitsmodell)
   - [Digitale Souveränität](#digitale-souveränität)
3. [Artifact-Lock-Dateien](#artifact-lock-dateien)
   - [Manuelle Verifikation und Auditing](#manuelle-verifikation-und-auditing)
4. [Runs und Pipeline-Jobs](#runs-und-pipeline-jobs)
   - [cibuilder-Image-Varianten](#cibuilder-image-varianten)
   - [Build-Clients](#build-clients)
   - [Einzelner Job vs. getrennte Jobs](#einzelner-job-vs-getrennte-jobs)
5. [Konfigurationsreferenz](#konfigurationsreferenz)

Für die vollständige Konfigurationsreferenz — alle Umgebungsvariablen,
CI-Adapter-Variablen, Tag-Templates, Registry- und Mirror-Konfiguration,
Test-Assertions und Logging — siehe **[REFERENCE.md](REFERENCE.md)** (englisch).

---

## Überblick

`cibuild` ist ein CI-Werkzeug zum Bauen, Testen und Releasen von
OCI-Container-Images. Es ist in POSIX-Shell geschrieben und läuft innerhalb
eines Container-Images, das vom [cibuilder](https://github.com/stack4ops/cibuilder)-Projekt
bereitgestellt wird.

Das Werkzeug wird so aufgerufen:

```sh
cibuild -r <command>
# command: check | build | test | release | update-caches | all
```

Die CI-Plattform wird automatisch erkannt (GitLab CI, GitHub Actions, lokal).
Jede Plattform hat einen Adapter, der die nativen CI-Variablen auf die interne
Schnittstelle von cibuild abbildet.

Um alle Build-Modi lokal zu erkunden oder cibuild selbst weiterzuentwickeln,
stellt das Verzeichnis `installer/` eine vollständige, in sich geschlossene
Laborumgebung bereit — siehe [`installer/README.md`](installer/README.md).

---

## Designprinzipien

cibuild existiert, um zwei Überzeugungen darüber zu demonstrieren, wie Software
gebaut und released werden sollte — eine technische, eine strategische. Beide
sind vollständig dokumentiert:

### Sicherheitsmodell

cibuild ist um ein **Security-First**-Modell für die Supply Chain herum gebaut:
kryptografische Nachvollziehbarkeit ist das strukturelle Fundament, kein
nachträglicher Gedanke. Jedes Artefakt ist an einen unveränderlichen Digest
gebunden, jeder Digest ist signiert, und die gesamte Kette ist von jeder Person,
zu jeder Zeit, von jedem Ort aus überprüfbar.

Das vollständige Modell — der Commit als kryptografischer Anker, die
Artifact-Lock-Datei, die zwei kryptografischen Scopes (Build mit statischem
Schlüssel und keyless Release), die OCI-Referrer-Attestierungen und das
Compliance-Governance-Gate — ist separat dokumentiert:

- **[Sicherheitsmodell](docs/SECURITY-MODEL.de.md)** (Deutsch)
- **[Security Model](docs/SECURITY-MODEL.md)** (English)

### Digitale Souveränität

cibuild hält jeden Integrationspunkt — die CI-Plattform, die Build-Engine, die Registry, das Test-Backend — hinter einer schlanken, austauschbaren Abstraktion. Die Freiheit, ein Werkzeug zu verlassen, ohne alles neu zu bauen, wird als Vorbedingung digitaler Souveränität behandelt, nicht als nachträglicher Gedanke — und das praktische Lab ist Teil des Aufbaus jener Expertise, die solche Entscheidungen erst möglich macht.

- **[Digitale Souveränität und die Freiheit zu gehen](docs/SOVEREIGNTY.de.md)** (Deutsch)
- **[Digital Sovereignty and the Freedom to Leave](docs/SOVEREIGNTY.md)** (English)

---

## Artifact-Lock-Dateien

Nach jedem Plattform-Build schreibt cibuild eine Datei
`artifact-lock.<platform_name>.json` (z. B. `artifact-lock.linux-amd64.json`)
in das Repository-Root und committet sie über den CI-Adapter zurück in den
Branch.

Die Lock-Datei hält die exakten Digests des Plattform-Images und aller seiner
Supply-Chain-Referrer fest — SBOM, Schwachstellenbericht und Provenance —
zusammen mit dem Digest der cosign-Signatur. Das erzeugt einen
**kryptografischen Anker**: jedes Artefakt ist an den unveränderlichen
Image-Digest gebunden, und da das Image signiert ist, ist die gesamte Kette zu
jedem Zeitpunkt nachweislich intakt.

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

### Verwendung über Runs hinweg

**Test-Run** — bevor ein Test ausgeführt wird, liest der Test-Run den
Plattform-Digest aus der Lock-Datei und verifiziert die cosign-Signatur dagegen.
Tests laufen immer gegen genau den Digest, der gebaut und signiert wurde — nicht
gegen einen Tag, der überschrieben worden sein könnte. Dies kann mit
`CIBUILD_TEST_COSIGN_VERIFY_BUILD_ARTIFACTS=0` deaktiviert werden.

**Release-Run** — der Release-Run liest die Plattform-Digests aus den
Lock-Dateien, um den Multi-Plattform-Index zusammenzubauen, und verifiziert alle
cosign-Signaturen erneut, bevor er fortfährt. Dies kann mit
`CIBUILD_RELEASE_COSIGN_VERIFY_BUILD_ARTIFACTS=0` deaktiviert werden.

Beide Runs lösen das Image über den Digest auf — unabhängig vom Tag-Zustand in
der Registry — sodass die gesamte Pipeline über Jobs hinweg
manipulationssicher nachweisbar ist.

> Die architektonische Begründung hinter Artifact-Locks, kryptografischen Scopes
> und dem Verifikationsmodell findet sich im
> [Sicherheitsmodell](docs/SECURITY-MODEL.de.md).

### Compliance-Werkzeuge

Die Lock-Datei ist eine einfache JSON-Datei, die ins Repository committet wird,
wodurch alle Artefakt-Digests externen Werkzeugen ohne Registry-Zugang zur
Verfügung stehen. Compliance-Pipelines und Audit-Werkzeuge können sie direkt
konsumieren:

- **SBOM-Consumer** (OWASP Dependency-Track, DevGuard) — nutzen
  `referrers.sbom`, um die CycloneDX-SBOM per Digest aus der Registry abzurufen
- **CVE-/VEX-Pipelines** — nutzen `referrers.vuln`, um den
  trivy-Schwachstellenbericht abzurufen und in VEX-Generierungswerkzeuge
  einzuspeisen
- **SARIF-/Audit-Dashboards** — kombinieren `image_digest`, `source_commit` und
  `built_at`, um Image-Versionen mit Source-Commits und Scan-Ergebnissen zu
  korrelieren

Lock-Dateien werden mit einer `[skip ci]`-Commit-Message committet, um keine
neue Pipeline auszulösen. Im lokalen Adapter werden sie lokal committet, ohne
Push.

### Manuelle Verifikation und Auditing

Da die Lock-Datei jeden Digest festhält und das Image signiert ist, kann jede
Person ein Artefakt von überall verifizieren und auditieren — ohne Zugang zur
Pipeline, zum CI-System oder zu den Build-Logs. Es genügen die committete
Lock-Datei, der öffentliche Schlüssel und Lesezugriff auf die Registry.

**Signatur verifizieren.** Den Image-Digest aus der Lock-Datei lesen und gegen
den öffentlichen Schlüssel verifizieren:

```sh
DIGEST=$(jq -r .image_digest artifact-lock.linux-amd64.json)
cosign verify --key cosign.pub registry.example.com/myorg/myapp@"$DIGEST"
```

Das Image wird über den Digest aufgelöst, nicht über einen Tag — die
Verifikation hält also auch dann, wenn der Tag später verschoben oder entfernt
wurde.

**Attestierungen auditieren.** Jeder Referrer-Digest steht in der Lock-Datei.
Beliebige davon direkt aus der Registry ziehen und inspizieren:

```sh
# CycloneDX SBOM
SBOM=$(jq -r .referrers.sbom artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$SBOM" | jq .

# CVE-Schwachstellenbericht
VULN=$(jq -r .referrers.vuln artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$VULN" | jq .

# SLSA-Provenance
PROV=$(jq -r .referrers.provenance artifact-lock.linux-amd64.json)
regctl artifact get registry.example.com/myorg/myapp@"$PROV" | jq .
```

**Den vollständigen Referrer-Baum entdecken.** Alle an den Image-Digest
angehängten Attestierungen direkt aus der Registry auflisten:

```sh
regctl artifact list registry.example.com/myorg/myapp@"$DIGEST"
```

Das ist der Kern des Security-First-Modells in der Praxis: das Artefakt trägt
seine eigene Provenienz, und diese Provenienz ist von jeder Person, zu jeder
Zeit, von jedem Ort aus unabhängig überprüfbar.

---

## Runs und Pipeline-Jobs

cibuild hat fünf Runs, die einzeln oder alle zusammen aufgerufen werden können:

| Run | cibuilder-Image | Beschreibung |
|-----|-----------------|--------------|
| `check` | `cibuilder:check` | Vergleicht die Layer des Basis-Images mit dem zuletzt gebauten Image. Bricht die Pipeline ab, wenn sich nichts geändert hat. Läuft nur bei geplanten oder manuell ausgelösten Pipelines. |
| `build` | `cibuilder:build-buildctl` / `build-nix` / `build-kaniko` / `build-buildx` | Baut pro Plattform OCI-Images, erzeugt SBOM und CVE-Bericht als OCI-Referrer, signiert mit cosign und pusht alles in die Target-Registry. |
| `test` | `cibuilder:test-docker` / `test-k8s` | Führt Test-Skript und/oder JSON-Assertions gegen das frisch gebaute Image aus. |
| `release` | `cibuilder:release` | Baut einen sauberen Multi-Plattform-Index zusammen, erzeugt SBOM (SPDX + CycloneDX) aus dem bestehenden CycloneDX-Referrer, signiert mit cosign, kopiert zusätzliche Tags, spiegelt zu anderen Registries. |
| `update-caches` | `cibuilder:update-caches` | Aktualisiert externe Caches (trivy-Schwachstellen-DB). Für geplante Pipelines gedacht — kein Build, kein Release. |

Jeder Run kann einzeln aktiviert oder deaktiviert werden und unterstützt
`pre_script`- / `post_script`-Hooks.

Für einfache Setups führt `-r all` alle Schritte sequenziell in einem einzigen
Job aus — kein Artefakt-Transfer zwischen Jobs, minimale Runner-Konfiguration.
Getrennte Runs werden nur für native Multi-Arch-Builds oder Job-Isolation
benötigt.

### cibuilder-Image-Varianten

Jeder cibuild-Run hat eine passende cibuilder-Image-Variante mit fest
eingebautem `CIBUILD_RUN_CMD` — keine Konfiguration in der CI nötig:

```yaml
# GitLab CI — der Image-Tag bestimmt, was läuft
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

Für lokale Entwicklung und Tests kombiniert `cibuilder:all` alle Varianten und
akzeptiert `CIBUILD_RUN_CMD` als Override.

### Build-Clients

Der Build-Run unterstützt vier Clients, ausgewählt über `CIBUILD_BUILD_CLIENT`:

| Client | Image-Variante | Beschreibung |
|--------|----------------|--------------|
| `buildctl` *(Standard)* | `build-buildctl` | Daemonloses BuildKit via rootlesskit. Läuft überall — kein Docker-Daemon nötig. |
| `buildx` | `build-buildx` | Docker buildx mit drei Treiber-Optionen: `dockercontainer`, `remote`, `kubernetes`. |
| `kaniko` | `build-kaniko` | Rootless Kubernetes-native Builds. Läuft als root, kein Daemon. |
| `nix` | `build-nix` | Deklarative, reproduzierbare Builds via Nix-Flakes. Kein Dockerfile nötig. Output ist ein content-addressed OCI-Tar. |

#### Nix-Build-Client

Der `nix`-Client baut OCI-Images aus einer `flake.nix` im Repository-Root mit
`nixpkgs.dockerTools`. Das Ergebnis ist ein vollständig reproduzierbares,
distroless-artiges Image — bei gleichen Inputs Byte für Byte identisch bei jedem
Build.

```sh
# cibuild.env
CIBUILD_BUILD_CLIENT=nix
CIBUILD_NIX_FLAKE_ATTR=default        # packages.<system>.default in flake.nix
CIBUILD_NIX_CACHE_URL=https://attic.example.com/mycache   # optional Attic/Cachix
CIBUILD_NIX_CACHE_TOKEN=...           # optionaler Cache-Auth-Token
```

Die `build-nix`-cibuilder-Variante liefert eine Single-User-Nix-Installation mit
aktivierten Flakes. Der Sandbox-Modus wird zur Laufzeit automatisch erkannt.
Kein `--privileged`-Flag erforderlich.

Beim nix-Client werden SBOM und CVE-Berichte vom Nix-Build selbst erzeugt (über
`bombon` und `vulnxscan`) und direkt als OCI-Referrer übergeben. Die
trivy-basierte SBOM-/Vuln-Generierung im Build-Run wird für `build_client=nix`
übersprungen.

### Einzelner Job vs. getrennte Jobs

**`-r all` — einzelner Job (empfohlener Standard)**

```sh
cibuild -r all
```

Alle Runs werden sequenziell innerhalb eines einzigen CI-Jobs ausgeführt. Es
müssen keine Zwischen-Artefakte zwischen Jobs transferiert werden. Das ist das
einfachste Setup und funktioniert gut für die meisten Projekte — auch für
produktive CI-Pipelines, bei denen native Multi-Arch-Builds oder Job-Isolation
nicht erforderlich sind.

**Getrennte Runs — mehrere CI-Jobs**

Das Aufteilen ist sinnvoll, wenn:

- **Native Multi-Plattform-Builds** — `CIBUILD_BUILD_NATIVE=1` erfordert einen
  Runner pro Architektur. Jeder Runner führt seinen eigenen Build-Job aus; der
  Release-Job baut den Index zusammen.
- **Verschiedene Build-Backends** — z. B. `build-nix` auf einem Runner,
  `build-buildctl` auf einem anderen.
- **Sichtbarkeit und Kontrolle** — getrennte Jobs erlauben es, einzelne Schritte
  zu wiederholen und umgebungsspezifische Secrets nur an bestimmte Jobs zu
  binden.
- **DinD-Isolation** — `test-docker` benötigt einen Docker-in-Docker-Service,
  den man während Build oder Release vielleicht nicht laufen lassen möchte.

Nutze die `CIBUILD_*_ENABLED`-Variablen, um irrelevante Runs pro Job zu
deaktivieren (z. B. `CIBUILD_RELEASE_ENABLED=0` bei Build-Jobs).

---

## Konfigurationsreferenz

Das gesamte Laufzeitverhalten wird über `CIBUILD_*`-Umgebungsvariablen
gesteuert, gesetzt entweder in Konfigurationsdateien (`cibuild.env`,
`cibuild.<env>.env`) oder als CI-Variablen. Die vollständige Referenz wird
separat gepflegt:

**→ [REFERENCE.md](REFERENCE.md)** (englisch)

Sie umfasst Konfigurationsdateien und Variablen-Benennung, die vollständige
Umgebungsvariablen-Referenz für jeden Run (check, build, test, release,
update-caches), die gemeinsamen cosign-Einstellungen, dynamische Variablen
(Build-Secrets, Build-Args, cosign-Annotations), CI-Adapter-Variablen,
Tag-Templates, Registry-Konfiguration, Mirror-Registries, Test-Assertions und
Logging.