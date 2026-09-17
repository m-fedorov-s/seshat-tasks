#!/usr/bin/env bash
# Headless tests for client/shell/ (`make shell-test`). A local pre-commit target — CI does not
# run it (spec (c) D15). Needs fish >= 3.6.0, bash >= 5 and GNU coreutils; zsh and the
# bash-completion package are optional and their tests are skipped with a note.
#
# Every fish test runs the real files under `fish --no-config -i <script>` (the -i is what makes
# conf.d's `status is-interactive` guard pass), with HOME and the three XDG dirs inside a fresh
# temp sandbox and a fake `seshat` first on a PATH that never contains the developer's own.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
shell=$root/client/shell
fish_bin=$(command -v fish) || { echo "FAIL: fish is not on \$PATH"; exit 1; }
base_path=$(getconf PATH 2>/dev/null || echo /usr/bin:/bin)

block=$'○ Alpha task #a1b2\n├─ ○ Beta #c3d4\n◐ Gamma #e5f6\n… and 12 more'
src_conf="source $shell/fish/conf.d/seshat.fish"
src_fn="source $shell/fish/functions/seshat-prompt.fish"
src_comp="source $shell/fish/completions/seshat.fish"

pass=0; fail=0; skip=0; failed=()
tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT

# --- sandbox ---------------------------------------------------------------------------------

sandbox() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  tmp=$(mktemp -d)
  mkdir -p "$tmp/home" "$tmp/config" "$tmp/data" "$tmp/cache" "$tmp/bin" "$tmp/failbin" "$tmp/slowbin" "$tmp/nobin"
  export HOME=$tmp/home XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_CACHE_HOME=$tmp/cache
  cache=$tmp/cache/seshat
  calls=$tmp/calls
  : > "$calls"
  cat > "$tmp/bin/seshat" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
cat <<'BLOCK'
$block
BLOCK
FAKE
  cat > "$tmp/slowbin/seshat" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
sleep 3
cat <<'BLOCK'
$block
BLOCK
FAKE
  cat > "$tmp/failbin/seshat" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$calls"
echo 'error: no config' >&2
exit 1
FAKE
  chmod +x "$tmp/bin/seshat" "$tmp/slowbin/seshat" "$tmp/failbin/seshat"
}

# seed <stamp-age> [cache-content]: a warm cache dir with a backdated stamp
seed() {
  mkdir -p -m 700 "$cache"
  [ $# -ge 2 ] && printf '%s' "$2" > "$cache/prompt"
  touch -d "$1" "$cache/prompt.stamp"
}

# run_fish <fakes dir> [-n] <script line>...: fish --no-config -i (-n: without -i), stdin from
# /dev/null; sets $out, $err, $code.
run_fish() {
  local bindir=$1 flag=-i; shift
  [ "${1:-}" = -n ] && { flag=""; shift; }
  printf '%s\n' "$@" > "$tmp/script.fish"
  # shellcheck disable=SC2086
  PATH="$bindir:$base_path" TERM=dumb "$fish_bin" --no-config $flag "$tmp/script.fish" \
    </dev/null >"$tmp/out" 2>"$tmp/err"
  code=$?; out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

mode()  { stat -c %a "$1"; }
mtime() { stat -c %Y "$1"; }
now_ms() { echo $(( ${EPOCHREALTIME/[.,]/} / 1000 )); }
wait_calls() {  # <n>: until $calls has n lines (3 s budget)
  local i; for i in $(seq 1 30); do [ "$(wc -l < "$calls")" -ge "$1" ] && return 0; sleep 0.1; done; return 1
}
wait_file() {   # <path>: until it exists (3 s budget)
  local i; for i in $(seq 1 30); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1
}
first_new() { local f; for f in "$cache"/prompt.new.*; do [ -e "$f" ] && { echo "$f"; return 0; }; done; return 1; }

run() {
  why=""; sandbox
  if "$1"; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); failed+=("$1"); echo "FAIL: $1${why:+ — $why}"; fi
}
skip() { skip=$((skip+1)); echo "SKIP: $1 — $2"; }

# --- the hook --------------------------------------------------------------------------------

test_fish_version_floor() {
  local v; v=$("$fish_bin" --version | sed 's/^fish, version //')
  [[ $v =~ ^([4-9]|[1-9][0-9]|3\.([6-9]|[1-9][0-9])) ]] || { why="fish $v is too old: need >= 3.6.0 (path mtime --relative)"; return 1; }
}

test_noninteractive_is_inert() {
  run_fish "$tmp/bin" -n "$src_conf" 'functions -q __seshat_prompt; and echo DEFINED' 'echo "cache=$__seshat_cache"'
  [[ $out != *DEFINED* ]] || { why="the prompt handler was defined without -i"; return 1; }
  [[ $out == *"cache=$cache/prompt"* ]] || { why="part 1 did not run: $out"; return 1; }
}

test_cold_cache_silent() {
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ -z "$out" ] || { why="printed on a cold cache: $out"; return 1; }
  wait_file "$cache/prompt" || { why="no refresh landed"; return 1; }
  [ "$(mode "$cache")" = 700 ] || { why="dir mode $(mode "$cache")"; return 1; }
  [ "$(mode "$cache/prompt")" = 600 ] || { why="prompt mode $(mode "$cache/prompt")"; return 1; }
  [ "$(cat "$cache/prompt")" = "$block" ] || { why="cache content: $(cat "$cache/prompt")"; return 1; }
}

