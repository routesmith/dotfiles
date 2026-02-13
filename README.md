# Dotfiles

Cross-platform dotfiles for WSL Ubuntu 24.04 and macOS Sequoia, managed with [chezmoi](https://www.chezmoi.io/).

## Quick Start
```zsh
chezmoi init git@github.com:routesmith/dotfiles.git
# Edit ~/.config/chezmoi/chezmoi.toml and add your github_username
chezmoi apply
```

## Tools
- Zsh + modern plugins
- Neovim (separate repo)
- Tmux with gruvbox theme
- Starship prompt
- fzf, fd, ripgrep, bat, zoxide, delta
