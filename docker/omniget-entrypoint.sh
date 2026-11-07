#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OmniGet container entrypoint.
#
#  1. When started as root, fix volume ownership and re-exec as `omniget`.
#  2. Start a virtual X display (Xvfb) — Tauri needs a real X11 server.
#  3. Mirror that display with x11vnc and serve it over noVNC on :6080.
#  4. Run the app inside a DBus session so the tray icon/notifications work.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_USER="${APP_USER:-omniget}"
export HOME="${HOME:-/home/omniget}"
export OMNIGET_DATA_DIR="${OMNIGET_DATA_DIR:-/data}"
export DISPLAY="${DISPLAY:-:99}"
export GDK_BACKEND="${GDK_BACKEND:-x11}"
export NO_AT_BRIDGE="${NO_AT_BRIDGE:-1}"

# WebKitGTK sandboxes its web process with bubblewrap, which needs user
# namespaces that most container runtimes restrict. The app already disables
# the DMABUF/compositing paths on Linux; this keeps the web process alive.
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS="${WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS:-1}"

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$OMNIGET_DATA_DIR" "$HOME/Downloads"
  # Top-level only: downloads can be large and the app writes as `omniget`.
  chown "$APP_USER:$APP_USER" "$OMNIGET_DATA_DIR" "$HOME/Downloads" 2>/dev/null || true
  exec gosu "$APP_USER" "$0" "$@"
fi

mkdir -p "$OMNIGET_DATA_DIR" "$HOME/Downloads"

RESOLUTION="${RESOLUTION:-1440x900x24}"
VNC_PASSWORD="${VNC_PASSWORD:-omniget}"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-6080}"

# A fresh /tmp (tmpfs) starts without the X11 socket directory; Xvfb needs it.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# A container restart keeps /tmp. If the previous Xvfb died without cleaning up
# (EasyPanel restarts, app crash), its lock makes the next start fail with
# "Server is already active for display 99" and the container loops forever.
# Remove it only when no X server is actually answering on that display.
display_num="${DISPLAY#:}"
if [ -e "/tmp/.X${display_num}-lock" ] && ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "[omniget] removing stale /tmp/.X${display_num}-lock"
  rm -f "/tmp/.X${display_num}-lock" "/tmp/.X11-unix/X${display_num}"
fi

echo "[omniget] starting Xvfb on ${DISPLAY} (${RESOLUTION})"
Xvfb "$DISPLAY" -screen 0 "$RESOLUTION" -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!

for _ in $(seq 1 100); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! kill -0 "$XVFB_PID" 2>/dev/null; then
  echo "[omniget] Xvfb failed to start" >&2
  cat /tmp/xvfb.log >&2 || true
  exit 1
fi

echo "[omniget] starting x11vnc on 127.0.0.1:${VNC_PORT}"
x11vnc -storepasswd "$VNC_PASSWORD" "$HOME/.vncpass" >/dev/null 2>&1
x11vnc -display "$DISPLAY" -rfbauth "$HOME/.vncpass" \
       -forever -shared -rfbport "$VNC_PORT" -localhost -quiet \
       >/tmp/x11vnc.log 2>&1 &

echo "[omniget] serving noVNC on 0.0.0.0:${WEB_PORT}"
websockify --web=/usr/share/novnc --heartbeat=30 "$WEB_PORT" "127.0.0.1:${VNC_PORT}" \
       >/tmp/websockify.log 2>&1 &

echo "[omniget] launching the app (data: ${OMNIGET_DATA_DIR})"
exec dbus-run-session -- /usr/local/bin/omniget