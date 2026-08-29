#!/usr/bin/env bash
# install this privileged deploy helper file into /usr/local/sbin/deploy-youless.sh

set -euo pipefail

usage() {
  cat <<'EOF'
deploy-youless.sh --app-dir /opt/youless --unit youless.service --src /path/to/src --unit-src /path/to/youless.service
                 [--venv /opt/youless/.venv] [--requirements /path/to/requirements.txt]
                 [--python /usr/bin/python3]

Performs an atomic-ish deploy:
- syncs application files into APP_DIR (excluding .git etc.)
- installs/updates the systemd unit into /etc/systemd/system/
- installs the capture-freshness check and its service+timer, and enables the
  timer if /etc/youless/freshness.env exists (that file is provisioned by hand,
  see INSTALL.md)
- runs systemctl daemon-reload
- restarts the service
- optionally updates a python venv from requirements.txt

NOTE: this script is installed at /usr/local/sbin/deploy-youless.sh and the
sudoers rule pins that path, so editing it in git is not enough -- copy it onto
each node by hand. See INSTALL.md.
EOF
}

APP_DIR=""
UNIT_NAME=""
SRC_DIR=""
UNIT_SRC=""
VENV_DIR=""
REQ_FILE=""
# Interpreter the venv is built from. Defaults to Debian's, deliberately: the venv
# should depend on a dpkg-managed python, not on a hand-built one in /usr/local.
PYTHON_BIN="/usr/bin/python3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)       APP_DIR="$2"; shift 2 ;;
    --unit)          UNIT_NAME="$2"; shift 2 ;;
    --src)           SRC_DIR="$2"; shift 2 ;;
    --unit-src)      UNIT_SRC="$2"; shift 2 ;;
    --venv)          VENV_DIR="$2"; shift 2 ;;
    --requirements)  REQ_FILE="$2"; shift 2 ;;
    --python)        PYTHON_BIN="$2"; shift 2 ;;
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

echo "deploy_youless.sh is starting."

# Ensure directories exist
install -d -m 0755 "$APP_DIR"
install -d -m 0755 "/etc/systemd/system"

# Delete existing application files (preserving directory structure).
#
# .venv and data are excluded, and that exclusion is load-bearing. -type f does not
# match symlinks, so without it this wiped every real file out of the venv --
# pyvenv.cfg, site-packages, the lot -- while leaving bin/python, bin/python3 and
# lib64 behind, because those are symlinks. What survived looked enough like a venv
# that the guard below skipped rebuilding it, and pip then installed into whatever
# the base interpreter was. That is how both nodes ended up with a decoy .venv and
# their dependencies in /usr/local. See INSTALL.md.
find "${APP_DIR}" -mindepth 1 -type f \
     -not -path "${APP_DIR}/.venv/*" \
     -not -path "${APP_DIR}/data/*" -delete
find "${APP_DIR}" -mindepth 1 -depth -type d -empty \
     -not -path "${APP_DIR}/.venv" -not -path "${APP_DIR}/.venv/*" \
     -not -path "${APP_DIR}/data"  -not -path "${APP_DIR}/data/*" -delete

# Copy specific source files individually
install -m 0644 -D "${SRC_DIR}/src/youless_reader.py" "${APP_DIR}/src/youless_reader.py"
install -m 0644 -D "${SRC_DIR}/src/youless_dao_postgres.py" "${APP_DIR}/src/youless_dao_postgres.py"
# Tested and installed from the same path. It used to test ${SRC_DIR}/requirements.txt
# while installing ${SRC_DIR}/src/requirements.txt, so on a workspace where the file
# lives under src/ -- which is every workspace -- the test failed and APP_DIR never
# got a copy at all.
if [[ -f "${SRC_DIR}/src/requirements.txt" ]]; then
  install -m 0644 -D "${SRC_DIR}/src/requirements.txt" "${APP_DIR}/requirements.txt"
fi

# Copy any additional Python modules from src/ if they exist
#  if [[ -d "${SRC_DIR}/src" ]]; then
#    find "${SRC_DIR}/src" -type f -name "*.py" ! -name "*.pyc" -exec bash -c '
#      rel="${1#${2}/}"
#      install -m 0644 -D "$1" "${3}/$rel"
#    ' _ {} "${SRC_DIR}" "${APP_DIR}" \;
#  fi

