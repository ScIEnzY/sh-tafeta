# sh-tafeta — tmux side. Sourced from your tmux.conf by `sh-tafeta install`
# (the source-file line must come BEFORE `run '~/.tmux/plugins/tpm/tpm'`).
# `sh-tafeta` must be in the PATH of the tmux server (~/.local/bin usually is).

set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'

# Panes that were running Claude Code come back with THEIR session.
# Add your own programs after this line if you need them, e.g.
#   set -ga @resurrect-processes ' "~htop"'
set -g @resurrect-processes '"~claude->sh-tafeta resume"'

# Every layout snapshot also records which Claude session runs in which pane,
# and a finished restore is reported to `sh-tafeta restore`.
set -g @resurrect-hook-post-save-all 'sh-tafeta snapshot'
set -g @resurrect-hook-post-restore-all 'sh-tafeta restored-mark'

# Pane scrollback is NOT saved to disk (it would contain whatever Claude printed,
# secrets included). Turn it on if you want it.
set -g @resurrect-capture-pane-contents 'off'

# Snapshot every 10 minutes, restore automatically when the tmux server starts.
set -g @continuum-save-interval '10'
set -g @continuum-restore 'on'
