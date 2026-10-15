"""sh-tafeta sync agent.

The same code runs on both machines: imported in-process on the local side, and
sent over ssh (base64, nothing installed) on the remote side, where it serves a
JSON-lines protocol on stdin/stdout. It only ever touches files inside the roots
the orchestrator opens, and it refuses roots that would expose a home directory.

Writes are compare-and-swap: the caller says which content hash it expects at the
destination, and the agent re-checks it right before replacing or appending.
"""

import base64
import errno
import fnmatch
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

PROTOCOL = 2
CHUNK = 1 << 20

# Never synced as source, whatever the user's excludes say.
HARD_EXCLUDES = [
    ".git", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".claude",
    ".claude.json", ".netrc", ".git-credentials", ".pgpass", ".npmrc", ".pypirc",
    ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
    ".sht-tmp-*", "*.sync-conflict-*",
]
# Only these parts of ~/.claude travel with --with-config (settings.json does not:
# it can hold API keys in "env" and hooks that execute commands).
CONFIG_ALLOW = ["CLAUDE.md", "keybindings.json", "agents/", "commands/", "skills/", "output-styles/"]
CLAUDE_SKIP = [".sht-tmp-*", "*.sync-conflict-*"]
# Never a project (nor a parent of one): what lives there is credentials or code that runs.
SENSITIVE_HOME_DIRS = [".ssh", ".gnupg", ".config", ".local", ".aws", ".azure", ".kube", ".docker",
                       ".password-store", ".cache"]
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
SID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class AgentError(Exception):
    def __init__(self, msg, kind="error"):
        super().__init__(msg)
        self.kind = kind


