#!/bin/zsh
set -e
U=787A6027-0A86-4AE0-9412-C99DCF4CE992
APP=${APP:?path to the Debug-iphonesimulator VirtualSIM.app}
OUT=${OUT:-$PWD}
xcrun simctl install $U $APP
for f in homeRouter lineStore lineInbox thread home email; do
  xcrun simctl terminate $U com.anthersystems.VirtualSIM 2>/dev/null || true
  xcrun simctl launch $U com.anthersystems.VirtualSIM -screenshot $f >/dev/null
  sleep 7
  xcrun simctl io $U screenshot $OUT/frame_$f.png >/dev/null 2>&1
  echo "captured $f"
done
