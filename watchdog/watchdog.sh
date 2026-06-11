#!/bin/sh
# Keeps the tethered Android relay device's notification-forwarder app
# alive: whitelists it from battery optimization (Doze) so Android doesn't
# kill its notification listener, and relaunches it if it's not running.
# See README's "Android relay device" section for setup.
set -eu

FORWARDER_PACKAGE="${FORWARDER_PACKAGE:-com.arlosoft.macrodroid}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-60}"

echo "Tudget relay watchdog starting (forwarder: $FORWARDER_PACKAGE)"
adb start-server

while true; do
  if ! adb get-state >/dev/null 2>&1; then
    echo "$(date -Is) waiting for device..."
    adb wait-for-usb-device
    sleep 2
  fi

  adb shell dumpsys deviceidle whitelist "+$FORWARDER_PACKAGE" >/dev/null 2>&1 || true

  if ! adb shell pidof "$FORWARDER_PACKAGE" >/dev/null 2>&1; then
    echo "$(date -Is) $FORWARDER_PACKAGE not running, relaunching"
    adb shell monkey -p "$FORWARDER_PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
