#!/usr/bin/env zsh
# Prints the completion candidates zsh would offer for a command line, one per line, by driving
# a real `zsh -f -i` through zsh/zpty with `compadd` wrapped to record instead of insert. Exits 1
# if the completion printed an error (a `zsh -n` pass says nothing about _arguments specs).
# usage: zsh-complete.zsh <dir containing _seshat> <compdump path> <command line>
zmodload zsh/zpty || { echo 'zsh/zpty is unavailable' >&2; exit 2 }
dir=$1 dump=$2 line=$3
out=${TMPDIR:-/tmp}/zsh-complete.$$
: > $out
zpty -b z env TERM=dumb zsh -f -i
zpty -w z "PS1=''; fpath=($dir \$fpath); autoload -Uz compinit; compinit -u -d $dump"
zpty -w z 'zstyle ":completion:*" completer _complete'
zpty -w z 'compadd () { local -a m; builtin compadd -O m "$@"; (( $#m )) && print -l -- $m >> '$out'; return 1 }'
zpty -w z 'bindkey "^I" complete-word; setopt nobeep; print READY'
wait_for() {  # <marker>: drain the pty until the marker shows up, 5 s budget
  local chunk; acc=""
  for i in {1..50}; do
    zpty -r -t z chunk && acc+=$chunk
    [[ $acc == *$1* ]] && return 0
    sleep 0.1
  done
  return 1
}
wait_for READY || { echo 'zsh-complete: shell did not start' >&2; zpty -d z; rm -f $out; exit 2 }
zpty -w -n z "$line"$'\t'
sleep 0.5
zpty -w -n z $'\x15'"print MARK"$'\n'   # ^U clears whatever the completion inserted
wait_for MARK || { echo 'zsh-complete: no MARK after TAB' >&2; zpty -d z; rm -f $out; exit 2 }
zpty -d z
sort -u $out; rm -f $out
if print -r -- "$acc" | grep -aqiE 'parse error|command not found|_arguments:|_describe:|_values:'; then
  print -r -- "$acc" >&2
  exit 1
fi
exit 0
