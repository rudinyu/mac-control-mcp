// Runs $1, the recording program (screencapture), to record $3 seconds into the file $2.
// screencapture's own time limit (-V) cannot be stopped early: it ignores SIGINT, and any other signal ends it
// without a file. Without -V, SIGINT stops it and keeps what was recorded, so this script owns the time limit
// instead. When the time is up, or when the script gets SIGINT, SIGTERM, or SIGHUP, it sends SIGINT to the
// recorder every 0.2 seconds until it ends: a recorder that is still starting has not yet set up its handler and
// would miss a single signal. One that has not ended after 15 seconds is killed. The script keeps the limit even
// if the server is killed or crashes. It signals the recorder by job number, which stops naming it once it has
// ended, so another program that is given the same process ID is never signalled. It exits with the recorder's
// status.
let recordingScript = """
signalled=0
trap 'signalled=1' INT TERM HUP
"$1" -x -m -v "$2" </dev/null &
child=$!
end=$(( $(date +%s) + $3 ))
asked=
while kill -0 %1 2>/dev/null; do
  now=$(date +%s)
  if [ "$signalled" = 1 ] || [ "$now" -ge "$end" ]; then
    : "${asked:=$now}"
    if [ $(( now - asked )) -lt \(recordingKillSeconds) ]; then kill -INT %1 2>/dev/null; else kill -KILL %1 2>/dev/null; fi
  fi
  sleep 0.2
done
wait "$child"
"""

// How long the recorder has to finish its file once asked to stop, before it is killed.
let recordingKillSeconds = 15
