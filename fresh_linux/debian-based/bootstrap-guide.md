# Bootstrap Guide – Fresh Linux (Debian-based)

A step-by-step checklist for setting up a new system from scratch.

---

## 1. System

- [ ] Distro installieren
- [ ] System updaten: `sudo apt update && sudo apt upgrade -y`
- [ ] Basis-Tools installieren: `sudo apt install -y curl git wget unzip`

---

## 2. Passwortverwaltung

- [ ] [Bitwarden](https://bitwarden.com/download/) laden und installieren
- [ ] Mit Yubikey anmelden

---

## 3. Browser – Vivaldi

- [ ] [Vivaldi](https://vivaldi.com/de/download/) laden und installieren
- [ ] Anmelden & Einstellungen synchronisieren
- [ ] Email-Account verbinden
- [ ] Browser einrichten (Paneel, Tabs, Erweiterungen, ...)

---

## 4. Editor – Visual Studio Code

- [ ] [VS Code](https://code.visualstudio.com/download) laden und installieren
- [ ] Mit GitHub anmelden
- [ ] Einstellungen synchronisieren (Settings Sync)

---

## 5. SSH & GitHub

- [ ] SSH Key anlegen ([Anleitung](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent))
  ```bash
  ssh-keygen -t ed25519 -C "your_email@example.com"
  eval "$(ssh-agent -s)"
  ssh-add ~/.ssh/id_ed25519
  ```
- [ ] Public Key in GitHub hinterlegen (Settings → SSH Keys)
- [ ] Tooling-Repo clonen:
  ```bash
  git clone git@github.com:timlohse1104/tooling.git ~/tooling
  ```
- [ ] Bashrc-Setup ausführen:
  ```bash
  bash ~/tooling/bashrc-backup/install.bash
  ```

---

## 6. Claude Code

- [ ] [Claude Code](https://claude.ai/code) installieren: `npm install -g @anthropic-ai/claude-code`
- [ ] Anmelden: `claude`
- [ ] Bashrc-Setup ausführen:
  ```bash
  bash ~/tooling/claude-backup/install.sh
  ```

---

## 7. OpenCode

- [ ] OpenCode installieren:
  ```bash
  bash ~/tooling/opencode-backup/install.sh
  ```
- [ ] MCPs authentifizieren

---

## 8. Gaming – Steam

- [ ] [Steam](https://store.steampowered.com/about/) laden und installieren
- [ ] Anmelden
- [ ] Einstellungen anpassen (Sprache, Socials, Downloads, ...)

---

## 9. Weitere Schritte

> Platzhalter für zusätzliche Einrichtungsschritte.

- [ ] tbd

---

## Notizen

<!-- Hier können gerätespezifische Hinweise oder Abweichungen notiert werden -->
