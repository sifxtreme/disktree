#!/bin/sh
# Run the Guilty Spark UI harness in a separate process: the app you have open is not touched, and
# your saved marks are neither read nor written.
#   apps/mac/harness/run.sh [OUT_DIR]        DISK_APP=<binary> to test a build before installing
# The app writes to a file, not a pipe: a reader that stops early would kill it with SIGPIPE, silently
# (no crash report). Screenshots are window-only (screencapture -x -l); results in OUT_DIR/results.json.
set -u
out=${1:-${TMPDIR:-/tmp}/disk-harness-$(date +%Y%m%d-%H%M%S)}
app=${DISK_APP:-"$HOME/Applications/Guilty Spark.app/Contents/MacOS/GuiltySpark"}
mkdir -p "$out"
: > "$out/out.log"
"$app" -harness YES -harnessOut "$out" > "$out/out.log" 2> "$out/stderr.log" &
pid=$!
seen=0
while kill -0 "$pid" 2>/dev/null; do
  lines=$(wc -l < "$out/out.log")
  if [ "$lines" -gt "$seen" ]; then
    tail -n +"$((seen + 1))" "$out/out.log" | head -n "$((lines - seen))" | while IFS= read -r line; do
      case "$line" in
        SHOT\ *)
          set -- $line
          screencapture -x -o -l "$3" "$out/$2.png" && sips -Z 1600 "$out/$2.png" --out "$out/$2.png" >/dev/null
          touch "$out/$2.ack"
          echo "shot $2"
          ;;
        *) echo "$line" ;;
      esac
    done
    seen=$lines
  fi
  sleep 0.2
done
wait "$pid"
code=$?
tail -n +"$((seen + 1))" "$out/out.log"
rm -f "$out"/*.ack
echo "exit $code · results: $out/results.json"
exit "$code"
