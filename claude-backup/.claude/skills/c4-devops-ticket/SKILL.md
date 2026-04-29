---
name: c4-devops-ticket
description: Interaktive Jira-Ticket-Erstellung für das DO-Projekt mit geführtem Frage-Antwort-Prozess. Triggert bei: "Jira Ticket erstellen", "neues Ticket", "Ticket anlegen", "Bug melden", "Bug erfassen", "Task erstellen", "/c4-devops-ticket". Erstellt strukturierte Task- oder Bug-Tickets mit Templates und Sprint-Zuweisung. Approver wird automatisch gesetzt basierend auf dem aktuellen Nutzer.
---

Du führst den Benutzer interaktiv durch die Erstellung eines Jira-Tickets im **DO**-Projekt. Titel, Beschreibung und Akzeptanzkriterien werden **von dir generiert** – nicht vom Benutzer eingegeben. Verwende `AskUserQuestion` für alle strukturierten Eingaben.

---

## Schritt 0: Nutzer-Identifikation

Lies die Nutzer-Identität **automatisch** aus der lokalen Git-Konfiguration – frage den Nutzer **nicht** danach:

```bash
git config user.name
# alternativ: git config user.email
```

Mappe das Ergebnis (case-insensitive):
- Name/E-Mail enthält `Tim`, `Köster`, `tilloh` oder `timlohse` → Nutzer = **Tim Köster**
- Name/E-Mail enthält `Felix`, `Gebhard`, `fgunited` → Nutzer = **Felix Gebhard**
- Kein Match → frage einmalig per `AskUserQuestion` nach (Fallback):
  - Tim Köster
  - Felix Gebhard

Leite daraus den Approver ab:
- Nutzer = **Tim Köster** → Approver = **Felix Gebhard**
- Nutzer = **Felix Gebhard** → Approver = **Tim Köster**

Der Approver wird **nicht abgefragt** – er ergibt sich automatisch aus der Git-Identität.

---

## Schritt 1: Grobe Beschreibung & Ticket-Typ

Frage den Benutzer nach einer groben Zusammenfassung und dem Typ:

```
AskUserQuestion:
- "Was soll das Ticket beinhalten? (grobe Zusammenfassung)"
  → Freitext via "Sonstiges"
- "Welchen Ticket-Typ möchtest du erstellen?"
  → Task | Bug
```

---

## Schritt 2: Verständnisfragen (iterativ)

Analysiere die Zusammenfassung und stelle gezielte Verständnisfragen, bis das Feature / der Defekt **ganzheitlich geklärt** ist. Frage **maximal 3 Fragen pro Runde**, nutze `AskUserQuestion` mit sinnvollen Optionen wo möglich.

Typische Aspekte, die geklärt sein müssen:
- **Betroffene Komponente / Microservice** (z.B. address-book, invoices, frontend)
- **Auslöser / Kontext** (Wer braucht das? Warum jetzt?)
- **Abgrenzung** (Was ist explizit NICHT Teil des Tickets?)
- **Technische Details** (API, UI, Datenbank, Infrastruktur?)
- **Bei Bug**: Reproduzierbarkeit, Umgebung, betroffene Nutzer

Wiederhole Verständnisfragen, bis du sicher genug bist, ein vollständiges, testbares Ticket zu formulieren.

---

## Schritt 3: Akzeptanzkriterien generieren & bestätigen

Generiere auf Basis der gesammelten Informationen:
- **Titel** (prägnant, max. 80 Zeichen)
- **Beschreibung** nach Template (siehe unten)
- **Akzeptanzkriterien** (konkret, testbar, vollständig)

Zeige **nur die Akzeptanzkriterien** zur Bestätigung:

```
Ich habe folgende Akzeptanzkriterien formuliert:

- [AK 1]
- [AK 2]
- ...

Stimmst du diesen Akzeptanzkriterien zu, oder soll ich etwas anpassen?
```

Nutze `AskUserQuestion`:
- `Ja, Akzeptanzkriterien bestätigt` → weiter mit Schritt 4
- `Anpassen` → Benutzer erklärt was fehlt/falsch ist → Akzeptanzkriterien neu generieren → erneut fragen

**Das Ticket kann erst nach Bestätigung der Akzeptanzkriterien weitergeführt werden.**

---

## Schritt 4: Ticket-Felder erfassen

Frage die Felder in **zwei Runden** ab (je max. 4 Fragen):

### Runde 1:
```
AskUserQuestion (bis zu 3 gleichzeitig):
1. Sprint → Default: Aktueller Sprint | Option: anderen Sprint eingeben
2. Zugewiesene / Zuständige Person → Default: Tim Köster | andere Person eingeben
3. Komponenten → Default: Infrastruktur | Optionen: Backend, Frontend, Infrastruktur, Datenpipeline, Testing
```

*(Approver wird **nicht** abgefragt – er ist bereits aus Schritt 0 bekannt)*

### Runde 2:
```
AskUserQuestion (bis zu 2 gleichzeitig):
1. Übergeordnet (Epic/Parent) → Freitext (Issue-Key z.B. DO-123) | "Kein übergeordnetes Ticket"
2. Verknüpfte Vorgänge → Freitext (Issue-Keys kommagetrennt, z.B. DO-456, DO-789) | "Keine"
```