test_dir_mode_corrected() {
  mkdir -m 755 "$cache"
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  wait_file "$cache/prompt" || { why="no refresh landed"; return 1; }
  [ "$(mode "$cache")" = 700 ] || { why="dir left at $(mode "$cache")"; return 1; }
}

test_new_file_mode_during_write() {
  run_fish "$tmp/slowbin" "$src_conf" 'emit fish_prompt'
  local i f; for i in $(seq 1 30); do f=$(first_new) && break; sleep 0.1; done
  [ -n "${f:-}" ] || { why="no prompt.new.* appeared"; return 1; }
  [ "$(mode "$f")" = 600 ] || { why="$f is $(mode "$f") while being written"; return 1; }
}

test_refresh_argv() {
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  wait_calls 1 || { why="no call"; return 1; }
  [ "$(cat "$calls")" = "show --open --flat --no-color --limit 5" ] || { why="argv: $(cat "$calls")"; return 1; }
}

# The three knobs are read late, so `set -g` in config.fish (sourced after conf.d) is honoured.
test_knobs_late_bound() {
  seed '-90 seconds' "$block"$'\n'
  run_fish "$tmp/bin" "$src_conf" 'set -g seshat_prompt_idle_minutes 1' 'set -g seshat_prompt_limit 3' 'emit fish_prompt'
  [ "$out" = "$block" ] || { why="idle_minutes set after conf.d was ignored: [$out]"; return 1; }
  wait_calls 1 || { why="no call"; return 1; }
  [ "$(cat "$calls")" = "show --open --flat --no-color --limit 3" ] || { why="limit set after conf.d was ignored: $(cat "$calls")"; return 1; }
}

test_idle_prints() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ "$out" = "$block" ] || { why="printed: [$out]"; return 1; }
}

test_recent_stamp_silent() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt' 'emit fish_prompt'
  [ "$out" = "$block" ] || { why="expected the block once, got: [$out]"; return 1; }
}

test_stamp_updated() {
  seed '-2 hours'
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ "$(mtime "$cache/prompt.stamp")" -ge $(( $(date +%s) - 5 )) ] || { why="stamp not touched"; return 1; }
}

test_paused_silent() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/bin" 'set -g seshat_prompt_paused 1' "$src_conf" 'emit fish_prompt'
  [ -z "$out" ] || { why="printed while paused: $out"; return 1; }
}

test_no_binary_silent() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/nobin" "$src_conf" 'command -q seshat; and echo FOUND' 'emit fish_prompt'
  [[ $out != *FOUND* ]] || { why="a real seshat is reachable on $base_path"; return 1; }
  [ -z "$out" ] || { why="printed without a binary: $out"; return 1; }
  [ "$(mtime "$cache/prompt.stamp")" -lt $(( $(date +%s) - 3600 )) ] || { why="stamp was touched"; return 1; }
}

test_no_config_silent() {
  run_fish "$tmp/failbin" "$src_conf" 'emit fish_prompt' 'sleep 0.3' 'emit fish_prompt' 'emit fish_prompt'
  [ -z "$out" ] || { why="printed: $out"; return 1; }
  [ ! -e "$cache/prompt" ] || { why="a prompt file was created from a failed fetch"; return 1; }
  [ "$(wc -l < "$calls")" -eq 1 ] || { why="$(wc -l < "$calls") calls inside one TTL"; return 1; }
}

