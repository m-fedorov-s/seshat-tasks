# seshat fish completions. Hand-written from main.zig's flag tables; nothing here forks at file
# scope (a completion file that blocks hangs the shell).
set -l cmds show tui add update delete done completions init help
set -l seen __fish_seen_subcommand_from

complete -c seshat -f

complete -c seshat -n "not $seen $cmds" -a show   -d "Show the task forest"
complete -c seshat -n "not $seen $cmds" -a tui    -d "Interactive full-screen view"
complete -c seshat -n "not $seen $cmds" -a add    -d "Add a top-level task"
complete -c seshat -n "not $seen $cmds" -a update -d "Edit a task"
complete -c seshat -n "not $seen $cmds" -a delete -d "Delete a task"
complete -c seshat -n "not $seen $cmds" -a done   -d "Mark a task done"
complete -c seshat -n "not $seen $cmds" -a help   -d "Print usage"
complete -c seshat -n "not $seen $cmds" -a completions -d "Print shell completions"
complete -c seshat -n "not $seen $cmds" -a init   -d "Print the fish prompt-hook file"
complete -c seshat -n "not $seen $cmds" -l version -d "Print the client version"

complete -c seshat -n "$seen completions" -f -a "fish bash zsh"
complete -c seshat -n "$seen init"        -f -a "fish"

# show / tui
complete -c seshat -n "$seen show tui" -l sort -x -k \
    -a "urgency priority due title created" -d "Ordering (default urgency)"
complete -c seshat -n "$seen show tui" -l filter -x -a "(__seshat_filter)" \
    -d "tag:NAME | status:S1,S2 | overdue"
complete -c seshat -n "$seen show tui" -l open     -d "Only todo/in_progress"
complete -c seshat -n "$seen show"     -l flat     -d "Rank all tasks, no tree"
complete -c seshat -n "$seen show"     -l detailed -d "Multi-line blocks"
complete -c seshat -n "$seen show"     -l json     -d "Machine-readable Task array"
complete -c seshat -n "$seen show"     -l no-color -d "Disable color"
complete -c seshat -n "$seen show"     -l limit -x -d "Cap rendered rows at N"

# add / update
complete -c seshat -n "$seen add update" -l title       -x -d "Title"
complete -c seshat -n "$seen add update" -l description -x -d "Description"
complete -c seshat -n "$seen add update" -l status      -x -a "todo in_progress done cancelled"
complete -c seshat -n "$seen add update" -l priority    -x -k -a "high medium low none"
complete -c seshat -n "$seen add update" -l due         -x -d "YYYY-MM-DD | …THH:MM | +Nd|+Nw|+Nm | none"
complete -c seshat -n "$seen add update" -l scheduled   -x -d "YYYY-MM-DD | …THH:MM | +Nd|+Nw|+Nm | none"
complete -c seshat -n "$seen add update" -l tags        -x -d "comma-separated; empty clears"
complete -c seshat -n "$seen add update" -l dry-run  -d "Preview, do not write"
complete -c seshat -n "$seen add update" -l verbose  -d "Print the resulting task"

# ids, from the prompt-block cache (no network, no fork)
complete -c seshat -n "$seen update delete done" -a "(__seshat_handles)"

function __seshat_statuses_unchosen
    set -l chosen (string split , -- (string replace -r '^status:' '' -- (commandline -ct)))
    for s in todo in_progress done cancelled
        contains -- $s $chosen; or echo $s
    end
end

function __seshat_filter
    switch (commandline -ct)
        case 'status:*'
            # prefix goes as the 3rd argument; as the 4th it would yield status:todo,status:done
            __fish_complete_list , __seshat_statuses_unchosen 'status:'
        case '*'
            printf 'status:%s\n' todo in_progress done cancelled
            echo overdue
    end
end

# Parses compact `show` rows (`<glyph> <title> #<tail>`); offers the bare tail, since a leading
# `#` starts a comment in fish.
function __seshat_handles --description 'ids + titles from the prompt-block cache'
    path is -f -- $__seshat_cache; or return
    read -zl buf < $__seshat_cache
    for line in (string split -- \n $buf)
        set -l m (string match -r '^(.*?)\s+#([0-9a-z]+)$' -- $line)
        test (count $m) -eq 3; or continue
        printf '%s\t%s\n' $m[3] (string replace -r -- '(*UCP)^[^\w]+' '' $m[2])
    end
end
