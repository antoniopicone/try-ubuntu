# Where and how to report a crash

Only after a diagnosis, and only with the user's yes. Always show the full draft before
sending anything.

## 1. Whose bug is it?

Start from the package that owns the crashed binary:

```bash
exe=<the executable's path>
pkg=$(dpkg -S "$exe" 2>/dev/null | cut -d: -f1)
apt-cache policy "$pkg"              # which repository, and is it a rebuilt version?
case "$exe" in /app/*|*/flatpak/*) echo flatpak;; /usr/local/*) echo "the image's own";; esac
```

| Where the binary comes from | Where to report |
|---|---|
| An Ubuntu archive package, stock version | Ubuntu, on Launchpad |
| One of the image's **rebuilt GNOME packages** (a version above 26.04's) | the try-ubuntu repository first: the local fixes may be involved; upstream only once it's shown to happen with Ubuntu's own build too |
| A Flatpak | the app's upstream tracker (from `https://flathub.org/apps/<app-id>`); a packaging-only bug → `github.com/flathub/<app-id>` |
| Brave Origin, Tailscale, Claude, ChatGPT, Ollama | that vendor |
| The image's own programs (`/usr/local/bin`, `/usr/local/lib`, `live-*`) or its setup | the try-ubuntu repository |
| npm tools (Codex, OpenCode, qmd) | their GitHub repositories |

## 2. Ubuntu packages

There's no Apport (`ubuntu-bug`) on this image. Draft the report for Launchpad's web form,
`https://bugs.launchpad.net/ubuntu/+source/<source package>/+filebug`
(`apt-cache show "$pkg" | grep -m1 '^Source:'`, or the package name when there's none). The
user files it with their own Launchpad account: don't try to do it for them. Say that the
system is a try-ubuntu image (minimal, no recommends), since triagers will ask.

## 3. Upstream and the image: the draft

A text with:

- a short title: program, signal, context (`Segfault in <function> while <action>`);
- versions: the program's, `. /etc/os-release; echo $PRETTY_NAME`, `gnome-shell --version`,
  the kernel, live or installed, VM or hardware;
- the steps to reproduce it, if known;
- the **symbolized** backtrace, only the relevant part;
- what's shown and what's inferred, as in the diagnosis.

Before offering to send it:

- **remove personal data**: user names, paths with private file names, host names,
  addresses, tokens, document content visible in the stack or the command line;
- **never attach the core**: it's a copy of the process's memory. If maintainers ask for
  it, that's the user's decision, knowing what it holds;
- look for an existing report with the same stack: adding to an open one beats a
  duplicate.

When `gh` is installed and signed in, `gh issue create --repo <owner/repo> --title ...
--body-file <draft>` files it, but only after the user has read and approved the draft.
