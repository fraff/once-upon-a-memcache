#!/bin/bash

# use memcerror(1)
# implement a quiet mode
# XXX move _create_file _after_ memecexist

# use a no-milk-today.sh mecanism

SELF="${BASH_SOURCE[0]##*/}"
NAME="${SELF%.sh}"

failedDir="/var/tmp/$NAME"
lockDir="$failedDir"
logDir="/var/log/crons"
lockValue="$HOSTNAME"

OPTS="cCD:feEhlLstx"
USAGE="Usage: $SELF [$OPTS] [--] <cmdline> [arg] [...]"
HELP="
  $USAGE

        -c       clean last failedFile on success
        -C       clean lock and exit, usefull incase of stalled lock, use with caution
        -D <s>   delete lock <s> seconds after <cmdline> to be sure it won't be serialized on multiple machines
        -f       force, do not check/create lock, remove it on exit, use with caution
        -e       bash set -e
        -E       prompt on error
        -h       this help
        -l       log to $logDir/<cmdline>.log (default: stdout, stderr)
        -L       log append to $logDir/<cmdline>.log (default: stdout, stderr)
        -s       simul
        -t       simul
        -x       bash set -x

    if lock does not exist in memcache, create it, run <cmdline>, delete lock
    else create a .failed file in $workingDir and exit

    envvar: ONCE_UPON_A_MEMCACHE (low priority), ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE (high priority)

    ex: export ONCE_UPON_A_MEMCACHE=sleep-any-arg
        $SELF sleep 1m &
        $SELF sleep 2m &

    ex: MEMCACHED_SERVERS=....
        # limit lock concurrency with random sleep
        * * *  * *  admin sleep \${RANDOM:0:1}; $SELF -c -D 4 -l -- /path/to/cmd arg1 arg2
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

        if [[ "$tmp" == "$content" ]]
        then
            # create a failed file
            $run _create_failedfile "$failedFile" "$cmdLineStr"
            # create tmpLockFile for monitoring purpose, this file could warn us if a lock stalled in memcache.
            _create_file "$file" "$content"
            # and quit.
            _quit "not running '$cmdLineStr' because lock '$lockName' exists on this node ($HOSTNAME). exiting."

        else
            # lockFile exists but it's not on this node.
            _warn "not running '$cmdLineStr' because lock '$lockName' exists on an other node (${tmp:-null}). exiting."
            exit 0
        fi
    fi

    # create tmpLockFile.
    _create_file "$file" "$content"

    # create lock in memcache server with name=$(basename $file), value=$(cat $file)
    # --add is for "do not overwrite"
    $run memccp --add "$file" 2>/dev/null || _warn "Can't create $lockName on line $LINENO"

    # remove tmpLockFile XXX should we leave it for monit purpose and delete it at the end ?
    # _remove_file "$file"

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

    # this file was for monitoring purpose.
    _remove_file "$file"
}

unset run setX setE doLog deleteFailedFileOnSuccess deleteLockAndExit force

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
        x)    setX="set -x"                                         ;;
        :)    _quit "$SELF: option -$OPTARG needs an argument."     ;;
        *)    _quit "  $USAGE"                                      ;;
    esac
done

shift $(($OPTIND - 1))

$setE
$setX

for cmd in memcrm memccat memccp memcexist memctouch
do
    which $cmd &>/dev/null || _quit "$SELF: $cmd MUST be in PATH"
done

[[ $# -eq 0 ]] && _quit "  $USAGE"

cmdLineStr="$*"
cmdLineArr=("$@")

# [[ -x "${cmdLineArr[0]}" ]] || _quit "$SELF: ${cmdLineArr[0]}: No such file or not executable."
[[ "$newExpire" == *[![:digit:]]* ]] && _quit "$SELF: $newExpire: Invalid number"
[[ "$MEMCACHED_SERVERS" ]] || _quit "$SELF: please, set MEMCACHED_SERVERS first."
[[ "$HOSTNAME" ]] || _quit "$SELF: \$HOSTNAME must be defined for this script to work"

# get envVar
for i in failed lock log
do
    varName="${i}File" envName="ONCE_UPON_A_${i^^}_MEMCACHE" dirName="${i}Dir" dirName="${!dirName}"
    envValue="${!envName}" envValue="${envValue:-$ONCE_UPON_A_MEMCACHE}" envValue="${envValue:-$cmdLineStr}"
    envValue="${envValue//[\/[:blank:]]/_}"

    declare "$varName=$dirName/$envValue.${i}"
done


if [[ "$deleteLockAndExit" ]]
then
    _remove_memcache_lock "$lockFile"
    exit 0
fi

# create $workingDir
$run mkdir -m 1777 -p "$failedDir" "$lockDir"

# try to create a lock
$force _create_memcache_lock "$lockFile" "$lockValue" || exit $?

# delete failedFile on succes
[[ "$deleteFailedFileOnSuccess" ]] && _remove_failedfile "$failedFile"

# remove lockFile on exit, and exit with $commandLineReturnCode
trap '_remove_memcache_lock $lockFile; exit $commandLineReturnCode' EXIT

# log stdout and stderr in $logFile
(( doLog == 1 )) && $run exec &> $logFile
(( doLog == 2 )) && $run exec &>> $logFile

# flooding syslog is always a pleasure
_warn "starting: '$cmdLineStr'"

# just do it
$run "${cmdLineArr[@]}"

# return code, see trap EXIT above
commandLineReturnCode=$?

# one last for the road
_warn "stopping: '$cmdLineStr' (exitCode: $commandLineReturnCode, duration: ~${SECONDS}s)"


