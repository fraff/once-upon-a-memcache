#!/bin/bash

# This scripts cannot work without NTP.

# TODO set a default for *Warn et *Expire
# implement a quiet mode

# FIXME use ONCE_UPON_A_MEMCACHE_{LOCK,LOG,FAILED} instead of ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE
# add _TIMEOUT

SELF="${BASH_SOURCE[0]##*/}"
NAME="${SELF%.sh}"

failedDir="/var/tmp/$NAME"
lockDir="$failedDir"
logDir="/var/log/crons"
printf -v nowStamp "%(%s)T" -1

OPTS="cCd:D:fFeEhlLstw:W:xZ"
USAGE="Usage: $SELF [$OPTS] [--] <cmdline> [arg] [...]"
HELP="
  $USAGE

        -c       clean failedFile on success (== lock does not exist)
        -C       clean failedFile if return code == 0
        -d <s>   set ttl lock to <s> seconds on create
        -D <s>   set ttl lock to <s> seconds on exit (do not delete it, just set new ttl)
        -f       force, do not check/create lock, remove it on exit, use with caution
        -F       create failed file if return code != 0
        -e       bash set -e
        -E       prompt on error
        -h       this help
        -i       TODO: case insensitive
        -l       log to $logDir/<cmdline>.log (default: stdout, stderr)
        -L       log append to $logDir/<cmdline>.log (default: stdout, stderr)
        -s       simul
        -t       simul
        -w <s>   warn if execution time < s
        -W <s>   warn if execution time > s
        -x       bash set -x
        -Z       clean lock, failedFile and exit, usefull incase of stalled lock, use with caution

    if lock does not exist in memcache, create it, run <cmdline>, delete lock
    else create a .failed file in $failedDir and exit

    envvar: ONCE_UPON_A_MEMCACHE (low priority), ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE (high priority)

    ex: export ONCE_UPON_A_MEMCACHE=sleep-any-arg
        $SELF sleep 1m &
        $SELF sleep 2m &

    ex: MEMCACHED_SERVERS=....
        # limit lock concurrency with random sleep
        * * *  * *  admin sleep \${RANDOM:0:1}; $SELF -c -D 16 -L -- nice -n 19 /path/to/cmd arg1 arg2
"

function _log ()
{
    [[ -t 2 ]] && echo -e "$@" >&2 || $run logger -t "$SELF[$$]" -- "$*"
}

function _quit ()
{
    _log "$@"
    exit 1
}

function _create_file ()
{
    local file="$1" content="$2"

    echo "$content" > "$file" || _quit "$SELF: Can't create $file"
}

function _remove_file ()
{
    local file="$1"

    $run rm -f "$file"
}

# function _create_memcache_lock () {}
# function _get_memcache_lock_content () {}
# function _compare_memcache_lock_content () {}

function _try_create_memcache_lock ()
{
    local file="$1" localHost="$2" localStamp="$3" lockHost lockStamp lockName tmp retCode memccpOpts diffTime

    lockName="${file##*/}"

    tmp=($(memccat "$lockName" 2>/dev/null))
    retCode=$?

    # does key exist ? does it contains something
    if [[ $retCode -eq 0 ]]
    then

        lockHost="${tmp[0]}" lockStamp="${tmp[1]}"
        
        # is this a valid format ?
        if [[ "${#tmp[*]}" -ne 2 || "$lockStamp" == *[![:digit:]]* ]]
        then
            $run _create_file "$failedFile" "Invalid lock content, expecting <host> <stamp>, got '${tmp[*]}'"
            exit 1
        fi

        # this will be executed on others nodes.
        ((diffTime = localStamp - lockStamp))
        if (( maxWarn > 0 && diffTime > maxWarn ))
        then
            _log "Warning: $lockName exists for more than ${maxWarn}s (${diffTime}s)"
            $run _create_file "$failedFile" "Warning: $lockName exists for more than ${maxWarn}s (${diffTime}s)"
        fi

        if [[ "$lockHost" == "$localHost" ]]
        then

# XXX we should create a failed file anyway,
#     then check for stalled lock
#     then keep going
            if ! pgrep -fx "$cmdLineStr" >/dev/null
            then
                _log "Warning: '$cmdLineStr' is not running, removing stalled lock"
                $run _create_file "$failedFile" "Warning: '$cmdLineStr' is not running, removing stalled lock"
# XXX should we exit or just keep going ?
                $run _remove_memcache_lock "$lockFile"
                exit 1
            fi
            #
            # create a failed file
            $run _create_file "$failedFile" "$cmdLineStr is already running on '$localHost'"
            # and quit.
            _quit "not running '$cmdLineStr' because lock '$lockName' exists on this node ($localHost). exiting."

        else
            # lock exists but not on this node.
            _log "not running '$cmdLineStr' because lock '$lockName' exists on an other node ($lockHost). exiting."
            exit 0
        fi
    fi

    # create tmpLockFile.
    $run _create_file "$file" "$localHost $localStamp"

    (( startExpire > 0 )) && memccpOpts=("--expire=$startExpire")
    # create lock in memcache server with name=$(basename $file), value=$(cat $file)
    # --add is for "do not overwrite"
    $run memccp "${memccpOpts[@]}" --add "$file" 2>/dev/null || _log "Can't create $lockName in memcache (code $?)."

    # pseudo random sleep
    $run sleep 0.${RANDOM:0:1}

    tmp=($(memccat "$lockName" 2>/dev/null))
    retCode=$?

#    lockHost="${tmp[0]}" lockStamp="${tmp[1]}"

    # does it still contain what we've just written in it ?
    [[ $retCode -eq 0 && "${tmp[*]}" == "$localHost $localStamp" ]]

    return $?
}

