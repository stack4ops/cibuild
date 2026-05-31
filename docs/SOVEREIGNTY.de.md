# Digitale Souveränität und die Freiheit zu gehen

> [English](./SOVEREIGNTY.md) · **Deutsch**

Dieses Dokument beschreibt ein Prinzip und verwendet `cibuild` als
durchgearbeitetes Beispiel. Das Prinzip ist der Punkt; die Umsetzung ist nur der
Beleg, dass es sich bewährt.

---

## Die vernachlässigte Hälfte der Souveränität

Digitale Souveränität wird meist danach diskutiert, wo Daten liegen, wer die
Infrastruktur betreibt und welche Rechtsordnung gilt. Es gibt eine zweite
Hälfte, die weit weniger Aufmerksamkeit erhält: die Fähigkeit zu *gehen* — ein
Werkzeug, einen Anbieter oder eine Plattform zu wechseln, ohne alles neu zu
bauen.

Ein System, das man nicht verlassen kann, ist keines, das man vollständig
kontrolliert — egal wo es läuft. Exit-Fähigkeit ist kein Komfort, sondern eine
Vorbedingung von Souveränität.

Lock-in wird selten gewählt. Er akkumuliert — eine vernünftige Bequemlichkeit
nach der anderen, bis das Gehen mehr kostet als das Bleiben. Sichtbar wird er
meist dort, wo er am schwersten umkehrbar ist.

## Abstraktionen als Souveränitäts-Infrastruktur

Jeder Integrationspunkt einer Pipeline ist eine Stelle, an der Lock-in entstehen
kann: das VCS, die CI-Plattform, die Build-Engine, die Registry. Die
Gegenmaßnahme ist, jeden hinter einer schlanken Abstraktion zu halten. Die
Abstraktion muss nicht aufwendig sein — sie muss ehrlich sein: das Variable
isolieren, damit ein Austausch nicht durch alles andere hindurch fortwirkt.

`cibuild` ist so gebaut, um das Prinzip zu demonstrieren:

- **VCS-/CI-Adapter** — die CI-Plattform (GitLab, GitHub, lokal) wird auf einen
  Adapter reduziert, der native CI-Variablen auf eine gemeinsame Schnittstelle
  abbildet. Die Pipeline weiß nicht, auf welcher Plattform sie läuft; der Wechsel
  ist eine Frage des Adapters, kein Neuschrieb.
- **Build-Client** — die Build-Engine (BuildKit, buildx, Kaniko, Nix) ist ein
  Parameter, keine eingebrannte Wahl. Dieselbe Pipeline kann auf einem Runner
  rootless bauen und auf einem anderen vollständig reproduzierbar mit Nix.
- **Registry-Kompatibilität** — Registries unterscheiden sich darin, wie
  vollständig sie die OCI-Spezifikation umsetzen, besonders die 1.1-Referrers-
  API. Das Tooling funktioniert über das Spektrum hinweg, sodass die Registry
  eine Wahl bleibt und keine Einschränkung wird.
- **Test-Backend** — Tests laufen gegen das gebaute Image wahlweise auf Docker
  oder Kubernetes, per Parameter ausgewählt, mit demselben kleinen
  Assertion-Set (`log`, `response`) in beiden Fällen. Die Testdefinition hängt
  nicht davon ab, wo sie läuft.

Jede Abstraktion ist für sich unscheinbar. Die kombinierte Wirkung ist der
Punkt: jede Stelle, an der eine Abhängigkeit zu Lock-in erstarren könnte, wird
austauschbar gehalten.

## Ein proprietäres Feature bedienen, ohne von ihm abzuhängen

Es gibt einen Unterschied zwischen dem *Nutzen* eines Anbieter-Features und der
*Abhängigkeit* von einem.

Docker Hub etwa erwartet ein Docker-spezifisches Attestation-Manifest, damit
seine Compliance-UI ein Image als „signiert" anzeigt. Die Pipeline schreibt
dieses Manifest, wenn das Target Docker Hub ist — sodass die Integration
vollständig funktioniert — ohne es zur strukturellen Voraussetzung dafür zu
machen, *wie* Artefakte erzeugt werden. Das offene, standardbasierte Artefakt
bleibt die Quelle der Wahrheit; die proprietäre Ergänzung ist eine optionale
Schicht für die eine Registry, die sie will.

Das Muster: die Erwartungen einer Plattform an ihrem eigenen Rand erfüllen, ohne
sie den Kern umformen zu lassen.

## Expertise ist eine Vorbedingung souveräner Entscheidungen

Es gibt eine weitere Abhängigkeit: Wissen. Man kann einen Lock-in nicht
einschätzen, eine Exit-Strategie nicht abwägen und eine Abstraktion nicht
beurteilen, wenn man die Alternativen nie betrieben hat. Das rechtliche Recht zu
gehen ist nicht die praktische Fähigkeit zu gehen — letztere braucht Menschen,
die die beweglichen Teile verstehen.

Deshalb ist eine praktische Umgebung ebenso wichtig wie das Werkzeug. Das
`installer/`-Lab existiert, damit die gesamte Pipeline — jeder Build-Client,
jedes Registry-Verhalten, jeder Signing-Modus — lokal ausgeführt, inspiziert und
auch kaputtgemacht werden kann, ohne externe Infrastruktur. Sein Zweck ist nicht
nur Komfort; es geht darum, das operative Verständnis aufzubauen, das eine
Organisation *entscheidungsfähig* macht — zu beurteilen, was es kosten würde,
eine Abhängigkeit wieder zu verlassen.

Ohne das ist „Souveränität" ein Häkchen im Beschaffungsprozess. Mit ihm ist sie
etwas, das eine Organisation ausüben kann.

Die Wahl von POSIX-Shell statt einer kompilierten Sprache wie Go oder Rust ist im selben Geist bewusst getroffen: das gesamte Werkzeug ist ohne Build-Schritt les- und auditierbar und eignet sich für Rapid Prototyping — man sieht genau, was läuft, und kann es an Ort und Stelle ändern.

## Zusammenfassung

- Die Freiheit zu gehen ist Teil der Souveränität, nicht von ihr getrennt.
- Lock-in akkumuliert leise; die Verteidigung ist, jeden Integrationspunkt
  bewusst austauschbar zu halten.
- Schlanke, ehrliche Abstraktionen über CI-Plattform, Build-Engine, Registry und
  Test-Backend verwandeln Abhängigkeiten in austauschbare Entscheidungen.
- Proprietäre Features lassen sich am Rand bedienen, ohne im Kern von ihnen
  abzuhängen.
- Nichts davon ist ohne Expertise nutzbar — der Aufbau operativen Wissens, durch
  ein Lab und durch Praxis, ist daher selbst eine Souveränitätsmaßnahme.