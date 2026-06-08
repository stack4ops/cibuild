# Vision: Nix-native OCI

> [English](./VISION.md) · **Deutsch**

> **Status: Das ist eine Vision, kein Feature.** Nichts von dem Folgenden ist
> heute in cibuild implementiert. Teile hängen an noch offener Upstream-Arbeit
> (ein nativer `oci://`-Substituter im Nix-Daemon), Teile existieren nur als
> eingeschlafene oder experimentelle Projekte (`nix-snapshotter`, Proxy-Ansätze
> wie `nixcache-oci` und `oranc`). Es ist hier dokumentiert, weil die Richtung
> stimmig und durchdenkenswert ist — nicht, weil es verfügbar wäre.

---

Heute bedeutet das Bauen eines OCI-Images aus Nix eine Konvertierungskette: ein
Nix-Store-Path wird zu einem NAR-Archiv serialisiert, das NAR in einen
tar-Layer konvertiert, und der tar-Layer als neuer Blob gepusht — eine neue
Kopie bei jedem Build, auch wenn sich nichts geändert hat.

Die Vision entfernt die Kette. Könnte der Nix-Daemon direkt `oci://` sprechen,
lägen Store-Paths bereits als content-addressed NAR-Blobs in einer
OCI-Registry. Ein Image zu bauen hieße dann nicht mehr, Daten zu
*serialisieren*, sondern sie zu *referenzieren*: das Image-Manifest zeigt
einfach auf bereits existierende NAR-Blobs. Ein Image-Build kostete nur noch das
Schreiben eines Manifests — kein Datentransfer, keine tar-Konvertierung.

Daraus folgen zwei Dinge. Erstens **echte Deduplizierung**: zwei Images, die
sich `glibc` teilen, teilen exakt denselben Blob, nicht zwei identische
tar-Layer; `amd64`- und `arm64`-Builds desselben Pakets referenzieren einen
Blob, nicht zwei Kopien. Zweitens wird die Registry zu einem **einzigen
content-addressed Store** für sowohl den Nix-Binary-Cache als auch die daraus
gebauten OCI-Images — dieselben Objekte, von beiden Seiten referenziert.

Auf der Runtime-Seite setzt sich dasselbe Prinzip bis in die Container-Runtime
selbst fort: statt tar-Layer zu materialisieren, werden NAR-Blobs on-demand
gemountet. Genau das wollte `nix-snapshotter` für containerd als
Snapshotter-Plugin leisten — einen Store-Path direkt mounten, ohne
tar-Extraktion — und ein lazy NAR-Fetcher könnte das auf Standard-Runtimes
verallgemeinern, im Geist von estargz oder nydus lazy pulling.

Das folgende Diagramm zeigt das vollständige Bild: die Konvertierungskette wie
sie heute ist, das referenz-basierte Assembly wie es sein könnte, den geteilten
Blob-Store, das Runtime-Mounting und die eine Upstream-Änderung, die alles
verankert — einen Nix-Daemon, der eine OCI-Registry als nativen Substituter
behandelt.

![Nix-native OCI: die heutige Konvertierungskette gegenüber dem referenz-basierten Image-Assembly, der geteilte Zot-Blob-Store, das Runtime-NAR-Mounting und der native OCI-Substituter, der das ganze Bild verankert](./img/nix-native-oci.svg)
