# shellcheck shell=bash
# sh-tafeta setup: guided setup of this machine, remote hosts and Windows integration.
# Sourced by bin/sh-tafeta for: setup, host, windows.

SSH_DIR="$HOME/.ssh"
SSH_INCLUDE="$SSH_DIR/config.d/sh-tafeta.conf"
# shellcheck disable=SC2016  # expanded by the remote shell
REMOTE_INSTALL_DIR='$HOME/.local/share/sh-tafeta'
ASSUME_YES=0

# ---------- prompts ----------

tty_ok() { [[ -r /dev/tty && -w /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

ask() {   # question default -> answer (from the terminal, or the default with --yes)
    local q=$1 def=${2:-} ans
    if ((ASSUME_YES)); then printf '%s' "$def"; return 0; fi
    tty_ok || die "no terminal to ask '$q': run it interactively or add --yes"
    printf '%s%s%s ' "${C_B}?${C_0} " "$q" "${def:+ [$def]}" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    printf '%s' "${ans:-$def}"
}

confirm() {   # question default(y|n)
    local a
    a=$(ask "$1 [$( [[ $2 == y ]] && echo Y/n || echo y/N )]" "")
    [[ -z $a ]] && a=$2
    [[ $a == [yYsS]* ]]
}

step() { printf '\n%s\n' "${C_B}$*${C_0}" >&2; }
okl()  { printf '  %s %s\n' "${C_GRN}ok${C_0}" "$*" >&2; }
kol()  { printf '  %s %s\n' "${C_RED}!!${C_0}" "$*" >&2; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
powershell() { "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" "$@"; }

# ---------- this machine ----------

ensure_packages() {   # pkg... (offers apt-get when something is missing)
    local missing=() p
    for p in "$@"; do have "$p" || missing+=("$p"); done
    ((${#missing[@]})) || { okl "${*}"; return 0; }
    kol "missing: ${missing[*]}"
    if have apt-get && confirm "install them with: sudo apt-get install -y ${missing[*]}" y; then
        sudo apt-get install -y "${missing[@]}" || die "apt-get failed"
    else
        die "install ${missing[*]} and run setup again"
    fi
}

ensure_tpm() {
    if tpm_dir >/dev/null; then
        okl "TPM (tmux plugin manager)"
    elif ! confirm "TPM (tmux plugin manager) is not installed: clone it from GitHub" y; then
        return 0
    fi
    install_tpm
}

setup_local() {
    local what
    if is_wsl; then what="WSL ${WSL_DISTRO_NAME:-}"; else what=$(uname -s); fi
    step "[1/3] This machine ($what)"
    ensure_packages tmux python3 git
    cmd_install >/dev/null 2>&1 || die "install failed: run '$PROG install' to see why"
    okl "sh-tafeta linked, Claude Code hooks and tmux config in place"
    ensure_tpm
    if tmux list-sessions >/dev/null 2>&1; then
        tmux source-file "$(tmux_conf_path)" >/dev/null 2>&1 && okl "tmux config reloaded"
    fi
}

# ---------- ssh helpers ----------

ssh_cfg() { ssh -G "$1" 2>/dev/null | awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }

# true if ~/.ssh/config (or anything it includes) defines this alias
# true if a Host line of ~/.ssh/config (or a file in config.d) names exactly this alias
ssh_alias_exists() {
    local -a files=() f
    for f in "$SSH_DIR/config" "$SSH_DIR"/config.d/*; do [[ -f $f ]] && files+=("$f"); done
    ((${#files[@]})) || return 1
    awk -v n="$1" 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == n) found = 1 } END { exit !found }' "${files[@]}"
}

ensure_ssh_include() {
    mkdir -p "$SSH_DIR/config.d"
    chmod 700 "$SSH_DIR" "$SSH_DIR/config.d"
    [[ -f $SSH_INCLUDE ]] || : >"$SSH_INCLUDE"
    chmod 600 "$SSH_INCLUDE"
    local conf="$SSH_DIR/config" real tmp
    [[ -e $conf ]] || { : >"$conf"; chmod 600 "$conf"; }
    real=$(readlink -f "$conf")
    grep -qF "config.d/sh-tafeta.conf" "$real" && return 0
    # Include must come before any Host block to apply everywhere
    tmp="$real.sh-tafeta.tmp"
    { echo "Include config.d/sh-tafeta.conf   # sh-tafeta"; cat "$real"; } >"$tmp"
    backup_file "$real"
    replace_file "$conf" "$tmp"
    okl "added 'Include config.d/sh-tafeta.conf' at the top of ~/.ssh/config"
}

ssh_block_write() {   # alias hostname user port identityfile
    ensure_ssh_include
    ssh_block_remove "$1"
    {
        echo "# BEGIN sh-tafeta $1"
        echo "Host $1"
        echo "    HostName $2"
        echo "    User $3"
        echo "    Port $4"
        [[ -n $5 ]] && echo "    IdentityFile \"$5\"" && echo "    IdentitiesOnly yes"
        echo "    ServerAliveInterval 30"
        echo "# END sh-tafeta $1"
    } >>"$SSH_INCLUDE"
}

ssh_block_remove() {
    [[ -f $SSH_INCLUDE ]] || return 0
    local tmp="$SSH_INCLUDE.tmp"
    awk -v b="# BEGIN sh-tafeta $1" -v e="# END sh-tafeta $1" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$SSH_INCLUDE" >"$tmp" && mv -f "$tmp" "$SSH_INCLUDE"
}

ssh_ok() { sshx -o BatchMode=yes -o ConnectTimeout=10 -- "$1" true >/dev/null 2>&1; }

# ---------- host add ----------

choose_key() {   # alias -> path of the private key to use
    local alias=$1 keys=() k i choice
    for k in "$SSH_DIR"/*.pub; do [[ -f $k ]] && keys+=("${k%.pub}"); done
    if ((!ASSUME_YES)); then
        {
            echo "  Which SSH key should '$alias' use?"
            for i in "${!keys[@]}"; do echo "    $((i + 1))) ${keys[$i]/#$HOME/\~}"; done
            echo "    n) a new dedicated key for this host (~/.ssh/sh-tafeta_$alias)"
        } >/dev/tty
    fi
    choice=$(ask "key" "n")
    if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#keys[@]})); then
        printf '%s' "${keys[$((choice - 1))]}"
        return 0
    fi
    k="$SSH_DIR/sh-tafeta_$alias"
    if [[ ! -f $k ]]; then
        # ssh-keygen asks for a passphrase itself (empty is allowed); --yes makes none
        if ((ASSUME_YES)); then ssh-keygen -q -t ed25519 -N "" -C "sh-tafeta $alias $(hostname)" -f "$k" </dev/null
        else ssh-keygen -q -t ed25519 -C "sh-tafeta $alias $(hostname)" -f "$k" </dev/tty >/dev/tty 2>&1; fi
        [[ -f $k ]] || die "ssh-keygen failed"
        okl "created ${k/#$HOME/\~} (ed25519)"
    fi
    printf '%s' "$k"
}

authorize_key() {   # alias key
    local alias=$1 key=$2
    ((!ASSUME_YES)) && have ssh-copy-id && confirm "copy the key with ssh-copy-id (asks for the server password once)" y &&
        ssh-copy-id -i "$key.pub" -o StrictHostKeyChecking=ask -o ClearAllForwardings=yes "$alias" </dev/tty >/dev/tty 2>&1 && ssh_ok "$alias" && return 0
    {
        echo
        echo "  Add this public key to the server (provider console, cloud-init, or ~/.ssh/authorized_keys):"
        echo
        sed 's/^/    /' "$key.pub"
        echo
    } >&2
    ask "press Enter when it is in place" "" >/dev/null
}

remote_probe() {   # alias -> "key value" lines
    # shellcheck disable=SC2016  # runs on the remote
    sshx -o BatchMode=yes -o ConnectTimeout=15 -- "$1" '
        printf "home %s\n" "$HOME"
        for c in tmux python3 git mosh-server apt-get; do command -v $c >/dev/null 2>&1 && echo "$c yes" || echo "$c no"; done
        c=$(command -v claude 2>/dev/null || ls "$HOME/.local/bin/claude" 2>/dev/null); [ -n "$c" ] && echo "claude yes" || echo "claude no"
        s=$(command -v sh-tafeta 2>/dev/null || ls "$HOME/.local/bin/sh-tafeta" 2>/dev/null)
        [ -n "$s" ] && echo "shtafeta $("$s" version 2>/dev/null | cut -d" " -f2)" || echo "shtafeta no"
        [ -d "$HOME/.claude" ] && echo "claude_dir yes" || echo "claude_dir no"
        for d in "$HOME"/*/; do printf "dir %s\n" "$(basename "$d")"; done' 2>/dev/null
}

# The files sh-tafeta is made of (git-tracked when this is a clone), never tests or local junk
ship_files() {
    if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # tracked or new-but-not-ignored files (a fresh clone, or a working copy before its first commit)
        git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard -- bin libexec tmux windows examples README.md LICENSE CHANGELOG.md
    else
        (cd "$REPO_DIR" && find bin libexec tmux windows examples README.md LICENSE CHANGELOG.md -type f ! -path '*/__pycache__/*' -print0 2>/dev/null)
    fi
}

remote_install() {   # alias — pushes THIS version (sync needs the same protocol on both sides)
    local alias=$1
    # unpack next to the old copy, then swap: no stale files, no half-installed state
    ship_files | tar -C "$REPO_DIR" --null -T - -cz |
        sshx -o BatchMode=yes -- "$alias" "set -e; d=$REMOTE_INSTALL_DIR; n=\"\$d.new.\$\$\"; rm -rf \"\$n\"; mkdir -p \"\$n\"; tar -xz -C \"\$n\"
            rm -rf \"\$d.old\"; [ -e \"\$d\" ] && mv \"\$d\" \"\$d.old\"; mv \"\$n\" \"\$d\"; rm -rf \"\$d.old\"
            \"\$d/bin/sh-tafeta\" install --with-tpm >/dev/null 2>&1 || \"\$d/bin/sh-tafeta\" install --with-tpm"
}

# Guess "local=remote" project roots: parents of the projects Claude Code knows
# here, matched by name (case-insensitive) against the folders in the remote home.
guess_path_map() {   # remote_home remote_dirs(newline list)
    local rhome=$1 rdirs=$2 roots top r
    roots=$(python3 -I - "$CLAUDE_DIR" "$HOME" "$REPO_DIR/libexec" <<'PY'
import sys, collections
sys.path.insert(0, sys.argv[3])
import shtafeta_agent as A
claude, home = sys.argv[1], sys.argv[2]
a = A.Agent(claude)
c = collections.Counter()
for p in a.op_discover():
    if p.startswith(home + "/"):
        c[p[len(home) + 1:].split("/")[0]] += 1
for top, _ in c.most_common():
    print(top)
PY
)
    while IFS= read -r top; do
        [[ -n $top ]] || continue
        r=$(grep -ixF -- "$top" <<<"$rdirs" | head -n1)
        [[ -n $r ]] && printf '%s\n' "\$HOME/$top=$rhome/$r"
    done <<<"$roots"
    printf '%s\n' "\$HOME=$rhome"
}

write_host_file() {   # name ssh_host transport map-lines
    local f="$CONFIG_DIR/hosts/$1.conf" m
    mkdir -p "$CONFIG_DIR/hosts"
    {
        echo "# sh-tafeta host config for '$1' — written by \`$PROG host add\`, edit freely"
        echo
        echo "SSH_HOST=$(printf '%q' "$2")"
        echo "TRANSPORT=$(printf '%q' "$3")      # ssh | mosh (Windows launcher)"
        echo
        echo "# local=remote path prefixes (longest match wins)"
        echo "PATH_MAP=("
        local l r
        while IFS= read -r m; do
            [[ -n $m ]] || continue
            l=${m%%=*} r=${m#*=}
            # keep $HOME literal on the local side so the file survives a home rename;
            # everything else is escaped: this file is sourced by bash
            # shellcheck disable=SC2016  # a literal $HOME is what we look for and write
            if [[ $l == '$HOME' || $l == '$HOME/'* ]]; then
                printf '    "$HOME"%s=%s\n' "$( [[ -n ${l#\$HOME} ]] && printf '%q' "${l#\$HOME}")" "$(printf '%q' "$r")"
            else
                printf '    %s=%s\n' "$(printf '%q' "$l")" "$(printf '%q' "$r")"
            fi
        done <<<"$4"
        echo ")"
        echo
        echo "# projects synced when you run \`$PROG sync $1\` outside any project"
        echo "PROJECTS=("
        echo ")"
        echo
        echo "# screenshots (sh-tafeta shot, Windows screenshot bridge)"
        echo "# SHOTS_DIR='\$HOME/.cache/sh-tafeta/screenshots'"
        echo "# SHOTS_KEEP_DAYS=30      # 0 = never delete"
    } >"$f"
    chmod 600 "$f"
}

cmd_host_add() {
    local name="" remote_install_ok=1 trust_key=0 opt_addr="" opt_user="" opt_port="" opt_key=""
    while (($#)); do
        case $1 in
            --yes|-y) ASSUME_YES=1 ;;
            --no-remote-install) remote_install_ok=0 ;;
            --trust-host-key) trust_key=1 ;;
            --address) opt_addr=${2:?}; shift ;;
            --user) opt_user=${2:?}; shift ;;
            --port) opt_port=${2:?}; shift ;;
            --key) opt_key=${2:?}; shift ;;          # path to a private key, or "new"
            -h|--help) echo "usage: $PROG host add NAME [--address A --user U --port P --key PATH|new] [--no-remote-install] [--yes [--trust-host-key]]"; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) name=$1 ;;
        esac
        shift
    done
    ((ASSUME_YES)) || tty_ok || die "host add asks questions: run it in a terminal, or pass --yes with --address/--user"
    [[ -n $name ]] || name=$(ask "name for the host (an ssh alias, e.g. devbox)" "")
    [[ $name =~ $HOST_RE ]] || die "invalid host name: '$name'"
    have ssh || die "ssh not found"
    mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

    step "Host '$name'"
    if [[ -z $opt_addr ]] && ssh_alias_exists "$name"; then
        okl "using the ssh alias '$name' from your ssh config ($(ssh_cfg "$name" user)@$(ssh_cfg "$name" hostname):$(ssh_cfg "$name" port))"
    else
        local hn user port key
        hn=${opt_addr:-$(ask "server address (IP or DNS name)" "")}
        [[ $hn =~ ^[A-Za-z0-9.:_-]+$ ]] || die "invalid address: '$hn' (use --address with --yes)"
        user=${opt_user:-$(ask "user on the server" "$USER")}
        [[ $user =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "invalid user: '$user'"
        port=${opt_port:-$(ask "ssh port" "22")}
        [[ $port =~ ^[0-9]+$ ]] || die "invalid port: '$port'"
        if [[ -n $opt_key && $opt_key != new ]]; then
            [[ -f $opt_key ]] || die "no such key: $opt_key"
            key=$opt_key
        else
            key=$(choose_key "$name")
            [[ -n $key && -f $key ]] || die "no SSH key to use"
        fi
        ssh_block_write "$name" "$hn" "$user" "$port" "${key/#$HOME/\~}"
        okl "ssh alias '$name' written to ${SSH_INCLUDE/#$HOME/\~}"
    fi

    if ! ssh_ok "$name"; then
        # first contact: let ssh show the host key fingerprint and ask. With --yes the key
        # is only trusted if you also pass --trust-host-key (trust on first use).
        if ((ASSUME_YES && trust_key)); then sshx -o StrictHostKeyChecking=accept-new -o BatchMode=yes -- "$name" true >/dev/null 2>&1
        elif ((ASSUME_YES)); then
            sshx -o StrictHostKeyChecking=yes -o BatchMode=yes -- "$name" true >/dev/null 2>&1 ||
                kol "the host key of '$name' is not known yet: connect once with 'ssh $name' and check it, or add --trust-host-key"
        elif ! ssh-keygen -F "$(ssh_cfg "$name" hostname)" >/dev/null 2>&1; then
            echo "  First connection: compare the fingerprint below with the server's (provider console)." >&2
            # only the host key question: keys only, no password prompt, errors hidden
            # (the login itself is sorted out right after)
            sshx -o StrictHostKeyChecking=ask -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
                -o KbdInteractiveAuthentication=no -- "$name" true </dev/tty 2>/dev/null >/dev/null; true
        fi
    fi
    if ! ssh_ok "$name"; then
        local k
        k=$(ssh_cfg "$name" identityfile | head -n1); k=${k/#\~/$HOME}
        [[ -f $k.pub ]] && authorize_key "$name" "$k"
    fi
    ssh_ok "$name" || die "cannot log in to '$name' with its key yet: once the key above is on the server, run the same command again (ssh -v $name shows details)"
    okl "key-based login works"

    local probe rhome rdirs
    probe=$(remote_probe "$name") || die "could not inspect '$name'"
    rhome=$(awk '$1 == "home" { $1 = ""; sub(/^ /, ""); print }' <<<"$probe")
    rdirs=$(awk '$1 == "dir" { $1 = ""; sub(/^ /, ""); print }' <<<"$probe")
    pv() { awk -v k="$1" '$1 == k { print $2 }' <<<"$probe"; }
    local missing=() c
    for c in tmux python3 git; do [[ $(pv "$c") == yes ]] || missing+=("$c"); done
    if ((${#missing[@]})); then
        kol "missing on $name: ${missing[*]}"
        if [[ $(pv apt-get) == yes ]] && confirm "install them there with sudo apt-get" y; then
            sshx -t -- "$name" "sudo apt-get install -y ${missing[*]}" </dev/tty >/dev/tty 2>&1 || kol "apt-get failed on $name"
        fi
    else
        okl "tmux, python3, git on $name"
    fi
    if [[ $(pv claude) == yes ]]; then okl "Claude Code on $name"; else kol "Claude Code not found on $name (sync needs ~/.claude there)"; fi

    if ((remote_install_ok)); then
        local rv
        rv=$(pv shtafeta)
        if [[ $rv == "$VERSION" ]]; then okl "sh-tafeta $rv already on $name"
        elif confirm "install sh-tafeta $VERSION on $name too (sessions there survive reboots, sync needs the same version)" y; then
            if remote_install "$name"; then okl "sh-tafeta $VERSION installed on $name"; else kol "remote install failed"; fi
        fi
    fi

    local transport=ssh
    if [[ $(pv mosh-server) == yes ]] && have mosh; then
        if confirm "use mosh for the terminal tabs (survives sleep and roaming; needs UDP 60000-61000 open)" y; then transport=mosh; fi
    fi

    local map
    map=$(guess_path_map "$rhome" "$rdirs")
    {
        echo "  Path mapping (local = $name):"
        sed 's/^/    /; s/=/  =  /' <<<"$map"
    } >&2
    confirm "use this mapping (you can edit ~/.config/sh-tafeta/hosts/$name.conf later)" y || map="\$HOME=$rhome"
    write_host_file "$name" "$name" "$transport" "$map"
    okl "wrote ${CONFIG_DIR/#$HOME/\~}/hosts/$name.conf"

    if [[ $(pv claude_dir) == yes ]]; then
        if "$SELF" sync "$name" --check; then okl "sync check passed"; else kol "sync check failed"; fi
    fi
    mkdir -p "$STATE_DIR" && printf '%s' "$name" >"$STATE_DIR/last-added-host"
}

cmd_host_remove() {
    local name=${1:-}
    [[ $name =~ $HOST_RE ]] || die "usage: $PROG host remove NAME"
    local key="$SSH_DIR/sh-tafeta_$name"
    if [[ -f $key.pub ]] && ssh_ok "$name" && confirm "remove sh-tafeta's key for '$name' from the server's authorized_keys" y; then
        local pub
        pub=$(awk '{ print $2 }' "$key.pub")
        [[ $pub =~ ^[A-Za-z0-9+/=]+$ ]] || die "unexpected public key format in $key.pub"
        # grep exits 1 when nothing is left: fine; anything else aborts before touching the file
        sshx -o BatchMode=yes -- "$name" "set -e; f=\$HOME/.ssh/authorized_keys; [ -f \"\$f\" ] || exit 0
            t=\$(mktemp \"\$f.XXXXXX\"); grep -vF -- $(shq "$pub") \"\$f\" > \"\$t\" || [ \$? -eq 1 ]
            chmod 600 \"\$t\"; mv -f \"\$t\" \"\$f\"" &&
            okl "key removed from $name"
    fi
    ssh_block_remove "$name"
    rm -f "$CONFIG_DIR/hosts/$name.conf"
    if [[ -f $key ]] && confirm "delete the local key ${key/#$HOME/\~}" y; then rm -f "$key" "$key.pub"; fi
    if is_wsl; then
        remove_shortcuts "$name"
        windows_ps -Target "$name" -Remove >/dev/null 2>&1
        load_windows_conf
        if [[ $SHOTS_TARGET == "$name" ]]; then
            SHOTS_MODE=off SHOTS_TARGET=""
            save_windows_conf
            windows_ps -StopShots >/dev/null 2>&1
            okl "screenshot bridge turned off (it delivered to '$name')"
        fi
    fi
    okl "host '$name' removed"
}

cmd_host_list() {
    local f n
    printf '%s\n' "${C_B}NAME            SSH                                  TRANSPORT${C_0}"
    for f in "$CONFIG_DIR"/hosts/*.conf; do
        [[ -f $f ]] || continue
        n=$(basename "$f" .conf)
        printf '%-15s %-36s %s\n' "$n" "$(ssh_cfg "$n" user)@$(ssh_cfg "$n" hostname):$(ssh_cfg "$n" port)" \
            "$(awk -F= '$1 == "TRANSPORT" { split($2, a, " "); print a[1] }' "$f")"
    done
}

cmd_host() {
    local sub=${1:-list}
    (($#)) && shift
    case $sub in
        add) cmd_host_add "$@" ;;
        remove|rm) cmd_host_remove "$@" ;;
        list|ls) cmd_host_list ;;
        *) die "usage: $PROG host add|remove|list [NAME]" ;;
    esac
}

# ---------- windows ----------
#
# Shortcuts start `wsl.exe ... sh-tafeta open TARGET` (see windows/sh-tafeta.ps1 for
# why never PowerShell directly); the options live in windows.conf.

WIN_CONF="$CONFIG_DIR/windows.conf"
PS_EXE=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

load_windows_conf() {
    AUTOSTART_TABS=0 SHOTS_MODE=off SHOTS_TARGET="" SHOTS_FROM=both SHOTS_FOLDER=""
    # shellcheck source=/dev/null
    [[ -f $WIN_CONF ]] && . "$WIN_CONF"
    [[ $SHOTS_MODE =~ ^(off|window|background)$ ]] || SHOTS_MODE=off
    [[ $SHOTS_FROM =~ ^(both|clipboard|folder)$ ]] || SHOTS_FROM=both
    return 0
}

save_windows_conf() {
    mkdir -p "$CONFIG_DIR"
    {
        echo "# sh-tafeta Windows integration — written by \`$PROG setup\`, edit freely"
        echo "AUTOSTART_TABS=$(printf '%q' "$AUTOSTART_TABS")     # 1 = reopen the WSL tabs at login"
        echo "SHOTS_MODE=$(printf '%q' "$SHOTS_MODE")        # screenshot bridge: off | window | background"
        echo "SHOTS_TARGET=$(printf '%q' "$SHOTS_TARGET")      # where Claude Code runs"
        echo "SHOTS_FROM=$(printf '%q' "$SHOTS_FROM")        # clipboard | folder | both"
        echo "SHOTS_FOLDER=$(printf '%q' "$SHOTS_FOLDER")      # Windows folder to watch (empty = none)"
    } >"$WIN_CONF"
    chmod 600 "$WIN_CONF"
}

windows_ps() {   # args for windows/sh-tafeta.ps1
    is_wsl || die "the Windows integration runs from WSL"
    local ps1
    ps1=$(wslpath -w "$REPO_DIR/windows/sh-tafeta.ps1") || die "wslpath failed"
    (cd /mnt/c && "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$ps1" -Distro "${WSL_DISTRO_NAME:-}" -NoPause "$@") | tr -d '\r'
}

host_transport() {
    local f="$CONFIG_DIR/hosts/$1.conf" t=""
    [[ -f $f ]] && t=$(awk -F= '$1 == "TRANSPORT" { split($2, a, " "); print a[1] }' "$f")
    [[ $t == mosh ]] && echo mosh || echo ssh
}

shots_ps_args() {
    local from=$SHOTS_FROM
    [[ -z $SHOTS_FOLDER && $from == both ]] && from=clipboard
    printf '%s\n' -ShotsTarget "$SHOTS_TARGET" -ShotsFrom "$from"
    [[ -n $SHOTS_FOLDER && $from != clipboard ]] && printf '%s\n' -ShotsFolder "$SHOTS_FOLDER"
    return 0
}

# What a desktop shortcut runs: open one Windows Terminal tab per tmux session of TARGET
# (and, if the screenshot bridge belongs to this window, keep running as the bridge).
cmd_open() {
    local target=${1:-wsl} nopause=0 list=0
    [[ ${2:-} == --no-pause ]] && nopause=1
    [[ ${2:-} == --list ]] && list=1
    [[ $target == wsl || $target =~ $HOST_RE ]] || die "usage: $PROG open wsl|HOST [--list]"
    is_wsl || die "open runs from WSL (it drives Windows Terminal)"
    load_windows_conf
    local -a a=(-NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$REPO_DIR/windows/sh-tafeta.ps1")" -Target "$target")
    [[ -n ${WSL_DISTRO_NAME:-} ]] && a+=(-Distro "$WSL_DISTRO_NAME")
    [[ $target != wsl ]] && a+=(-Transport "$(host_transport "$target")")
    ((nopause)) && a+=(-NoPause)
    ((list)) && a+=(-ListOnly -NoPause)
    if ((!list)) && [[ $SHOTS_MODE == window && $SHOTS_TARGET == "$target" ]]; then
        local x
        a+=(-Shots)
        while IFS= read -r x; do a+=("$x"); done < <(shots_ps_args)
    fi
    cd /mnt/c || exit 1
    exec "$PS_EXE" "${a[@]}"
}

# Start the screenshot bridge hidden, detached from this shell
shots_start_background() {
    local -a a=() x
    while IFS= read -r x; do a+=("$x"); done < <(shots_ps_args)
    # options go through the environment: no quoting through cmd lines
    # shellcheck disable=SC2016
    local ps='$q = [char]34
$a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ($q + $env:SHT_PS1 + $q), "-ShotsOnly", "-ShotsTarget", $env:SHT_ST, "-ShotsFrom", $env:SHT_FROM)
if ($env:SHT_DISTRO) { $a += @("-Distro", $env:SHT_DISTRO) }
if ($env:SHT_SF) { $a += @("-ShotsFolder", ($q + $env:SHT_SF + $q)) }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $a'
    local from=$SHOTS_FROM folder=$SHOTS_FOLDER
    while [[ $folder == *\\ ]]; do folder=${folder%\\}; done   # a trailing \ would escape the closing quote
    [[ -z $folder && $from == both ]] && from=clipboard
    (cd /mnt/c && SHT_PS1=$(wslpath -w "$REPO_DIR/windows/sh-tafeta.ps1") SHT_ST=$SHOTS_TARGET SHT_FROM=$from \
        SHT_SF=$([[ $from != clipboard ]] && printf '%s' "$folder") SHT_DISTRO=${WSL_DISTRO_NAME:-} \
        WSLENV=${WSLENV:+$WSLENV:}SHT_PS1:SHT_ST:SHT_FROM:SHT_SF:SHT_DISTRO \
        "$PS_EXE" -NoProfile -Command "${ps//\"/\'}" </dev/null >/dev/null 2>&1)
}

# Shortcuts are written from WSL as plain .lnk files (libexec/mklnk.py) pointing to
# wsl.exe. Creating them through PowerShell's COM API — especially ones that run
# "powershell -ExecutionPolicy Bypass" — is what antivirus software (Bitdefender, at
# least) blocks as malware persistence. If writing still fails, we print the line to
# paste into New > Shortcut.
win_folder() {   # Desktop | Startup -> WSL path
    local w
    w=$("$PS_EXE" -NoProfile -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; [Environment]::GetFolderPath('$1')" 2>/dev/null | tr -d '\r')
    [[ -n $w ]] && wslpath "$w"
}

shortcut_label() { [[ $1 == wsl ]] && echo WSL || echo "$1"; }

make_shortcut() {   # desktop TARGET | startup
    local kind=$1 target=${2:-} dir name cmd icon show=1
    if [[ $kind == startup ]]; then
        dir=$(win_folder Startup) name="sh-tafeta.lnk" cmd=autostart icon='C:\Windows\System32\wsl.exe' show=7
    else
        dir=$(win_folder Desktop) name="sh-tafeta $(shortcut_label "$target").lnk" cmd="open $target"
        if [[ $target == wsl ]]; then icon='C:\Windows\System32\wsl.exe'; else icon='C:\Windows\System32\mstsc.exe'; fi
    fi
    [[ -d $dir ]] || { kol "Windows folder not found"; return 1; }
    local args="${WSL_DISTRO_NAME:+-d $WSL_DISTRO_NAME }-e bash -lc \"sh-tafeta $cmd\""
    if python3 -I "$REPO_DIR/libexec/mklnk.py" "$dir/$name" 'C:\Windows\System32\wsl.exe' "$args" "$icon" 0 "$show" \
        'sh-tafeta: reopen your tmux and Claude Code sessions' 2>/dev/null && [[ -f $dir/$name ]]; then
        okl "shortcut: $name"
        return 0
    fi
    kol "could not write $name (antivirus?)"
    if [[ $kind == startup ]]; then autostart_howto; else shortcut_howto "$target"; fi
    return 1
}

remove_shortcuts() {   # TARGET|* ; startup too when TARGET is '*'
    local desk start t f
    desk=$(win_folder Desktop) start=$(win_folder Startup)
    if [[ $1 == '*' ]]; then
        for f in "$desk"/sh-tafeta\ *.lnk "$start"/sh-tafeta*.lnk; do [[ -e $f ]] && rm -f "$f" && okl "removed ${f##*/}"; done
    else
        t=$(shortcut_label "$1")
        for f in "$desk/sh-tafeta $t.lnk" "$desk/sh-tafeta - $t.lnk"; do [[ -e $f ]] && rm -f "$f" && okl "removed ${f##*/}"; done
    fi
    return 0
}

shortcut_cmd() { printf 'C:\\Windows\\System32\\wsl.exe%s -e bash -lc "sh-tafeta %s"' "${WSL_DISTRO_NAME:+ -d $WSL_DISTRO_NAME}" "$1"; }

shortcut_howto() {   # target
    local label
    label=$(shortcut_label "$1")
    {
        echo "  Desktop shortcut 'sh-tafeta $label': right-click the desktop > New > Shortcut, paste"
        echo
        echo "      $(shortcut_cmd "open $1")"
        echo
        echo "  then Next, and name it 'sh-tafeta $label'."
    } >&2
}

autostart_howto() {
    {
        echo "  Login entry: Win+R > shell:startup > right-click > New > Shortcut, paste"
        echo
        echo "      $(shortcut_cmd autostart)"
        echo
        echo "  name it 'sh-tafeta' (Properties > Run: Minimized keeps it out of the way)."
    } >&2
}

# What the login entry runs
cmd_autostart() {
    is_wsl || die "autostart runs from WSL"
    load_windows_conf
    [[ $SHOTS_MODE == background && -n $SHOTS_TARGET ]] && shots_start_background
    if [[ $AUTOSTART_TABS == 1 ]]; then cmd_open wsl --no-pause; fi
    return 0
}

# Make the Windows side match windows.conf: background bridge, login entry (by hand)
apply_windows_conf() {
    local start
    start=$(win_folder Startup)
    if [[ $AUTOSTART_TABS == 1 || $SHOTS_MODE == background ]]; then
        make_shortcut startup
    else
        [[ -e $start/sh-tafeta.lnk ]] && rm -f "$start/sh-tafeta.lnk" && okl "login entry removed"
    fi
    windows_ps -StopShots >/dev/null 2>&1
    if [[ $SHOTS_MODE == background && -n $SHOTS_TARGET ]]; then
        shots_start_background && okl "screenshot bridge running in the background ($SHOTS_TARGET)"
    fi
    return 0
}

windows_shots() {
    local target=${1:-} folder="" mode=window
    (($#)) && shift
    while (($#)); do
        case $1 in
            --folder) folder=${2:?}; shift ;;
            --background) mode=background ;;
            --off) mode=off ;;
            --stop) windows_ps -StopShots; return ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    load_windows_conf
    if [[ $mode != off ]]; then
        [[ $target == wsl || $target =~ $HOST_RE ]] || die "usage: $PROG windows shots TARGET [--folder WINPATH] [--background] | --off | --stop"
        SHOTS_TARGET=$target
        [[ -n $folder ]] && SHOTS_FOLDER=$folder
    fi
    SHOTS_MODE=$mode
    save_windows_conf
    apply_windows_conf
    [[ $mode == window ]] && make_shortcut desktop "$SHOTS_TARGET"
    okl "screenshot bridge: $SHOTS_MODE${SHOTS_TARGET:+ -> $SHOTS_TARGET}"
}

cmd_windows() {
    local sub=${1:-} t
    (($#)) && shift
    case $sub in
        shortcut)   for t in "${@:-wsl}"; do make_shortcut desktop "$t"; done ;;
        profile)    for t in "${@:-wsl}"; do windows_ps -Target "$t" -InstallProfile; done ;;
        autostart)  load_windows_conf; AUTOSTART_TABS=$([[ ${1:-on} == off ]] && echo 0 || echo 1); save_windows_conf; apply_windows_conf ;;
        shots)      windows_shots "$@" ;;
        remove)     remove_shortcuts "${1:-*}"; windows_ps -Target "${1:-*}" -Remove >/dev/null ;;
        *) die "usage: $PROG windows shortcut|profile [TARGET...] | autostart [on|off] | shots TARGET [--folder WINPATH] [--background] | shots --off|--stop | remove [TARGET]" ;;
    esac
}

windows_default_shots_folder() {
    "$PS_EXE" -NoProfile -Command "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'" 2>/dev/null | tr -d '\r'
}

yn() { [[ $1 == 1 || $1 == y ]] && echo y || echo n; }

setup_windows() {
    step "[3/3] Windows"
    if ! is_wsl || [[ ${SHTAFETA_TEST_NO_WINDOWS:-} == 1 ]]; then okl "not WSL: nothing to do"; return 0; fi
    load_windows_conf
    local first=1 t
    [[ -f $WIN_CONF ]] && first=0
    local desk
    desk=$(win_folder Desktop)

    for t in wsl "${HOSTS_FOR_WINDOWS[@]}"; do
        local label
        label=$(shortcut_label "$t")
        if [[ -e "$desk/sh-tafeta $label.lnk" ]]; then
            okl "desktop shortcut 'sh-tafeta $label'"
        elif confirm "desktop shortcut 'sh-tafeta $label' (a tab per tmux session)" y; then
            make_shortcut desktop "$t"
        fi
    done

    echo >&2
    echo "  Screenshots — Claude in WSL reads them with Alt+V, nothing to set up. Claude on a" >&2
    echo "  server can't see your clipboard: the bridge sends each Win+Shift+S there and leaves" >&2
    echo "  its path on the clipboard, so Ctrl+V in Claude is enough." >&2
    local def=n
    ((${#HOSTS_FOR_WINDOWS[@]})) && def=y
    ((first)) || def=$([[ $SHOTS_MODE != off ]] && echo y || echo n)
    if confirm "screenshot bridge on" "$def"; then
        local to folder
        to=$(ask "server that receives the screenshots" "${SHOTS_TARGET:-${HOSTS_FOR_WINDOWS[0]:-wsl}}")
        [[ $to == wsl || $to =~ $HOST_RE ]] || die "invalid target: $to"
        SHOTS_TARGET=$to
        folder=$(ask "also send images saved in this Windows folder ('-' = clipboard only)" "${SHOTS_FOLDER:--}")
        if [[ $folder == - ]]; then SHOTS_FOLDER=""; SHOTS_FROM=clipboard; else SHOTS_FOLDER=$folder; SHOTS_FROM=both; fi
        if confirm "keep it always on from login (no = only while the 'sh-tafeta $(shortcut_label "$to")' window is open)" "$( [[ $SHOTS_MODE == background ]] && echo y || echo n)"; then
            SHOTS_MODE=background
        else
            SHOTS_MODE=window
            [[ -e "$desk/sh-tafeta $(shortcut_label "$to").lnk" ]] || make_shortcut desktop "$to"
        fi
    else
        SHOTS_MODE=off
    fi

    echo >&2
    if confirm "reopen your WSL sessions in Windows Terminal when you log in to Windows" "$(yn "$AUTOSTART_TABS")"; then
        AUTOSTART_TABS=1
    else
        AUTOSTART_TABS=0
    fi
    local frag
    # shellcheck disable=SC2016  # a PowerShell variable
    frag=$(wslpath "$("$PS_EXE" -NoProfile -Command '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $env:LOCALAPPDATA' 2>/dev/null | tr -d '\r')")/Microsoft/Windows\ Terminal/Fragments/sh-tafeta/sh-tafeta.json
    if confirm "also list them in the Windows Terminal dropdown menu" "$([[ -f $frag ]] && echo y || echo n)"; then
        for t in wsl "${HOSTS_FOR_WINDOWS[@]}"; do windows_ps -Target "$t" -InstallProfile >&2; done
    elif [[ -f $frag ]]; then
        rm -f "$frag" && rmdir "$(dirname "$frag")" 2>/dev/null
        okl "Windows Terminal dropdown entries removed"
    fi
    save_windows_conf
    apply_windows_conf
    okl "saved in ${WIN_CONF/#$HOME/\~}"
}

# ---------- setup ----------

cmd_setup() {
    while (($#)); do
        case $1 in
            --yes|-y) ASSUME_YES=1 ;;
            -h|--help) echo "usage: $PROG setup [--yes]"; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    ((ASSUME_YES)) || tty_ok || die "setup is interactive: run it in a terminal (or add --yes for the defaults)"
    printf '%s\n' "${C_B}sh-tafeta $VERSION setup${C_0}  — safe to re-run, it only changes what you say yes to" >&2
    setup_local

    step "[2/3] Remote hosts"
    HOSTS_FOR_WINDOWS=()
    local f n
    for f in "$CONFIG_DIR"/hosts/*.conf; do
        [[ -f $f ]] || continue
        n=$(basename "$f" .conf)
        okl "configured: $n"
        HOSTS_FOR_WINDOWS+=("$n")
    done
    while ((!ASSUME_YES)) && confirm "add a remote host$( ((${#HOSTS_FOR_WINDOWS[@]})) && echo ' (another)')" "$( ((${#HOSTS_FOR_WINDOWS[@]})) && echo n || echo y)"; do
        rm -f "$STATE_DIR/last-added-host"
        # a subshell, so a failed host doesn't end the whole setup
        ( cmd_host_add ) || { kol "host not added"; continue; }
        n=$(cat "$STATE_DIR/last-added-host" 2>/dev/null)
        [[ -n $n && -f $CONFIG_DIR/hosts/$n.conf ]] && HOSTS_FOR_WINDOWS+=("$n")
    done

    setup_windows
    printf '\n%s\n' "${C_GRN}Done.${C_0} '$PROG doctor' checks everything, '$PROG setup' changes it." >&2
}