test_missing_cache_dir_is_silent() {
  run_fish "$tmp/failbin" "$src_conf" 'emit fish_prompt' 'sleep 0.3' 'command rm -rf -- $XDG_CACHE_HOME/seshat' 'emit fish_prompt'
  [ -z "$out" ] || { why="stdout: $out"; return 1; }
  [ -z "$err" ] || { why="stderr: $err"; return 1; }
}

test_future_mtime_recovers() {
  seed '+1 hour' "$block"$'\n'
  touch -d '+1 hour' "$cache/prompt.attempt"
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ "$out" = "$block" ] || { why="printed: [$out]"; return 1; }
  wait_calls 1 || { why="no refresh with a future attempt clock"; return 1; }
}

test_trailing_newline() {
  seed '-2 hours' "$block"$'\n\n\n'
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ "$(tail -c1 "$tmp/out" | od -An -c | tr -d ' ')" = '\n' ] || { why="last byte is not \\n"; return 1; }
  [ "$(tail -c2 "$tmp/out" | od -An -c | tr -d ' ')" != '\n\n' ] || { why="ends in a blank line"; return 1; }
}

test_serve_stale() {
  seed '-2 hours' "$block"$'\n'
  touch -d '-7 days' "$cache/prompt"
  local before; before=$(mtime "$cache/prompt")
  run_fish "$tmp/failbin" "$src_conf" 'emit fish_prompt'
  wait_calls 1 || { why="no refresh attempted"; return 1; }
  sleep 0.2
  [ "$(cat "$cache/prompt")" = "$block" ] || { why="cache changed"; return 1; }
  [ "$(mtime "$cache/prompt")" = "$before" ] || { why="cache mtime moved"; return 1; }
  [ "$(mtime "$cache/prompt.attempt")" -ge $(( $(date +%s) - 5 )) ] || { why="attempt clock not moved"; return 1; }
}

test_empty_cache_silent() {
  seed '-2 hours' ''
  run_fish "$tmp/bin" "$src_conf" 'emit fish_prompt'
  [ -z "$out" ] || { why="printed: $out"; return 1; }
}

test_postexec_triggers() {
  run_fish "$tmp/bin" "$src_conf" 'emit fish_postexec "seshat done a1b2"' 'emit fish_postexec "seshat tui"' \
    'emit fish_postexec "  seshat done a1b2"' 'emit fish_postexec "seshat update --status done a1"'
  wait_calls 4 || { why="only $(wc -l < "$calls") of 4 mutating lines spawned a worker"; return 1; }
  sandbox
  run_fish "$tmp/bin" "$src_conf" 'emit fish_postexec "ls -la"' 'emit fish_postexec "seshat show --open"' \
    'emit fish_postexec "command seshat done a1b2"' 'emit fish_postexec "seshat doneX a1"' \
    'emit fish_postexec "echo seshat done a1b2"' 'emit fish_postexec "sudo seshat done a1"'
  sleep 0.5
  [ "$(wc -l < "$calls")" -eq 0 ] || { why="a non-matching line spawned: $(cat "$calls")"; return 1; }
}

test_postexec_no_double_spawn() {
  seed '-2 hours'
  touch -d '-5 min' "$cache/prompt.attempt"
  run_fish "$tmp/bin" "$src_conf" 'emit fish_postexec "seshat done a1b2"' 'emit fish_prompt'
  sleep 1
  [ "$(wc -l < "$calls")" -eq 1 ] || { why="$(wc -l < "$calls") workers for one postexec+prompt pair"; return 1; }
}

test_no_umask_leak() {
  run_fish "$tmp/bin" "$src_conf" 'umask' '__seshat_refresh force sync' 'umask' '__seshat_refresh force' 'umask'
  [ "$(printf '%s\n' "$out" | sort -u | wc -l)" -eq 1 ] || { why="umask changed: $(echo $out)"; return 1; }
}

test_refresh_is_async() {
  local t0 t1; t0=$(now_ms)
  run_fish "$tmp/slowbin" "$src_conf" 'emit fish_prompt'
  t1=$(now_ms)
  [ $(( t1 - t0 )) -lt 300 ] || { why="prompt took $(( t1 - t0 )) ms with a 3 s fetch"; return 1; }
}

