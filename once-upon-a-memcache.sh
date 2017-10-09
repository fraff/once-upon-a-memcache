#!/bin/bash

# use memcerror(1)
# implement a quiet mode
# use a no-milk-today.sh mecanism

# FIXME use ONCE_UPON_A_MEMCACHE_{LOCK,LOG,FAILED} instead of ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE
# add _TIMEOUT

# add a checkSetup option, create, test, delete lockFile

SELF="${BASH_SOURCE[0]##*/}"
NAME="${SELF%.sh}"

failedDir="/var/tmp/$NAME"
lockDir="$failedDir"
logDir="/var/log/crons"
printf -v nowStamp "%(%s)T" -1

OPTS="cCD:feEhlLstw:W:x"
USAGE="Usage: $SELF [$OPTS] [--] <cmdline> [arg] [...]"
HELP="
  $USAGE

        -c       clean last failedFile on success
        -C       clean lock and exit, usefull incase of stalled lock, use with caution
        -D <s>   set lock expiration to <s> seconds on exit.
        -f       force, do not check/create lock, remove it on exit, use with caution
        -e       bash set -e
        -E       prompt on error
        -h       this help
        -i       TODO: case insensitive
        -l       log to $logDir/<cmdline>.log (default: stdout, stderr)
        -L       log append to $logDir/<cmdline>.log (default: stdout, stderr)
        -s       simul
        -t       simul
        -W <s>   TODO warn if now - startTime > s
        -w <s>   TODO warn if execution time < s
        -x       bash set -x

    if lock does not exist in memcache, create it, run <cmdline>, delete lock
    else create a .failed file in $workingDir and exit

    envvar: ONCE_UPON_A_MEMCACHE (low priority), ONCE_UPON_A_{LOCK,LOG,FAILED}_MEMCACHE (high priority)

    ex: export ONCE_UPON_A_MEMCACHE=sleep-any-arg
        $SELF sleep 1m &
        $SELF sleep 2m &

    ex: MEMCACHED_SERVERS=....
        # limit lock concurrency with random sleep
        * * *  * *  admin sleep \${RANDOM:0:1}; $SELF -c -D 16 -L -- /path/to/cmd arg1 arg2
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

    echo "$content" > "$file"
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
    local file="$1" localHost="$2" localStamp="$3" lockHost lockStamp lockName tmp retCode

    lockName="${file##*/}"

    tmp=($(memccat "$lockName" 2>/dev/null))
    retCode=$?

    # does key exist ? does it contains something
    if [[ $retCode -eq 0 ]]
    then

        lockHost="${tmp[0]}" lockStamp="${tmp[1]}"
        
        # is this a valid format ?
        [[ "${#tmp[*]}" -eq 2 ]] || _quit "Invalid lock content, expecting <host> <stamp>, got '${tmp[*]}', we should delete it"
        [[ "$lockStamp" == *[![:digit:]]* ]] && _quit "Remote stamp is invalid, we should delete the lock."

        (( lockWarn > 0 && localStamp - lockStamp > lockWarn )) && _warn "Warning: lock exists for $((localStamp - lockStamp))s"

        if [[ "$lockHost" == "$localHost" ]]
        then
            # pgrep && _warn ?
            #
            # create a failed file
            $run _create_file "$failedFile" "$cmdLineStr"
            # and quit.
            _quit "not running '$cmdLineStr' because lock '$lockName' exists on this node ($localHost). exiting."

        else
            # lockFile exists but it's not on this node.
            _warn "not running '$cmdLineStr' because lock '$lockName' exists on an other node ($lockHost). exiting."
            exit 0
        fi
    fi

    # create tmpLockFile.
    _create_file "$file" "$localHost $localStamp"

    # create lock in memcache server with name=$(basename $file), value=$(cat $file)
    # --add is for "do not overwrite"
    $run memccp --add "$file" 2>/dev/null || _warn "Can't create $lockName in memcache (code $?)."

    # pseudo random sleep
    $run sleep 1.${RANDOM:0:1}

    tmp=($(memccat "$lockName" 2>/dev/null))
    retCode=$?

    lockHost="${tmp[0]}" lockStamp="${tmp[1]}"

    # does it still contain what we've just written in it ?
    [[ $retCode -eq 0 && "${tmp[*]}" == "$localHost $localStamp" ]]

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

unset run setX setE doLog deleteFailedFileOnSuccess deleteLockAndExit force localWarn lockWarn

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
        w)    lockWarn="$OPTARG"                                    ;;
        W)    localWarn="$OPTARG"                                   ;;
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

# command -v "${cmdLineArr[0]}" >/dev/null || _quit "$SELF: ${cmdLineArr[0]}: No such file or not executable."
[[ "$newExpire" == *[![:digit:]]* ]] && _quit "$SELF: $newExpire: Invalid number"
[[ "$localWarn" == *[![:digit:]]* ]] && _quit "$SELF: $localWarn: Invalid number"
[[ "$lockWarn" == *[![:digit:]]* ]] && _quit "$SELF: $lockWarn: Invalid number"
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

# FIXME from now until trap is defined, ctrl-C will leave lock forever
# try to create a lock
$force _try_create_memcache_lock "$lockFile" "$HOSTNAME" "$nowStamp" || exit $?

# remove lockFile on exit, and exit with $commandLineReturnCode
trap '_remove_memcache_lock $lockFile; exit $commandLineReturnCode' EXIT

# delete failedFile on succes
[[ "$deleteFailedFileOnSuccess" ]] && _remove_file "$failedFile"

# log stdout and stderr in $logFile
(( doLog == 1 )) && $run exec &> $logFile
(( doLog == 2 )) && $run exec &>> $logFile

# flooding syslog is always a pleasure
_warn "starting: '$cmdLineStr'"

# just do it
$run "${cmdLineArr[@]}"

# return code, see trap EXIT above
commandLineReturnCode=$?

# self explain
(( localWarn > 0 && $SECONDS < localWarn )) && _warn "Warning: script has been running less that ${localWarn}s"

# one last for the road
_warn "stopping: '$cmdLineStr' (exitCode: $commandLineReturnCode, duration: ~${SECONDS}s)"


