# ci

Wiederverwendbare GitHub-Actions-Workflows für Saschas Projekte (PuckHub, Recook,
Staplerschule Kittel). Der Standard und die Schnittstellen stehen in `README.md`. Diese
README ist der Vertrag mit den Projekten: Was dort steht, muss so funktionieren.

- Die Workflows liegen unter `.github/workflows/` und haben `on: workflow_call`.
- Aufgerufen werden sie mit `@v1`. Nach einer Änderung, die in `main` gelandet ist, wird
  ein neuer `v1.x.y`-Tag gesetzt und `v1` darauf verschoben. Inkompatible Änderungen gibt
  es nur als `v2`.
- Jede Änderung trifft alle Projekte gleichzeitig. Deshalb Inputs nur ergänzen, mit
  Standardwert, nie umbenennen oder entfernen.
- Die CI dieses Repos prüft die Workflows mit `actionlint`.
- Das Repo ist öffentlich (siehe „Zugriff“ in der README). Keine Secrets, internen
  Adressen oder projektspezifischen Werte hineinschreiben.
