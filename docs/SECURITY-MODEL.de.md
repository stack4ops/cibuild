# Sicherheitsmodell

> [English](./SECURITY-MODEL.md) · **Deutsch**

`cibuild` folgt einem **Security-First**-Modell für die Software Supply Chain:
kryptografische Nachvollziehbarkeit ist kein nachträglich angefügtes Feature,
sondern das strukturelle Fundament dafür, wie Artefakte gebaut, getestet und
released werden. Jedes Artefakt ist an einen unveränderlichen Digest gebunden,
jeder Digest ist signiert, und die gesamte Kette ist von jeder Person, zu jeder
Zeit, von jedem Ort aus überprüfbar.

Dieses Dokument beschreibt das Modell. Konfigurationsvariablen und operative
Details finden sich in der [Referenzdokumentation](../REFERENCE.md).

---

## Prinzipien

**Der Commit ist der kryptografische Anker.** Jeder Build wird durch einen
Commit ausgelöst — ein Developer-Push, ein geplantes Dependency-Update, ein
Merge Request. Dieser Commit-SHA wird durch die gesamte Pipeline getragen: in
die OCI-Image-Annotations (`org.opencontainers.image.revision`), in die
Signatur und in die Artifact-Lock-Datei. Code und Artefakte sind kryptografisch
miteinander verbunden, nicht durch Konvention.

**Arbeiten mit Digest, niemals mit Tag.** Tags sind veränderlich — sie können
überschrieben, verschoben oder durch Garbage Collection entfernt werden. Sobald
ein Image gebaut ist, löst jede nachfolgende Stage es über seinen
unveränderlichen `sha256:`-Digest auf. Plattform-spezifische Build-Tags
existieren nur vorübergehend während des Builds und können danach entfernt
werden. Nichts Nachgelagertes hängt davon ab, dass ein Tag stabil bleibt.

**Das Artefakt ist der Nachweis.** Ein signierter Digest mit seinen über OCI
Referrer angehängten Attestierungen *ist* der Sicherheitsnachweis. Es gibt keine
separate „Sicherheitsschicht" oberhalb des Artefakts — das Artefakt trägt seine
eigene Provenienz. Das ist dieselbe Idee wie „Test First" oder „API First",
angewandt auf Sicherheit: die Eigenschaft wird hineindesignt, nicht nachträglich
hineingeprüft.

**Minimale Artefakte, minimale Angriffsfläche.** Jedes zusätzliche Objekt in der
Supply Chain ist eine potenzielle Diskrepanz und ein Verifikationsrisiko. Das
Modell bevorzugt die kleinstmögliche Menge an Objekten, die Integrität und
Herkunft eines Artefakts vollständig beschreibt.

---

## Die Artifact-Lock-Datei

Nach jedem Plattform-Build wird eine Datei
`artifact-lock.<platform_name>.json` geschrieben und als signiertes OCI-Artefakt
in die Registry gepusht (artifact-type "application/vnd.cibuild.artifact-lock+json")
— co-lokalisiert mit dem Image, das sie beschreibt. Pro
Plattform werden zwei Tags gepflegt:

- **`<image>:lock-<build-tag>-<commit-sha>-<platform>`** — unveränderliche,
  commit-spezifische Referenz auf den exakten Build, der diesen Lock erzeugt hat
- **`<image>:lock-<build-tag>-latest-<platform>`** — veränderlicher Zeiger auf
  den aktuellsten Build dieses Tags, nach jedem erfolgreichen Push aktualisiert

Die Lock-Datei hält die exakten Digests des Plattform-Images und aller seiner
Supply-Chain-Referrer fest — SBOM, Schwachstellenbericht, Provenance — zusammen
mit dem Digest der Signatur und dem Source-Commit. Da das Image signiert ist und
die Referrer an seinen Digest gebunden sind, ist die gesamte Kette nachweislich
intakt, wann immer das Lock-Artefakt gelesen wird.

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

Ein optionaler Kondensierungsschritt (`cibuild_ci_condense_lock_artifacts`) kann
Lock-Dateien nach einem Merge ins VCS zurückspiegeln, für Workflows die
Lock-Daten im Repository benötigen. Dieser Schritt ist explizit und vom
Build-Pipeline-Fluss entkoppelt.

---

## Kryptografische Scopes

Das Modell unterscheidet zwei kryptografische Scopes mit unterschiedlichen
Vertrauenseigenschaften.

### Build-Scope — statischer Schlüssel

Die Build-Stage signiert jedes Plattform-Image, seine Referrer und sein
Lock-Artefakt mit einem statischen Schlüsselpaar. Der private Schlüssel wird als
Secret injiziert; der öffentliche Schlüssel liegt im Repository (z. B.
`cosign.pub`), sodass jeder Consumer verifizieren kann. Dieser Scope eignet sich
für interne Infrastruktur, in der ein bekanntes Schlüsselpaar von der
Organisation verwaltet wird.

Das folgende Diagramm zeigt, wie das Plattform-Image, seine Referrer, das
Lock-Artefakt und die Signatur ein einziges kryptografisch gebundenes Objekt
bilden — und wie jede Stage, vom Build über das Testen bis zur externen
Governance, diese Signatur gegen den Digest erneut verifiziert, statt einem Tag
zu vertrauen.

![Plattform-Image-Integrität im Build-Scope: Digests werden in eine Artifact-Lock gebunden, mit SBOM und Provenance als OCI Referrer, gegen cosign.pub signiert und in jeder Stage erneut verifiziert](./img/scope1-platform-integrity.svg)

### Release-Scope — keyless