# Install the unit file with correct permissions
# (644 is standard for unit files)
install -m 0644 "$UNIT_SRC" "/etc/systemd/system/${UNIT_NAME}"

# Optional: build/update venv (recommended to run as a non-root service user in the unit file)
# Here we update the venv as root because this script is root-run; that’s acceptable if APP_DIR is root-owned.
if [[ -n "${VENV_DIR}" && -n "${REQ_FILE}" && -f "${REQ_FILE}" ]]; then
  # Test pyvenv.cfg, not -x bin/python. bin/python is a symlink and stays executable
  # even when every real file in the venv has been deleted, so the old test could
  # never detect a gutted venv and never rebuilt one. pyvenv.cfg is what actually
  # makes an interpreter treat the directory as a venv: no pyvenv.cfg, no isolation,
  # and pip silently installs into the base interpreter instead.
  if [[ ! -f "${VENV_DIR}/pyvenv.cfg" ]]; then
    echo "no ${VENV_DIR}/pyvenv.cfg -- (re)creating the virtual environment with ${PYTHON_BIN}"
    rm -rf "${VENV_DIR}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  fi

  # Belt and braces: refuse to continue if the result is still not a venv, rather
  # than letting pip write into the system interpreter again.
  if ! "${VENV_DIR}/bin/python" -c 'import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)'; then
    echo "Refusing: ${VENV_DIR} is not a virtual environment after creation" >&2
    exit 4
  fi
  echo "From python in ${VENV_DIR} installing pip and the modules from ${REQ_FILE}"
  "${VENV_DIR}/bin/python" -m pip install -U pip wheel
  "${VENV_DIR}/bin/python" -m pip install -r "${REQ_FILE}"
else
  echo "Skipping venv setup - venv directory ${VENV_DIR} or requirements file ${REQ_FILE} not provided"
fi

# --- capture-freshness monitoring -------------------------------------------
# Installed by the deploy rather than by hand, so a rebuilt or newly added node
# comes up WITH monitoring. Hand-installing it is how pi4 ended up capturing
# nothing for 98 days with no alarm.
#
# Skipped quietly when the sources are absent, so this script still works
# against an older workspace.
FRESHNESS_SRC="${SRC_DIR}/deployment/youless-freshness.py"
if [[ -f "${FRESHNESS_SRC}" ]]; then
  install -m 0755 -D "${FRESHNESS_SRC}" /usr/local/sbin/youless-freshness.py
  install -m 0644 "${SRC_DIR}/systemd/youless-freshness.service" /etc/systemd/system/
  install -m 0644 "${SRC_DIR}/systemd/youless-freshness.timer"   /etc/systemd/system/
  echo "Installed capture-freshness check and units"
else
  echo "No ${FRESHNESS_SRC} in this workspace; skipping freshness check install"
fi

# Reload and restart service
/bin/systemctl daemon-reload

# Enable the freshness timer only once its config exists. /etc/youless/freshness.env
# holds the database password AND differs per node (NODES names this node and its
# peer), so it is provisioned by hand -- see INSTALL.md. Never overwrite it, and
# never enable a timer that could only fail: a permanently-failed unit trains you
# to ignore `systemctl --failed`, which defeats the point of having it.
if [[ -f /etc/systemd/system/youless-freshness.timer ]]; then
  if [[ -f /etc/youless/freshness.env ]]; then
    /bin/systemctl enable --now youless-freshness.timer
    echo "Enabled youless-freshness.timer"
  else
    echo "WARNING: /etc/youless/freshness.env is missing -- freshness timer NOT enabled."
    echo "         This node has NO capture monitoring. See INSTALL.md, then run:"
    echo "           sudo systemctl enable --now youless-freshness.timer"
  fi
fi

/bin/systemctl restart "${UNIT_NAME}"

# Optional: show a brief status summary (useful in Jenkins logs)
echo "Deployed to ${APP_DIR} and restarted ${UNIT_NAME}"
/bin/systemctl --no-pager --full status "${UNIT_NAME}" | sed -n '1,20p'
