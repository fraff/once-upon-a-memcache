#!/bin/bash

# use memcerror(1)
# implement a quiet mode
# make lockName global

SELF="${BASH_SOURCE[0]##*/}"
NAME="${SELF%.sh}"

workingDir="/var/tmp/$NAME"
logDir="/var/log/crons"
lockValue="$HOSTNAME"

OPTS="cCD:feEhlLstT:x"
USAGE="Usage: $SELF [$OPTS] [--] <cmdline> [arg] [...]"
HELP="
  $USAGE

        -c       clean last failedFile on success
        -C       clean lock and exit, usefull incase of stalled lock, use with caution
        -D <s>   delete lock <s> seconds after <cmdline> to be sure it won't be serialized on multiple machines
        -f       force, run anyway, use with caution
        -e       bash set -e
        -E       prompt on error
        -h       this help
        -l       log to $logDir/<cmdline>.log (default: stdout, stderr)
        -L       log append to $logDir/<cmdline>.log (default: stdout, stderr)
        -s       simul
        -t       simul
        -T <t>   kill <cmdline> after <t> seconds (default: none)
        -x       bash set -x

    if lock does not exist in memcache, create it, run <cmdline>, delete lock
    else create a .failed file in $workingDir and exit

    envvar: ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE

    ex: export ONCE_UPON_A_LOCK_MEMCACHE=sleep-any-arg
        $SELF sleep 1m &
        $SELF sleep 2m &

    ex: MEMCACHED_SERVERS=....
        MAILTO=....
        # limit lock concurrency with random sleep
        * * *  * *  admin sleep \${RANDOM:0:1}; $0 -c -D 4 -l -- /path/to/cmd arg1 arg2
"

function _warn ()
{
    [[ -t 2 ]] && echo -e "$@" >&2 || $run logger -t "$SELF[$$]" -- "$*"
}

function _quit ()
{
    _warn "$@"
    exit 1
}

function _create_file ()
{
    local file="$1" content="$2"

    echo "${content}" > "$file"
}

function _remove_file ()
{
    local file="$1"

    $run rm -f "$file"
}

function _create_failedfile ()
{
    _create_file "$@"
}

function _remove_failedfile ()
{
    _remove_file "$@"
}

function _create_memcache_lock ()
{
    local file="$1" content="$2" lockName tmp

    lockName="${file##*/}"

    # does key exist ?
    if memcexist "$lockName"
    then
        # does it contain "$content" ? if yes, it's already running
        tmp="$(memccat $lockName)"

        [[ "$tmp" == "$content" ]] && return 1

        # lockFile exists but it's not on this node.
        _warn "not running '$cmdLineStr' because lock '$lockName' exists on an other node ($tmp). exiting."
        exit 0
    fi

    # create tmpFile.
    _create_file "$file" "$content"

    # create lock in memcache server with name=$(basename $file), value=$(cat $file)
    # --add is for "do not overwrite"
    $run memccp --add "$file"

    # remove tempFile XXX should we leave it for monit purpose and delete it at the end ?
    _remove_file "$file"

    # random sleep
    $run sleep 1.${RANDOM:0:1}

    # $lockName does not exist, something went wrong
    $run memcexist "$lockName" || _quit "$SELF: memccp failed to create $lockName."

    # does it still contain $content ?
    tmp="$(memccat $lockName)"

    [[ "$tmp" == "$content" ]]

    return $?
}

function _remove_memcache_lock ()
{
    local file="$1" lockName

    lockName="${file##*/}"

    # if newExpire > 0, let memcache server delete $lockName, else, remove it now.
    (( newExpire > 0 )) && $run memctouch --expire $newExpire "$lockName" || $run memcrm "$lockName"

    # this should have been done before, but migth be interresting for monit purpose.
    _remove_file "$file"
}

unset run setX setE doLog deleteFailedFileOnSuccess deleteLockAndExit force

timeoutTerm=0
timeoutKill=32
newExpire=0