Die Release-Stage kann den finalen Multi-Plattform-Index per Keyless-Signing
signieren: die Identität des CI-Jobs selbst, etabliert über ein OIDC-Token, wird
genutzt, um ein kurzlebiges Zertifikat von einer Zertifizierungsstelle zu
erhalten, und das Signing-Ereignis wird in einem Transparency-Log
aufgezeichnet. Es wird nirgends ein langlebiger privater Schlüssel gespeichert.
Dieser Scope eignet sich für Releases, bei denen eine öffentlich überprüfbare,
auditierbare Signing-Identität gewünscht ist.

Das folgende Diagramm zeigt den Keyless-Ablauf: die CI-Identität wird gegen ein
kurzlebiges Zertifikat eingetauscht, der Multi-Plattform-Index wird signiert,
und das Signing-Ereignis wird im Transparency-Log aufgezeichnet — wodurch eine
öffentlich auditierbare Spur ohne jeden gespeicherten Schlüssel entsteht.

![Keyless-Release-Signing: die CI-OIDC-Identität wird gegen ein kurzlebiges Zertifikat eingetauscht, der Multi-Plattform-Index wird signiert, und das Ereignis wird in einem Transparency-Log aufgezeichnet](./img/scope2-release-signing.svg)

Die beiden Scopes sind unabhängig: ein interner Build kann einen statischen
Schlüssel verwenden, während das öffentliche Release keyless signiert wird, oder
beide nutzen denselben Modus. Entscheidend ist, dass jedes Artefakt innerhalb
eines klar definierten Scopes signiert wird und dass der Verifikationspfad
eindeutig ist.

---

## Supply-Chain-Attestierungen

Jedes Plattform-Image trägt seine Attestierungen als OCI Referrer, gebunden an
den Image-Digest:

```
application/vnd.cyclonedx+json        # CycloneDX SBOM
application/vnd.trivy.vuln+json       # CVE-Schwachstellenbericht
application/vnd.slsa.provenance+json  # SLSA Provenance
```

Da diese Referrer an den Digest angehängt sind und der Digest signiert ist,
verifiziert das Überprüfen der Signatur implizit, welche Attestierungen zum
Image gehören. Es gibt keine Mehrdeutigkeit darüber, welche SBOM welchen Build
beschreibt — die kryptografische Bindung beantwortet diese Frage.

Der Artifact-Lock wird als separates OCI-Artefakt neben dem Image gespeichert,
adressiert über einen Tag statt als Referrer an den Image-Digest angehängt:

```
application/vnd.cibuild.artifact-lock+json  # Artifact-Lock
```

Sowohl der commit-spezifische Tag als auch der `latest`-Zeiger werden im selben
Build-Scope signiert — der Verifikationspfad ist identisch zu dem des Images.

### Verifikation über Stages hinweg

Sowohl die Test- als auch die Release-Stage verifizieren Signaturen, bevor sie
handeln:

- Die **Test-Stage** lädt das Plattform-Lock-Artefakt aus der Registry,
  verifiziert seine cosign-Signatur und liest den Plattform-Digest daraus. Tests
  laufen daher immer gegen genau den Digest, der gebaut und signiert wurde —
  niemals gegen einen veränderlichen Tag.

- Die **Release-Stage** lädt und verifiziert alle Plattform-Lock-Artefakte
  erneut und baut erst dann den Multi-Plattform-Index zusammen.

Beide Stages lösen Images über den Digest auf, unabhängig vom Tag-Zustand —
dadurch ist die Pipeline über Job-Grenzen und Runner hinweg
manipulationssicher nachweisbar.

---

## Compliance und Governance

Da das Lock-Artefakt alle Artefakt-Digests als reines JSON in der Registry
bereitstellt, können Compliance- und Governance-Werkzeuge es direkt konsumieren:

```sh
# aktuellsten Lock für einen Build-Tag und eine Plattform abrufen
regctl artifact get registry.example.com/myorg/myapp:lock-main-latest-linux-amd64 | jq .
```

- **SBOM-Consumer** (z. B. OWASP Dependency-Track, DevGuard) nutzen
  `referrers.sbom`, um die CycloneDX-SBOM per Digest abzurufen.
- **CVE-/VEX-Pipelines** nutzen `referrers.vuln`, um den Schwachstellenbericht
  abzurufen und in die VEX-Generierung einzuspeisen.
- **Audit-Dashboards** kombinieren `image_digest`, `source_commit` und
  `built_at`, um Image-Versionen mit Source-Commits und Scan-Ergebnissen zu
  korrelieren.

Ein Compliance-Governance-Gate, das diese Artefakte konsumiert, agiert als
Lifecycle-Wächter: es verifiziert Policy (CVE-Schwellenwerte,
SBOM-Vollständigkeit, Lizenz-Policy) gegen die Attestierungen, bevor ein Release
zugelassen wird. Dies ist getrennt von der technischen Verifikation während des
Builds — Governance prüft Policy, nicht Funktion. Beides muss bestehen, bevor
ein Artefakt weitergereicht wird.

---

## Reproduzierbare Builds

Wenn der Build reproduzierbar ist — etwa mit dem Nix-Build-Client — wird die
Provenance-Garantie verstärkt: dieselben Inputs erzeugen denselben
Output-Digest, Byte für Byte. Der Derivation-Hash selbst wird zu einer starken
Aussage über die Herkunft, unabhängig davon, wann oder wo der Build lief. Das
ist der natürliche Endpunkt des Security-First-Modells: ein Artefakt, dessen
Integrität und Herkunft nicht nur attestiert, sondern strukturell garantiert
sind.