# seshat fish integration: a `fish_prompt` hook that prints a cached block of the most urgent
# open tasks after a period of inactivity. Part 1 (above the guard) is always sourced — the
# `seshat-prompt` function depends on it; part 2 is interactive-only.
# `seshat init fish` prints functions/seshat-prompt.fish followed by this file.

set -q seshat_prompt_ttl;          or set -g seshat_prompt_ttl 60
set -q seshat_prompt_limit;        or set -g seshat_prompt_limit 5
set -q seshat_prompt_idle_minutes; or set -g seshat_prompt_idle_minutes 15

set -l __base $XDG_CACHE_HOME
test -n "$__base"; or set __base $HOME/.cache
set -g __seshat_dir     $__base/seshat
set -g __seshat_cache   $__seshat_dir/prompt
set -g __seshat_stamp   $__seshat_dir/prompt.stamp
set -g __seshat_attempt $__seshat_dir/prompt.attempt

# `__seshat_refresh` = TTL-gated async; `force` = async, no gate; `force sync` = blocking.
function __seshat_refresh --argument-names force mode
    if test "$force" != force
        set -l tried (path mtime --relative -- $__seshat_attempt)
        # a future mtime reads negative: treat it as stale
        if test -n "$tried"; and test $tried -ge 0; and test $tried -lt $seshat_prompt_ttl
            return
        end
    end

    # Close the spawn race before forking. Guarded: an unguarded redirect into a missing
    # directory warns into the prompt, and only the worker (under umask 077) may create the file.
    path is -f -- $__seshat_attempt; and echo > $__seshat_attempt

    # The umask must live inside the sh child: a fish `umask` here would leak into the shell.
    set -l script '
        umask 077
        d=$1; c=$2; a=$3; n=$4; t="$c.new.$$"
        mkdir -p -m 700 "$d" 2>/dev/null; chmod 700 "$d" 2>/dev/null
        : > "$a"
        rm -f "$c".new.* 2>/dev/null
        if seshat show --open --flat --no-color --limit "$n" > "$t" 2>/dev/null; then
            chmod 600 "$t" && mv -f "$t" "$c"
        else
            rm -f "$t"
        fi
    '
    set -l args seshat-refresh $__seshat_dir $__seshat_cache $__seshat_attempt $seshat_prompt_limit
    if test "$mode" = sync
        command sh -c $script $args >/dev/null 2>&1
    else
        # Only a simple external command truly backgrounds; `begin … end &` runs synchronously.
        command sh -c $script $args >/dev/null 2>&1 &
        disown 2>/dev/null
    end
end

# ------------------------------------------------------------------ part 2: interactive only
status is-interactive; or exit

path is -d -- $__seshat_dir;   or command mkdir -m 700 -p -- $__seshat_dir 2>/dev/null
path is -f -- $__seshat_stamp; or begin
    command touch -- $__seshat_stamp 2>/dev/null
    command chmod 600 -- $__seshat_stamp 2>/dev/null
end

# Zero forks on this path: every command substitution here is a builtin.
function __seshat_prompt --on-event fish_prompt
    set -q seshat_prompt_paused; and return
    command -q seshat; or return

    set -l idle (path mtime --relative -- $__seshat_stamp)
    path is -d -- $__seshat_dir; and echo > $__seshat_stamp

    __seshat_refresh

    # derived per prompt, so the knob can be set in config.fish (sourced after conf.d)
    set -l threshold (math -s0 "$seshat_prompt_idle_minutes * 60")
    # a missing stamp, or a future mtime, reads as maximally idle
    test -n "$idle"; and test $idle -ge 0; or set idle $threshold
    test $idle -ge $threshold; or return

    path is -f -- $__seshat_cache; or return
    read -zl buf < $__seshat_cache
    test -n "$buf"; or return
    # exactly one trailing newline: pure's prompt begins with \r\e[K
    printf '%s\n' (string trim -r -- $buf)
end

# A heuristic, deliberately incomplete (`command seshat …`, wrappers and sudo are missed); a miss
# costs one stale block for one TTL.
function __seshat_postexec --on-event fish_postexec
    string match -q -r '^\s*seshat\s+(add|update|delete|done|tui)\b' -- "$argv"
    and __seshat_refresh force
end

# fish autoloads completions/$cmd.fish only, so the seshat-prompt rules live here.
complete -c seshat-prompt -f
complete -c seshat-prompt -n "not __fish_seen_subcommand_from pause resume now status" -a pause  -d "Silence the block"
complete -c seshat-prompt -n "not __fish_seen_subcommand_from pause resume now status" -a resume -d "Un-silence the block"
complete -c seshat-prompt -n "not __fish_seen_subcommand_from pause resume now status" -a now    -d "Refresh and show on the next prompt"
complete -c seshat-prompt -n "not __fish_seen_subcommand_from pause resume now status" -a status -d "Report state, ages and row count"

# fisher lifecycle (event names derive from this file's basename); inert for installer users
function __seshat_fisher_install --on-event seshat_install
    echo "seshat: prompt block installed. `seshat-prompt pause` silences it."
end
function __seshat_fisher_uninstall --on-event seshat_uninstall
    command rm -rf -- $__seshat_dir
    set -e seshat_prompt_paused; or true
end