function _remove_memcache_lock ()
{
    local file="$1" lockName

    lockName="${file##*/}"

    # if exitExpire > 0, let memcache server delete $lockName, else, remove it now.
    (( exitExpire > 0 )) && $run memctouch --expire $exitExpire "$lockName" || $run memcrm "$lockName"

    # this file was for monitoring purpose.
    _remove_file "$file"
}

unset run setX setE doLog deleteFailedFileOnSuccess deleteLockAndExit force minWarn maxWarn createFailedFileIfNotZero deleteFailedFileOnZero

exitExpire=0
startExpire=0

while getopts :$OPTS arg
do
    case "$arg" in
        c)    deleteFailedFileOnSuccess=1                           ;;
        C)    deleteFailedFileOnZero=1                              ;;
        d)    startExpire="$OPTARG"                                 ;;
        D)    exitExpire="$OPTARG"                                  ;;
        e)    setE="set -e"                                         ;;
        E)    trap "read -p 'an error occurred, press ENTER '" ERR  ;;
        f)    force=true                                            ;;
        F)    createFailedFileIfNotZero=1                           ;;
        h)    _quit "$HELP"                                         ;;
        l)    doLog=1                                               ;;
        L)    doLog=2                                               ;;
        s)    run=echo                                              ;;
        t)    run=echo                                              ;;
        w)    minWarn="$OPTARG"                                     ;;
        W)    maxWarn="$OPTARG"                                     ;;
        x)    setX="set -x"                                         ;;
        Z)    deleteLockAndExit=1                                   ;;
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

command -v "${cmdLineArr[0]}" >/dev/null || _quit "$SELF: ${cmdLineArr[0]}: No such file or not executable."
[[ "$startExpire" == *[![:digit:]]* ]] && _quit "$SELF: $startExpire: Invalid number"
[[ "$exitExpire" == *[![:digit:]]* ]] && _quit "$SELF: $exitExpire: Invalid number"
[[ "$minWarn" == *[![:digit:]]* ]] && _quit "$SELF: $minWarn: Invalid number"
[[ "$maxWarn" == *[![:digit:]]* ]] && _quit "$SELF: $maxWarn: Invalid number"
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


if (( deleteLockAndExit ))
then
    _remove_memcache_lock "$lockFile"
    _remove_memcache_lock "$failedFile"
    exit 0
fi

# create $workingDir
$run mkdir -m 1777 -p "$failedDir" "$lockDir"

# from now until trap is defined, ctrl-C will leave lock forever
trap '' INT
trap '' TERM

# try to create a lock
$force _try_create_memcache_lock "$lockFile" "$HOSTNAME" "$nowStamp" || exit $?

# remove lockFile on exit, and exit with $commandLineReturnCode
trap '_remove_memcache_lock $lockFile; exit $commandLineReturnCode' EXIT
trap '_remove_memcache_lock $lockFile; exit $commandLineReturnCode' INT

# delete failedFile on succes
(( deleteFailedFileOnSuccess )) && $run _remove_file $failedFile

# log stdout and stderr in $logFile
(( doLog == 1 )) && $run exec &> $logFile
(( doLog == 2 )) && $run exec &>> $logFile

# flooding syslog is always a pleasure
_log "starting: '$cmdLineStr'"

# just do it
$run "${cmdLineArr[@]}"

# return code, see trap EXIT above
commandLineReturnCode=$?

# self explain
# TODO create a "warning' failed file for this ?
(( maxWarn > 0 && $SECONDS > maxWarn )) && _log "Warning: script has been running more that ${maxWarn}s"
(( minWarn > 0 && $SECONDS < minWarn )) && _log "Warning: script has been running less that ${minWarn}s"

# FIXME this would overwrite warning about execution time above.
if (( commandLineReturnCode == 0 ))
then
    (( deleteFailedFileOnZero )) && $run _remove_file $failedFile
else
    (( createFailedFileIfNotZero )) && _create_file "$failedFile" "$cmdLineStr: failed with exit code: $commandLineReturnCode"
fi


# one last for the road
_log "stopping: '$cmdLineStr' (exitCode: $commandLineReturnCode, duration: ~${SECONDS}s)"


