// Runs $1, the recording program (screencapture), to record $3 seconds into the file $2.
// screencapture's own time limit (-V) cannot be stopped early: it ignores SIGINT, and any other signal ends it
// without a file. Without -V, SIGINT stops it and keeps what was recorded, so this script owns the time limit
// instead, and stops the recording with SIGINT when the time is up or when it gets SIGINT, SIGTERM, or SIGHUP
// itself. It keeps the limit even if the server is killed or crashes, and the recording program stays its
// child, so its process ID cannot be reused by another program while it is signalled. It exits with the
// recording program's status.
let recordingScript = """
"$1" -x -m -v "$2" </dev/null &
child=$!
( trap 'kill "$s" 2>/dev/null; exit 0' TERM; sleep "$3" & s=$!; wait "$s"; kill -INT "$child" 2>/dev/null ) &
timer=$!
signalled=0
trap 'signalled=1; kill -INT "$child" 2>/dev/null' INT TERM HUP
wait "$child"; status=$?
while [ "$signalled" = 1 ]; do signalled=0; wait "$child"; status=$?; done
kill "$timer" 2>/dev/null
exit "$status"
"""
