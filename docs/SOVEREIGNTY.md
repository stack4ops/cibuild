# Digital Sovereignty and the Freedom to Leave

> **English** · [Deutsch](./SOVEREIGNTY.de.md)

This document describes a principle and uses `cibuild` as a worked example. The
principle is the point; the implementation is only evidence that it holds up.

---

## The neglected half of sovereignty

Digital sovereignty is usually discussed in terms of where data lives, who
operates the infrastructure, and which jurisdiction applies. There is a second
half that gets far less attention: the ability to *leave* — to change a tool,
vendor, or platform without rebuilding everything.

A system you cannot exit is not one you fully control, wherever it runs. Exit
capability is not a convenience; it is a precondition of sovereignty.

Lock-in is rarely chosen. It accumulates — one reasonable convenience at a time,
until leaving costs more than staying. It usually becomes visible at the point
where it is hardest to reverse.

## Abstractions as sovereignty infrastructure

Every integration point in a pipeline is a place where lock-in can form: the VCS,
the CI platform, the build engine, the registry. The countermeasure is to keep
each one behind a thin abstraction. The abstraction need not be elaborate — it
needs to be honest: isolate what varies, so swapping it doesn't ripple through
everything else.

`cibuild` is built this way to demonstrate the principle:

- **VCS / CI adapter** — the CI platform (GitLab, GitHub, local) is reduced to an
  adapter mapping native CI variables onto a common interface. The pipeline
  doesn't know which platform it runs on; switching is a matter of the adapter,
  not a rewrite.
- **Build client** — the build engine (BuildKit, buildx, Kaniko, Nix) is a
  parameter, not a baked-in choice. The same pipeline can build rootless on one
  runner and fully reproducible with Nix on another.
- **Registry compatibility** — registries differ in how completely they implement
  the OCI spec, especially the 1.1 referrers API. The tooling works across the
  range, so the registry stays a choice rather than a constraint.
- **Test backend** — tests run against the built image on either Docker or
  Kubernetes, selected by parameter, with the same small assertion set (`log`,
  `response`) either way. The test definition does not depend on where it runs.

Each abstraction is unremarkable alone. The combined effect is the point: every
juncture where a dependency could harden into lock-in is kept exchangeable.

## Serving a proprietary feature without depending on it

There is a difference between *using* a vendor feature and *depending* on one.

Docker Hub, for example, expects a Docker-specific attestation manifest for its
compliance UI to show an image as "signed". The pipeline writes that manifest
when the target is Docker Hub — so the integration works fully — without making
it a structural requirement of how artifacts are produced. The open,
standards-based artifact stays the source of truth; the proprietary addition is
an optional layer for the one registry that wants it.

The pattern: meet a platform's expectations at its own edge, without letting them
reshape the core.

## Expertise is a precondition for sovereign decisions

There is one more dependency: knowledge. You cannot assess a lock-in, weigh an
exit strategy, or judge an abstraction if you have never operated the
alternatives. The legal right to leave is not the practical ability to leave —
the latter needs people who understand the moving parts.

This is why a hands-on environment matters as much as the tool. The `installer/`
lab exists so the whole pipeline — every build client, registry behaviour, and
signing mode — can be run, inspected, and broken locally, without external
infrastructure. Its purpose is not just convenience; it is to build the
operational understanding that makes an organization *able to decide* what
leaving a dependency would actually cost.

Without that, "sovereignty" is a procurement checkbox. With it, it is something
an organization can exercise.

The choice of POSIX shell over a compiled language like Go or Rust is deliberate in the same spirit: the entire tool is readable and auditable without a build step, and it lends itself to rapid prototyping — you can inspect exactly what runs, and change it on the spot.

## Summary

- The freedom to leave is part of sovereignty, not separate from it.
- Lock-in accumulates silently; the defence is keeping each integration point
  deliberately replaceable.
- Thin, honest abstractions over the CI platform, build engine, registry, and
  test backend turn dependencies into exchangeable choices.
- Proprietary features can be served at the edge without being depended on at the
  core.
- None of this is usable without expertise — so building operational knowledge,
  through a lab and through practice, is itself a sovereignty measure.