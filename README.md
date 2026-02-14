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

### tmux + Wezterm + Neovim Mouse & Clipboard Behavior (WSL / Windows 11)

Mouse is enabled in tmux (`set -g mouse on`) and Wezterm (custom bindings). Behavior changes depending on context:

- **Yank / Copy**:
  - tmux copy-mode (prefix + Space or mouse drag + y/Enter): Copies to tmux buffer **and** system clipboard (via OSC 52 → Wezterm → Windows clipboard).
  - Mouse drag-release in tmux: Same as above (auto-yank).
  - Plain Wezterm (no tmux): Drag-release or right-click → copies to system clipboard.

- **Paste**:
  - **Ctrl+Shift+V** (Wezterm default): Always pastes **system clipboard** (reliable across all contexts).
  - **Middle mouse click**:
    - Inside tmux: Pastes latest/active **tmux buffer**.
    - Inside tmux + Neovim: Pastes **system clipboard** (Neovim overrides).
    - Plain Wezterm: Pastes **system clipboard**.
  - **Shift+Insert**: Alternative for system clipboard paste (Wezterm default).

- **Right-click**:
  - Inside tmux: Opens tmux menu (pane/window/buffer operations) or context menu at cursor/line.
  - Plain Wezterm/PowerShell: Copies highlighted text + clears highlight (flush lingering selection).

- **Nested tmux sessions**:
  - Buffers are isolated per level.
  - Middle mouse in inner session → pastes inner tmux buffer.
  - In outer session → pastes outer tmux buffer.
  - System clipboard (OSC 52) is shared outward from any level.

#### Quick Reference Table

| Action                  | Plain Wezterm (no tmux)        | Inside tmux                    | Inside tmux + Neovim           | tmux Copy-Mode / Buffer Select |
|-------------------------|--------------------------------|--------------------------------|--------------------------------|--------------------------------|
| Left Drag-Select        | Copy to system clipboard       | tmux buffer + system clipboard | Neovim visual select           | tmux buffer + system clipboard |
| Left Single Click       | Focus                          | Focus                          | Cursor jump                    | Nothing                        |
| Left Double Click       | Snap + copy to clipboard       | Nothing                        | Snap to Visual mode            | Snap-copy + exit mode          |
| Middle Click (Paste)    | System clipboard               | tmux buffer                    | System clipboard               | Nothing                        |
| Middle Scroll           | Scroll output                  | Scroll copy-mode               | Scroll view                    | Scroll buffer                  |
| Right Click             | Nothing / Wezterm menu         | tmux menu                      | tmux menu at cursor            | tmux menu at position          |

#### Tips
- Prefer **Ctrl+Shift+V** for consistent system clipboard paste (ignores tmux nesting).
- Use middle mouse for quick repeat of last tmux yank inside sessions.
- Right-click flush in plain PowerShell/Wezterm clears lingering highlights after unfocus.
- See Wezterm config (`wezterm-wsl.lua`) for mouse_bindings overrides.
- Nested sessions: Buffers don't sync across levels—detach inner to reset.

This is the observed behavior as of Feb 2026. Update here if config changes affect it.
