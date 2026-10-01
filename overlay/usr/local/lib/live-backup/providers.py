"""providers: how the Cloud Backup app signs in to each destination, without any
UI: what each one needs becomes an rclone remote (cloud.set_setup_remote),
or, for iCloud, a signed-in icloud-linux mount.

  - Google Drive, OneDrive, Dropbox: `rclone authorize` in the browser,
    with the image's own OAuth clients when it has them
    (/etc/live-backup/oauth-clients.json, from build.sh --oauth-clients),
    else rclone's: shared by every rclone user, so Google often refuses it
    for a while (rateLimitExceeded). OneDrive also needs the id and type of
    the user's drive, asked to Microsoft Graph with the new token.
  - Nextcloud: Login Flow v2, the one Nextcloud's own clients use: the
    user approves in the browser, and the server hands out an app password
    (revocable in Nextcloud's Security settings).
  - Samba, SFTP: what the user typed. SFTP checks the server's host key:
    the app shows its fingerprint before it's trusted (known_hosts).
  - iCloud Drive: icloud-linux (icloudctl, icloudd): Apple ID, password and
    a code by SMS, then the mount in ~/iCloud. `icloudctl auth` reads from
    a terminal, so it runs in a pseudo-terminal (ICloudSignIn).
"""
import json
import os
import pty
import re
import select
import signal
import subprocess
import threading
import time
import urllib.parse
import urllib.request

import cloud

USER_AGENT = "Ubuntu Backup (rclone)"
OAUTH = {"google": "drive", "onedrive": "onedrive", "dropbox": "dropbox"}
OAUTH_CLIENTS = "/etc/live-backup/oauth-clients.json"
ICLOUDCTL = "icloudctl"

MESSAGES = {
    "en": {"rate_limit": "{service} is refusing requests for now (too many). Try again in a "
                         "few minutes."},
    "it": {"rate_limit": "{service} sta rifiutando le richieste per ora (troppe). Riprova "
                         "tra qualche minuto."},
}
RATE_LIMIT = re.compile(r"rateLimitExceeded|userRateLimitExceeded|Quota exceeded|"
                        r"too_many_requests|Error 429|TooManyRequests|activityLimited")
SERVICES = {"drive": "Google Drive", "onedrive": "OneDrive", "dropbox": "Dropbox"}


def _t(key, **kw):
    return MESSAGES.get(os.environ.get("LANG", "")[:2], MESSAGES["en"])[key].format(**kw)


class SignInError(Exception):
    pass


def rclone_error(stderr, backend=""):
    """What went wrong, from rclone's log: a sentence for the known cases,
    else its last error line without the timestamp."""
    if RATE_LIMIT.search(stderr):
        return _t("rate_limit", service=SERVICES.get(backend, backend or "The service"))
    lines = [re.sub(r"^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d (?:(?:ERROR|NOTICE|INFO|DEBUG) *: *)?",
                    "", l).strip()
             for l in stderr.splitlines() if l.strip()]
    errors = [l for l in lines if re.search(r"error|failed|couldn't", l, re.I)]
    return (errors or lines or ["rclone"])[-1]


def _backend(remote):
    return cloud.remote_options(remote).get("type", "")


def _rclone(*args, remote=cloud.SETUP_REMOTE):
    """rclone for the remote. Google Drive gets rclone's full retries: its
    rate limits pass after a short wait, and rclone backs off by itself.
    The others fail fast, so a wrong password is said at once."""
    retries = [] if _backend(remote) == "drive" else ["--low-level-retries", "2"]
    return ["rclone", "--contimeout", "20s", *retries, *args]