while getopts :$OPTS arg
do
    case "$arg" in
        c)    deleteFailedFileOnSuccess="yes"                       ;;
        C)    deleteLockAndExit="yes"                               ;;
        D)    newExpire="$OPTARG"                                   ;;
        f)    force=true                                            ;;
        e)    setE="set -e"                                         ;;
        E)    trap "read -p 'an error occurred, press ENTER '" ERR  ;;
        h)    _quit "$HELP"                                         ;;
        l)    doLog=1                                               ;;
        L)    doLog=2                                               ;;
        s)    run=echo                                              ;;
        t)    run=echo                                              ;;
        T)    timeoutTerm="$OPTARG"                                 ;;
        x)    setX="set -x"                                         ;;
        :)    _quit "$SELF: option -$OPTARG needs an argument."     ;;
        *)    _quit "  $USAGE"                                      ;;
    esac
done

shift $(($OPTIND - 1))

$setE
$setX

for cmd in timeout memcrm memccat memccp memcexist memctouch
do
    which $cmd &>/dev/null || _quit "$SELF: $cmd MUST be in PATH"
done

[[ $# -eq 0 ]] && _quit "  $USAGE"

[[ "$timeoutTerm" == *[![:digit:]]* ]] && _quit "$SELF: $timeoutTerm: Invalid number"
[[ "$newExpire" == *[![:digit:]]* ]] && _quit "$SELF: $newExpire: Invalid number"
[[ "$MEMCACHED_SERVERS" ]] || _quit "$SELF: please, set MEMCACHED_SERVERS first."
[[ "$HOSTNAME" ]] || _quit "$SELF: \$HOSTNAME must be defined for this script to work"

cmdLineStr="$*"
cmdLineArr=("$@")

# replace slahes and blanks with underscores.
tmpFile="${cmdLineStr//[\/[:blank:]]/_}"

ONCE_UPON_A_LOCK_MEMCACHE="${ONCE_UPON_A_LOCK_MEMCACHE//[\/[:blank:]]/_}"
ONCE_UPON_A_LOG_MEMCACHE="${ONCE_UPON_A_LOG_MEMCACHE//[\/[:blank:]]/_}"
ONCE_UPON_A_FAILED_MEMCACHE="${ONCE_UPON_A_FAILED_MEMCACHE//[\/[:blank:]]/_}"

lockFile="$workingDir/${ONCE_UPON_A_LOCK_MEMCACHE:-$tmpFile}.lock"
failedFile="$workingDir/${ONCE_UPON_A_FAILED_MEMCACHE:-$tmpFile}.failed"
logFile="$logDir/${ONCE_UPON_A_LOG_MEMCACHE:-$tmpFile}.log"

if [[ "$deleteLockAndExit" ]]
then
    _remove_memcache_lock "$lockFile"
    exit 0
fi

# create $workingDir
$run mkdir -m 1777 -p "$workingDir"

# if we can't create $lockFile with $cmdLineStr in it
_create_memcache_lock "$lockFile" "$lockValue"

# it will return a code != 0
createLockFileReturnCode=$?

if [[ "$createLockFileReturnCode" -ne 0 && -z "$force" ]]
then
    # create a failedFile
    $run _create_failedfile "$failedFile" "$cmdLineStr"
    # and exit
    # _quit "$SELF: already running: '$cmdLineStr' (at least, lock exists in memcache servers)"
    _quit "$SELF: not running '$cmdLineStr' because lock '${lockFile##*/}' exists. exiting."
fi

# delete failedFile on succes
[[ "$deleteFailedFileOnSuccess" ]] && _remove_failedfile "$failedFile"

# remove lockFile on exit, and exit with $commandLineReturnCode
trap '_remove_memcache_lock $lockFile; exit $commandLineReturnCode' EXIT

# log stdout and stderr in $logFile
(( doLog == 1 )) && $run exec &> $logFile
(( doLog == 2 )) && $run exec &>> $logFile

# flooding syslog is always a pleasure
_warn "starting: '$cmdLineStr'"

# "timeout" trap SIGINT, a workaround would be
# trap 'kill $!' INT
# ${cmdLineArr[@]} &
# wait

# just do it
$run timeout --kill-after=$timeoutKill $timeoutTerm "${cmdLineArr[@]}"

# return code, see trap EXIT above
commandLineReturnCode=$?

# one last for the road
_warn "stopping: '$cmdLineStr' (exitCode: $commandLineReturnCode, duration: ~${SECONDS}s)"


