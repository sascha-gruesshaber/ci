# ci

Gemeinsame GitHub-Actions-Bausteine und der CI-Standard für Saschas Node-Projekte
(PuckHub, Recook, Staplerschule Kittel). Die Tests bleiben in jedem Projekt, weil sie
projektspezifisch sind. Bauen, Ausliefern und das Einspielen von Aktualisierungen kommen
von hier, damit alle Projekte gleich funktionieren.

## Der Ablauf in jedem Projekt

```
Pull Request ──► check ──► e2e                     (nur prüfen, nichts bauen)
push main    ──► check ──► e2e ──► build ──► deploy (Image bauen, auf Coolify ausliefern)
```

- Es gibt **eine** Umgebung: `main` ist live.
- Änderungen kommen nur per Pull Request und **Squash-Merge**. Der PR-Titel wird zum
  Commit-Titel, die PR-Beschreibung zur Commit-Nachricht, der Branch wird danach gelöscht.
- Images werden **nur auf `main`** gebaut, nicht in Pull Requests. Scheitert der Build,
  wird nicht ausgeliefert, und die laufende Version bleibt stehen.

## Der Standard

### Workflow-Datei

Jedes Projekt hat genau eine Pipeline: `.github/workflows/ci.yml`.

```yaml
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  # Ein neuer Push auf einen PR bricht den alten Lauf ab, auf main nie.
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Jobs mit genau diesen Namen (fehlt einer, weil das Projekt ihn nicht braucht, entfällt er):

| Job | Wann | Inhalt |
|---|---|---|
| `check` | immer | Lint, Typen, Unit-Tests, Migrations-Checks. Projektspezifisch. |
| `e2e` | immer | Playwright o. Ä. Projektspezifisch. |
| `build` | nur push auf `main` | `uses: sascha-gruesshaber/ci/.github/workflows/docker-image.yml@v1` |
| `deploy` | nur push auf `main` | `uses: sascha-gruesshaber/ci/.github/workflows/coolify-deploy.yml@v1` |
| `automerge` | nur Dependabot-PRs | `uses: sascha-gruesshaber/ci/.github/workflows/dependabot-automerge.yml@v1` |

Weitere Regeln:

- Jeder Job hat `timeout-minutes`.
- Node 24, `actions/setup-node` mit Paketmanager-Cache.
- Actions auf ihrer aktuellen Hauptversion. Dependabot hält sie aktuell.
- Keine Tag-Trigger (`v*`), keine Releases, keine zweite Umgebung.

### Images

| | Name | Tags |
|---|---|---|
| Projekt mit einer App | `ghcr.io/<owner>/<repo>` | `main`, `sha-<12 Zeichen>` |
| Projekt mit mehreren Apps | `ghcr.io/<owner>/<repo>/<app>` | `main`, `sha-<12 Zeichen>` |

Coolify folgt immer dem Tag `main`. Gebaut wird für `linux/amd64`, ohne Provenance-Attestierung
(ein schlichtes Image, kein Index mit „unknown/unknown“). Jedes Image bekommt die Build-Argumente
`APP_REVISION` (volle Commit-SHA) und `APP_BUILT_AT` (ISO-Zeit, UTC) sowie die
OCI-Labels `org.opencontainers.image.revision`, `.created` und `.source`.

### Revision

Jede ausgelieferte App mit HTTP-Endpoint meldet, welcher Stand läuft. Dazu enthält ihr
Health-Endpoint (oder `/version`) im JSON-Body genau:

```json
"revision":"<volle 40-stellige Commit-SHA>"
```

Der Wert kommt aus `APP_REVISION`. Nur so kann `deploy` erkennen, dass wirklich der
neue Stand läuft und nicht der alte Container weiter antwortet. Für eine rein statische
App reicht eine beim Build erzeugte `/version.json` mit demselben Feld.

### Coolify

- Secret `COOLIFY_API_TOKEN` im Projekt-Repo.
- UUIDs der Coolify-*Anwendungen* als Repo-Variablen: `COOLIFY_UUID` bei einer App,
  `COOLIFY_UUID_<APP>` (Großbuchstaben, `-` wird `_`) bei mehreren.
- GitHub-Environment `production` mit der öffentlichen URL.

### Dependabot

`.github/dependabot.yml` nach der Vorlage in [`templates/dependabot.yml`](templates/dependabot.yml):
Paketmanager und `github-actions`, wöchentlich montags 05:00 Berliner Zeit, 7 Tage
Wartezeit nach einem Release, alle Minor- und Patch-Updates in einem PR, Hauptversionen
einzeln. Minor und Patch führt `automerge` nach grüner CI selbst zusammen, Hauptversionen
bleiben liegen, bis Sascha sie liest.

## Die Bausteine

Aufruf immer mit `@v1`. `v1` ist ein beweglicher Tag auf dem neuesten `v1.x.y`.
Inkompatible Änderungen gibt es nur als `v2`.

### `docker-image.yml`: Image bauen und pushen

```yaml
build:
  needs: [check, e2e]
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  permissions:
    contents: read
    packages: write
  uses: sascha-gruesshaber/ci/.github/workflows/docker-image.yml@v1
  with:
    image: ghcr.io/${{ github.repository }}   # ohne Tag
    # dockerfile: Dockerfile                  # Standard
    # context: .                              # Standard
    # target: api-runner                      # Multi-Stage-Target, optional
    # build-args: |                           # zusätzliche Build-Argumente, optional
    #   VITE_API_URL=https://api.example.org
    # smoke-test: ./scripts/smoke-test.sh     # optional, siehe unten
