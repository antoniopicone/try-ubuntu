"""aisetup: what the AI app (live-ai) does, apart from its window.

Everything here runs as the user: the system installs go through
install-ai (pkexec). Functions that take a while are meant for a thread; they
raise RuntimeError with a message to show.
"""
import json
import os
import re
import shutil
import subprocess

HOME = os.path.expanduser("~")
LOCAL_BIN = os.path.join(HOME, ".local", "bin")
XDG_CONFIG = os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
INSTALL_AI = "/usr/local/lib/live-ai/install-ai"
OPENCODE_CONFIG = os.path.join(XDG_CONFIG, "opencode", "opencode.json")
CODEX_CONFIG = os.path.join(os.environ.get("CODEX_HOME", os.path.join(HOME, ".codex")),
                            "config.toml")
STATE = os.path.join(XDG_CONFIG, "live-ai", "state.json")

# npm installs into the home: its bin directory first, for us and our children.
if LOCAL_BIN not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = LOCAL_BIN + os.pathsep + os.environ.get("PATH", "")

# The terminal agents: command, npm package (None: from Anthropic's apt repository).
AGENTS = {
    "claude": None,
    "codex": "@openai/codex",
    "opencode": "opencode-ai",
}
QMD_PACKAGE = "@tobilu/qmd"


def which(command):
    return shutil.which(command)


def run(cmd, check=True, timeout=None, **kw):
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    if check and result.returncode != 0:
        lines = (result.stderr or result.stdout or "").strip().splitlines()
        raise RuntimeError(lines[-1] if lines else f"{cmd[0]} failed ({result.returncode})")
    return result


def dpkg_installed(package):
    out = subprocess.run(["dpkg-query", "-W", "-f=${Status}", package],
                         capture_output=True, text=True).stdout
    return "install ok installed" in out


# --- state ----------------------------------------------------------------------------

def load_state():
    try:
        with open(STATE, encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return {}


def save_state(**changes):
    state = load_state()
    state.update(changes)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, STATE)


# --- the computer ---------------------------------------------------------------------

def resources():
    """live-ai-resources --env, as a dict."""
    out = run(["live-ai-resources", "--env"]).stdout
    values = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    values["ALT_MODELS"] = values.get("ALT_MODELS", "").split()
    return values


def has_kvm():
    return os.path.exists("/dev/kvm")


# --- system installs (pkexec) ---------------------------------------------------------

