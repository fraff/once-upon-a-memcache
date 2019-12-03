#!/bin/bash

# TODO manage trap TERM/INT

SELF="${BASH_SOURCE[0]##*/}"
NAME="${SELF%.sh}"

failedDir="/var/tmp/$NAME"
lockDir="$failedDir"
logDir="/var/log/crons"

OPTS="cCeEFhlLstw:W:xZ"
USAGE="Usage: $SELF [$OPTS] [--] <cmdline> [arg] [...]"
HELP="
  $USAGE

        -c       clean failedFile on success (== lock does not exist)
        -C       clean failedFile if return code == 0
        -e       bash set -e
        -E       prompt on error
        -F       create failed file if return code != 0
        -h       this help
        -l       log to $logDir/<cmdline>.log (default: stdout, stderr)
        -L       log append to $logDir/<cmdline>.log (default: stdout, stderr)
        -s       simul
        -t       simul
        -w <s>   warn if execution time < s
        -W <s>   warn if execution time > s
        -x       bash set -x
        -Z       clean lock, failedFile and exit, usefull incase of stalled lock, use with caution

    if <cmdline> [arg] [...] is NOT running, run it
    else create a .failed file in $workingDir and exit

    envvar: ONCE_UPON_A_{LOCK,LOG,FAILED}_DIR && ONCE_UPON_A_{LOCK,LOG,FAILED}_FILE

    ex: export ONCE_UPON_A_LOCK_FILE=sleep-any-arg
        $SELF sleep 1m &
        $SELF sleep 2m &
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

# only usefull in run=echo mode
function _create_file ()
{
    local file="$1" content="$2"

    # in a subshell, don't allow bash to overwrite file, and try to create/overwrite $file
    # redirect stderr to /dev/null
    ( set -o noclobber; echo -n "$content" > $file ) 2> /dev/null
}

function _remove_file ()
{
    local file="$1"

    $run rm -f "$file"
}


unset run setX setE minWarn maxWarn doLog deleteFailedFileOnSuccess createFailedFileIfNotZero deleteFailedFileOnZero deleteLockAndExit

while getopts :$OPTS arg
do
    case "$arg" in
        c)    deleteFailedFileOnSuccess=1                           ;;
        C)    deleteFailedFileOnZero=1                              ;;
        e)    setE="set -e"                                         ;;
        E)    trap "read -p 'an error occurred, press ENTER '" ERR  ;;
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

[[ $# -eq 0 ]] && _quit "  $USAGE"

cmdLineStr="$*"
cmdLineArr=("$@")

command -v "${cmdLineArr[0]}" >/dev/null || _quit "$SELF: ${cmdLineArr[0]}: No such file or not executable."
[[ "$minWarn" == *[![:digit:]]* ]] && _quit "$SELF: $minWarn: Invalid number"
[[ "$maxWarn" == *[![:digit:]]* ]] && _quit "$SELF: $maxWarn: Invalid number"

# get envVar
for i in failed lock log
do
    varDirName="${i}Dir" envDirName="ONCE_UPON_A_${i^^}_DIR"
    envDirValue="${!envDirName}" varDirValue="${envDirValue:-$ONCE_UPON_A_DIR}" varDirValue="${varDirValue:-${!varDirName}}"

    declare "$varDirName=$varDirValue"

    varFileName="${i}File" envFileName="ONCE_UPON_A_${i^^}_FILE"
    envFileValue="${!envFileName}" varFileValue="${envFileValue:-$ONCE_UPON_A_FILE}" varFileValue="${varFileValue:-$cmdLineStr}"
    varFileValue="${varFileValue//[\/[:blank:]]/_}"

    declare "$varFileName=$varDirValue/$varFileValue.${i}"
done

if (( deleteLockAndExit ))
then
    $run _remove_file $lockDir
    $run _remove_file $failedFile
    exit 0
fi


# create $workingDir
$run mkdir -m 1777 -p "$failedDir" "$lockDir" || _quit "$SELF: Can't create '$failedDir' or '$lockDir'"

# if we can't create $lockFile with $cmdLineStr in it
$run _create_file "$lockFile" "$cmdLineStr"

# it will return a code != 0
createLockFileReturnCode=$?

if (( createLockFileReturnCode ))
then
    # FIXME script.sh will appear as "bash script.sh" in /bin/ps and won't be catched by pgrep
    if ! pgrep -fx "$cmdLineStr" > /dev/null
    then
        $run _create_file "$failedFile" "Warning: '$cmdLineStr' is not running, removing stalled lock"
        _remove_file "$lockFile"
        _quit "Warning: '$cmdLineStr' is not running, stalled lock removed"

        # TODO: save original command line with option and run it below        
        _log "Warning: '$cmdLineStr' is not running, stalled lock removed"
        $run _create_file "$failedFile" "Warning: '$cmdLineStr' is not running, stalled lock removed"
        exec $originalCommandLineWithOptions "$@"
    else
        # create a failedFile
        $run _create_file "$failedFile" "$cmdLineStr: lockfile exists."
        _quit "$SELF: already running: $cmdLineStr (lockFile: $lockFile)"
    fi
fi

# delete failedFile on succes
(( deleteFailedFileOnSuccess )) && $run _remove_file $failedFile

# remove lockFile on exit, and exit with $commandLineReturnCode
trap '_remove_file "$lockFile"; exit $commandLineReturnCode' EXIT

# log stdout and stderr in $logFile
(( doLog == 1 )) && $run exec &> $logFile
(( doLog == 2 )) && $run exec &>> $logFile

# flooding syslog is always a pleasure
_log "starting: '$cmdLineStr'"

$run "${cmdLineArr[@]}"

# return code, see trap EXIT above
commandLineReturnCode=$?

# self explain
# TODO create a "warning' failed file for this ?
(( maxWarn > 0 && $SECONDS > maxWarn )) && _log "Warning: script has been running more that ${maxWarn}s"
(( minWarn > 0 && $SECONDS < minWarn )) && _log "Warning: script has been running less that ${minWarn}s"


if (( commandLineReturnCode == 0 ))
then
    (( deleteFailedFileOnZero )) && $run _remove_file $failedFile
else
    (( createFailedFileIfNotZero )) && _create_file "$failedFile" "$cmdLineStr: failed with exit code: $commandLineReturnCode"
fi

# one last for the road
_log "stopping: '$cmdLineStr' (exitCode: $commandLineReturnCode, duration: ~${SECONDS}s)"


