---
name: commit-push
description: Führt einen vollständigen Commit-und-Push-Workflow durch. Auslösen bei Anfragen wie "committe meine Änderungen", "push das", "erstelle einen Commit" oder dem Befehl /commit-push.
disable-model-invocation: true
---

Führe einen vollständigen Commit-und-Push-Workflow durch. Falls `$ARGUMENTS` übergeben wurde, verwende es als Commit-Nachricht. Andernfalls leite eine kurze Nachricht (max. 1 Satz, Englisch, Imperativ) aus den Änderungen ab.

## Schritte

### 1. Status analysieren
Führe folgende Befehle parallel aus:
- `git status` — zeigt untracked und geänderte Dateien
- `git diff` — zeigt staged und unstaged Änderungen
- `git log --oneline -5` — zeigt die letzten 5 Commits für Stil-Konsistenz

### 2. Dateien stagen
Stage alle relevanten Dateien **gezielt per Name** (kein `git add -A` oder `git add .`):
- Starte mit allen geänderten Dateien aus `git status`
- Falls `Agents.md` im Repository existiert: Stage diese immer mit
- Vermeide versehentliches Stagen von: `.env`, Credential-Dateien, Binaries, `node_modules/`

### 3. Agents.md aktualisieren
**Nur wenn `Agents.md` im Repository existiert:**
- Lese `Agents.md` und prüfe, ob Commit-Nachrichten-Regeln, Gitmoji-Usage oder andere relevante Anweisungen den aktuellen Änderungen entsprechen.
- Falls veraltet: Aktualisiere gezielt die betroffenen Abschnitte.
- Falls alles aktuell: keine Änderung.

### 4. Commit erstellen
- Wähle einen passenden [Gitmoji](https://gitmoji.carloscuesta.dev/) basierend auf der Änderung:
  - `🔧` fix — Bugfix
  - `✨` feat — neues Feature
  - `📝` docs — Dokumentation
  - `♻️` refactor — Refactoring
  - `🧹` chore — Housekeeping, Config
  - `🔒` security — Security-Änderung
  - `🚀` ci — CI/CD
- Füge den Gitmoji **am Anfang** der Commit-Nachricht hinzu
- Falls `$ARGUMENTS` übergeben: verwende exakt diesen Text (mit Gitmoji vorangestellt)
- Sonst: leite einen prägnanten Satz aus den Änderungen ab

```
git commit -m "$(cat <<'EOF'
🔧 Commit-Nachricht hier.
EOF
)"
```

### 5. Push
- Branch hat noch kein Upstream-Tracking → immer: `git push -u origin <branch-name>`
- Sonst: `git push`

### 6. Bestätigung
- Führe `git status` aus
- Gib eine kurze Zusammenfassung aus: Commit-Hash, Nachricht, gepushter Branch

## Wichtige Regeln

- **Niemals** `.env`, Credential-Dateien oder Secrets committen
- **Kein** `--no-verify` oder `--force`
- **Kein** `git add -A` oder `git add .`
- Bei Pre-Commit-Hook-Fehler: Problem beheben, dann **neuen** Commit erstellen (kein `--amend`)
- Commit-Nachricht: **maximal 1 Satz**, Imperativ, **Englisch**, mit Gitmoji am Anfang
- Immer `Agents.md` prüfen und ggf. mitstagen
