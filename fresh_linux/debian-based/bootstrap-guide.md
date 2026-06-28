# Bootstrap Guide – Fresh Linux (Debian-based)

A step-by-step checklist for setting up a new system from scratch.

---

## 1. System

- [ ] Distro installieren
- [ ] System updaten: `sudo apt update && sudo apt upgrade -y`
- [ ] Basis-Tools installieren: `sudo apt install -y curl git wget unzip`
- [ ] Terminal: Copy & Paste auf `Strg + C` / `Strg + V` einstellen (Terminaleinstellungen → Tastenkombinationen)

---

## 2. Passwortverwaltung

- [ ] [Bitwarden](https://bitwarden.com/download/) laden und installieren
- [ ] Mit Yubikey anmelden

---

## 3. Browser – Vivaldi

- [ ] [Vivaldi](https://vivaldi.com/de/download/) laden und installieren
- [ ] Anmelden & Einstellungen synchronisieren
- [ ] Email-Account verbinden
- [ ] Paneel einrichten – nur folgende Apps in dieser Reihenfolge (von oben nach unten):
  1. Downloads
  2. Verlauf
  3. Mail
  4. Übersetzen
- [ ] Tabs & Erweiterungen einrichten

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

## 7. Node.js (via nvm)

- [ ] nvm installieren: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash`
- [ ] Terminal neu starten (oder nvm manuell sourcen), dann Node LTS installieren: `nvm install --lts`
- [ ] `node`/`npx` in System-PATH verlinken (damit OpenCode sie ohne Shell-Integration findet):
  ```bash
  ln -sf ~/.nvm/versions/node/$(node --version)/bin/node ~/.local/bin/node
  ln -sf ~/.nvm/versions/node/$(node --version)/bin/npx ~/.local/bin/npx
  ```
- [ ] Playwright Chromium installieren: `npx @playwright/mcp@latest install-browser chromium`

---

## 8. OpenCode

- [ ] OpenCode installieren:
  ```bash
  bash ~/tooling/opencode-backup/install.sh
  ```
- [ ] MCPs authentifizieren

---

## 9. Gaming – Steam

- [ ] [Steam](https://store.steampowered.com/about/) laden und installieren
- [ ] Anmelden
- [ ] Einstellungen anpassen (Sprache, Socials, Downloads, ...)

---

## 10. Docker Engine

- [ ] Docker Engine installieren ([Anleitung](https://docs.docker.com/engine/install/debian/#install-using-the-repository))
- [ ] User zur `docker`-Gruppe hinzufügen: `sudo usermod -aG docker $USER && newgrp docker`
- [ ] Installation prüfen: `docker run hello-world`

---

## 11. llama.cpp – lokale LLM-Inferenz (Vulkan, optional)

- [ ] Setup ausführen (prebuilt Vulkan-Binary, kein Compiler nötig):
  ```bash
  cd ~/tooling/llama.cpp
  cp config.env.example config.env      # Version/Port/Pfade anpassen
  bash bootstrap.sh                     # lädt + verifiziert llama.cpp (Vulkan)
  ```
- [ ] Modell(e) laden (Manifest `models.list` editieren, dann):
  ```bash
  bash download-model.sh --all          # nach $LLAMA_MODELS_DIR (außerhalb Repo)
  ```
- [ ] Router-Preset anlegen und starten:
  ```bash
  cp presets/models.example.ini presets/models.ini
  sed -i "s|/home/USER|$HOME|g" presets/models.ini
  bash server.sh                        # http://127.0.0.1:8081
  ```
- [ ] In `~/.config/opencode/opencode.jsonc` die `llama.cpp`-`baseURL` auf
  `http://127.0.0.1:8081/v1` setzen (statt `172.30.48.1`).

---

## 12. Weitere Schritte

> Platzhalter für zusätzliche Einrichtungsschritte.

- [ ] tbd

---

## Notizen

<!-- Hier können gerätespezifische Hinweise oder Abweichungen notiert werden -->
