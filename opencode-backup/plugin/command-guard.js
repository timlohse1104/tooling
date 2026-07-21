// ============================================================
// command-guard.js — generic, configurable protection layer for OpenCode's
// bash tool.
//
// This is the *generalisation* of the C4 `prod-guard.js` idea: instead of
// hard-coding one cluster check, it loads a rule set from
// `command-guard.rules.json` (next to this file, overridable via the
// COMMAND_GUARD_RULES env var) and blocks / warns / prompts based on it.
//
// WHY THIS EXISTS
// ---------------
// OpenCode's built-in bash permission matcher (and Claude Code's, for that
// matter) matches the *raw* command string against glob patterns. As the
// wren.wtf "Stop Using OpenCode" post demonstrates, that is trivially bypassed:
//
//     env git push --force            # prefixed with `env`
//     /usr/bin/git reset --hard        # absolute path
//     $(which git) clean -fdx .        # command substitution
//     GIT=git && $GIT push -f          # variable indirection
//     echo cm0gLXJmIC8K | base64 -d | bash   # base64 -> bash
//     bash -c 'git reset --hard'       # nested shell
//     python3 -c 'import subprocess; subprocess.run(["rm","-rf","/"])'
//
// A string glob like `"git push --force*": "deny"` catches NONE of these.
//
// command-guard defends against this class of bypass by NORMALISING the command
// (stripping wrappers, decoding base64, resolving `$(which x)`/absolute paths to
// bare verbs, expanding trivial `VAR=git` indirection) and RECURSIVELY splitting
// it into its constituent simple commands (across pipes, `&&`, `;`, subshells,
// here-docs, and `-c '...'` payloads of bash/sh/python/node/perl/ruby) BEFORE
// matching. Every extracted fragment is checked against the rules.
//
// It is NOT a sandbox. A sufficiently creative model can still defeat any
// in-process text analysis (that is the whole point of the wren.wtf post — real
// enforcement belongs in the OS: Landlock / bubblewrap / seccomp / read-only
// mounts). Treat this as a strong *seatbelt* that turns the common, accidental,
// and lazily-obfuscated footguns into hard errors — not as a security boundary.
//
// RULE FILE FORMAT (command-guard.rules.json)
// -------------------------------------------
//   {
//     "enabled": true,
//     // If true, a rule payload we cannot confidently decode (e.g. base64 that
//     // isn't valid utf-8, or an unreadable here-doc) is treated as suspicious
//     // and, for "deny" categories, blocked. Recommended: true.
//     "failClosed": true,
//     "rules": [
//       {
//         "id": "git-history-rewrite",
//         "action": "deny",                 // "deny" | "ask" | "warn"
//         "message": "History-rewrite/force ops are blocked.",
//         // A fragment matches if ANY `patterns` regex matches AND (if given)
//         // NONE of `unless` regexes match. Patterns are case-insensitive,
//         // matched against the normalised fragment.
//         "patterns": ["\\bgit\\b.*\\bpush\\b.*(--force|-f)\\b"],
//         "unless": ["--force-with-lease"]
//       }
//     ]
//   }
//
// ACTIONS
//   deny  -> throw (hard block, aborts the tool call)
//   ask   -> not directly supported by the before-hook return value, so we
//            re-map it to a hard block WITH an explanatory message telling the
//            agent to get explicit human approval / run it manually. (The hook
//            API only lets us pass-through or throw; there is no "escalate to
//            prompt" here, and silently passing through would defeat the point.)
//            If you truly want an interactive prompt, express it as an OpenCode
//            `permission.bash` "ask" pattern instead — this plugin is for the
//            cases the string matcher cannot see.
//   warn  -> log to stderr and pass through (visibility without friction).
//
// The plugin is defensive: any internal error is logged and treated according
// to failClosed (block if we were mid-evaluating a deny candidate, else pass).
// A broken/missing rule file disables guarding (with a warning) rather than
// bricking every bash call.
// ============================================================

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------- rule loading -------------------------------------------------

