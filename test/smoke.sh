#!/usr/bin/env bash
# Smoke tests for sh-tafeta. Needs tmux and python3. Uses a private tmux socket
# and a throwaway HOME, so it never touches your real sessions or config.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/sh-tafeta"
T=$(mktemp -d)
SOCK="sh-tafeta-test-$$"
fails=0

export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" SHTAFETA_TEST_NO_ANCESTRY=1
unset CLAUDE_CONFIG_DIR SHTAFETA_STATE_DIR SHTAFETA_CONFIG_DIR TMUX_PLUGIN_MANAGER_PATH
mkdir -p "$HOME/.claude/projects/-tmp-app"
MAP="$XDG_STATE_HOME/sh-tafeta/pane-map.tsv"

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

check() {   # description, expected, actual
    if [[ $2 == "$3" ]]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

tmux -L "$SOCK" -f /dev/null new-session -d -s demo -c /tmp
tmux -L "$SOCK" split-window -t demo -c /tmp
SOCKET_PATH=$(tmux -L "$SOCK" display-message -p '#{socket_path}')
export TMUX="$SOCKET_PATH,$$,0"
P0=$(tmux -L "$SOCK" display-message -p -t demo:0.0 '#{pane_id}')
P1=$(tmux -L "$SOCK" display-message -p -t demo:0.1 '#{pane_id}')

transcript() { local f="$HOME/.claude/projects/-tmp-app/$1.jsonl"; echo '{}' >"$f"; printf '%s' "$f"; }
hook_json() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","hook_event_name":"UserPromptSubmit"}' "$1" "$2"; }

echo "track / resume"
TA=$(transcript aaaa-1111)
TB=$(transcript bbbb-2222)
out=$(hook_json aaaa-1111 "$TA" | TMUX_PANE=$P0 "$BIN" track; echo "rc=$?")
check "hook is silent and exits 0" "rc=0" "$out"
check "pane 0 resumes its session" "claude --resume aaaa-1111" "$(TMUX_PANE=$P0 "$BIN" resume --dry-run)"
check "unmapped pane falls back to the picker" "claude --resume" "$(TMUX_PANE=$P1 "$BIN" resume --dry-run)"

hook_json bbbb-2222 "$TB" | TMUX_PANE=$P1 "$BIN" track
check "two panes in the same folder keep different sessions" "claude --resume bbbb-2222" "$(TMUX_PANE=$P1 "$BIN" resume --dry-run)"

hook_json aaaa-1111 "$TA" | TMUX_PANE=$P1 "$BIN" track
check "a session resumed elsewhere moves with it (old pane)" "claude --resume" "$(TMUX_PANE=$P0 "$BIN" resume --dry-run)"
check "a session resumed elsewhere moves with it (new pane)" "claude --resume aaaa-1111" "$(TMUX_PANE=$P1 "$BIN" resume --dry-run)"

hook_json bbbb-2222 "/nowhere/moved.jsonl" | TMUX_PANE=$P0 "$BIN" track
check "a moved transcript is found by session id" "claude --resume bbbb-2222" "$(TMUX_PANE=$P0 "$BIN" resume --dry-run)"

rm -f "$TB"
check "a deleted transcript falls back to the picker" "claude --resume" "$(TMUX_PANE=$P0 "$BIN" resume --dry-run)"
check "SHTAFETA_FALLBACK=new" "claude" "$(SHTAFETA_FALLBACK=new TMUX_PANE=$P0 "$BIN" resume --dry-run)"
check "extra claude args" "claude --model opus --resume aaaa-1111" "$(SHTAFETA_CLAUDE_ARGS='--model opus' TMUX_PANE=$P1 "$BIN" resume --dry-run)"

out=$(printf 'not json' | TMUX_PANE=$P0 "$BIN" track; echo "rc=$?")
check "garbage input never breaks the hook" "rc=0" "$out"
out=$(hook_json cccc "$TA" | env -u TMUX "$BIN" track; echo "rc=$?")
check "outside tmux the hook does nothing" "rc=0" "$out"

echo "rename"
"$BIN" rename demo work 2>/dev/null
check "rename keeps the mapping" "claude --resume aaaa-1111" "$(TMUX_PANE=$P1 "$BIN" resume --dry-run)"
check "map positions follow the new name" "0" "$(awk -F'\t' 'index($2, "demo:") == 1' "$MAP" | wc -l)"

echo "snapshot"
TC=$(transcript cccc-3333)
hook_json cccc-3333 "$TC" | TMUX_PANE=$P0 "$BIN" track
"$BIN" snapshot
check "snapshot freezes position -> session" "work:0.0 cccc-3333" "$(awk -F'\t' '$2 == "cccc-3333" { print $1, $2 }' "$XDG_STATE_HOME/sh-tafeta/pane-map.saved.tsv")"
tmux -L "$SOCK" swap-pane -s work:0.0 -t work:0.1
check "after panes move, resume follows the snapshot, not the live map" "claude --resume cccc-3333" "$(TMUX_PANE=$P1 "$BIN" resume --dry-run)"

echo "snapshots"
RS="$HOME/.local/share/tmux/resurrect"
mkdir -p "$RS"
tmux -L "$SOCK" new-window -t work -c /tmp
P2=$(tmux -L "$SOCK" display-message -p -t work:1.0 '#{pane_id}')
# shellcheck disable=SC2016  # literal on purpose
printf 'pane\twork\t1\t1\t:*\t0\ttitle\t:/tmp\t1\tless\t:less $(touch %s/pwned) claude-notes.md\n' "$T" >"$RS/tmux_resurrect_A.txt"
ln -sfn tmux_resurrect_A.txt "$RS/last"
"$BIN" snapshot
check "every layout snapshot gets its own session map" "yes" "$([[ -f $XDG_STATE_HOME/sh-tafeta/snapshots/tmux_resurrect_A.txt.tsv ]] && echo yes)"
check "a non-Claude pane caught by ~claude is never re-run through a shell" "shell (was: less \$(touch $T/pwned) claude-notes.md) no" "$(TMUX_PANE=$P2 "$BIN" resume --dry-run) $([[ -e $T/pwned ]] && echo yes || echo no)"
# no map entry at all, but the saved command line names the session (claude run through an interpreter)
transcript eeee-5555 >/dev/null
printf 'pane\twork\t1\t1\t:*\t0\ttitle\t:/tmp\t1\tbash\t:/bin/bash /usr/local/bin/claude --resume eeee-5555\n' >"$RS/tmux_resurrect_A.txt"
check "without a map entry, the session id is read from the saved command line" "claude --resume eeee-5555" "$(TMUX_PANE=$P2 "$BIN" resume --dry-run)"
rm -rf "$RS" "$XDG_STATE_HOME/sh-tafeta/snapshots"

echo "hostile input"
out=$(printf '{"session_id":"--dangerously-skip-permissions","transcript_path":"/x"}' | TMUX_PANE=$P0 "$BIN" track; echo "rc=$?")
check "a session id that looks like a flag is ignored" "0" "$(grep -c -- '--dangerously' "$MAP")"
printf '{"session_id":"dddd-4444","transcript_path":"%s\\tinjected\\nrow","cwd":"/tmp"}' "$TA" | TMUX_PANE=$P0 "$BIN" track
check "control characters never create extra map rows" "0" "$(grep -c '^row' "$MAP")"

echo "install / uninstall"
mkdir -p "$HOME/.tmux/plugins/tpm"
printf 'set -g mouse on\nrun %s\n' "'~/.tmux/plugins/tpm/tpm'" >"$HOME/.tmux.conf"
printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' >"$HOME/.claude/settings.json"
chmod 600 "$HOME/.claude/settings.json"
"$BIN" install >/dev/null 2>&1
"$BIN" install >/dev/null 2>&1
check "install is idempotent (1 hook per event)" "1 1" "$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; print(len(h["SessionStart"]), len(h["UserPromptSubmit"]))' "$HOME/.claude/settings.json")"
check "install keeps unrelated settings" "opus say done" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["model"], d["hooks"]["Stop"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")"
check "tmux snippet sourced before TPM" "source-file run" "$(grep -E '^(source-file|run)' "$HOME/.tmux.conf" | awk '{printf "%s%s", sep, $1; sep=" "}')"
check "binary linked" "yes" "$([[ -L $HOME/.local/bin/sh-tafeta ]] && echo yes)"
check "settings.json keeps its 0600 mode" "600" "$(stat -c %a "$HOME/.claude/settings.json")"
mkdir -p "$HOME/dotfiles"; mv "$HOME/.tmux.conf" "$HOME/dotfiles/tmux.conf"; ln -s "$HOME/dotfiles/tmux.conf" "$HOME/.tmux.conf"
"$BIN" uninstall >/dev/null 2>&1
check "a symlinked tmux.conf stays a symlink" "yes" "$([[ -L $HOME/.tmux.conf ]] && echo yes)"
check "the pre-install original is kept" "yes" "$([[ -f $HOME/.claude/settings.json.sh-tafeta.orig ]] && grep -q '"model"' "$HOME/.claude/settings.json.sh-tafeta.orig" && ! grep -q sh-tafeta "$HOME/.claude/settings.json.sh-tafeta.orig" && echo yes)"
check "uninstall removes the hooks only" '{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$HOME/.claude/settings.json")"
check "uninstall cleans tmux.conf" "0" "$(grep -c sh-tafeta "$HOME/dotfiles/tmux.conf")"

echo "restore"
export TMUX_TMPDIR="$T/tmux-tmp"
mkdir -p "$TMUX_TMPDIR"
printf '' >"$HOME/.tmux.conf"
(
    unset TMUX TMUX_PANE
    SHTAFETA_RESTORE_WAIT=1 "$BIN" restore >/dev/null 2>&1
    check "nothing saved: an empty 'main' session" "main" "$(tmux list-sessions -F '#{session_name}')"
    tmux kill-server

    # continuum never fires (the WSL clock-jump case): sh-tafeta must run resurrect itself
    mkdir -p "$HOME/.tmux/plugins/tmux-resurrect/scripts" "$HOME/.local/share/tmux/resurrect"
    printf '#!/bin/sh\ntmux new-session -d -s restored\n' >"$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
    chmod +x "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
    touch "$HOME/.local/share/tmux/resurrect/last"
    SHTAFETA_RESTORE_WAIT=1 "$BIN" restore >/dev/null 2>&1
    check "clock jump: explicit resurrect restore, boot session removed" "restored" "$(tmux list-sessions -F '#{session_name}')"
    out=$("$BIN" restore 2>&1)
    check "restore is a no-op when tmux is running" "yes" "$([[ $out == *"already running"* ]] && echo yes)"
    tmux kill-server
    exit "$fails"
) || fails=$((fails + $?))

echo
if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "all tests passed"
