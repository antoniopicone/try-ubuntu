# The AI app and its tools

The **AI** app (`live-ai`, in the app grid; at the first login it comes after Cloud
Backup) sets everything here up. To add, remove or reconfigure an agent, the local model
or the knowledge base, send the user there; the tools below are for reading state and for
the agents themselves.

| Command | What |
|---|---|
| `live-agent` | starts the default agent (`--list`, `--set-default NAME`, `--prompt TEXT`) |
| `live-agent-link` | links these skills into each agent's skills folder (`--status`) |
| `live-agent-crash <PID>` | opens the default agent on a crash, with the diagnose-crash skill |
| `live-crash-watch` | the user service behind the "… crashed" notifications (only with an agent installed) |
| `live-crash-mute ['<program>' [off]]` | mutes one program's crash notifications |
| `live-kb` | the knowledge base's sources (`status`, `list`, `add`, `remove`, `update`): see `knowledge-base` |
| `live-ai-resources` | CPU, RAM, GPU, disk, and the local model that fits |
| `live-debug` | a summary of the system, including an AI section |

## Where things are

- **Agents**: Claude Code from Anthropic's apt repository (`claude-code`); Codex CLI and
  OpenCode from npm, in the user's home (`~/.local/bin`, `~/.local/lib/node_modules`):
  update them with `npm install -g <package>@latest`, never `sudo npm`. Claude Desktop
  (`claude-desktop`) and ChatGPT (`chatgpt`) are apt packages from their vendors'
  repositories, added by their install.
- **Default agent**: `~/.config/live-ai/agent.conf`.
- **Ollama**: `/usr/bin/ollama` and `/usr/lib/ollama` from Ollama's release, run by
  `ollama.service` as the `ollama` user, listening on 127.0.0.1:11434 only; models in
  `/usr/share/ollama/.ollama`. The context length is in
  `/etc/systemd/system/ollama.service.d/live-ai.conf`. On this image it runs on the CPU
  unless the computer has an NVIDIA GPU with its driver or an AMD one with ROCm.
- **The knowledge base**: qmd (`~/.local/bin/qmd`), its config `~/.config/qmd/index.yml`
  (written by `live-kb`), its index and models in `~/.cache/qmd`, converted documents and
  GitHub copies in `~/.local/share/live-ai/kb`. Updated by `live-kb-update.timer` every 6
  hours on the charger.
- **MCP**: the `qmd` server is registered in Claude Code (`claude mcp list`), Codex
  (`~/.codex/config.toml`) and OpenCode (`~/.config/opencode/opencode.json`), for the
  agents the user allowed.

## Privacy, to tell the user when it matters

The index stays on this computer. But when a cloud agent (Claude Code, Codex) searches the
knowledge base, what it finds goes to its provider with the question. OpenCode with the
local model keeps everything here.
