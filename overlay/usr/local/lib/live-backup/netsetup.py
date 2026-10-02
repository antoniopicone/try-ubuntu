"""netsetup: the network and Tailscale, for Cloud Backup's first run (before
the backups are set up, which need the network).

NetworkManager through nmcli (the session's user may manage connections),
Tailscale through its CLI: `tailscale up` needs root once, through pkexec,
with --operator so that the user can run it afterwards.
"""
import json
import os
import pwd
import re
import shutil
import subprocess

TAILSCALE = "/usr/bin/tailscale"


def _nmcli(*args, timeout=30):
    return subprocess.run(["nmcli", *args], capture_output=True, text=True, timeout=timeout)


def online():
    """Full connectivity, as NetworkManager sees it."""
    try:
        out = _nmcli("-t", "-f", "CONNECTIVITY", "general", timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return True  # no NetworkManager to ask: don't stand in the way
    return out == "full"


def devices():
    """The kinds of network devices this computer has: {"ethernet", "wifi"}."""
    try:
        out = _nmcli("-t", "-f", "TYPE,STATE", "device", timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    kinds = set()
    for line in out.splitlines():
        kind, _, state = line.partition(":")
        if kind in ("ethernet", "wifi") and state != "unmanaged":
            kinds.add(kind)
    return kinds


def _fields(line):
    """nmcli -t -e yes's fields: ':' separates, '\\:' and '\\\\' are literal."""
    parts = re.split(r"(?<!\\):", line)
    return [p.replace("\\:", ":").replace("\\\\", "\\") for p in parts]


def wifi_networks():
    """The Wi-Fi networks in range, strongest first:
    [{"ssid", "signal", "secure", "active"}], one per name."""
    out = _nmcli("-t", "-e", "yes", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi",
                 "list", "--rescan", "yes", timeout=40).stdout
    seen = {}
    for line in out.splitlines():
        fields = _fields(line)
        if len(fields) < 4 or not fields[3]:
            continue  # hidden networks have no name
        in_use, signal, security, ssid = fields[0], fields[1], fields[2], ":".join(fields[3:])
        network = {"ssid": ssid, "signal": int(signal or 0),
                   "secure": security not in ("", "--"), "active": in_use.strip() == "*"}
        if ssid not in seen or network["signal"] > seen[ssid]["signal"]:
            seen[ssid] = network
    return sorted(seen.values(), key=lambda n: -n["signal"])


def wifi_connect(ssid, password=None):
    """Connects to a Wi-Fi network. Raises RuntimeError with nmcli's reason."""
    args = ["device", "wifi", "connect", ssid]
    if password:
        args += ["password", password]
    out = _nmcli(*args, timeout=90)
    if out.returncode != 0:
        message = (out.stderr or out.stdout).strip()
        # "Error: Connection activation failed: (7) Secrets were required..."
        raise RuntimeError(re.sub(r"^Error:\s*", "", message.splitlines()[-1] if message else ""))


def tailscale_available():
    return shutil.which("tailscale") is not None


def tailscale_running():
    """This computer is already on a tailnet."""
    try:
        out = subprocess.run([TAILSCALE, "status", "--json"], capture_output=True, text=True,
                             timeout=10).stdout
        return json.loads(out).get("BackendState") == "Running"
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def tailscale_up():
    """Starts `tailscale up` (as root, through pkexec): a Popen whose output
    carries the sign-in URL. The user becomes the operator, so later
    `tailscale` commands need no password."""
    user = pwd.getpwuid(os.getuid()).pw_name
    return subprocess.Popen(["pkexec", TAILSCALE, "up", f"--operator={user}", "--timeout=15m"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def login_url(line):
    m = re.search(r"https://login\.tailscale\.com/\S+", line)
    return m[0] if m else None
