#!/usr/bin/env bash
# Sync safety tests. Two throwaway homes on this machine play "laptop" (local) and
# "devbox" (remote, reached through test/fake-ssh). Nothing touches your real files.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/sh-tafeta"
export PATH="$ROOT/test/bin:$PATH"
unset CLAUDE_CONFIG_DIR SHTAFETA_STATE_DIR SHTAFETA_CONFIG_DIR XDG_CONFIG_HOME XDG_STATE_HOME TMUX TMUX_PANE
export SHTAFETA_TEST_CLAUDE_RUNNING=0
fails=0
TOP=$(mktemp -d)
trap 'rm -rf "$TOP"' EXIT

check() {   # description, expected, actual
    if [[ $2 == "$3" ]]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
nconflicts() { local f n=0; for f in "$1"/*.sync-conflict-*; do [[ -e $f ]] && n=$((n + 1)); done; echo "$n"; }

# A fresh pair of machines with one project (~/code/app on both).
world() {
    W=$(mktemp -d -p "$TOP")
    export HOME="$W/laptop" FAKE_REMOTE_HOME="$W/devbox"
    LP="$HOME/code/${1:-app}" RP="$FAKE_REMOTE_HOME/code/${1:-app}"
    LC="$HOME/.claude/projects/$(enc "$LP")" RC="$FAKE_REMOTE_HOME/.claude/projects/$(enc "$RP")"
    mkdir -p "$LP" "$RP" "$LC/memory" "$RC/memory"
    cd "$LP" || exit 1
}
sync() { "$BIN" sync devbox "$@" -y >"$W/out" 2>&1; echo $? >"$W/rc"; }
rc() { cat "$W/rc"; }
outhas() { grep -q -- "$1" "$W/out" && echo yes || echo no; }
put() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" >"$1"; }

echo "basics"
world
put "$LC/s1.jsonl" '{"uuid":"a"}\n'
put "$RC/s2.jsonl" '{"uuid":"b"}\n'
sync
check "first sync, disjoint files: exit 0" 0 "$(rc)"
check "first sync, disjoint files: both sides have both" "yes yes" "$([[ -f $RC/s1.jsonl ]] && echo yes) $([[ -f $LC/s2.jsonl ]] && echo yes)"
sync
check "second sync: nothing to do" "yes" "$(outhas 'Nothing to do')"
check "sync state is private" "700" "$(stat -c %a "$HOME/.local/state/sh-tafeta")"

world
rm -rf "$RC"
put "$LC/s1.jsonl" '{"uuid":"a"}\n'
put "$LC/memory/MEMORY.md" 'm\n'
sync
check "first sync into a project the other machine has never seen" "0 yes" "$(rc) $([[ -f $RC/memory/MEMORY.md && -f $RC/s1.jsonl ]] && echo yes)"
check "...and the new folders are private" "700" "$(stat -c %a "$RC")"

world
put "$LC/s1.jsonl" '{"uuid":"a"}\n'
put "$RC/.sht-tmp-deadbeef" 'half a file from a sync that died\n'
sync
check "temp files of a sync that died are cleaned up" "no" "$([[ -e $RC/.sht-tmp-deadbeef ]] && echo yes || echo no)"

echo "transcripts"
world
put "$LC/s.jsonl" '{"uuid":"a"}\n{"uuid":"b"}\n{"uuid":"c"}\n'
put "$RC/s.jsonl" '{"uuid":"a"}\n'
sync
check "no base, remote is a prefix: fast-forward" "$(cat "$LC/s.jsonl")" "$(cat "$RC/s.jsonl")"
check "fast-forward is not a conflict" 0 "$(rc)"

world
put "$LC/s.jsonl" '{"uuid":"a"}\n{"uuid":"b"}\n'
cp "$LC/s.jsonl" "$RC/s.jsonl"
sync
printf '{"uuid":"L1"}\n' >>"$LC/s.jsonl"; touch -d '2026-01-01 10:00' "$LC/s.jsonl"
printf '{"uuid":"R1"}\n{"uuid":"R2"}\n' >>"$RC/s.jsonl"; touch -d '2026-01-01 11:00' "$RC/s.jsonl"
sync
check "same session continued on both machines: exit 2" 2 "$(rc)"
check "DIVERGED is reported" "yes" "$(outhas DIVERGED)"
check "local turns are not lost" "yes" "$(grep -q L1 "$LC/s.jsonl" && ! grep -q R1 "$LC/s.jsonl" && echo yes)"
check "remote turns are not lost" "yes" "$(grep -q R2 "$RC/s.jsonl" && ! grep -q L1 "$RC/s.jsonl" && echo yes)"
check "the other copy is saved aside" "yes" "$(grep -rqs R2 "$HOME/.local/state/sh-tafeta/conflicts" && echo yes)"

world
head -c 3000000 /dev/urandom | base64 -w 100 >"$LC/big.jsonl"
head -c 1000 "$LC/big.jsonl" >"$RC/big.jsonl"
sync
check "multi-megabyte fast-forward is byte-exact" "$(sha256sum <"$LC/big.jsonl")" "$(sha256sum <"$RC/big.jsonl")"

echo "the wrong-machine scenarios"
world
put "$LC/memory/MEMORY.md" 'base\n'; cp "$LC/memory/MEMORY.md" "$RC/memory/MEMORY.md"
sync
put "$LC/memory/MEMORY.md" 'base\nlocal new fact\n'; touch -d '2020-01-01' "$LC/memory/MEMORY.md"
touch -d '2030-01-01' "$RC/memory/MEMORY.md"     # remote clock far ahead, content unchanged
sync
check "clock skew: newer content wins over a newer date" "$(printf 'base\nlocal new fact')" "$(cat "$RC/memory/MEMORY.md")"

world
put "$RC/memory/notes.md" 'v1\n'; cp "$RC/memory/notes.md" "$LC/memory/notes.md"
sync
put "$RC/memory/notes.md" 'v2 real work on devbox\n'; touch -d '-1 hour' "$RC/memory/notes.md"
touch "$LC/memory/notes.md"                         # git checkout / cp / editor: fresh date, old content
sync
check "a fresh date on old content does not overwrite real work" "v2 real work on devbox" "$(cat "$LC/memory/notes.md")"

world
put "$LC/memory/a.md" 'a\n'; cp "$LC/memory/a.md" "$RC/memory/a.md"
sync
put "$RC/memory/a.md" 'devbox did the work\n'
put "$RC/s9.jsonl" '{"uuid":"x"}\n'
"$BIN" sync devbox push -y >"$W/out" 2>&1
check "push from the stale machine leaves the newer side alone" "devbox did the work" "$(cat "$RC/memory/a.md")"
check "...and says so" "yes" "$(outhas 'Wrong machine')"

world
put "$LC/memory/MEMORY.md" 'local version\n'
put "$RC/memory/MEMORY.md" 'remote version\n'
sync
check "changed on both sides: exit 2" 2 "$(rc)"
check "changed on both sides: nothing overwritten" "local version|remote version" "$(cat "$LC/memory/MEMORY.md")|$(cat "$RC/memory/MEMORY.md")"
check "conflict copies on both sides" "1 1" "$(nconflicts "$LC/memory") $(nconflicts "$RC/memory")"
sync
check "conflict copies are not duplicated on the next run" "1 1" "$(nconflicts "$LC/memory") $(nconflicts "$RC/memory")"
"$BIN" sync devbox --force=remote -y >"$W/out" 2>&1
check "--force=remote resolves it" "remote version" "$(cat "$LC/memory/MEMORY.md")"
check "...and backs up the replaced file" "yes" "$(grep -rqs 'local version' "$HOME/.local/state/sh-tafeta/backups" && echo yes)"

echo "deletions"
world
put "$LC/old.jsonl" '{"uuid":"o"}\n'
sync
rm "$RC/old.jsonl"                                   # e.g. cleanupPeriodDays on the devbox
sync
check "a session deleted on one side is restored, never propagated" "yes" "$([[ -f $RC/old.jsonl && -f $LC/old.jsonl ]] && echo yes)"

echo "live sessions and races"
world
put "$LC/s.jsonl" '{"uuid":"a"}\n{"uuid":"b"}\n'
put "$RC/s.jsonl" '{"uuid":"a"}\n'
FAKE_REMOTE_CLAUDE_RUNNING=1 sync
check "a session Claude is writing right now is skipped" "1" "$(wc -l <"$RC/s.jsonl")"
check "...and reported" "yes" "$(outhas LIVE)"
FAKE_REMOTE_CLAUDE_RUNNING=1 sync --include-live
check "--include-live writes it" "2" "$(wc -l <"$RC/s.jsonl")"

world
put "$LC/memory/m.md" 'base\n'; cp "$LC/memory/m.md" "$RC/memory/m.md"
sync
put "$LC/memory/m.md" 'local edit\n'
SHTAFETA_TEST_BEFORE_APPLY="printf 'edited on devbox during the sync\n' >'$RC/memory/m.md'" sync
check "destination changed between plan and write: kept" "edited on devbox during the sync" "$(cat "$RC/memory/m.md")"
check "...reported, exit 2" 2 "$(rc)"

world
put "$LC/s.jsonl" '{"uuid":"a"}\n'
mkdir -p "$FAKE_REMOTE_HOME/.local/state/sh-tafeta/sync.lock.d"
sleep 60 & holder=$!
printf '{"pid": %d, "owner": "other sync", "time": %d}' "$holder" "$(date +%s)" >"$FAKE_REMOTE_HOME/.local/state/sh-tafeta/sync.lock.d/info.json"
sync
check "a running sync on the other side blocks this one" "yes no" "$(outhas 'another sync is running') $([[ -f $RC/s.jsonl ]] && echo yes || echo no)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
sync
check "a dead sync's lock is taken over" "yes" "$([[ -f $RC/s.jsonl ]] && echo yes)"

echo "safety rails"
world
put "$LC/s.jsonl" '{"uuid":"a"}\n'
"$BIN" sync devbox -n >"$W/out" 2>&1
check "dry run writes nothing" "no no" "$([[ -f $RC/s.jsonl ]] && echo yes || echo no) $([[ -d $HOME/.local/state/sh-tafeta/sync ]] && echo yes || echo no)"
"$BIN" sync devbox </dev/null >"$W/out" 2>&1
check "no terminal and no --yes: refuses" "yes no" "$(outhas 'add --yes') $([[ -f $RC/s.jsonl ]] && echo yes || echo no)"
FAKE_SSH_FAIL=1 sync
check "unreachable host: clear error" "yes" "$([[ $(rc) != 0 ]] && grep -q 'Connection refused\|lost the connection' "$W/out" && echo yes)"

world
mkdir -p "$HOME/.ssh" "$HOME/.claude/projects/$(enc "$HOME")"
put "$HOME/.ssh/id_ed25519" 'PRIVATE KEY\n'
put "$HOME/.claude/projects/$(enc "$HOME")/h.jsonl" "{\"cwd\":\"$HOME\"}\n"
"$BIN" sync devbox -p "$HOME" --with-source -y >"$W/out" 2>&1
check "the home folder is never a project" "yes no" "$(outhas 'home directory') $([[ -e $FAKE_REMOTE_HOME/.ssh/id_ed25519 ]] && echo yes || echo no)"
"$BIN" sync devbox --all --with-source -y >"$W/out" 2>&1
check "--all --with-source is refused" "yes" "$(outhas 'explicit --project')"
"$BIN" sync devbox --all -y >"$W/out" 2>&1
check "--all skips a session started in ~" "no" "$([[ -e $FAKE_REMOTE_HOME/.ssh/id_ed25519 ]] && echo yes || echo no)"

world
put "$LP/app.py" 'print(1)\n'
put "$LP/.env" 'API_KEY=secret\n'
put "$LP/deploy.pem" 'KEY\n'
put "$LP/.ssh/id_rsa" 'KEY\n'
put "$LP/node_modules/x/index.js" 'x\n'
put "$LC/s.jsonl" '{"uuid":"a"}\n'
sync --with-source
check "source files travel" "yes" "$([[ -f $RP/app.py ]] && echo yes)"
check "secrets and excluded folders never do" "0" "$(find "$RP" -name '.env' -o -name '*.pem' -o -name 'id_rsa' -o -name node_modules | wc -l)"
rm "$RP/app.py"
sync --with-source
check "a source file deleted on one side is not resurrected" "no" "$([[ -f $RP/app.py ]] && echo yes || echo no)"
check "...but it is reported" "yes" "$(outhas 'deleted')"

world "my app \$(touch pwned)"
put "$LC/s.jsonl" '{"uuid":"a"}\n'
put "$LP/file with spaces.txt" 'ok\n'
sync --with-source
check "paths with spaces and \$() work and run nothing" "yes no" "$([[ -f "$RP/file with spaces.txt" && -f $RC/s.jsonl ]] && echo yes) $([[ -e $FAKE_REMOTE_HOME/pwned || -e $HOME/pwned || -e $LP/pwned ]] && echo yes || echo no)"

world
put "$HOME/.claude/agents/reviewer.md" 'agent\n'
put "$HOME/.claude/settings.json" '{"env":{"API_KEY":"secret"}}\n'
put "$HOME/.claude/.credentials.json" '{"token":"x"}\n'
put "$LC/s.jsonl" '{"uuid":"a"}\n'
sync --with-config
check "--with-config copies agents" "yes" "$([[ -f $FAKE_REMOTE_HOME/.claude/agents/reviewer.md ]] && echo yes)"
check "...never settings.json or credentials" "no no" "$([[ -f $FAKE_REMOTE_HOME/.claude/settings.json ]] && echo yes || echo no) $([[ -f $FAKE_REMOTE_HOME/.claude/.credentials.json ]] && echo yes || echo no)"

echo "hostile or odd remote"
# a remote whose agent lists files it should never send (settings.json, git hooks)
hostile() {
    mkdir -p "$W/evilbin"
    cat >"$W/evilbin/python3" <<'PY'
#!/bin/bash
# fake remote python3: patches the sh-tafeta agent it is asked to run
real=$(PATH=${PATH#*evilbin:} command -v python3)
args=("$@")
for i in "${!args[@]}"; do
    if [[ ${args[$i]} == -c ]]; then
        code=${args[$((i + 1))]}
        b64=${code#*b64decode(\'}; b64=${b64%%\')*}
        src=$(printf '%s' "$b64" | base64 -d | sed -e 's/^CONFIG_ALLOW = \[/CONFIG_ALLOW = ["settings.json", /' -e 's/^    ".git", /    /')
        args[$((i + 1))]="import base64;exec(base64.b64decode('$(printf '%s' "$src" | base64 -w0)'))"
    fi
done
exec "$real" "${args[@]}"
PY
    chmod +x "$W/evilbin/python3"
    export FAKE_REMOTE_PATH="$W/evilbin:$PATH"
}
world
hostile
put "$FAKE_REMOTE_HOME/.claude/settings.json" '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /tmp/pwned"}]}]}}'
put "$FAKE_REMOTE_HOME/.claude/agents/ok.md" 'agent\n'
put "$LC/s.jsonl" '{"uuid":"a"}\n'
sync --with-config
check "a hostile remote cannot plant settings.json" "no" "$([[ -e $HOME/.claude/settings.json ]] && echo yes || echo no)"
check "...it is reported, exit 2" "yes 2" "$(outhas 'outside what is synced here') $(rc)"
check "...and the legitimate agent still syncs" "yes" "$([[ -f $HOME/.claude/agents/ok.md ]] && echo yes)"
put "$RP/.git/hooks/pre-commit" '#!/bin/sh\ntouch /tmp/pwned\n'
put "$RP/main.py" 'print(1)\n'
sync --with-source
check "a hostile remote cannot plant git hooks" "no yes" "$([[ -e $LP/.git/hooks/pre-commit ]] && echo yes || echo no) $([[ -f $LP/main.py ]] && echo yes)"
unset FAKE_REMOTE_PATH

world
put "$RP/run.sh" '#!/bin/sh\n'; chmod 777 "$RP/run.sh"
put "$RC/s.jsonl" '{"uuid":"a"}\n'; chmod 666 "$RC/s.jsonl"
sync --with-source
check "file modes are never taken from the other side" "700 600" "$(stat -c %a "$LP/run.sh") $(stat -c %a "$LC/s.jsonl")"

world
put "$LC/memory/old-topic.md" 'x\n'
sync
rm "$RC/memory/old-topic.md"
sync
check "a memory file deleted on one side is not resurrected" "no" "$([[ -e $RC/memory/old-topic.md ]] && echo yes || echo no)"
check "...but reported" "yes" "$(outhas 'deleted')"

world
mkdir -p "$HOME/.ssh/proj"
"$BIN" sync devbox -p "$HOME/.ssh/proj" -y >"$W/out" 2>&1
check "a project inside ~/.ssh is refused" "yes" "$(outhas 'credentials, config or programs')"

world
put "$LC/s1.jsonl" '{"uuid":"a"}\n{"uuid":"b"}\n'
put "$RC/s1.jsonl" '{"uuid":"a"}\n'
(exec -a claude python3 -c 'import time; time.sleep(30)' --resume s1) & holder=$!
sleep 0.5
sync
check "a session open (idle) in Claude on the other side is not appended to" "1 yes" "$(wc -l <"$RC/s1.jsonl") $(outhas LIVE)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "screenshots"
world
put "$W/Screenshot 2026-10-15 112233.png" 'PNG'
put "$W/notes.txt" 'x'
d="$FAKE_REMOTE_HOME/.cache/sh-tafeta/screenshots"
check "a screenshot lands where Claude runs, with a clean name" "$d/Screenshot_2026-10-15_112233.png" "$("$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png")"
check "the same name never overwrites" "$d/Screenshot_2026-10-15_112233-1.png" "$("$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png")"
check "screenshots are private" "700 600" "$(stat -c %a "$d") $(stat -c %a "$d/Screenshot_2026-10-15_112233.png")"
check "only images" "1" "$("$BIN" shot devbox "$W/notes.txt" >/dev/null 2>&1; echo $?)"
check "the original file is not renamed" "yes" "$([[ -f "$W/Screenshot 2026-10-15 112233.png" ]] && echo yes)"
mkdir -p "$HOME/.config/sh-tafeta/hosts"
# shellcheck disable=SC2016  # literal $HOME / $(...) on purpose
printf 'SHOTS_DIR=%q\n' '$HOME/screens' >"$HOME/.config/sh-tafeta/hosts/devbox.conf"
check "SHOTS_DIR from the host config" "$FAKE_REMOTE_HOME/screens/Screenshot_2026-10-15_112233.png" "$("$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png")"
# shellcheck disable=SC2016
printf 'SHOTS_DIR=%q\n' '/tmp/$(touch pwned)' >"$HOME/.config/sh-tafeta/hosts/devbox.conf"
check "a hostile SHOTS_DIR is refused" "1 no" "$("$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png" >/dev/null 2>&1; echo $?) $([[ -e pwned || -e $FAKE_REMOTE_HOME/pwned ]] && echo yes || echo no)"
mkdir -p "$FAKE_REMOTE_HOME/docs"; put "$FAKE_REMOTE_HOME/docs/tax-2019.pdf" 'old'; put "$FAKE_REMOTE_HOME/docs/old.png" 'old'
touch -d '-400 days' "$FAKE_REMOTE_HOME/docs/tax-2019.pdf" "$FAKE_REMOTE_HOME/docs/old.png"
printf 'SHOTS_DIR=%q\nSHOTS_KEEP_DAYS=1\n' "$FAKE_REMOTE_HOME/docs" >"$HOME/.config/sh-tafeta/hosts/devbox.conf"
"$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png" >/dev/null
check "an existing folder is never pruned nor chmod-ed" "yes yes 755" "$([[ -f $FAKE_REMOTE_HOME/docs/tax-2019.pdf ]] && echo yes) $([[ -f $FAKE_REMOTE_HOME/docs/old.png ]] && echo yes) $(stat -c %a "$FAKE_REMOTE_HOME/docs")"
# shellcheck disable=SC2016  # literal on purpose
for bad in '$HOME/.' '$HOME/./x' '$HOME/.ssh'; do
    printf 'SHOTS_DIR=%q\n' "$bad" >"$HOME/.config/sh-tafeta/hosts/devbox.conf"
    check "SHOTS_DIR $bad is refused" "1" "$("$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png" >/dev/null 2>&1; echo $?)"
done
printf 'SHOTS_KEEP_DAYS=3\n' >"$HOME/.config/sh-tafeta/hosts/devbox.conf"
touch -d '-10 days' "$d/Screenshot_2026-10-15_112233.png"
"$BIN" shot devbox "$W/Screenshot 2026-10-15 112233.png" >/dev/null
check "SHOTS_KEEP_DAYS prunes old screenshots" "no" "$([[ -e $d/Screenshot_2026-10-15_112233.png ]] && echo yes || echo no)"
check "local target" "$HOME/.cache/sh-tafeta/screenshots/Screenshot_2026-10-15_112233.png" "$("$BIN" shot local "$W/Screenshot 2026-10-15 112233.png")"

echo
if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "all sync tests passed"
