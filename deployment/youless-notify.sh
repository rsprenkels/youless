#!/bin/bash
#
# Push a notification about a failed unit to ntfy.
#
# Started by youless-notify@.service, which systemd runs via OnFailure= on the
# units worth being woken up for. Takes the failed unit's name as its only
# argument.
#
# Config lives in /etc/youless/notify.env (NTFY_URL, NTFY_TOPIC), provisioned by
# hand and deliberately NOT in git: on the public ntfy.sh instance the topic name
# is the only thing keeping strangers out of the feed.
#
# Exits non-zero when it cannot deliver, so a notification that never reached a
# phone still shows up in `systemctl --failed`. An alerting path that fails
# silently is worse than none, because it is trusted.

set -uo pipefail

UNIT="${1:-unknown.unit}"
HOST="$(hostname -s)"

: "${NTFY_URL:?NTFY_URL not set -- is /etc/youless/notify.env installed?}"
: "${NTFY_TOPIC:?NTFY_TOPIC not set -- is /etc/youless/notify.env installed?}"

# Include the last few lines the unit logged before it gave up. Without them the
# phone is just a pager that says "something broke", and you still have to be at
# a laptop to learn anything -- which is most of the delay this is meant to cut.
CONTEXT="$(journalctl -u "${UNIT}" -n 12 --no-pager -o cat 2>/dev/null \
             | grep -v '^[[:space:]]*$' | tail -8)"
[[ -z "${CONTEXT}" ]] && CONTEXT="(no journal output for ${UNIT})"

BODY="$(printf 'unit: %s\nhost: %s\ntime: %s\n\n%s\n' \
          "${UNIT}" "${HOST}" "$(date -Is)" "${CONTEXT}")"

# Retry, because the single likeliest reason a youless alert fails to send is
# that the network is the thing that broke. Three attempts over ~15s rides out a
# blip without holding the unit open for minutes.
for attempt in 1 2 3; do
  if curl -sS --fail --max-time 10 \
       -H "Title: youless: ${UNIT} failed on ${HOST}" \
       -H "Priority: urgent" \
       -H "Tags: rotating_light" \
       -d "${BODY}" \
       "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null; then
    echo "notified ntfy about ${UNIT} (attempt ${attempt})"
    exit 0
  fi
  echo "ntfy publish attempt ${attempt} failed"
  [[ "${attempt}" -lt 3 ]] && sleep $(( attempt * 5 ))
done

echo "CRITICAL: could not deliver the ${UNIT} failure notification to ntfy"
exit 1
