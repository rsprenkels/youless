#!/usr/bin/env bash
# install this privileged deploy helper file into /usr/local/sbin/deploy-youless.sh

set -euo pipefail

usage() {
  cat <<'EOF'
deploy-youless.sh --app-dir /opt/youless --unit youless.service --src /path/to/src --unit-src /path/to/youless.service
                 [--venv /opt/youless/.venv] [--requirements /path/to/requirements.txt]

Performs an atomic-ish deploy:
- syncs application files into APP_DIR (excluding .git etc.)
- installs/updates the systemd unit into /etc/systemd/system/
- runs systemctl daemon-reload
- restarts the service
- optionally updates a python venv from requirements.txt
EOF
}

APP_DIR=""
UNIT_NAME=""
SRC_DIR=""
UNIT_SRC=""
VENV_DIR=""
REQ_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)       APP_DIR="$2"; shift 2 ;;
    --unit)          UNIT_NAME="$2"; shift 2 ;;
    --src)           SRC_DIR="$2"; shift 2 ;;
    --unit-src)      UNIT_SRC="$2"; shift 2 ;;
    --venv)          VENV_DIR="$2"; shift 2 ;;
    --requirements)  REQ_FILE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$APP_DIR" || -z "$UNIT_NAME" || -z "$SRC_DIR" || -z "$UNIT_SRC" ]]; then
  echo "Missing required args." >&2
  usage
  exit 2
fi

# Safety checks: enforce expected service name (prevents abusing sudo to restart arbitrary units)
if [[ "$UNIT_NAME" != "youless.service" ]]; then
  echo "Refusing: unit must be youless.service (got: $UNIT_NAME)" >&2
  exit 3
fi

# Ensure directories exist
install -d -m 0755 "$APP_DIR"
install -d -m 0755 "/etc/systemd/system"

# Delete existing application files (preserving directory structure)
find "${APP_DIR}" -mindepth 1 -type f -delete
find "${APP_DIR}" -mindepth 1 -type d -empty -delete

# Copy specific application files individually
install -m 0755 -D "${SRC_DIR}/youless_reader.py" "${APP_DIR}/youless_reader.py"
if [[ -f "${SRC_DIR}/requirements.txt" ]]; then
  install -m 0644 -D "${SRC_DIR}/requirements.txt" "${APP_DIR}/requirements.txt"
fi
# Copy any additional Python modules from src/ if they exist
if [[ -d "${SRC_DIR}/src" ]]; then
  find "${SRC_DIR}/src" -type f -name "*.py" ! -name "*.pyc" -exec bash -c '
    rel="${1#${2}/}"
    install -m 0644 -D "$1" "${3}/$rel"
  ' _ {} "${SRC_DIR}" "${APP_DIR}" \;
fi

# Install the unit file with correct permissions
# (644 is standard for unit files)
install -m 0644 "$UNIT_SRC" "/etc/systemd/system/${UNIT_NAME}"

# Optional: build/update venv (recommended to run as a non-root service user in the unit file)
# Here we update the venv as root because this script is root-run; that’s acceptable if APP_DIR is root-owned.
if [[ -n "${VENV_DIR}" && -n "${REQ_FILE}" && -f "${REQ_FILE}" ]]; then
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
  fi
  "${VENV_DIR}/bin/python" -m pip install -U pip wheel
  "${VENV_DIR}/bin/python" -m pip install -r "${REQ_FILE}"
fi

# Reload and restart service
/bin/systemctl daemon-reload
/bin/systemctl restart "${UNIT_NAME}"

# Optional: show a brief status summary (useful in Jenkins logs)
echo "Deployed to ${APP_DIR} and restarted ${UNIT_NAME}"
/bin/systemctl --no-pager --full status "${UNIT_NAME}" | sed -n '1,20p'
