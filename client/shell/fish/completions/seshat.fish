# seshat fish completions — PLACEHOLDER. Contents are owned by the Stage 3 (c) spec; this
# file must exist (build.zig embeds it) and name every subcommand (src/shell.zig checks).
complete -c seshat -f
complete -c seshat -n __fish_use_subcommand -a show -d 'Show tasks'
complete -c seshat -n __fish_use_subcommand -a tui -d 'Interactive full-screen view'
complete -c seshat -n __fish_use_subcommand -a add -d 'Add a task'
complete -c seshat -n __fish_use_subcommand -a update -d 'Edit a task'
complete -c seshat -n __fish_use_subcommand -a delete -d 'Delete a task'
complete -c seshat -n __fish_use_subcommand -a done -d 'Mark a task done'
complete -c seshat -n __fish_use_subcommand -a completions -d 'Print shell completions'
complete -c seshat -n __fish_use_subcommand -a init -d 'Print the fish prompt-hook file'