---

## Schritt 5: Ticket-Vorschau & Erstellen

Zeige die vollständige Vorschau als Text-Output:

### Vorschau Task:
```
📋 TICKET-VORSCHAU (Task)
─────────────────────────────────────
Projekt:    DO
Typ:        Task
Titel:      [Titel]
Sprint:     [Sprint]
Komponente: [Komponente]
Approver:   [Automatisch gesetzt: Felix Gebhard ODER Tim Köster]
Übergeordnet:[Parent-Key oder –]
Verknüpft:  [Linked Issues oder –]
Zugewiesen: [Person]
Zuständig:  [Person]

BESCHREIBUNG
─────────────────────────────────────
Aufgabe
[Beschreibung]

Akzeptanzkriterien
[Akzeptanzkriterien]

Arbeitsschritte
- [ ] Akzeptanzkriterien umsetzen
- [ ] Unit Tests schreiben / aktualisieren
- [ ] Changelog aktualisieren
- [ ] "Voraussetzungen zum Testen" ausfüllen

Voraussetzung zum Testen
Umgebung: staging
Was ist zu Testen: …

Zusätzlicher Kontext
[Weitere relevante Informationen]
```

### Vorschau Bug:
```
🐛 TICKET-VORSCHAU (Bug)
─────────────────────────────────────
Projekt:    DO
Typ:        Bug
Titel:      [Titel]
Sprint:     [Sprint]
Severity:   [Severity]
Komponente: [Komponente]
Approver:   [Automatisch gesetzt: Felix Gebhard ODER Tim Köster]
Übergeordnet:[Parent-Key oder –]
Verknüpft:  [Linked Issues oder –]
Zugewiesen: [Person]
Zuständig:  [Person]

BESCHREIBUNG
─────────────────────────────────────
Beschreibung des Defekts
[Fehlerbeschreibung]

Benötigte Daten
Uhrzeit:
URL:
Benutzer:
Umgebung:

Schritte zum Reproduzieren
[Schritte]

Erwartetes Verhalten
[Erwartetes Verhalten]

Screenshots
[Falls vorhanden]

Arbeitsschritte
- [ ] Bug in der lokalen Entwicklungsumgebung nachstellen
- [ ] Erwartetes Verhalten umsetzen
- [ ] Unit Tests schreiben / aktualisieren
- [ ] Changelog aktualisieren
- [ ] "Voraussetzungen zum Testen" ausfüllen

Voraussetzung zum Testen
Umgebung: staging
Was ist zu Testen: …

Zusätzlicher Kontext
[Weitere relevante Informationen]
```

Danach fragen:
```
AskUserQuestion: "Soll ich das Ticket so anlegen?"
- Ja, Ticket erstellen
- Titel anpassen
- Beschreibung anpassen
- Abbrechen
```

---

## Ticket erstellen

Bei Bestätigung folgende Schritte **in dieser Reihenfolge**:

### 1. Sprint-ID ermitteln
```
mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql
JQL: project = DO AND sprint in openSprints() ORDER BY created DESC
→ Extrahiere Sprint-ID aus dem ersten Ergebnis
```

### 2. Account-IDs ermitteln
```
mcp__claude_ai_Atlassian__lookupJiraAccountId
→ Suche nach "Tim Köster" oder der angegebenen zuständigen Person

mcp__claude_ai_Atlassian__lookupJiraAccountId
→ Suche nach dem Approver (Felix Gebhard ODER Tim Köster, je nach Schritt 0)
```

### 3. Ticket erstellen
```
mcp__claude_ai_Atlassian__createJiraIssue
- projectKey: DO
- issueType: Task oder Bug
- summary: [Titel]
- description: Vollständiger Ticket-Text im ADF-Format
- sprint: [Sprint-ID]
- assignee: [Account-ID]
- components: [Komponente]
```

### 4. Optionale Nachbearbeitung
- **Approver immer setzen**: via `mcp__claude_ai_Atlassian__editJiraIssue` als Custom Field setzen (Account-ID aus Schritt 2)
- Falls **Übergeordnet** angegeben: via `mcp__claude_ai_Atlassian__editJiraIssue` Parent setzen
- Falls **Verknüpfte Vorgänge** angegeben: via `mcp__claude_ai_Atlassian__createIssueLink` Verlinkungen erstellen

### 5. Bestätigung ausgeben
```
✅ Ticket [DO-XXXX] wurde erstellt!
Titel:    [Titel]
Sprint:   [Sprint]
Approver: [Felix Gebhard / Tim Köster]
Link:     [Jira-URL]
```

---

## Regeln

- Alle Tickets werden auf **Deutsch** erstellt
- Projekt ist immer **DO**
- **Keine Ticket-Erstellung ohne Bestätigung der Akzeptanzkriterien** (Schritt 3)
- **Approver wird immer automatisch gesetzt** – nie abfragen
  - Nutzer = Tim Köster → Approver = Felix Gebhard
  - Nutzer = Felix Gebhard → Approver = Tim Köster
- Bei Anpassungswunsch: Zurück zum entsprechenden Schritt, dann erneut Preview zeigen
- Bei Abbruch: Freundlich bestätigen, kein Ticket erstellen
- Default Zugewiesene / Zuständige Person: **Tim Köster**