```

| Input | Pflicht | Standard | Bedeutung |
|---|---|---|---|
| `image` | ja | | Image-Name ohne Tag |
| `dockerfile` | | `Dockerfile` | Pfad zum Dockerfile, vom Repo-Wurzelverzeichnis aus (wie `docker build -f`), nicht vom `context` |
| `context` | | `.` | Build-Kontext |
| `target` | | leer | Multi-Stage-Target |
| `build-args` | | leer | weitere Build-Argumente, eins pro Zeile |
| `smoke-test` | | leer | Befehl, der nach dem Build gegen das Image läuft |

Output `image`: die gebaute Referenz mit `sha-…`-Tag.

`smoke-test` läuft im ausgecheckten Repo mit gesetzter Umgebungsvariable `IMAGE`, bevor
etwas gepusht wird. Schlägt er fehl, wird nichts gepusht.

Mehrere Apps: Den Job mit `strategy.matrix` aufrufen, eine Matrix-Zeile pro App.

### `coolify-deploy.yml`: ausliefern und prüfen

```yaml
deploy:
  needs: build
  uses: sascha-gruesshaber/ci/.github/workflows/coolify-deploy.yml@v1
  with:
    uuids: ${{ vars.COOLIFY_UUID }}
    revision-urls: https://example.org/version
    environment-url: https://example.org
  secrets:
    COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
```

| Input | Pflicht | Standard | Bedeutung |
|---|---|---|---|
| `uuids` | ja | | UUIDs der Coolify-Anwendungen, durch Leerzeichen oder Zeilen getrennt |
| `revision-urls` | | leer | URLs, deren Body `"revision":"<github.sha>"` enthalten muss |
| `urls` | | leer | URLs, die nur mit HTTP 2xx antworten müssen |
| `environment` | | `production` | GitHub-Environment |
| `environment-url` | | leer | URL, die GitHub am Environment anzeigt |
| `coolify-url` | | `https://coolify.gruesshaber.eu` | |
| `wait-minutes` | | `10` | wie lange auf die neue Revision gewartet wird, höchstens 55 (der Job hat 60 Minuten) |

Stößt jede Anwendung per `POST /api/v1/deploy?uuid=…&force=false` an. Lehnt Coolify ab,
wird der Lauf rot. Danach wird jede URL so lange abgefragt, bis sie die neue Revision
meldet bzw. antwortet. Es gibt keine feste Wartezeit. Läuft nach `wait-minutes` noch der
alte Stand, wird der Lauf rot.

Deployments eines Repos laufen nacheinander, und ein laufendes wird nie abgebrochen, weil
die Container beim Start migrieren. Kommen während eines Deployments mehrere neue dazu,
wartet nur das neueste; die dazwischen verfallen (so arbeitet GitHubs `concurrency`). Das
schadet nicht, denn alle liefern ohnehin den Tag `main` aus.

Eine leere `uuids`-Liste ist ein Fehler („Repo-Variable fehlt?“). Werden mehrere Variablen
zu einer Liste verbunden, fällt eine einzelne fehlende nicht auf, sie verschwindet im
Leerraum. Dann meldet höchstens die zugehörige `revision-url` die alte Revision.

Wichtig bei mehreren Apps mit Pfadfilter: In `revision-urls` gehören nur die Apps, die in
diesem Lauf auch gebaut wurden. Eine nicht neu gebaute App meldet zu Recht die alte
Revision.

### `dependabot-automerge.yml`: Aktualisierungen einspielen

```yaml
automerge:
  needs: [check, e2e]
  if: github.event_name == 'pull_request' && github.event.pull_request.user.login == 'dependabot[bot]'
  permissions:
    contents: write
    pull-requests: write
    actions: write
  uses: sascha-gruesshaber/ci/.github/workflows/dependabot-automerge.yml@v1
```

| Input | Pflicht | Standard | Bedeutung |
|---|---|---|---|
| `workflow` | | `ci.yml` | Workflow-Datei, die nach dem Merge auf `main` angestoßen wird |

Führt Minor- und Patch-Updates per Squash zusammen, Hauptversionen nicht. Danach startet
es `workflow` auf `main` per `workflow_dispatch`. Das ist nötig, weil ein Merge mit
`GITHUB_TOKEN` keinen Push-Workflow auslöst und die Aktualisierung sonst nie ausgeliefert
würde.

## Neue Version veröffentlichen

1. Änderung per PR nach `main`. Die CI prüft mit `actionlint` und lässt
   `test/coolify-deploy.test.sh` laufen, die Deploy-Logik gegen einen Dummy-Server. Lokal
   genauso: `bash test/coolify-deploy.test.sh`.
2. Auf `main` den Workflow `selftest` von Hand starten (`gh workflow run selftest.yml`).
   Er baut `test/Dockerfile` mit Rauchtest über `docker-image.yml`, pusht nach
   `ghcr.io/sascha-gruesshaber/ci/selftest` und prüft Tags und Labels in der Registry.
3. Ist er grün, einen neuen `v1.x.y`-Tag setzen und `v1` auf denselben Commit verschieben
   (`git push -f origin v1`).

## Zugriff

Das Repo ist öffentlich. Solange es privat war, kam Dependabot in den Projekten nicht an
seine Tags: Der `github-actions`-Lauf brach jede Woche mit `git_dependencies_not_reachable`
ab. Ein persönliches Konto (keine Organisation) hat keine Einstellung, die Dependabot den
Zugriff auf andere private Repos erlaubt.

Deshalb gehören hier keine Secrets, internen Adressen, Coolify-UUIDs oder anderen
projektspezifischen Werte hinein. Die bleiben als Secrets und Variablen in den Projekt-Repos.

Die Skripte stehen weiter direkt in den Workflows und nicht in eigenen Dateien. Sonst
müsste jeder Aufruf dieses Repo zusätzlich auschecken, und zwar auf genau dem Stand von `@v1`.