def install_ai(*args, progress=None):
    """install-ai through pkexec. progress(line) gets its stderr as it goes."""
    proc = subprocess.Popen(["pkexec", INSTALL_AI, *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    for line in proc.stderr:
        if progress and line.strip():
            progress(line.strip())
    out = proc.stdout.read().strip().splitlines()
    code = proc.wait()
    if code in (126, 127) and not out:
        raise RuntimeError("cancelled")  # pkexec: dismissed, or not authorized
    try:
        result = json.loads(out[-1]) if out else {}
    except ValueError:
        result = {}
    if not result.get("ok"):
        raise RuntimeError(result.get("error") or f"install-ai failed ({code})")


def ensure_node(progress=None):
    """Node.js and npm from the archive (Ubuntu 26.04's Node 22 is enough for
    the agents and qmd), and npm's global prefix in the home: no sudo npm."""
    missing = [p for p, cmd in (("nodejs", "node"), ("npm", "npm")) if not which(cmd)]
    if missing:
        install_ai("packages", *missing, progress=progress)
    prefix = run(["npm", "config", "get", "prefix"], check=False).stdout.strip()
    if not prefix.startswith(HOME):
        run(["npm", "config", "set", "prefix", os.path.join(HOME, ".local")])


def npm_install(package, progress=None):
    ensure_node(progress)
    if progress:
        progress(f"npm install -g {package}")
    run(["npm", "install", "-g", "--no-fund", "--no-audit", package], timeout=1800)


# --- agents ---------------------------------------------------------------------------

def agent_installed(agent):
    return which(agent) is not None


def install_agent(agent, progress=None):
    if agent == "claude":
        install_ai("claude-code", progress=progress)
    else:
        npm_install(AGENTS[agent], progress)
    link_skills([agent])


def installed_agents():
    return [a for a in AGENTS if agent_installed(a)]


def link_skills(agents):
    if agents:
        args = []
        for a in agents:
            args += ["--agent", a]
        run(["live-agent-link", *args])


def default_agent():
    return run(["live-agent", "--get-default"], check=False).stdout.strip() or "claude"


def set_default_agent(agent):
    run(["live-agent", "--set-default", agent])


def open_agent(agent):
    """The agent in a terminal: its first run signs in."""
    subprocess.Popen(["live-agent", "--agent", agent, "--terminal"], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --- MCP: the knowledge base for the agents -------------------------------------------

def qmd_path():
    return which("qmd") or os.path.join(LOCAL_BIN, "qmd")


def mcp_enabled(agent):
    if agent == "claude":
        return agent_installed("claude") and run(["claude", "mcp", "get", "qmd"],
                                                 check=False).returncode == 0
    if agent == "codex":
        return _codex_has_qmd()
    if agent == "opencode":
        return "qmd" in (_read_json(OPENCODE_CONFIG).get("mcp") or {})
    return False


def _codex_has_qmd():
    try:
        with open(CODEX_CONFIG, encoding="utf-8") as fh:
            return re.search(r"^\[mcp_servers\.qmd\]", fh.read(), re.M) is not None
    except FileNotFoundError:
        return False


def set_mcp(agent, enabled):
    """Lets AGENT search the knowledge base (the qmd MCP server), or not.
    Codex's config is also what ChatGPT Desktop's Codex reads."""
    qmd = qmd_path()
    if agent == "claude":
        if not agent_installed("claude"):
            return
        run(["claude", "mcp", "remove", "qmd", "--scope", "user"], check=False)
        if enabled:
            run(["claude", "mcp", "add", "--scope", "user", "qmd", "--", qmd, "mcp"])
    elif agent == "codex":
        if agent_installed("codex"):
            run(["codex", "mcp", "remove", "qmd"], check=False)
            if enabled:
                run(["codex", "mcp", "add", "qmd", "--", qmd, "mcp"])
        else:  # only ChatGPT Desktop: the table by hand
            _codex_table(qmd if enabled else None)
    elif agent == "opencode":
        configure_opencode(qmd=qmd if enabled else "", model=None)


def _codex_table(qmd):
    try:
        with open(CODEX_CONFIG, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        text = ""
    # Drop our table (up to the next table), then add it back if wanted.
    text = re.sub(r"\n?^\[mcp_servers\.qmd\]\n(?:(?!^\[).*\n?)*", "", text, flags=re.M)
    if qmd:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + \
            f'[mcp_servers.qmd]\ncommand = {json.dumps(qmd)}\nargs = ["mcp"]\n'
    os.makedirs(os.path.dirname(CODEX_CONFIG), exist_ok=True)
    with open(CODEX_CONFIG, "w", encoding="utf-8") as fh:
        fh.write(text)


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}
    except ValueError:
        raise RuntimeError(f"{path} isn't valid JSON: left as it is")


def configure_opencode(qmd=None, model=None):
    """OpenCode's global config: the qmd MCP server (qmd: its path to add it,
    "" to remove it, None to leave it) and the local model (model: an Ollama
    tag, None to leave it). The v1 layout, which OpenCode v2 still reads."""
    if os.path.exists(OPENCODE_CONFIG[:-5] + ".jsonc"):
        raise RuntimeError("OpenCode uses opencode.jsonc (with comments): add qmd by hand")
    config = _read_json(OPENCODE_CONFIG) or {"$schema": "https://opencode.ai/config.json"}
    if qmd:
        config.setdefault("mcp", {})["qmd"] = {"type": "local", "command": [qmd, "mcp"],
                                               "enabled": True}
    elif qmd == "":
        (config.get("mcp") or {}).pop("qmd", None)
    if model:
        provider = config.setdefault("provider", {}).setdefault("ollama", {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Ollama (this computer)",
            "options": {"baseURL": "http://127.0.0.1:11434/v1"},
            "models": {},
        })
        provider.setdefault("models", {})[model] = {"name": f"{model} (local)"}
        config["model"] = f"ollama/{model}"
    os.makedirs(os.path.dirname(OPENCODE_CONFIG), exist_ok=True)
    if os.path.exists(OPENCODE_CONFIG):
        shutil.copy2(OPENCODE_CONFIG, OPENCODE_CONFIG + ".bak")
    tmp = OPENCODE_CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, OPENCODE_CONFIG)


# --- the local model ------------------------------------------------------------------

def ollama_installed():
    return which("ollama") is not None


def ollama_models():
    if not ollama_installed():
        return []
    out = run(["ollama", "list"], check=False).stdout.splitlines()[1:]
    return [line.split()[0] for line in out if line.strip()]


PERCENT = re.compile(r"(\d{1,3})%")


def install_model(model, context, rocm=False, progress=None, fraction=None):
    """Ollama (when missing) and MODEL. fraction(0..1) follows the download."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9._/-]*(:[a-z0-9._-]+)?", model):
        raise RuntimeError(f"not a model tag: {model}")
    if not ollama_installed() or not _ollama_answers():
        install_ai("ollama", str(context), *(["--rocm"] if rocm else []), progress=progress)
    proc = subprocess.Popen(["ollama", "pull", model], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    buf, last = "", ""
    while True:
        chunk = proc.stdout.read(256)
        if not chunk:
            break
        buf += chunk
        parts = re.split(r"[\r\n]", buf)
        buf = parts.pop()
        for part in parts:
            part = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", part).strip()
            if not part:
                continue
            last = part
            m = PERCENT.search(part)
            if fraction and m and part.startswith("pulling") and "manifest" not in part:
                fraction(min(int(m[1]), 100) / 100)
    if proc.wait() != 0:
        raise RuntimeError(last or f"ollama pull {model} failed")
    save_state(model=model)
    if agent_installed("opencode"):
        configure_opencode(model=model)


def _ollama_answers():
    return run(["ollama", "list"], check=False, timeout=10).returncode == 0


# --- the knowledge base ---------------------------------------------------------------

def kb_status():
    if not which("live-kb"):
        return {"qmd": False, "configured": False, "collections": []}
    out = run(["live-kb", "status", "--json"], check=False).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"qmd": which("qmd") is not None, "configured": False, "collections": []}


def shared_folders():
    """The QEMU host's shared folders (run-qemu.sh --shared-folder: bindfs in
    /media), where the user's projects often are."""
    found = []
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as fh:
            for line in fh:
                left, _, right = line.partition(" - ")
                point = left.split()[4]
                if right.split()[0] == "fuse.bindfs" and point.startswith("/media/"):
                    found.append(point.encode().decode("unicode_escape"))
    except OSError:
        pass
    return found


def discover_repos():
    """Git repositories in the home folder and the host's shared folders (3
    levels down, no hidden folders, no cloud mounts): (path, name, remote)."""
    out = run(["live-kb", "discover-repos", HOME, *shared_folders()], check=False).stdout
    return [tuple(line.split("\t")) for line in out.splitlines() if line.count("\t") == 2]


def user_dir(kind):
    out = run(["xdg-user-dir", kind], check=False).stdout.strip()
    return out if out and out != HOME and os.path.isdir(out) else None


def setup_kb(sources, repos, convert, progress=None):
    """qmd, the embedding model, the sources. sources: [(name, path, context)],
    repos: [(path, name, remote)]."""
    needed = []
    if not _python_yaml():
        needed.append("python3-yaml")
    if convert and not which("pdftotext"):
        needed.append("poppler-utils")  # PDFs; live-kb reads Word/OpenDocument itself
    if needed:
        install_ai("packages", *needed, progress=progress)
    if not which("qmd"):
        npm_install(QMD_PACKAGE, progress)
    run(["live-kb", "init", "--embed", "multilingual"])
    for name, path, context in sources:
        cmd = ["live-kb", "add", name, path, "--context", context]
        if convert:
            cmd.append("--convert")
        run(cmd)
    used = set()
    for path, name, remote in repos:
        cname, n = f"repo-{name}", 2
        while cname in used:
            cname, n = f"repo-{name}-{n}", n + 1
        used.add(cname)
        run(["live-kb", "add", cname, path, "--code", "--context",
             f"Repository {name}" + (f" ({remote})" if remote else "")])


def _python_yaml():
    return run(["python3", "-c", "import yaml"], check=False).returncode == 0


def kb_timer_enabled():
    return run(["systemctl", "--user", "is-enabled", "live-kb-update.timer"],
               check=False).stdout.strip() == "enabled"


def set_kb_timer(enabled):
    run(["systemctl", "--user", "enable" if enabled else "disable", "--now",
         "live-kb-update.timer"])


def kb_updating():
    return run(["systemctl", "--user", "is-active", "live-kb-update.service"],
               check=False).stdout.strip() in ("active", "activating")


def start_kb_update():
    run(["systemctl", "--user", "start", "--no-block", "live-kb-update.service"])


# --- crash notifications --------------------------------------------------------------

# The service is on for every user (enabled globally at build time): a user
# turns it off by masking it.
def crash_watch_enabled():
    return run(["systemctl", "--user", "is-enabled", "live-crash-watch.service"],
               check=False).stdout.strip() != "masked"


def set_crash_watch(enabled):
    if enabled:
        run(["systemctl", "--user", "unmask", "live-crash-watch.service"])
        run(["systemctl", "--user", "start", "live-crash-watch.service"], check=False)
    else:
        run(["systemctl", "--user", "mask", "--now", "live-crash-watch.service"])
