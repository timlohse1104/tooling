# Plan: llama.cpp-Setup für Pop!_OS / Debian-based Linux

Adaption von [countzero/windows_llama.cpp@v1.34.0](https://github.com/countzero/windows_llama.cpp/tree/v1.34.0)
für Linux. Ziel: ein einfach zu bootstrappender, **config-getriebener** llama.cpp-Bereich,
der **nur bereits erzeugte GGUF-Dateien** lädt und serviert (kein Quantisieren/Konvertieren
eigener Gewichte). Modelle landen **außerhalb** des Repos und werden **nie** zu GitHub gepusht.

> Status: **Planungsdokument**. Es wird noch kein Code geschrieben. Die unten beschriebenen
> Skripte sind die geplanten Deliverables.

---

## 1. Entscheidungen (bereits getroffen)

| Thema | Entscheidung | Konsequenz |
|-------|--------------|------------|
| Compute-Backend | **Vulkan** | Vendor-neutral (NVIDIA/AMD/Intel), keine CUDA-Toolchain nötig |
| llama.cpp-Bezug | **Prebuilt Release-Binaries** | Kein Compiler, kein CMake, kein conda – nur Download + Entpacken |
| Lieferumfang jetzt | **Nur dieses Planungsdokument** | Implementierung folgt nach Review |

---

## 2. Was die Windows-Vorlage macht (und wie wir es übersetzen)

| Windows (PowerShell) | Zweck | Linux-Adaption |
|----------------------|-------|----------------|
| `rebuild_llama.cpp.ps1` | llama.cpp aus Quellen bauen (OpenBLAS/CUDA), conda-Python, CMake-Patch | `bootstrap.sh`: APT-Runtime-Deps + **prebuilt Vulkan-Tarball** herunterladen & entpacken. Kein Build, kein conda. |
| Git-Submodule `vendor/llama.cpp` | Quellcode pinnen | Entfällt. Stattdessen **Release-Tag** in `config.env` pinnen; Tarball wird geladen. |
| OpenBLAS-Fetch + `CMakeLists.txt`-Patch | CPU-BLAS unter Windows | Entfällt. Vulkan = GPU; CPU-Fallback ist im Binary enthalten. |
| conda-Env + `requirements.txt` | Python für `gguf-py` | Entfällt im Normalfall (siehe §6, Metadaten). Optionales venv nur falls GGUF-Introspektion gewünscht. |
| `examples/server.ps1` | GGUF-Metadaten lesen, GPU-Layer/ctx automatisch berechnen, `llama-server` starten | `server.sh`: schlanker. `-ngl 999` (alles offloaden, llama.cpp clamped), Thread-Autodetect, mmproj-Autodetect, Alias=Dateiname. Feintuning lebt im Preset-INI. |
| `presets/*.ini` | Multi-Modell-Router-Config | **1:1 übernommen** (gleiches INI-Format), nur Pfade Windows→Linux. Direkt kompatibel mit `--models-preset`. |
| `--models-dir` (extern) | Modell-Speicherort | `LLAMA_MODELS_DIR` **außerhalb** des Repos. |
| Manueller Browser-Download des GGUF | Modell beschaffen | **Neu:** `download-model.sh` + `models.list`-Manifest (HuggingFace, mit Resume). |
| `.gitignore` (nur Logs) | – | Root-`.gitignore` erweitern: `vendor/`, `cache/`, `config.env`, `*.gguf` ignorieren. |

Nicht portiert (außerhalb des Scopes „nur fertige GGUF nutzen"): `benchmark.ps1`,
`count_tokens.ps1`, `speculative_decoding.ps1`, `mtp-bench.py`, Perplexity/Quantisierung,
wikitext/Kalibrierungs-Datasets. Können später als Bonus folgen.

---

## 3. Geplante Verzeichnisstruktur

```
llama.cpp/
├── PLAN.md                  # dieses Dokument
├── README.md               # Benutzung (folgt)
├── bootstrap.sh            # APT-Deps + prebuilt Vulkan-Binary holen      [committed]
├── download-model.sh       # GGUF(s) von HuggingFace in externen Dir laden [committed]
├── server.sh               # Einzelmodell ODER Router via Preset starten   [committed]
├── config.env.example      # zentrale Pfade/Version (Vorlage)             [committed]
├── config.env              # echte lokale Werte                           [GITIGNORED]
├── models.list             # HF-Download-Manifest                         [committed]
├── presets/
│   └── models.example.ini  # Router-Preset (Linux-Pfade)                  [committed]
├── vendor/                 # entpackte llama.cpp-Binaries                 [GITIGNORED]
│   └── llama.cpp/build/bin/{llama-server,llama-cli,*.so}
└── cache/                  # Prompt-Caches o.ä.                           [GITIGNORED]
```

**Modelle liegen NICHT hier**, sondern unter `LLAMA_MODELS_DIR`
(Default `~/.local/share/llama.cpp/models`, also außerhalb des Repos).

---

## 4. Konfiguration (`config.env`)

Eine zentrale, gut dokumentierte Env-Datei (committed als `.example`, real als gitignored
`config.env`). Wird von allen Skripten gesourced.

```sh
# llama.cpp Release-Tag oder "latest"
LLAMA_VERSION=b9827
LLAMA_BACKEND=vulkan

# Repo-interner Skript-/Binary-Bereich
LLAMA_DIR="$HOME/Programming/tooling/llama.cpp"

# Modell-Speicher AUSSERHALB des Repos (wird nie committet)
LLAMA_MODELS_DIR="$HOME/.local/share/llama.cpp/models"

# Server
LLAMA_HOST=127.0.0.1
LLAMA_PORT=8081                     # passt zur opencode.jsonc baseURL
LLAMA_PRESET="presets/models.ini"
LLAMA_MODELS_MAX=1

# Optional: nur für gated HF-Modelle
HF_TOKEN=
```

> **Cross-Referenz opencode:** `opencode-backup/opencode.jsonc` zeigt aktuell auf
> `http://172.30.48.1:8081/v1` (typische WSL→Windows-Host-Gateway-IP). Auf nativem
> Pop!_OS muss das auf `http://127.0.0.1:8081/v1` geändert werden. Port `8081` ist
> hier bewusst übernommen, damit die bestehende Modell-Liste weiter passt.

---

## 5. Modell-Konfiguration (Preset-INI, unverändertes Format)

Das INI-Format der Vorlage wird **beibehalten**, damit Router-Mode direkt funktioniert:
jede `[section]` = ein Modell, Keys = `llama-server`-Flags ohne `--`. Clients wählen das
Modell über den OpenAI-Feldwert `"model"` = Section-Header.

Beispiel `presets/models.example.ini` (Linux-Pfade, abgeleitet aus deiner bestehenden
`opencode.jsonc`-Modellliste):

```ini
[Qwen3.6-27B-IQ4_XS-mtp.gguf]
alias = Qwen3.6-27B-IQ4_XS-mtp.gguf
model = /home/USER/.local/share/llama.cpp/models/Qwen3.6-27B/Qwen3.6-27B-IQ4_XS-mtp.gguf
ctx-size = 172032
n-gpu-layers = 999
flash-attn = on
jinja = true
# Linux-Pfad (Forward-Slash!) – ersetzt vendor\...\chat_template.jinja
chat-template-file = /home/USER/.local/share/llama.cpp/templates/qwen_chat_template.jinja

[gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf]
alias = gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf
model = /home/USER/.local/share/llama.cpp/models/gemma-4-26B-A4B/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf
ctx-size = 81920
n-gpu-layers = 999
flash-attn = on
jinja = true
```

**Wichtige Pfad-Anpassungen Windows→Linux im INI:**
- `D:\AI\LLM\gguf\...` → `$LLAMA_MODELS_DIR/...` (absolute Linux-Pfade, Forward-Slash)
- `chat-template-file = vendor\Qwen-Fixed-Chat-Templates\...` → Forward-Slash + reale Datei
  (das Submodul gibt es hier nicht; die Jinja-Datei wird optional per `download-model.sh`
  geladen, siehe §7).
- VRAM-spezifische Tuning-Keys (`n-cpu-moe`, `cache-type-k/v`, `spec-type`, …) bleiben
  optional und werden vom Vulkan-`llama-server` genauso akzeptiert.

---

## 6. `bootstrap.sh` (ersetzt `rebuild_llama.cpp.ps1`)

Ablauf:
1. `set -euo pipefail`, `config.env` sourcen.
2. **APT-Runtime-Deps** (mit `sudo`, idempotent):
   `curl ca-certificates tar jq libvulkan1 mesa-vulkan-drivers vulkan-tools libgomp1 libcurl4`
   - `mesa-vulkan-drivers` deckt AMD/Intel ab; bei NVIDIA liefert der proprietäre Treiber
     den Vulkan-ICD (auf Pop!_OS i.d.R. vorinstalliert). Installation schadet nicht.
   - `vulkan-tools` → `vulkaninfo` zur Verifikation.
3. **Version auflösen:** wenn `LLAMA_VERSION=latest`, via GitHub-API
   `https://api.github.com/repos/ggml-org/llama.cpp/releases/latest` das `tag_name`
   (mit `jq`) ziehen; sonst Tag direkt nutzen.
4. **Asset-URL** bauen (verifiziertes Namensschema):
   ```
   https://github.com/ggml-org/llama.cpp/releases/download/<TAG>/llama-<TAG>-bin-ubuntu-vulkan-x64.tar.gz
   ```
   (z.B. `b9827` → `llama-b9827-bin-ubuntu-vulkan-x64.tar.gz`, ~31 MB).
5. Nach `cache/` herunterladen (`curl -L --fail -C -`), nach `vendor/llama.cpp/` entpacken
   (Tarball enthält `build/bin/` mit `llama-server`, `llama-cli`, `*.so`; rpath `$ORIGIN`,
   d.h. Binaries finden ihre Libs relativ).
6. **Verifikation:** `vendor/.../llama-server --version` und `vulkaninfo --summary`
   (GPU sichtbar?) ausführen; Klartext-Status ausgeben.
7. Idempotent: bereits installierte, passende Version überspringen (Tag-Marker in `vendor/`).

**Risiko/Caveat (im README dokumentieren):** Die Ubuntu-Prebuilts werden gegen eine
bestimmte Ubuntu-glibc gebaut. Pop!_OS = Ubuntu-LTS-Basis → i.d.R. kompatibel. Falls
`GLIBC_x.xx not found`: entweder neuere Pop!_OS-Basis oder Fallback „aus Quellen bauen"
(als zukünftige Option vermerkt, jetzt bewusst nicht implementiert).

---

## 7. `download-model.sh` (neu – HuggingFace-Loader)

Lädt **fertige GGUF** nach `$LLAMA_MODELS_DIR` (außerhalb Repo). Zwei Modi:

- **Ad-hoc:** `./download-model.sh <repo_id> <filename> [dest_subdir]`
- **Manifest:** `./download-model.sh --all` liest `models.list` und lädt fehlende Dateien.

Mechanik:
- Bevorzugt `hf` CLI (`huggingface_hub`, falls vorhanden): Resume, Auth/gated via `HF_TOKEN`,
  optional schneller via `hf_transfer`.
- Fallback ohne Python: `curl -L --fail -C - -o <ziel>` gegen
  `https://huggingface.co/<repo_id>/resolve/main/<filename>`.
- Skip, wenn Datei existiert und Größe > 0 (optional sha256-Spalte im Manifest prüfen).
- Legt `dest_subdir` unter `$LLAMA_MODELS_DIR` an.

Manifest `models.list` (einfaches, greppbares Format):
```
# repo_id | filename | dest_subdir
bartowski/gemma-2-9b-it-GGUF | gemma-2-9b-it-IQ4_XS.gguf | gemma-2-9b-it
# Optional: Qwen Fixed Chat Template (für chat-template-file im Preset)
froggeric/Qwen-Fixed-Chat-Templates | chat_template.jinja | ../templates
```

> Gated/Private Modelle: `HF_TOKEN` in `config.env` setzen oder `hf auth login`.

---

## 8. `server.sh` (ersetzt `examples/server.ps1`)

Bewusst schlanker als die PowerShell-Variante (deren VRAM-Mathematik beruht auf
`nvidia-smi`, was unter Vulkan/AMD/Intel nicht trägt). Stattdessen:

- **Router-Mode (Default, multi-model):**
  ```
  llama-server --host $LLAMA_HOST --port $LLAMA_PORT \
    --models-dir "$LLAMA_MODELS_DIR" \
    --models-preset "$LLAMA_PRESET" \
    --models-max "$LLAMA_MODELS_MAX"
  ```
- **Einzelmodell-Mode:** `./server.sh /pfad/zu/model.gguf [--ctx-size N] [...]`
  - `-ngl 999` (alles offloaden; llama.cpp clamped auf max. Layer; CPU-Fallback automatisch)
  - Threads = **physische Kerne** (via `lscpu`: `Core(s) per socket` × `Socket(s)`; Fallback `nproc`)
  - `--alias <Dateiname>` (Pfad nicht leaken, wie in der Vorlage)
  - mmproj-Autodetect: `mmproj.*` neben der Modelldatei → `--mmproj`
  - KV-Cache-Typ default `f16`, überschreibbar
  - `LD_LIBRARY_PATH` auf `build/bin` setzen, falls rpath nicht greift
- Ohne Argument: vorhandene `*.gguf` unter `$LLAMA_MODELS_DIR` auflisten (wie die Vorlage).

Heavy-Tuning (`n-cpu-moe`, `spec-type`, `cache-type-*`, sampling) bleibt im **Preset-INI** –
das matcht deinen bestehenden Workflow und hält `server.sh` portabel.

---

## 9. Modelle aus dem Repo heraushalten

Root-`.gitignore` erweitern um:
```
llama.cpp/vendor/
llama.cpp/cache/
llama.cpp/config.env
llama.cpp/**/*.gguf
```
- `LLAMA_MODELS_DIR` liegt per Default **komplett außerhalb** des Repos → wird nie getrackt.
- `*.gguf`-Regel als zusätzlicher Schutz, falls jemand Modelle versehentlich im Repo ablegt.
- Nur Skripte, `*.example`-Vorlagen, `models.list` und `presets/*.ini` werden committet.

---

## 10. Integration in bestehende Tooling-Konventionen

- **`fresh_linux/debian-based/bootstrap-guide.md`:** neuen Schritt „llama.cpp" ergänzen
  (`cd ~/tooling/llama.cpp && cp config.env.example config.env && bash bootstrap.sh`).
- **`AGENTS.md`:** Abschnitt „llama.cpp" + Install-Tabellen-Zeile ergänzen.
- **`README.md` (root):** optional Link/Notiz.
- **`opencode.jsonc`:** `baseURL` auf `http://127.0.0.1:8081/v1` umstellen (siehe §4).
- Stil: bash + `printf`-Statusmeldungen, idempotent, analog zu `opencode-backup/install.sh`
  und `bashrc-backup/install.bash`.

---

## 11. Geplanter End-to-End-Ablauf (nach Implementierung)

```sh
cd ~/tooling/llama.cpp
cp config.env.example config.env      # Pfade/Port/Version anpassen
bash bootstrap.sh                     # Vulkan-Binary holen + verifizieren
bash download-model.sh --all          # GGUF(s) laut models.list nach $LLAMA_MODELS_DIR
cp presets/models.example.ini presets/models.ini   # Pfade eintragen
bash server.sh                        # Router auf 127.0.0.1:8081 starten
```

Danach: OpenAI-kompatibler Endpoint unter `http://127.0.0.1:8081/v1`, nutzbar durch
OpenCode/LM Studio etc.

---

## 12. Offene Punkte / Annahmen

1. **glibc-Kompatibilität** der Prebuilts auf der konkreten Pop!_OS-Version – beim ersten
   `bootstrap.sh`-Lauf verifizieren. Fallback „aus Quellen bauen" ist bewusst (noch) nicht Teil.
2. **`hf` CLI vs. reines `curl`** im Downloader – Plan deckt beides ab; Default = vorhandenes Tool.
3. **Chat-Template** für Qwen: nur nötig, wenn die GGUF-eingebetteten Templates Probleme machen;
   optional über `models.list` beziehbar.
4. **Architektur:** Plan zielt auf `x64`. Für ARM64 gäbe es `...-ubuntu-vulkan-arm64.tar.gz`
   (analog, nur anderes Asset).

---

## 13. Nächster Schritt

Nach deinem „Go": Implementierung der Skripte aus §3 (`bootstrap.sh`, `download-model.sh`,
`server.sh`), der Vorlagen (`config.env.example`, `models.list`, `presets/models.example.ini`),
des `README.md` sowie der `.gitignore`- und Doku-Ergänzungen.