test_refresh_job_is_disowned() {
  run_fish "$tmp/slowbin" "$src_conf" '__seshat_refresh force' 'echo jobs=(count (jobs -p 2>/dev/null))'
  [[ $out == *"jobs=0"* ]] || { why="$out"; return 1; }
}

test_hot_path_is_fast() {
  printf '#!/bin/sh\necho date >> %s/forks\n' "$tmp" > "$tmp/bin/date"; chmod +x "$tmp/bin/date"
  run_fish "$tmp/bin" "$src_conf" 'function __seshat_test_noop --on-event seshat_test_noop; end' \
    'set -l xs (string split "" -- (string repeat -n 100 x))' \
    'time for i in $xs; emit seshat_test_noop; end' \
    'time for i in $xs; emit fish_prompt; end'
  local -a ms
  mapfile -t ms < <(printf '%s\n' "$err" | awk '/^Executed in/ { v=$3; u=$4; if (u ~ /^micro/) v/=1000; else if (u ~ /^sec/) v*=1000; printf "%d\n", v }')
  [ "${#ms[@]}" -eq 2 ] || { why="could not parse fish's time output: $err"; return 1; }
  local budget=$(( ms[0] * 20 )); [ "$budget" -lt 150 ] && budget=150
  [ "${ms[1]}" -le "$budget" ] || { why="hook ${ms[1]} ms per 100 prompts vs baseline ${ms[0]} ms"; return 1; }
  [ ! -s "$tmp/forks" ] || { why="the hook forked date"; return 1; }
  echo "      (hook ${ms[1]} ms / baseline ${ms[0]} ms per 100 prompts, zero forks)"
}

test_fish_syntax() {
  local f; for f in completions/seshat.fish conf.d/seshat.fish functions/seshat-prompt.fish; do
    "$fish_bin" -n "$shell/fish/$f" || { why="$f"; return 1; }
  done
}

test_resume_prints_next() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/bin" "$src_conf" "$src_fn" 'seshat-prompt pause' 'seshat-prompt resume' \
    'set -q seshat_prompt_paused; and echo STILL-SET' 'emit fish_prompt'
  [[ $out != *STILL-SET* ]] || { why="resume left the variable set"; return 1; }
  [[ $out == *"seshat prompt: paused"*"seshat prompt: resumed"*"$block" ]] || { why="got: [$out]"; return 1; }
}

test_status_reports_content_age() {
  seed '-2 hours' "$block"$'\n'
  touch -d '-7 days' "$cache/prompt"
  touch "$cache/prompt.attempt"
  run_fish "$tmp/bin" -n "$src_conf" "$src_fn" 'seshat-prompt status'
  [[ $out =~ content:\ +6048[0-9][0-9]\ s\ old ]] || { why="content age: $out"; return 1; }
  [[ $out =~ last\ try:\ +[0-9]\ s\ ago ]] || { why="last try: $out"; return 1; }
  [[ $out == *"idle:       15 min"* ]] || { why="idle line: $out"; return 1; }
}

test_seshat_prompt_status_noninteractive() {
  run_fish "$tmp/bin" -n "$src_conf" "$src_fn" 'seshat-prompt status'
  [ "$code" -eq 0 ] || { why="exit $code"; return 1; }
  [[ $out == *"idle:       15 min"* && $out == *"rows:       (no cache)"* ]] || { why="got: $out"; return 1; }
}

test_status_rows_excludes_trailer() {
  seed '-2 hours' "$block"$'\n'
  run_fish "$tmp/bin" -n "$src_conf" "$src_fn" 'seshat-prompt status'
  [[ $out == *"rows:       3"* ]] || { why="got: $out"; return 1; }
}

test_prompt_now() {
  run_fish "$tmp/slowbin" "$src_conf" "$src_fn" 'seshat-prompt now' "echo calls=(count (cat $calls))" \
    'path is -f -- $__seshat_stamp; and echo STAMP-PRESENT'
  [[ $out == *"calls=1"* ]] || { why="now returned before the fetch: $out"; return 1; }
  [[ $out != *STAMP-PRESENT* ]] || { why="stamp not removed"; return 1; }
}

test_prompt_bare_usage() {
  run_fish "$tmp/bin" -n "$src_conf" "$src_fn" 'seshat-prompt' 'echo "code=$status"'
  [[ $err == *"usage: seshat-prompt pause|resume|now|status"* ]] || { why="stderr: $err"; return 1; }
  [[ $out == *"code=1"* ]] || { why="bare call did not fail: $out"; return 1; }
}

