// Runs $1, the recording program (screencapture), to record $3 seconds into the file $2.
// screencapture's own time limit (-V) cannot be stopped early: it ignores SIGINT, and any other signal ends it
// without a file. Without -V, SIGINT stops it and keeps what was recorded, so this script owns the time limit
// instead. When the time is up, or when the script gets SIGINT, SIGTERM, or SIGHUP, it sends SIGINT to the
// recorder every 0.2 seconds until it ends: a recorder that is still starting has not yet set up its handler and
// would miss a single signal. One that has not ended after 15 seconds is killed. Time is counted in 0.2-second
// turns of the loop, which may run a little long but never short, so a recording is never cut short. The script keeps the limit even
// if the server is killed or crashes. It signals the recorder by job number, which stops naming it once it has
// ended, so another program that is given the same process ID is never signalled. It exits with the recorder's
// status.
let recordingScript = """
signalled=0
trap 'signalled=1' INT TERM HUP
"$1" -x -m -v "$2" </dev/null &
child=$!
left=$(( $3 * 5 ))
grace=$(( \(recordingKillSeconds) * 5 ))
while kill -0 %1 2>/dev/null; do
  if [ "$signalled" = 1 ] || [ "$left" -le 0 ]; then
    if [ "$grace" -gt 0 ]; then kill -INT %1 2>/dev/null; grace=$(( grace - 1 )); else kill -KILL %1 2>/dev/null; fi
  else
    left=$(( left - 1 ))
  fi
  sleep 0.2
done
wait "$child"
"""

// How long the recorder has to finish its file once asked to stop, before it is killed.
let recordingKillSeconds = 15
