# Control the seshat prompt block. Everything it reads is defined above conf.d's interactivity
# guard, so it also works from `fish -c`.
function seshat-prompt --description 'Control the seshat prompt block'
    if test (count $argv) -ne 1
        echo "usage: seshat-prompt pause|resume|now|status" >&2
        return 1
    end
    switch "$argv[1]"
        case pause
            set -U seshat_prompt_paused 1
            echo "seshat prompt: paused (seshat-prompt resume to undo)"
        case resume
            # no -U: `set -e -U` fails whenever the variable is not actually universal
            set -e seshat_prompt_paused; or true
            echo "seshat prompt: resumed"
        case now
            __seshat_refresh force sync
            command rm -f -- $__seshat_stamp
        case status
            set -q seshat_prompt_paused; and echo "state:      paused"; or echo "state:      active"
            echo "idle:       $seshat_prompt_idle_minutes min"
            echo "cache:      $__seshat_cache"
            set -l age (path mtime --relative -- $__seshat_cache)
            test -n "$age"; and echo "content:    $age s old"; or echo "content:    (no cache yet)"
            set -l tried (path mtime --relative -- $__seshat_attempt)
            test -n "$tried"; and echo "last try:   $tried s ago"; or echo "last try:   never"
            if path is -f -- $__seshat_cache
                read -zl buf < $__seshat_cache
                if test -n "$buf"
                    set -l rows (string match -v -r '^… and ' -- (string split -- \n (string trim -r -- $buf)))
                    echo "rows:       "(count $rows)
                else
                    echo "rows:       0 (empty — no open tasks, or the last refresh failed)"
                end
            else
                echo "rows:       (no cache)"
            end
            return 0
        case '*'
            echo "usage: seshat-prompt pause|resume|now|status" >&2
            return 1
    end
end