# The single-file layout `seshat init fish` produces: functions first, then conf.d, so a
# non-interactive shell reaches the function before the guard aborts sourcing.
test_single_file_layout() {
  cat "$shell/fish/functions/seshat-prompt.fish" "$shell/fish/conf.d/seshat.fish" > "$tmp/single.fish"
  run_fish "$tmp/bin" -n "source $tmp/single.fish" 'seshat-prompt status'
  [ "$code" -eq 0 ] && [[ $out == *"idle:       15 min"* ]] || { why="code=$code out=[$out] err=[$err]"; return 1; }
  run_fish "$tmp/bin" "source $tmp/single.fish" 'functions -q __seshat_prompt; and echo DEFINED'
  [[ $out == *DEFINED* ]] || { why="interactive single-file layout did not define the hook"; return 1; }
}

# --- fish completions ------------------------------------------------------------------------

complete_names() { printf '%s\n' "$out" | cut -f1 | sort | tr '\n' ' '; }

test_complete_subcommands() {
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat '"
  [ "$(complete_names)" = "add completions delete done help init show tui update " ] || { why="$(complete_names)"; return 1; }
}

test_complete_show_flags() {
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --'"
  [ "$(complete_names)" = "--detailed --filter --flat --json --limit --no-color --open --sort " ] || { why="$(complete_names)"; return 1; }
}

test_complete_sort_order() {
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --sort '"
  [ "$(printf '%s\n' "$out" | head -1 | cut -f1)" = urgency ] || { why="first candidate: $(printf '%s\n' "$out" | head -1)"; return 1; }
}

test_complete_filter() {
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --filter '"
  [ "$(complete_names)" = "overdue status:cancelled status:done status:in_progress status:todo " ] || { why="bare: $(complete_names)"; return 1; }
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --filter status:'"
  [ "$(complete_names)" = "status:cancelled status:done status:in_progress status:todo " ] || { why="status: → $(complete_names)"; return 1; }
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --filter status:todo,'"
  [ "$(complete_names)" = "status:todo,cancelled status:todo,done status:todo,in_progress " ] || { why="status:todo, → $(complete_names)"; return 1; }
  run_fish "$tmp/bin" -n "$src_comp" "complete -C 'seshat show --filter tag:'"
  [ -z "$out" ] || { why="tag: offered: $out"; return 1; }
}

test_complete_handles() {
  seed '-2 hours' $'○ Über task #a1b2\n├─ ○ fix bug #123 in parser #c3d4\n└─ ○ [missing: #host]\n… and 12 more\n'
  run_fish "$tmp/bin" -n "$src_conf" "$src_comp" "complete -C 'seshat done '"
  [ "$out" = $'a1b2\tÜber task\nc3d4\tfix bug #123 in parser' ] || { why="got: [$out]"; return 1; }
}

test_complete_handles_no_cache() {
  run_fish "$tmp/bin" -n "$src_conf" "$src_comp" "complete -C 'seshat done '"
  [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] || { why="code=$code out=[$out] err=[$err]"; return 1; }
}

# --- main ------------------------------------------------------------------------------------

for t in test_fish_version_floor test_noninteractive_is_inert test_cold_cache_silent test_dir_mode_corrected \
  test_new_file_mode_during_write test_refresh_argv test_knobs_late_bound test_idle_prints \
  test_recent_stamp_silent test_stamp_updated test_paused_silent test_resume_prints_next \
  test_no_binary_silent test_no_config_silent test_missing_cache_dir_is_silent test_future_mtime_recovers \
  test_trailing_newline test_serve_stale test_status_reports_content_age test_seshat_prompt_status_noninteractive \
  test_status_rows_excludes_trailer test_empty_cache_silent test_postexec_triggers test_postexec_no_double_spawn \
  test_prompt_now test_prompt_bare_usage test_single_file_layout test_no_umask_leak \
  test_refresh_is_async test_refresh_job_is_disowned test_hot_path_is_fast test_complete_subcommands \
  test_complete_show_flags test_complete_sort_order test_complete_filter test_complete_handles \
  test_complete_handles_no_cache test_fish_syntax; do
  run "$t"
  [ "$t" = test_fish_version_floor ] && [ "$fail" -gt 0 ] && break
done

echo "shell-test: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || { printf '  %s\n' "${failed[@]}"; exit 1; }
