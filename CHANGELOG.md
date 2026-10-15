# Changelog

## 0.2.0 — 2026-10-15

Safety release, after an independent audit (74 agents, every finding reproduced).

**sync, rewritten** — no more "newest file wins":
- content hashes compared against a per-pair record of the last sync, kept on both machines
- transcripts fast-forward only when one copy is a byte prefix of the other; diverged sessions are never overwritten (other copy saved aside)
- other files changed on both sides become `.sync-conflict` copies; `--force=local|remote` to choose, with backup
- compare-and-swap writes, atomic replace, live-session guard, locks on both sides, unique backup runs with pruning, exit code 2 on conflicts
- `push`/`pull` only filter writes and warn when the other side is newer ("wrong machine")
- one SSH connection, python agent sent on the fly; rsync no longer needed
- home folder, `/`, `~/.claude` and parents can never be a project; remote-supplied paths are validated
- `--with-source`: git-aware ignores plus hard-coded secret excludes, explicit projects only
- `--with-config`: allow-list without `settings.json`/credentials, warns before importing agents/commands/skills

**tmux / resume**
- `snapshot` (tmux-resurrect post-save hook): sessions follow the restored layout even if panes moved
- nested Claude processes no longer steal a pane's mapping; hook input sanitised
- non-Claude panes caught by `~claude` get their own command back
- hook 6x faster (73 → 12 ms per prompt)
- `restore` no longer waits when there is nothing to restore, and waits for resurrect to really finish
- pane scrollback capture off by default

**Screenshots**
- `sh-tafeta shot HOST|local FILE...`: deliver images where Claude Code runs (private dir, clean names, never overwrites, optional pruning), print the paths; one ssh connection reused for 10 minutes
- Windows screenshot bridge (`-Shots` / `-ShotsOnly`): watches the clipboard (`Win+Shift+S`, nothing to save) and/or a folder (`-ShotsFrom`), delivers through WSL, leaves image **and** path on the clipboard, sends a snip that is both copied and saved only once, notifies; single instance; `windows shots TARGET [--background|--stop]`
- README: in WSL use `Alt+V` for images (Windows Terminal keeps `Ctrl+V`)

**Setup**
- `sh-tafeta setup`: guided and re-runnable — this machine (packages, hooks, tmux, TPM and plugins), remote hosts, Windows
- `host add|remove|list`: ssh alias in `~/.ssh/config.d/sh-tafeta.conf`, existing or dedicated key (ssh-copy-id or paste), host key fingerprint check, remote prerequisites, same-version remote install, path map guessed from your project folders
- `windows shortcut|profile|autostart|shots|remove`: desktop shortcuts, Windows Terminal dropdown entries (JSON fragment), login autostart; options in `~/.config/sh-tafeta/windows.conf`
- shortcuts start `wsl.exe … sh-tafeta open TARGET` (never PowerShell) and are written from WSL in the Shell Link format (`libexec/mklnk.py`): Bitdefender quarantined PowerShell-based shortcuts as malware persistence; fallback: the line to paste
- the launcher's ssh now runs inside WSL (one ssh config, one set of keys); `-Transport winssh` for Windows OpenSSH

**Second audit (79 agents) — fixed**
- sync: the receiving side enforces the same allow-lists as the sender (a compromised server could plant `settings.json`, credentials or git hooks); remote replies validated, time-limited and printed escaped; file modes never taken from the peer; `~/.ssh`, `~/.config`, `~/.local`… refused as projects; sessions open (even idle) in Claude on the destination are skipped, not forked; deleted memory files are no longer resurrected; per-file errors don't abort the run; config conflicts set aside instead of becoming new commands; lock race fixed; remote agent runs with `python3 -I`
- setup: host config values escaped (they are sourced); exact ssh alias matching; quoted IdentityFile; `--yes` no longer trusts unknown host keys without `--trust-host-key`; TPM and plugins via `install --with-tpm`, XDG-aware; remote install ships only tracked files and swaps atomically; `host remove` also cleans the shortcut and bridge config, rewrites `authorized_keys` safely
- screenshots: pruning and `chmod 700` only in folders sh-tafeta created (an existing folder is never touched), only image files; SHOTS_DIR sanity checks; control socket in a short private dir; the delivered path is marked, so banners never reach the clipboard; the bridge never overwrites something you copied meanwhile; `-StopShots` only stops our own bridge
- tmux: a non-Claude pane matched by `~claude` is never re-run through a shell; per-snapshot session maps; stale live-map positions ignored; nested Claude detection when claude is the pane process; stale restore markers cleared
- `uninstall` also removes the Windows side; state dir forced private; CI actions pinned by SHA with read-only permissions; README claims aligned with the code

**End-to-end tests (Windows Server 2025 + WSL2 on Azure, Ubuntu on Hetzner) — fixed**
- tabs opened at login were lost while Windows Terminal was still starting: the launcher now waits for its window, and puts the tabs in a window named after the target
- after a restore the next snapshot could be empty until each pane got a prompt: `resume` records the pane itself, and reads `--resume ID` from the saved command line when there is no map entry
- first contact in `host add` asked for the server password and printed a scary "Host key verification failed": now it only asks about the host key
- `host add` shipped no files from a git working copy without commits
- the launcher window is titled ("sh-tafeta: devbox (screenshot bridge)")

**Everything else**
- `install`/`uninstall` keep file modes and symlinks, keep the pre-install original, fail loudly on non-JSON settings
- state files private (umask 077); remote output never reaches shell arithmetic; host names validated
- Windows launcher attaches by tmux session id, sanitises tab titles, one WSL call, checks wt.exe

## 0.1.0 — 2026-10-15

First public release.

- `track` / `resume`: per-pane Claude Code session mapping for tmux-resurrect (self-healing, one pane per session)
- `restore`: WSL-safe tmux start with explicit resurrect restore when tmux-continuum skips it
- `ls`, `rename` (keeps pane mappings), local or remote
- `sync`: rsync over SSH with path mapping, newer-wins, no deletes, timestamped backups; `--all`, `--with-config`, `--with-source`
- `install` / `uninstall` / `doctor`
- `windows/sh-tafeta.ps1`: one Windows Terminal tab per tmux session, WSL or SSH/mosh host, desktop shortcut
