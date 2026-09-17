# seshat bash completions. Needs the bash-completion package (for _init_completion and
# __ltrim_colon_completions, which handle the `:` in --filter status:…); installed as
# ${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/seshat.
_seshat() {
    local cur prev words cword cmd i
    _init_completion -n : || return
    local cmds="show tui add update delete done completions init help"
    for ((i=1; i<cword; i++)); do
        case ${words[i]} in
            show|tui|add|update|delete|done|completions|init|help) cmd=${words[i]}; break;;
        esac
    done
    case $prev in
        --sort)     COMPREPLY=($(compgen -W "urgency priority due title created" -- "$cur")); return;;
        --status)   COMPREPLY=($(compgen -W "todo in_progress done cancelled" -- "$cur")); return;;
        --priority) COMPREPLY=($(compgen -W "none low medium high" -- "$cur")); return;;
        --filter)   COMPREPLY=($(compgen -W "overdue status:todo status:in_progress status:done status:cancelled" -- "$cur"))
                    __ltrim_colon_completions "$cur"; return;;
        --title|--description|--due|--scheduled|--tags|--limit) return;;
        completions) COMPREPLY=($(compgen -W "fish bash zsh" -- "$cur")); return;;
        init)        COMPREPLY=($(compgen -W "fish" -- "$cur")); return;;
    esac
    if [[ -z $cmd ]]; then COMPREPLY=($(compgen -W "$cmds --version" -- "$cur")); return; fi
    case $cmd in
        show) COMPREPLY=($(compgen -W "--sort --filter --open --flat --detailed --json --no-color --limit" -- "$cur"));;
        tui)  COMPREPLY=($(compgen -W "--sort --filter --open" -- "$cur"));;
        add|update) COMPREPLY=($(compgen -W "--title --description --status --priority --due --scheduled --tags --dry-run --verbose" -- "$cur"));;
    esac
}
complete -F _seshat seshat
