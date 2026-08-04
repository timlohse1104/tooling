---
name: commit-push
description: Committet alle von git getrackten Änderungen und pusht sie. Auslösen bei Anfragen wie "committe meine Änderungen", "push das", "commit und push" oder dem Befehl /commit-push.
---

# commit-push

Commit every tracked change, then push. Untracked files stay out — if the user wants a new
file in, they add it themselves first.

## Steps

1. **Look** — `git status --short`, `git diff` and `git diff --name-only` in parallel. The
   diff is what the message is derived from; `--name-only` is the list to stage.
2. **Stage** — `git add <path> …` with those names spelled out, never `git add -A`, `.` or
   `-u`. The names come from `git diff --name-only`, which lists modifications and deletions
   of tracked files only, so an untracked `.env` or credential file cannot end up in the list.
3. **Commit** — `git commit -m "<gitmoji> <message>"`. If the user supplied a message, use it
   verbatim and only prepend the gitmoji.
4. **Push** — `git push`, or `git push -u origin <branch>` when the branch has no upstream.
5. **Report** — commit hash, message, branch.

## Message

English, exactly one sentence. Say what changed and why, not which files.

| Gitmoji | When |
|---------|------|
| `✨` | new feature |
| `🔧` | bugfix |
| `📝` | docs |
| `♻️` | refactor |
| `🧹` | chore, config |
| `🔒` | security |
| `🚀` | CI/CD |

## Rules

- Never `--force`, `--no-verify`, or `--amend`.
- A rejecting pre-commit hook means fix the cause and make a **new** commit.
- Empty `git diff --name-only` → say so and stop. Do not invent a commit.