function loadRules() {
  const path =
    process.env.COMMAND_GUARD_RULES ||
    resolve(__dirname, "command-guard.rules.json");
  try {
    const raw = readFileSync(path, "utf8");
    const cfg = JSON.parse(raw);
    if (cfg.enabled === false) return { enabled: false, rules: [], failClosed: true, path };
    const rules = Array.isArray(cfg.rules) ? cfg.rules : [];
    // Pre-compile regexes once.
    const compiled = rules.map((r) => ({
      id: r.id || "(unnamed)",
      action: r.action === "warn" || r.action === "ask" ? r.action : "deny",
      message: r.message || "Blocked by command-guard.",
      patterns: (r.patterns || []).map((p) => new RegExp(p, "i")),
      unless: (r.unless || []).map((p) => new RegExp(p, "i")),
    }));
    return {
      enabled: cfg.enabled !== false,
      failClosed: cfg.failClosed !== false,
      rules: compiled,
      path,
    };
  } catch (e) {
    console.warn(
      `[command-guard] rule file not loaded (${path}): ${e.message} — guarding DISABLED.`,
    );
    return { enabled: false, rules: [], failClosed: true, path };
  }
}

// ---------- normalisation ------------------------------------------------

// Strip surrounding single/double quotes from a token.
function stripQuotes(s) {
  return s.replace(/^['"]|['"]$/g, "");
}

// Reduce an absolute/relative executable path to its bare command name:
//   /usr/bin/git -> git ; ./scripts/x.sh -> x.sh
function basenameCmd(word) {
  const m = /(?:^|\/)([^\/\s]+)$/.exec(word);
  return m ? m[1] : word;
}

// Best-effort base64 decode; returns null if it doesn't look like text.
function tryBase64(s) {
  try {
    const cleaned = s.trim().replace(/\s+/g, "");
    if (cleaned.length < 8 || !/^[A-Za-z0-9+/=]+$/.test(cleaned)) return null;
    const out = Buffer.from(cleaned, "base64").toString("utf8");
    // Reject if the round-trip is garbage (non-printable heavy).
    const printable = out.replace(/[^\x09\x0a\x0d\x20-\x7e]/g, "");
    if (printable.length < out.length * 0.8) return null;
    return out;
  } catch {
    return null;
  }
}

// Collapse the cheap, common obfuscations into a canonical-ish form so the
// regex rules can see the real verb. This is intentionally conservative: it
// removes noise, it does not try to be a shell.
function normaliseFragment(frag) {
  let s = frag;

  // Line-continuations and redundant whitespace.
  s = s.replace(/\\\r?\n/g, " ").replace(/\s+/g, " ").trim();

  // Remove leading env-var assignments and common transparent prefixes:
  //   FOO=bar BAZ=1 env -i command ...  ->  command ...
  //   env git ... / command git ... / builtin git ... / exec git ...
  //   nice/nohup/time/stdbuf/timeout/xargs wrappers
  let prev;
  do {
    prev = s;
    s = s.replace(/^\s*[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+/, "");
    s = s.replace(
      /^\s*(?:env(?:\s+-i)?|command|builtin|exec|nice(?:\s+-n\s*-?\d+)?|nohup|time|stdbuf(?:\s+\S+)*|timeout\s+\S+|xargs(?:\s+-[^\s]+)*|sudo(?:\s+-[^\s]+)*)\s+/,
      "",
    );
  } while (s !== prev);

  // Resolve `$(which git)` / `` `which git` `` / `$(command -v git)` -> git
  s = s.replace(/\$\((?:which|command\s+-v|type\s+-p)\s+([^)]+)\)/g, (_, c) =>
    basenameCmd(stripQuotes(c.trim())),
  );
  s = s.replace(/`(?:which|command\s+-v|type\s+-p)\s+([^`]+)`/g, (_, c) =>
    basenameCmd(stripQuotes(c.trim())),
  );

  // Bare absolute/relative path as the FIRST word -> basename.
  s = s.replace(/^(\S+)/, (w) => basenameCmd(w));

  // Trivial `$VAR` / `${VAR}` indirection where VAR was assigned in the same
  // fragment: `GIT=git && $GIT push` — we already split on && before we get
  // here, so instead map a leading `$VAR`/`${VAR}` to nothing meaningful is
  // hard; we settle for stripping the `$`/`${}` so a downstream literal like
  // `$GIT` at least isn't mistaken for a comment. (Real indirection is caught
  // because the assignment fragment `GIT=git` and the use are both scanned.)
  s = s.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, "$1");

  return s;
}

// ---------- recursive command extraction ---------------------------------

// Interpreters whose `-c '<code>'` / `-e '<code>'` payload we want to re-scan.
const DASH_C_INTERP = /\b(?:ba|z|k|da|a)?sh|python[0-9.]*|perl|ruby|node|deno|bun\b/;

// Pull out quoted payloads that follow a `-c`/`-e`/`-e`-style flag so nested
// code gets scanned too. Returns an array of inner code strings.
function extractDashCPayloads(frag) {
  const out = [];
  // Match: <interp> ... -c 'payload'  |  -c "payload"
  const re =
    /(?:^|[\s|;&(])((?:ba|z|k|da|a)?sh|python[0-9.]*|perl|ruby|node|deno|bun)\b[^|;&\n]*?\s-(?:c|e)\s+('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\S+)/g;
  let m;
  while ((m = re.exec(frag)) !== null) {
    out.push(stripQuotes(m[2]).replace(/\\(['"])/g, "$1"));
  }
  return out;
}

// Extract here-doc bodies:  cmd << 'EOF' ... EOF
function extractHeredocs(cmd) {
  const out = [];
  const re = /<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1\r?\n([\s\S]*?)\r?\n\s*\2\b/g;
  let m;
  while ((m = re.exec(cmd)) !== null) out.push(m[3]);
  return out;
}

// Extract base64 blobs that are piped into a shell:
//   echo <b64> | base64 -d | bash   (also -D, --decode, openssl base64 -d)
function extractBase64ToShell(cmd) {
  const out = [];
  // Any base64-ish literal anywhere, but only bother if a decoder AND a shell
  // sink are present in the command (cheap heuristic to avoid false decodes).
  const hasDecoder = /\b(?:base64\s+(?:-d|-D|--decode)|openssl\s+(?:base64|enc\s+-d)|xxd\s+-r)\b/.test(cmd);
  const hasShellSink = /\|\s*(?:(?:ba|z|k|da|a)?sh|python[0-9.]*|perl|ruby|node)\b/.test(cmd);
  if (!hasDecoder && !hasShellSink) return out;
  const re = /(?:^|['"\s=(])([A-Za-z0-9+/]{16,}={0,2})(?:['"\s|)]|$)/g;
  let m;
  while ((m = re.exec(cmd)) !== null) {
    const dec = tryBase64(m[1]);
    if (dec) out.push(dec);
  }
  return out;
}

// Split a command line into simple fragments on shell operators, ignoring
// operators inside quotes. Not a full parser — good enough to separate the
// verbs the rules care about.
function splitTopLevel(cmd) {
  const parts = [];
  let buf = "";
  let quote = null;
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    const next = cmd[i + 1];
    if (quote) {
      buf += c;
      if (c === quote && cmd[i - 1] !== "\\") quote = null;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      buf += c;
      continue;
    }
    // Operators: | || & && ; and newlines. Subshell parens too.
    if (
      c === ";" ||
      c === "\n" ||
      c === "(" ||
      c === ")" ||
      ((c === "|" || c === "&") && (next === c || true))
    ) {
      if (buf.trim()) parts.push(buf.trim());
      buf = "";
      if ((c === "|" || c === "&") && next === c) i++; // consume second char
      continue;
    }
    buf += c;
  }
  if (buf.trim()) parts.push(buf.trim());
  return parts;
}

// Produce the full set of normalised fragments to scan for a raw command,
// following nested shells / here-docs / base64 / -c payloads recursively
// (bounded depth to avoid pathological input).
function collectFragments(rawCmd, depth = 0, seen = new Set()) {
  const results = [];
  if (depth > 6 || !rawCmd) return results;

  // Recurse into decoded/nested payloads first (they hold the real intent).
  for (const inner of extractHeredocs(rawCmd)) {
    if (!seen.has(inner)) {
      seen.add(inner);
      results.push(...collectFragments(inner, depth + 1, seen));
    }
  }
  for (const inner of extractBase64ToShell(rawCmd)) {
    if (!seen.has(inner)) {
      seen.add(inner);
      results.push({ text: normaliseFragment(inner), decoded: true });
      results.push(...collectFragments(inner, depth + 1, seen));
    }
  }
  for (const inner of extractDashCPayloads(rawCmd)) {
    if (!seen.has(inner)) {
      seen.add(inner);
      results.push(...collectFragments(inner, depth + 1, seen));
    }
  }

  for (const frag of splitTopLevel(rawCmd)) {
    results.push({ text: normaliseFragment(frag), decoded: false });
  }
  return results;
}

// ---------- evaluation ---------------------------------------------------

function evaluate(rules, fragments) {
  // Returns the most severe hit: deny > ask > warn.
  const order = { deny: 3, ask: 2, warn: 1 };
  let hit = null;
  for (const f of fragments) {
    for (const r of rules) {
      if (r.unless.some((u) => u.test(f.text))) continue;
      if (r.patterns.some((p) => p.test(f.text))) {
        if (!hit || order[r.action] > order[hit.rule.action]) {
          hit = { rule: r, fragment: f };
        }
      }
    }
  }
  return hit;
}

// ---------- plugin -------------------------------------------------------

export default async () => {
  const cfg = loadRules();
  if (cfg.enabled) {
    console.warn(
      `[command-guard] active — ${cfg.rules.length} rule(s) from ${cfg.path} (failClosed=${cfg.failClosed}).`,
    );
  }

  return {
    "tool.execute.before": async (input, output) => {
      if (!cfg.enabled) return;
      if (input.tool !== "bash") return;

      const cmd = (output.args && output.args.command) || "";
      if (!cmd) return;

      let fragments;
      try {
        fragments = collectFragments(cmd);
        // Always also scan the raw + globally-normalised command so single
        // simple commands are covered even if splitting produced nothing new.
        fragments.push({ text: normaliseFragment(cmd), decoded: false });
      } catch (e) {
        // Normalisation blew up on adversarial input.
        if (cfg.failClosed) {
          throw new Error(
            `command-guard: failed to analyse the command and failClosed is on — BLOCKED.\n` +
              `Command: ${cmd}\nError: ${e.message}`,
          );
        }
        console.warn(`[command-guard] analysis error (passed through): ${e.message}`);
        return;
      }

      const hit = evaluate(cfg.rules, fragments);
      if (!hit) return;

      const where = hit.fragment.decoded ? " (found inside a decoded/nested payload)" : "";
      const detail =
        `command-guard: rule "${hit.rule.id}" matched${where}.\n` +
        `${hit.rule.message}\n` +
        `Command: ${cmd}`;

      if (hit.rule.action === "warn") {
        console.warn(`[command-guard] WARN ${detail}`);
        return;
      }

      // deny and ask both hard-block (see header note on why "ask" maps here).
      const suffix =
        hit.rule.action === "ask"
          ? `\nThis command needs explicit human approval — run it yourself or ` +
            `have the user confirm, then re-issue via an allowed path.`
          : "";
      throw new Error(detail + suffix);
    },
  };
};
