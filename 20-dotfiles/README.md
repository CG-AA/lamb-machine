# 20-dotfiles (placeholder)

Per-user config managed by **chezmoi** (decided; not built yet).

Planned scope:
- Shell: `~/.bashrc_lamb` (pyenv init, PATH, `gemini`/`claude`/`s` aliases, `mount-subvol`).
- Git: `~/.gitconfig` (SSH-signed commits), `~/.config/git/ignore`.
- AI tools: Claude Code (`CLAUDE.md`, `settings.json`, `keybindings.json`), Gemini, Copilot —
  **config only, never credentials**.
- Editor: VSCode `settings.json` + a tracked extension list.

Migration: absorb the existing `/space/customisations` (stow-based: `bashrc/.bashrc_lamb`,
`stow_all.py`) into this chezmoi source and retire it.