def _http(url, data=None, headers=None, timeout=30):
    request = urllib.request.Request(
        url, data=urllib.parse.urlencode(data).encode() if data is not None else None,
        headers={"User-Agent": USER_AGENT, **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


# --- Google Drive, OneDrive, Dropbox: rclone authorize -----------------------------

def oauth_client(provider):
    """The image's own OAuth client for the provider ({"client_id",
    "client_secret"}), or None for rclone's."""
    try:
        client = json.load(open(OAUTH_CLIENTS)).get(OAUTH[provider])
    except (OSError, ValueError, AttributeError):
        return None
    return client if client and client.get("client_id") else None


def authorize_cmd(provider):
    """Prints the sign-in URL (stderr), serves the redirect on
    127.0.0.1:53682 and prints the token (stdout)."""
    client = oauth_client(provider)
    own = [client["client_id"], client.get("client_secret", "")] if client else []
    return ["rclone", "authorize", OAUTH[provider], *own, "--auth-no-open-browser"]


def authorize_url(line):
    m = re.search(r"(http://127\.0\.0\.1:\d+/auth\S*)", line)
    return m[1] if m else None


def token_from(output):
    for line in output.splitlines():
        if line.strip().startswith("{"):
            return json.loads(line)
    return None


def oauth_remote(provider, token):
    options = {"type": OAUTH[provider], "token": json.dumps(token)}
    client = oauth_client(provider)
    if client:  # the token is renewed with the client that got it
        options.update(client_id=client["client_id"],
                       client_secret=client.get("client_secret", ""))
    if provider == "google":
        options["scope"] = "drive"
    elif provider == "onedrive":
        drive = _http("https://graph.microsoft.com/v1.0/me/drive",
                      headers={"Authorization": f"Bearer {token['access_token']}"})
        options.update(drive_id=drive["id"], drive_type=drive["driveType"])
    return options


def identity(remote=cloud.SETUP_REMOTE):
    """The signed-in user, when the backend tells (Dropbox, OneDrive do)."""
    out = subprocess.run(_rclone("config", "userinfo", "--json", f"{remote}:", remote=remote),
                         env=cloud.env(), capture_output=True, text=True)
    try:
        info = json.loads(out.stdout)
    except ValueError:
        return ""
    return info.get("Email") or info.get("Name") or ""


# --- Nextcloud: Login Flow v2 -------------------------------------------------------

def nextcloud_server(text):
    text = text.strip().rstrip("/")
    if not re.match(r"https?://", text):
        text = "https://" + text
    parsed = urllib.parse.urlsplit(text)
    if not parsed.hostname:
        raise SignInError("bad address")
    # The server's address, not a page of it (…/index.php/apps/files)
    path = re.sub(r"/(index\.php|apps|login|remote\.php)(/.*)?$", "", parsed.path)
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def nextcloud_start(server):
    """{"login": URL to open, "poll": {"token", "endpoint"}}."""
    return _http(f"{server}/index.php/login/v2", data={})


def nextcloud_poll(flow, timeout=20 * 60, interval=2, cancelled=lambda: False):
    """The approved login ({"server", "loginName", "appPassword"}), or None
    when cancelled or timed out."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not cancelled():
        try:
            return _http(flow["poll"]["endpoint"], data={"token": flow["poll"]["token"]})
        except urllib.error.HTTPError as e:
            if e.code != 404:  # 404: not approved yet
                raise
        time.sleep(interval)
    return None


def nextcloud_remote(login):
    user = login["loginName"]
    return {"type": "webdav", "vendor": "nextcloud", "user": user,
            "url": f"{login['server'].rstrip('/')}/remote.php/dav/files/{urllib.parse.quote(user)}",
            "pass": cloud.obscure(login["appPassword"])}


# --- Samba ---------------------------------------------------------------------------

def samba_remote(host, user, password, domain):
    # Without a user: the guest account, as Files does.
    return {"type": "smb", "host": host.strip().removeprefix("smb://").strip("/"),
            "user": user.strip() or "guest", "pass": cloud.obscure(password) if password else "",
            "domain": domain.strip() or "WORKGROUP"}


# --- SFTP ----------------------------------------------------------------------------

def host_keys(host, port):
    """(known_hosts lines, [fingerprints]) of the server, as ssh-keyscan sees it."""
    scan = subprocess.run(["ssh-keyscan", "-T", "10", "-p", str(port), host],
                          capture_output=True, text=True)
    lines = [l for l in scan.stdout.splitlines() if l and not l.startswith("#")]
    if not lines:
        raise SignInError(scan.stderr.strip().splitlines()[-1] if scan.stderr.strip()
                          else f"{host}:{port}")
    prints = subprocess.run(["ssh-keygen", "-l", "-f", "-"], input="\n".join(lines) + "\n",
                            capture_output=True, text=True).stdout.split("\n")
    return lines, [p.split(" ", 2)[1] + " (" + p.rsplit("(", 1)[-1] for p in prints if p.strip()]


def host_keys_known(lines):
    """Already trusted (all of the server's keys are in known_hosts)?"""
    try:
        known = set(open(cloud.KNOWN_HOSTS).read().splitlines())
    except OSError:
        return False
    return all(line in known for line in lines)


def trust_host_keys(lines):
    cloud._private(cloud.KNOWN_HOSTS)
    with open(cloud.KNOWN_HOSTS, "a") as f:
        f.write("\n".join(lines) + "\n")


def sftp_remote(host, port, user, password=None, key_file=None, passphrase=None):
    options = {"type": "sftp", "host": host.strip(), "port": int(port or 22), "user": user.strip(),
               "known_hosts_file": cloud.KNOWN_HOSTS}
    if key_file:
        options["key_file"] = key_file
        if passphrase:
            options["key_file_pass"] = cloud.obscure(passphrase)
    else:
        options["pass"] = cloud.obscure(password or "")
    return options


# --- checking a remote -------------------------------------------------------------

def check_remote(remote=cloud.SETUP_REMOTE):
    """Can the remote be listed? Raises SignInError with rclone's reason."""
    out = subprocess.run(_rclone("lsjson", "--dirs-only", "--max-depth", "1", f"{remote}:",
                                 remote=remote),
                         env=cloud.env(), capture_output=True, text=True, timeout=600)
    if out.returncode != 0:
        raise SignInError(rclone_error(out.stderr, _backend(remote)))


def list_dirs(path, remote=cloud.SETUP_REMOTE):
    out = subprocess.run(_rclone("lsjson", "--dirs-only", cloud.remote_path(path, remote),
                                 remote=remote),
                         env=cloud.env(), capture_output=True, text=True)
    if out.returncode != 0:
        raise SignInError(rclone_error(out.stderr, _backend(remote)))
    # Not the hidden ones (.cache, .ssh...): no place for backups
    return sorted((e["Name"] for e in json.loads(out.stdout or "[]")
                   if not e["Name"].startswith(".")), key=str.lower)


def make_dir(path, remote=cloud.SETUP_REMOTE):
    out = subprocess.run(_rclone("mkdir", cloud.remote_path(path, remote), remote=remote),
                         env=cloud.env(), capture_output=True, text=True)
    if out.returncode != 0:
        raise SignInError(rclone_error(out.stderr, _backend(remote)))


# --- the encrypted folders ------------------------------------------------------------

def vault_candidates(path, names):
    """Of the folder at `path` (whose subfolders are `names`), the ones that
    may be encrypted backups (their neutral names), the folder itself first
    if it is one."""
    here = [path] if cloud.VAULT_NAME.match(path.rsplit("/", 1)[-1]) else []
    return here + [f"{path}/{n}".strip("/") for n in names if cloud.VAULT_NAME.match(n)]


# --- iCloud Drive: icloud-linux ------------------------------------------------------

def icloud_remote():
    """iCloud Drive for rclone: the icloud-linux mount, under another name."""
    return {"type": "alias", "remote": cloud.ICLOUD_MOUNT}


def icloud_list_dirs(path):
    base = os.path.join(cloud.ICLOUD_MOUNT, path)
    return sorted((e.name for e in os.scandir(base) if e.is_dir() and not e.name.startswith(".")),
                  key=str.lower)


def icloud_make_dir(path):
    os.makedirs(os.path.join(cloud.ICLOUD_MOUNT, path), exist_ok=True)


def icloud_mounted():
    return os.path.ismount(cloud.ICLOUD_MOUNT)


ICLOUD_SERVICE = "icloud.service"


def icloud_problem():
    """Why the running icloudd can't reach iCloud, or None. A daemon started
    without a session (before the sign-in, or once it expired) mounts anyway
    and serves only its cache, which then looks like an empty iCloud Drive:
    it says so in its log, once per start."""
    run = subprocess.run(["systemctl", "--user", "show", "-p", "InvocationID", "--value",
                          ICLOUD_SERVICE], capture_output=True, text=True).stdout.strip()
    if not run:
        return None
    log = subprocess.run(["journalctl", "--user", f"_SYSTEMD_INVOCATION_ID={run}", "-o", "cat",
                          "--no-pager"], capture_output=True, text=True).stdout
    for line in log.splitlines():
        m = re.search(r"starting UNAUTHENTICATED: (.*?)\. The cache", re.sub(r"\x1b\[[\d;]*m", "", line))
        if m:
            return m[1]
    return None


def icloud_start(timeout=90, restart=False):
    """Start the icloud-linux service (restart: so that it takes the session
    just signed in) and wait for the mount; SignInError if it has no
    session."""
    if restart or not icloud_mounted():
        out = subprocess.run([ICLOUDCTL, "restart" if restart else "start"],
                             capture_output=True, text=True)
        if out.returncode != 0:
            raise SignInError((out.stderr or out.stdout).strip() or "icloudctl start")
    deadline = time.monotonic() + timeout
    while not icloud_mounted():
        if time.monotonic() > deadline:
            raise SignInError("iCloud Drive isn't mounted (icloudctl start)")
        time.sleep(1)
    problem = icloud_problem()
    if problem:
        raise SignInError(problem)


class ICloudSignIn:
    """`icloudctl init` and `configure`, then `icloudctl auth --force-sms` in
    a pseudo-terminal: its prompts become calls of `on_event(kind, data)`,
    from a thread:
      ("phones", ["+39 ••• ••12", ...])  answer with choose(index)
      ("code", sent_to)                  answer with code("123456")
      ("wrong_code", message)            ask again; answer with code(...)
      ("done", apple_id)                 signed in
      ("error", message)
    The password goes to the terminal prompt only: it isn't stored (that's
    icloud-linux's default)."""

    def __init__(self, apple_id, password, on_event):
        self.apple_id, self.password, self.on_event = apple_id, password, on_event
        self.pid = self.fd = None

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _prepare(self):
        for cmd in ([ICLOUDCTL, "init", cloud.ICLOUD_MOUNT], [ICLOUDCTL, "configure", self.apple_id]):
            out = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
            if out.returncode != 0:
                raise SignInError((out.stderr or out.stdout).strip().splitlines()[-1]
                                  if (out.stderr or out.stdout).strip() else " ".join(cmd))

    def _run(self):
        try:
            self._prepare()
        except (SignInError, OSError) as e:
            self.on_event("error", str(e))
            return
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # the child: icloudctl on the terminal
            os.environ["LANG"] = "C.UTF-8"
            os.execvp(ICLOUDCTL, [ICLOUDCTL, "auth", "--force-sms"])
        text, said, sent_to, phones = "", [], "", []
        while True:
            try:
                ready, _, _ = select.select([self.fd], [], [], 600)
                chunk = os.read(self.fd, 4096).decode(errors="replace") if ready else ""
            except OSError:  # the child closed the terminal
                chunk = ""
            if not chunk:
                break
            text += chunk.replace("\r", "")
            # whole lines: what icloudctl says
            while "\n" in text:
                line, text = text.split("\n", 1)
                said.append(line.strip())
                phone = re.match(r"\s*(\d+): (.+)$", line)
                if phone:
                    phones.append(phone[2].strip())
                sms = re.search(r"A code was sent by SMS to (.+?)\.$", line.strip())
                if sms:
                    sent_to = sms[1]
                if "was not accepted" in line and "attempt" in line:
                    self.on_event("wrong_code", line.strip())
                if line.strip().startswith("Authenticated as:"):
                    self.apple_id = line.split(":", 1)[1].strip()
            # prompts: the rest of a line, waiting for an answer
            if text.endswith("password (input hidden): "):
                self._send(self.password)
                text = ""
            elif text.endswith("Number: "):
                self.on_event("phones", phones)
                text = ""
            elif text.endswith("Verification code: "):
                self.on_event("code", sent_to)
                text = ""
        _, status = os.waitpid(self.pid, 0)
        os.close(self.fd)
        if "AUTH_OK" in said and os.waitstatus_to_exitcode(status) == 0:
            self.on_event("done", self.apple_id)
        else:
            reason = next((l for l in reversed(said) if l and not l.endswith(":")), "")
            self.on_event("error", re.sub(r"^(Error|error):\s*", "", reason) or "icloudctl auth")

    def _send(self, answer):
        os.write(self.fd, (answer + "\n").encode())

    def choose(self, index):
        self._send(str(index + 1))

    def code(self, code):
        self._send(code.strip())

    def cancel(self):
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
