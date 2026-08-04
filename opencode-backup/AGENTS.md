# Personal rules

Global, applies to every project. Keep this file short — it is loaded into every session.

## Language

Converse in German. Write everything that lands in a file in English — code, comments, docs,
commit messages — so artefacts match the ecosystem they live in.

One exception: text a human reads while the program runs — CLI output, error messages, toasts —
follows the language of the team that reads it. Same reason, different ecosystem.

## Writing register

Two audiences, two registers. Match the file, not your habit.

**Human-facing** — READMEs, code comments, config headers, CLI output, commit messages.
Short and dense. A comment earns its place only by saying something the code cannot; if it
restates the obvious, delete it. Prefer a table or `key = value` over a paragraph. Someone
reading this at 2am with a broken build wants the answer, not the story.

**Agent-facing** — `AGENTS.md`, `CLAUDE.md`, skill definitions.
Prose is welcome here. These files exist to carry context an agent cannot otherwise recover:
rationale, measured numbers, per-machine differences, and the dead ends someone already ruled
out. Verbosity here prevents wrong work later; the same verbosity in a README is noise.

When one fact serves both, split it: the rule goes in the human file, the reasoning in the
agent file.

## Numbers

Document measured values as measured, and guessed values as guessed. State how and when
something was measured so a later reader knows when to distrust it.

## Leave the machine as you found it

If you start a server, a background loop or a temp file to investigate something, stop and
remove it when you are done. Before touching something already running that you did not
start, ask — it may be load-bearing right now.

## Trust the machine, not the notes

Docs and config drift from reality. When a documented value matters, verify it against the
live system — with read-only commands — before acting on it, and fix the doc when it is
wrong. In reverse too: before "fixing" something that looks like a typo, confirm it is
actually broken.