def encode_path(path):
    """Claude Code's project folder name: every non [A-Za-z0-9] UTF-16 code unit -> '-'."""
    out = []
    for ch in path:
        if ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9"):
            out.append(ch)
        else:
            out.append("-" * (len(ch.encode("utf-16-le")) // 2))
    return "".join(out)


def sha256_file(path, limit=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        left = limit
        while True:
            n = CHUNK if left is None else min(CHUNK, left)
            if n == 0:
                break
            b = f.read(n)
            if not b:
                break
            h.update(b)
            if left is not None:
                left -= len(b)
    return h


def is_under(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def atomic_write(path, data, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%s" % (path, uuid.uuid4().hex[:8])
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def claude_running():
    """True if a `claude` process runs on this machine."""
    forced = os.environ.get("SHTAFETA_TEST_CLAUDE_RUNNING")
    if forced in ("0", "1"):
        return forced == "1"
    try:
        for p in os.listdir("/proc"):
            if not p.isdigit():
                continue
            try:
                with open("/proc/%s/comm" % p) as f:
                    if f.read().strip() == "claude":
                        return True
            except OSError:
                pass
        return False
    except OSError:
        try:
            return subprocess.call(["pgrep", "-x", "claude"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
        except OSError:
            return False


class Root:
    def __init__(self, rid, scope, project, path, excludes):
        self.id = rid
        self.scope = scope            # claude | source | config
        self.project = project        # project path on this machine ('' for config)
        self.path = path              # directory being synced
        self.real = os.path.realpath(path)
        self.excludes = excludes


class Agent:
    def __init__(self, claude_dir=None):
        os.umask(0o077)
        self.home = os.path.realpath(os.path.expanduser("~"))
        self.claude_dir = os.path.realpath(os.path.expanduser(
            claude_dir or os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"))
        st = os.environ.get("SHTAFETA_STATE_DIR") or os.path.join(
            os.environ.get("XDG_STATE_HOME") or os.path.join(self.home, ".local", "state"), "sh-tafeta")
        self.state = os.path.realpath(os.path.expanduser(st))
        try:
            if os.path.isdir(self.state) and os.stat(self.state).st_uid == os.getuid():
                os.chmod(self.state, 0o700)   # also a dir made by an older version
        except OSError:
            pass
        self.roots = {}
        self.puts = {}
        self.lock_dir = os.path.join(self.state, "sync.lock.d")
        self.locked = False

    # ---------- identity ----------

    def machine_id(self):
        p = os.path.join(self.state, "machine-id")
        try:
            with open(p) as f:
                mid = f.read().strip()
            if re.match(r"^[0-9a-f]{32}$", mid):
                return mid
        except OSError:
            pass
        mid = uuid.uuid4().hex
        atomic_write(p, (mid + "\n").encode())
        return mid

    def op_hello(self, protocol=PROTOCOL):
        if protocol != PROTOCOL:
            raise AgentError("protocol mismatch: local %s, remote %s (update sh-tafeta on both machines)" % (protocol, PROTOCOL))
        return {
            "home": self.home,
            "hostname": socket.gethostname().split(".")[0],
            "machine_id": self.machine_id(),
            "claude_dir": self.claude_dir,
            "claude_dir_exists": os.path.isdir(self.claude_dir),
            "state_dir": self.state,
            "time": time.time(),
            "claude_running": claude_running(),
            "python": sys.version.split()[0],
        }

    # ---------- lock ----------

    def op_lock(self, owner, break_lock=False):
        os.makedirs(self.state, mode=0o700, exist_ok=True)
        info = {"pid": os.getpid(), "owner": owner, "time": time.time(), "host": socket.gethostname()}
        broke = None
        for _ in range(2):
            try:
                os.mkdir(self.lock_dir, 0o700)
                atomic_write(os.path.join(self.lock_dir, "info.json"), json.dumps(info).encode())
                self.locked = True
                return {"broke": broke}
            except FileExistsError:
                try:
                    with open(os.path.join(self.lock_dir, "info.json")) as f:
                        old = json.load(f)
                except (OSError, ValueError):
                    old = {}
                if not old:
                    # another sync may have just created the dir and not written info.json yet
                    try:
                        young = time.time() - os.stat(self.lock_dir).st_mtime < 60
                    except OSError:
                        young = False
                    stale = not young
                else:
                    stale = not pid_alive(int(old.get("pid", 0))) or time.time() - old.get("time", 0) > 6 * 3600
                if not (stale or break_lock):
                    raise AgentError("another sync is running on %s (%s, pid %s); if it is not, use --break-lock"
                                     % (socket.gethostname(), old.get("owner", "?"), old.get("pid", "?")), "locked")
                broke = old
                shutil.rmtree(self.lock_dir, ignore_errors=True)
        raise AgentError("cannot take the sync lock in %s" % self.lock_dir)

    def op_unlock(self):
        if self.locked:
            shutil.rmtree(self.lock_dir, ignore_errors=True)
            self.locked = False
        return True

    # ---------- roots ----------

    def forbidden(self, project):
        """Why a project path must never be synced, or None."""
        if not project.startswith("/") or os.path.normpath(project) != project or "\n" in project:
            return "not a clean absolute path"
        real = os.path.realpath(project)
        for p in {project, real}:
            if p == "/" or is_under(self.home, p):
                return "it is the home directory (or one of its parents)"
            if is_under(p, self.claude_dir) or is_under(self.claude_dir, p):
                return "it overlaps the Claude Code config dir"
            if is_under(p, self.state) or is_under(self.state, p):
                return "it overlaps the sh-tafeta state dir"
            for d in SENSITIVE_HOME_DIRS:
                s = os.path.join(self.home, d)
                if is_under(p, s) or is_under(s, p):
                    return "it overlaps %s (credentials, config or programs)" % s
        return None

    def op_open(self, rid, scope, project="", excludes=None):
        if scope == "config":
            path = self.claude_dir
        else:
            why = self.forbidden(project)
            if why:
                raise AgentError("refusing to sync %s on %s: %s" % (project, socket.gethostname(), why), "forbidden")
            path = os.path.join(self.claude_dir, "projects", encode_path(project)) if scope == "claude" else project
        root = Root(rid, scope, project, path, list(excludes or []))
        self.roots[rid] = root
        res = {"path": path, "exists": os.path.isdir(path)}
        if scope == "source" and res["exists"]:
            res["git"] = self._git_head(path)
        return res

    def _git_head(self, path):
        try:
            out = subprocess.check_output(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD", "HEAD"],
                                          stderr=subprocess.DEVNULL, timeout=10).decode().split()
            return {"branch": out[0], "commit": out[1][:10]} if len(out) == 2 else None
        except (OSError, subprocess.SubprocessError):
            return None

    def _root(self, rid):
        try:
            return self.roots[rid]
        except KeyError:
            raise AgentError("unknown root %r" % rid)

    @staticmethod
    def _clean_rel(rel):
        """A relative path we are willing to handle at all."""
        if not isinstance(rel, str) or not rel or rel.startswith("/") or CONTROL_RE.search(rel):
            return False
        try:
            rel.encode("utf-8")
        except UnicodeEncodeError:   # undecodable file name (surrogateescape)
            return False
        return not any(p in ("", ".", "..") for p in rel.split("/"))

    def _allowed(self, root, rel):
        """The scope rules. Applied to what we list AND to what we accept to write, so a
        peer cannot make us write a file that we would never have sent."""
        if not self._clean_rel(rel):
            return False
        if root.scope == "config":
            return any(rel == a or (a.endswith("/") and rel.startswith(a)) for a in CONFIG_ALLOW)
        if root.scope == "source":
            return not self._excluded(rel, HARD_EXCLUDES + root.excludes)
        return not self._excluded(rel, CLAUDE_SKIP)

    def op_allowed(self, rid, rels):
        root = self._root(rid)
        return [r for r in rels if not self._allowed(root, r)]

    def _target(self, root, rel, must_exist=True, check_allowed=True):
        """Absolute path of rel inside root, refusing anything that escapes it."""
        if not self._clean_rel(rel):
            raise AgentError("bad path %r" % rel)
        if not must_exist and check_allowed and not self._allowed(root, rel):
            raise AgentError("%r is outside what %s syncs here" % (rel, root.scope), "notallowed")
        full = os.path.join(root.path, rel)
        if not must_exist and not os.path.isdir(root.path):
            # first write into a project this machine hasn't seen yet: the root itself was
            # validated when it was opened, so create it and compare against it from now on
            os.makedirs(root.path, mode=0o700, exist_ok=True)
            root.real = os.path.realpath(root.path)
        probe = full if must_exist else os.path.dirname(full)
        while not must_exist and not os.path.lexists(probe):
            probe = os.path.dirname(probe)
        if not is_under(os.path.realpath(probe), root.real):
            raise AgentError("path %r escapes %s" % (rel, root.path))
        if must_exist:
            st = os.lstat(full)
            if not stat.S_ISREG(st.st_mode):
                raise AgentError("%r is not a regular file" % rel)
        return full

    # ---------- scan ----------

    def _excluded(self, rel, patterns):
        name = rel.rsplit("/", 1)[-1]
        for pat in patterns:
            if pat.endswith("/"):
                pat = pat[:-1]
            if fnmatch.fnmatch(name, pat) or fnmatch.fnmatch(rel, pat):
                return True
            if any(fnmatch.fnmatch(part, pat) for part in rel.split("/")[:-1]):
                return True
        return False

    def _list(self, root):
        base = root.path
        if not os.path.isdir(base):
            return []
        files = []
        if root.scope == "source" and os.path.isdir(os.path.join(base, ".git")):
            # git knows .gitignore, .git/info/exclude and the global excludesFile
            try:
                out = subprocess.check_output(
                    ["git", "-C", base, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                    stderr=subprocess.DEVNULL, timeout=120)
                files = [f for f in out.decode("utf-8", "surrogateescape").split("\0") if f]
            except (OSError, subprocess.SubprocessError):
                files = None
        else:
            files = None
        if files is None:
            files = []
            for d, dirs, names in os.walk(base, followlinks=False):
                reld = os.path.relpath(d, base)
                reld = "" if reld == "." else reld + "/"
                keep = []
                for x in dirs:
                    if root.scope != "claude" and self._excluded(reld + x, HARD_EXCLUDES + root.excludes):
                        continue
                    keep.append(x)
                dirs[:] = keep
                files.extend(reld + n for n in names)
        return [rel for rel in files if self._allowed(root, rel)]

    def _clean_stale_tmp(self, root):
        """Temp files of a sync that died. Only while holding the lock: then no other
        sync can be writing into this root."""
        if not self.locked or not os.path.isdir(root.path):
            return 0
        n = 0
        for d, dirs, names in os.walk(root.path):
            dirs[:] = [x for x in dirs if x != ".git" and x != "node_modules"]
            for name in names:
                if name.startswith(".sht-tmp-"):
                    try:
                        os.unlink(os.path.join(d, name))
                        n += 1
                    except OSError:
                        pass
        return n

    def op_scan(self, rid):
        root = self._root(rid)
        cleaned = self._clean_stale_tmp(root)
        cache_path = os.path.join(self.state, "hashcache",
                                  hashlib.sha1(("%s\0%s" % (root.scope, root.path)).encode()).hexdigest() + ".json")
        try:
            with open(cache_path) as f:
                cache = json.load(f)
        except (OSError, ValueError):
            cache = {}
        entries, newcache, skipped = {}, {}, 0
        for rel in self._list(root):
            full = os.path.join(root.path, rel)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                skipped += 1
                continue
            key = [st.st_size, st.st_mtime_ns, st.st_ino]
            c = cache.get(rel)
            if c and c[:3] == key:
                sha = c[3]
            else:
                try:
                    sha = sha256_file(full).hexdigest()
                except OSError:
                    continue
            newcache[rel] = key + [sha]
            entries[rel] = {"size": st.st_size, "mtime": st.st_mtime, "sha": sha, "mode": stat.S_IMODE(st.st_mode)}
        atomic_write(cache_path, json.dumps(newcache).encode())
        return {"files": entries, "skipped_non_regular": skipped, "cleaned_tmp": cleaned}

    def op_live_sessions(self):
        """Session ids that are open in a Claude Code process on this machine: on its
        command line (claude --resume ID) or mapped to a pane of a running tmux server
        by the sh-tafeta hook. Writing into them would fork the conversation."""
        live = set()
        try:
            for p in os.listdir("/proc"):
                if not p.isdigit():
                    continue
                try:
                    with open("/proc/%s/cmdline" % p, "rb") as f:
                        argv = f.read().decode("utf-8", "replace").split("\0")
                except OSError:
                    continue
                if not argv or not os.path.basename(argv[0]).startswith("claude"):
                    if not any(os.path.basename(a) == "claude" for a in argv[:2]):
                        continue
                for i, a in enumerate(argv):
                    if a in ("--resume", "-r", "--session-id") and i + 1 < len(argv) and SID_RE.match(argv[i + 1]):
                        live.add(argv[i + 1])
        except OSError:
            pass
        try:
            with open(os.path.join(self.state, "pane-map.tsv")) as f:
                for line in f:
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) >= 3 and SID_RE.match(cols[2]):
                        try:
                            if pid_alive(int(cols[0].split(":", 1)[0])):
                                live.add(cols[2])
                        except ValueError:
                            pass
        except OSError:
            pass
        return sorted(live)

    def op_prefix_sha(self, rid, rel, n):
        return sha256_file(self._target(self._root(rid), rel), n).hexdigest()

    def op_read(self, rid, rel, off, n):
        with open(self._target(self._root(rid), rel), "rb") as f:
            f.seek(off)
            return base64.b64encode(f.read(min(n, CHUNK))).decode()

    # ---------- discovery ----------

    def op_discover(self):
        """Project paths known to Claude Code here, from the newest transcript of each project dir."""
        pdir = os.path.join(self.claude_dir, "projects")
        found = []
        try:
            dirs = sorted(os.listdir(pdir))
        except OSError:
            return found
        for d in dirs:
            full = os.path.join(pdir, d)
            try:
                tr = sorted((e for e in os.scandir(full) if e.name.endswith(".jsonl") and e.is_file(follow_symlinks=False)),
                            key=lambda e: e.stat().st_mtime, reverse=True)
            except OSError:
                continue
            cwd = None
            for e in tr[:3]:
                try:
                    with open(e.path, "rb") as f:
                        for _ in range(200):
                            line = f.readline()
                            if not line:
                                break
                            if b'"cwd"' not in line:
                                continue
                            try:
                                v = json.loads(line).get("cwd")
                            except ValueError:
                                continue
                            if isinstance(v, str):
                                cwd = v
                                break
                except OSError:
                    continue
                if cwd:
                    break
            # trust the cwd only if it really is this folder's project
            if cwd and encode_path(cwd) == d and not self.forbidden(cwd):
                found.append(cwd)
        return found

    # ---------- writes ----------

    def _special(self, kind, root, rel, extra):
        if kind == "file":
            return rel
        if kind == "conflict":
            # name.sync-conflict-<stamp>-<host>.ext next to the file (Syncthing style)
            d, _, name = rel.rpartition("/")
            stem, dot, ext = name.partition(".") if not name.startswith(".") else (name, "", "")
            n = "%s.sync-conflict-%s-%s%s%s" % (stem, extra["stamp"], extra["host"], dot, ext)
            return (d + "/" if d else "") + n
        raise AgentError("bad kind")

    def op_has_conflict_copy(self, rid, rel, sha):
        root = self._root(rid)
        d, _, name = rel.rpartition("/")
        stem = name.partition(".")[0] if not name.startswith(".") else name
        folder = os.path.join(root.path, d)
        try:
            for e in os.scandir(folder):
                if e.name.startswith(stem + ".sync-conflict-") and e.is_file(follow_symlinks=False):
                    if sha256_file(e.path).hexdigest() == sha:
                        return True
        except OSError:
            pass
        return False

    def op_put_begin(self, rid, rel, kind="file", extra=None):
        root = self._root(rid)
        extra = dict(extra or {})
        extra["host"] = re.sub(r"[^A-Za-z0-9.-]", "_", str(extra.get("host", "peer")))[:40]
        extra["run"] = re.sub(r"[^A-Za-z0-9-]", "_", str(extra.get("run", "run")))
        if kind == "stash":
            if not self._clean_rel(rel):
                raise AgentError("bad path %r" % rel)
            dest = os.path.join(self.state, "conflicts", extra["run"], root.scope,
                                encode_path(root.project or "config"), rel + "@" + extra["host"])
            os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
        else:
            if kind == "conflict" and root.scope == "config":
                # a copy next to an agent or command would be picked up as a new one
                raise AgentError("no conflict copies in the Claude Code config dir", "notallowed")
            # the file the copy stands for must be one we would sync at all
            if not self._allowed(root, rel):
                raise AgentError("%r is outside what %s syncs here" % (rel, root.scope), "notallowed")
            rel = self._special(kind, root, rel, extra)
            dest = self._target(root, rel, must_exist=False, check_allowed=False)
            os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
            self._target(root, rel, must_exist=False, check_allowed=False)   # re-check after mkdir
        tmp = os.path.join(os.path.dirname(dest), ".sht-tmp-" + uuid.uuid4().hex)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        token = uuid.uuid4().hex
        self.puts[token] = {"tmp": tmp, "dest": dest, "fh": os.fdopen(fd, "wb"), "h": hashlib.sha256(),
                            "root": root, "rel": rel, "append": False}
        return {"token": token, "dest": dest}

    def op_append_begin(self, rid, rel, expect_sha, expect_size):
        """Fast-forward a transcript: check it is still exactly what we planned, then append."""
        root = self._root(rid)
        if not self._allowed(root, rel):
            raise AgentError("%r is outside what %s syncs here" % (rel, root.scope), "notallowed")
        dest = self._target(root, rel)
        if os.path.getsize(dest) != expect_size:
            return {"token": None, "changed": True}
        h = sha256_file(dest)
        if h.hexdigest() != expect_sha:
            return {"token": None, "changed": True}
        token = uuid.uuid4().hex
        self.puts[token] = {"dest": dest, "fh": open(dest, "ab"), "h": h, "root": root, "rel": rel,
                            "append": True, "size": expect_size}
        return {"token": token, "changed": False}

    def op_put_chunk(self, token, data):
        p = self.puts[token]
        b = base64.b64decode(data)
        p["fh"].write(b)
        p["h"].update(b)
        return len(b)

    def op_put_abort(self, token):
        p = self.puts.pop(token, None)
        if not p:
            return False
        p["fh"].close()
        if p["append"]:
            os.truncate(p["dest"], p["size"])
        else:
            try:
                os.unlink(p["tmp"])
            except OSError:
                pass
        return True

    def op_put_commit(self, token, sha, expect=None, mtime=None, mode=None, backup_run=None, new_only=False):
        """Replace dest with the staged file if dest still has hash `expect` (None: must not exist)."""
        p = self.puts.pop(token)
        p["fh"].flush()
        os.fsync(p["fh"].fileno())
        p["fh"].close()
        got = p["h"].hexdigest()
        if p["append"]:
            if got != sha:
                os.truncate(p["dest"], p["size"])
                return {"ok": False, "why": "source changed during sync"}
            return {"ok": True}
        if got != sha:
            os.unlink(p["tmp"])
            return {"ok": False, "why": "source changed during sync"}
        dest = p["dest"]
        exists = os.path.lexists(dest)
        if new_only or expect is None:
            if exists:
                os.unlink(p["tmp"])
                return {"ok": False, "why": "destination appeared during sync"}
        else:
            if not exists or not stat.S_ISREG(os.lstat(dest).st_mode) or sha256_file(dest).hexdigest() != expect:
                os.unlink(p["tmp"])
                return {"ok": False, "why": "destination changed during sync"}
            if backup_run:
                b = os.path.join(self.state, "backups", backup_run, p["root"].scope,
                                 encode_path(p["root"].project or "config"), p["rel"])
                os.makedirs(os.path.dirname(b), mode=0o700, exist_ok=True)
                shutil.copy2(dest, b)
        if mode is not None:
            # only the executable bit travels, and only for source files; the rest is ours
            exe = p["root"].scope == "source" and mode & 0o100
            os.chmod(p["tmp"], 0o700 if exe else 0o600)
        if mtime is not None:
            os.utime(p["tmp"], (mtime, mtime))
        os.replace(p["tmp"], dest)
        return {"ok": True}

    # ---------- manifests ----------

    def _manifest_path(self, peer, scope, project):
        if not re.match(r"^[0-9a-f]{32}$", peer):
            raise AgentError("bad peer id")
        return os.path.join(self.state, "sync", peer, scope, encode_path(project or "config") + ".json")

    def op_manifest_read(self, peer, scope, project):
        try:
            with open(self._manifest_path(peer, scope, project)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def op_manifest_write(self, peer, scope, project, manifest):
        atomic_write(self._manifest_path(peer, scope, project), json.dumps(manifest).encode())
        return True

    def op_prune(self, keep_days=30, keep_min=20):
        bdir = os.path.join(self.state, "backups")
        try:
            runs = sorted(os.listdir(bdir))
        except OSError:
            return 0
        cutoff = time.time() - keep_days * 86400
        removed = 0
        for r in runs[:-keep_min] if len(runs) > keep_min else []:
            full = os.path.join(bdir, r)
            try:
                if os.path.getmtime(full) < cutoff:
                    shutil.rmtree(full)
                    removed += 1
            except OSError:
                pass
        return removed


def serve():
    """JSON-lines RPC loop (remote side). Whatever ends it — the connection dropping,
    a signal — the lock is released and half-received files are removed."""
    state = {"agent": None}

    def stop(signum, frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
        signal.signal(sig, stop)
    out = sys.stdout
    try:
        for line in sys.stdin:
            try:
                req = json.loads(line)
                op, args = req["op"], req.get("args", {})
                if op == "init":
                    state["agent"] = Agent(args.get("claude_dir"))
                    res = True
                else:
                    fn = getattr(state["agent"], "op_" + op, None)
                    if fn is None:
                        raise AgentError("unknown op %r" % op)
                    res = fn(**args)
                reply = {"ok": True, "result": res}
            except AgentError as e:
                reply = {"ok": False, "error": str(e), "kind": e.kind}
            except (SystemExit, KeyboardInterrupt):
                raise
            except Exception as e:  # report, keep serving
                reply = {"ok": False, "error": "%s: %s" % (type(e).__name__, e), "kind": "error"}
            out.write(json.dumps(reply) + "\n")
            out.flush()
    except (BrokenPipeError, OSError, SystemExit, KeyboardInterrupt):
        pass
    finally:
        agent = state["agent"]
        if agent:
            for t in list(agent.puts):
                try:
                    agent.op_put_abort(t)
                except Exception:
                    pass
            agent.op_unlock()


if __name__ == "__main__":
    serve()
