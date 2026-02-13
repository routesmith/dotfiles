#!/usr/bin/env bash
git config --global core.pager "delta"
git config --global delta.features "side-by-side line-numbers decorations"
git config --global delta.syntax-theme "gruvbox-dark"
git config --global delta.navigate true
git config --global delta.line-numbers true
git config --global delta.decorations.commit-decoration-style "bold yellow box"
git config --global delta.decorations.file-style "bold yellow ul"
git config --global delta.decorations.hunk-header-style "line-number syntax"
