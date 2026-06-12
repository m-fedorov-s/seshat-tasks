#!/usr/bin/env fish
# Dependencies: curl, jq, yq (mikefarah/yq or similar), sha256sum (or shasum -a 256)
# Make executable: chmod +x client/fish/print_tasks.fish
# Public functions in this file:
# - load_config [config_path]
# - fetch_tasks CONFIG -> prints JSON
# - format_tasks JSON [max_lines]
# Helper CLI: seshat show|add|delete

function seshat_eval -a cmd
    # seshat_eval CMD
    # Executes a single command string. If global SESHAT_DEBUG is set,
    # prints the command to stderr before executing it.
    if set -q SESHAT_DEBUG
        echo "[SESHAT_DEBUG] $cmd" >&2
    end
    eval $cmd
end

function load_config -a config_path
    # load_config [config_path]
    # Returns config as an array: [URL SECRET MAX_LINES CACHE_TTL CACHE_DIR]
    set -l CONFIG_FILE
    if test (count $config_path) -gt 0
        set CONFIG_FILE $config_path[1]
    else
        set CONFIG_FILE $HOME/.config/seshat/config.yaml
    end

    if not type -q yq
        echo "yq not found in path!" >&2
        echo "Install with: go install github.com/mikefarah/yq/v4@latest" >&2
        return 1
    end

    if not test -f $CONFIG_FILE
        echo "Error: config.yaml not found at $CONFIG_FILE" >&2
        return 1
    end

    echo (yq e '.url' $CONFIG_FILE)
    echo (yq e '.secret' $CONFIG_FILE)
    echo (yq e '.max_lines // 3' $CONFIG_FILE)
    echo (yq e '.cache_ttl_seconds // 300' $CONFIG_FILE)
    echo $HOME/.cache/seshat
    # ensure cache directory exists (do not expose as global here)
    test -d $HOME/.cache/seshat; or mkdir -p $HOME/.cache/seshat
    return 0
end

function fetch_tasks
    # fetch_tasks CONFIG
    # Writes JSON to stdout, using a local cache keyed by URL.

    set -l URL $argv[1]
    set -l SECRET $argv[2]
    set -l CACHE_TTL $argv[4]
    set -l CACHE_DIR $argv[5]

    if set -q SESHAT_DEBUG
        echo URL=$URL >&2
        echo SECRET=$SECRET >&2
        echo CACHE_TTL=$CACHE_TTL >&2
        echo CACHE_DIR=$CACHE_DIR >&2
    end

    set -l HASH ""
    if type -q sha256sum
        set HASH (printf "%s" $URL | sha256sum | awk '{print $1}')
    else if type -q shasum
        set HASH (printf "%s" $URL | shasum -a 256 | awk '{print $1}')
    else
        set HASH (printf "%s" $URL | base64 | tr '/+' '_-' | cut -c1-32)
    end

    set -l CACHE_FILE "$CACHE_DIR/tasks_$HASH.json"
    set -l META_FILE "$CACHE_DIR/tasks_$HASH.meta"

    set -l use_cache 0
    if test -f $CACHE_FILE -a -f $META_FILE -a -n "$URL"
        set -l last_fetch (seshat_eval "cat $META_FILE")
        set -l now (date +%s)
        set -l age (math $now - $last_fetch)
        if test $age -lt $CACHE_TTL
            set use_cache 1
        end
    end

    if test $use_cache -eq 1
        seshat_eval "cat $CACHE_FILE"
        return 0
    end

    set -l tmpfile (mktemp)
    seshat_eval "curl -s --max-time 10 -o $tmpfile $URL/api/tasks/get -H \"Authorization: $SECRET\""
    if test $status -ne 0
        if test -f $CACHE_FILE
            seshat_eval "cat $CACHE_FILE"
            rm -f $tmpfile
            return 0
        else
            echo "Error: failed to fetch tasks from $URL" >&2
            rm -f $tmpfile
            return 1
        end
    end

    seshat_eval "cat $tmpfile"
    seshat_eval "mv $tmpfile $CACHE_FILE"
    date +%s > $META_FILE
    return 0
end

function format_tasks -a json max_lines
    # format_tasks JSON [max_lines]
    if test (count $json) -eq 0
        echo ""; return 0
    end
    set -l JSON_INPUT $json
    if test -z $max_lines
        set max_lines 3
    end

    set -l total_tasks (printf "%s" $JSON_INPUT | jq length 2>/dev/null)
    if test $status -ne 0
        echo "Error: failed to parse JSON" >&2
        return 1
    end

    set -l lines_to_print $max_lines
    if test $total_tasks -gt $max_lines
        set lines_to_print (math "$max_lines - 1")
    end

    printf "%s" $JSON_INPUT | jq -r '
    if type=="array" then
        sort_by(-(.priority // 0)) |
        .[:'"$lines_to_print"'] |
        map("★ " + ((.priority // 0 | tostring) // "0") + "  " + (.title // "<no title>")) |
        .[]
    else
        "Error: expected JSON array"
    end
    '

    if test $status -ne 0
        echo "Error: failed to parse/format JSON (ensure jq is installed)" >&2
        return 1
    end

    if test $total_tasks -gt $max_lines
        echo "-> And more..."
    end
    return 0
end

function print_tasks
    set_color normal
    seshat show
end

function seshat
    # CLI wrapper: seshat show | add "title" priority | delete "title"
    set -l cmd $argv[1]
    set -l DIR (dirname (status -f))
    # Source public helpers if they exist next to this file
    if test -f $DIR/add_task.fish
        source $DIR/add_task.fish
    end
    if test -f $DIR/delete_task.fish
        source $DIR/delete_task.fish
    end

    switch $cmd
        case show
            set -l CONFIG (load_config $config_path)
            set -l json (fetch_tasks $CONFIG)
            if test $status -ne 0
                return $status
            end
            format_tasks "$json" $CONFIG[3]
            return $status
        case add
            if functions -q add_task
                add_task $argv[2..-1]
                return $status
            else
                echo "add_task function not available. Ensure add_task.fish is in the same dir." >&2
                return 1
            end
        case delete
            if functions -q delete_task
                delete_task $argv[2..-1]
                return $status
            else
                echo "delete_task function not available. Ensure delete_task.fish is in the same dir." >&2
                return 1
            end
        case '*'
            echo "Unkown sub command '$cmd'"
            echo "Usage: seshat show|add \"title\" priority|delete \"title\"" >&2
            return 2
    end
end
