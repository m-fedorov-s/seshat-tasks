#!/usr/bin/env fish
# Public function: delete_task "title" [config_path]
# Sends a JSON POST to /api/tasks/delete with Authorization header from config

function delete_task
    if test (count $argv) -lt 1
        echo "Usage: delete_task \"title\" [config_path]" >&2
        return 2
    end
    set -l title $argv[1]
    set -l config_path
    if test (count $argv) -gt 1
        set config_path $argv[2]
    end

    # Load config via the central loader
    set -l CONFIG (load_config $config_path)
    if test $status -ne 0
        echo "Failed to load config" >&2
        return 1
    end
    set -l URL $CONFIG[1]
    set -l SECRET $CONFIG[2]

    set -l cmd "printf '{\"title\":\"%s\"}' \"$title\" | curl -s -X POST -H \"Content-Type: application/json\" -H \"Authorization: $SECRET\" -d @- $URL/api/tasks/delete"
    seshat_eval "$cmd"
    return $status
end
