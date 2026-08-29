#!/bin/bash
#
# Validate the Jenkinsfile before pushing.
#
# Two Jenkinsfile bugs got past review and broke real builds on 2026-08-29, and
# neither is visible by reading the file:
#
#   build 67  valid Groovy, broken bash. Groovy processes escape sequences
#             inside triple-quoted strings, so a doubled backslash written in
#             the Jenkinsfile reaches bash as a single one. It escaped a closing
#             quote and bash died on a paren three lines later.
#
#   build 68  invalid Groovy. A comment inside an sh block quoted the string
#             delimiter itself, closing the block early. Nothing compiled, so no
#             stage ran at all.
#
# Checking the Jenkinsfile text directly catches neither: bash never sees that
# text, and a truncated block still parses. So this checks what actually runs --
# the sh bodies AFTER Groovy unescaping, and the file through a real Groovy
# parser, the same groovy-all jar the Jenkins controller itself ships.
#
# Usage:  deployment/check-jenkinsfile.sh [path/to/Jenkinsfile]
#
# The Groovy parse needs ssh to the Jenkins host and is skipped with a warning
# when unreachable; the local checks always run.

set -uo pipefail

JENKINSFILE="${1:-Jenkinsfile}"
JENKINS_HOST="${JENKINS_HOST:-patricia}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
rc=0

[[ -f "${JENKINSFILE}" ]] || { echo "no such file: ${JENKINSFILE}"; exit 2; }

PY="$(command -v python3 || command -v python)"
[[ -n "${PY}" ]] || { echo "need python3 for the unescape step"; exit 2; }

# --- local: delimiter balance, stray backslashes, and bash syntax ------------
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

"${PY}" - "${JENKINSFILE}" "${tmpdir}" <<'PYEOF'
import re, sys
BS, Q3 = chr(92), chr(39) * 3
path, tmpdir = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()
rc = 0

n_open, n_total = len(re.findall(r"sh\s+" + Q3, src)), src.count(Q3)
if n_total != n_open * 2:
    print("FAIL  triple-quote count is %d, expected %d -- a stray delimiter "
          "inside an sh block (this broke build 68)" % (n_total, n_open * 2))
    rc = 1
else:
    print("ok    triple-quote balance (%d blocks)" % n_open)

for i, b in enumerate(re.findall(r"sh\s+" + Q3 + r"(.*?)" + Q3, src, re.S), 1):
    # Model what Groovy hands to the shell, then let bash judge that.
    open("%s/blk%d.sh" % (tmpdir, i), "w", encoding="utf-8",
         newline="\n").write(b.encode().decode("unicode_escape"))
    # A backslash before a newline is a line continuation to both Groovy and
    # bash and is fine. Mid-line backslashes are the dangerous ones.
    bad = [n for n, l in enumerate(b.split("\n"), 1)
           if BS in l.rstrip() and not l.rstrip().endswith(BS)]
    if bad:
        print("FAIL  block %d has mid-line backslashes on line(s) %s "
              "(this broke build 67)" % (i, bad))
        rc = 1
    else:
        print("ok    block %d has no mid-line backslashes" % i)
sys.exit(rc)
PYEOF
[[ $? -ne 0 ]] && rc=1

for f in "${tmpdir}"/blk*.sh; do
  [[ -e "${f}" ]] || continue
  if bash -n "${f}" 2>"${tmpdir}/err"; then
    echo "ok    bash -n $(basename "${f}") after Groovy unescaping"
  else
    echo "FAIL  bash -n $(basename "${f}") after Groovy unescaping:"
    sed 's/^/        /' "${tmpdir}/err"
    rc=1
  fi
done

# --- remote: parse with the Groovy that Jenkins itself runs ------------------
if ! scp -q -o ConnectTimeout=8 -o BatchMode=yes \
       "${JENKINSFILE}" "${JENKINS_HOST}:/tmp/jf.check" 2>/dev/null; then
  echo "WARN  ${JENKINS_HOST} unreachable; skipped the Groovy parse"
  echo
  [[ ${rc} -eq 0 ]] && echo "local checks passed (Groovy parse NOT run)" \
                    || echo "PROBLEMS FOUND"
  exit ${rc}
fi

if ssh -o BatchMode=yes "${JENKINS_HOST}" 'bash -s' "${JENKINS_CONTAINER}" <<'REMOTE'
set -e
C="$1"
printf '%s\n' 'new GroovyShell().parse(new File("/tmp/jf.check"))' \
              'println "GROOVY PARSE OK"' > /tmp/jf.groovy
docker cp /tmp/jf.check  "$C:/tmp/jf.check"  >/dev/null
docker cp /tmp/jf.groovy "$C:/tmp/jf.groovy" >/dev/null
docker exec "$C" bash -lc '
  JAR=$(ls /var/jenkins_home/war/WEB-INF/lib/groovy-all-*.jar 2>/dev/null | head -1)
  JAVA=$(ls /opt/java/openjdk/bin/java 2>/dev/null || command -v java)
  "$JAVA" -cp "$JAR" groovy.ui.GroovyMain /tmp/jf.groovy'
st=$?
docker exec "$C" rm -f /tmp/jf.check /tmp/jf.groovy 2>/dev/null
rm -f /tmp/jf.check /tmp/jf.groovy
exit $st
REMOTE
then
  echo "ok    Groovy parse (via the jar Jenkins runs)"
else
  echo "FAIL  Groovy parse -- the Jenkinsfile would not compile"
  rc=1
fi

echo
[[ ${rc} -eq 0 ]] && echo "all checks passed" || echo "PROBLEMS FOUND"
exit ${rc}
