#!/usr/bin/env fish
# Public function: add_task "title" priority [config_path]
# Sends a JSON POST to /api/tasks/add with Authorization header from config

function add_task
    if set -q SESHAT_DEBUG
        echo aargv"$argv"
    end
    if test (count $argv) -lt 2
        echo "Usage: add_task \"title\" priority [config_path]" >&2
        return 2
    end
    set -l title $argv[1]
    set -l priority $argv[2]
    set -l config_path
    if test (count $argv) -gt 2
        set config_path $argv[3]
    end

    set -l CONFIG (load_config $config_path)
    if test $status -ne 0
        echo "Failed to load config" >&2
        return 1
    end
    set -l URL $CONFIG[1]
    set -l SECRET $CONFIG[2]

    set -l cmd "printf '{\"title\":\"%s\",\"priority\":%s}' \"$title\" \"$priority\" | curl -s -X POST -H \"Content-Type: application/json\" -H \"Authorization: $SECRET\" -d @- $URL/api/tasks/add"
    seshat_eval "$cmd"
    return $status
end
