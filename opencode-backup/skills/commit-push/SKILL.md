---
name: commit-push
description: Committet alle von git getrackten Änderungen und pusht sie. Auslösen bei Anfragen wie "committe meine Änderungen", "push das", "commit und push" oder dem Befehl /commit-push.
---

# commit-push

Commit every tracked change, then push. Untracked files stay out — if the user wants a new
file in, they add it themselves first.

## Steps

1. **Look** — `git status --short` and `git diff` in parallel. The diff is what the message
   is derived from.
2. **Stage** — `git add -u`. This stages modifications and deletions of tracked files and
   nothing else, so an untracked `.env` or credential file cannot slip in.
3. **Commit** — `git commit -m "<gitmoji> <message>"`. If the user supplied a message, use it
   verbatim and only prepend the gitmoji.
4. **Push** — `git push`, or `git push -u origin <branch>` when the branch has no upstream.
5. **Report** — commit hash, message, branch.

## Message

English, one sentence. A second sentence is fine when the change is genuinely broad, and
never more than that. Say what changed and why, not which files.

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
- Nothing to stage after `git add -u` → say so and stop. Do not invent a commit.
