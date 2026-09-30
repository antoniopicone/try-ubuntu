# ~/.zshrc of the live image. The pure prompt is enabled for every user in
# /etc/zsh/zshrc.
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups share_history autocd interactive_comments
bindkey -e
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select

# ls with icons (Hack Nerd Font Mono, the terminal's font)
alias ls="eza --icons=always"
