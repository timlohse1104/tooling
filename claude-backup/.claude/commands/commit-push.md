Führe einen vollständigen Commit-und-Push-Workflow durch. Falls `$ARGUMENTS` übergeben wurde, verwende es als Commit-Nachricht. Andernfalls leite eine kurze Nachricht (max. 1 Satz) aus den Änderungen ab.

## Schritte

### 1. Status analysieren
Führe folgende Befehle parallel aus:
- `git status` — zeigt untracked und geänderte Dateien
- `git diff` — zeigt staged und unstaged Änderungen
- `git log --oneline -5` — zeigt die letzten 5 Commits für Stil-Konsistenz

### 2. Feature Branch erstellen
Leite aus den Änderungen einen kurzen Branch-Namen ab (Format: `feature/<kebab-case-beschreibung>`).
- Erstelle den Branch von `main`: `git checkout -b feature/<name>`
- Der Branch-Name soll die Änderungen knapp beschreiben, z.B. `feature/memorandum-skeleton-loading`

### 3. Qualitätschecks (Frontend & Backend)
Führe **parallel** aus:
- `cd frontend && npm run build` — Frontend-Build
- `cd backend && npm run build` — Backend-Build

Führe danach **parallel** aus:
- `cd frontend && nx run-many -t lint` — Frontend-Lint
- `cd backend && nx run-many -t lint` — Backend-Lint

Führe danach **parallel** aus:
- `cd frontend && nx run-many -t test` — Frontend-Tests
- `cd backend && nx run-many -t test` — Backend-Tests

**Bei jedem Fehler in Build, Lint oder Tests: Sofort abbrechen, zurück zu `main` wechseln (`git checkout main`) und den Fehler dem User melden. Keinen Commit erstellen.**

### 4. CHANGELOG.md prüfen und aktualisieren
Prüfe, ob CHANGELOG.md bereits geändert wurde (`git status`). Falls **nicht**:
- Analysiere die Änderungen und erstelle passende Einträge unter `## [Unreleased]`
- Nutze das bestehende Format: `### Added / Changed / Fixed / Removed` mit `[modul]`-Prefix
- Beispiel: `- [memorandum] Neue Funktion XY hinzugefügt.`

Falls CHANGELOG.md bereits geändert wurde: Prüfe, ob die aktuellen Änderungen darin bereits vollständig abgedeckt sind. Falls nicht, ergänze fehlende Einträge.

### 5. Dateien stagen
Stage alle relevanten Dateien **gezielt per Name** (kein `git add -A` oder `git add .`):
- Starte mit allen geänderten Dateien aus `git status`
- Stage immer auch CHANGELOG.md mit
- Vermeide versehentliches Stagen von: `.env`, Credential-Dateien, Binaries, `node_modules/`

### 6. Commit erstellen
- Falls `$ARGUMENTS` übergeben: verwende exakt diesen Text als Commit-Nachricht
- Sonst: leite einen prägnanten Satz aus den Änderungen ab (Imperativ, Englisch, max. 1 Satz)
- **Kein Gitmoji** in der Nachricht — der Post-Commit Hook fügt es automatisch hinzu
- Erstelle den Commit im HEREDOC-Format mit Co-Authored-By-Zeile:

```
git commit -m "$(cat <<'EOF'
Commit-Nachricht hier.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

### 7. Push
- Branch hat noch kein Upstream-Tracking → immer: `git push -u origin <branch-name>`

### 8. Bestätigung
- Führe `git status` aus
- Gib eine kurze Zusammenfassung aus: Commit-Hash, Nachricht, gepushter Branch

## Wichtige Regeln

- **Niemals** `.env`, Credential-Dateien oder Secrets committen
- **Kein** `--no-verify` oder `--force`
- **Kein** `git add -A` oder `git add .`
- **Kein Commit bei fehlgeschlagenem Build, Lint oder Test** — Fehler melden und abbrechen
- Bei Pre-Commit-Hook-Fehler: Problem beheben, dann **neuen** Commit erstellen (kein `--amend`)
- Commit-Nachricht: **maximal 1 Satz**, Imperativ, Englisch
- Immer CHANGELOG.md mit aktualisieren und auf Vollständigkeit prüfen
