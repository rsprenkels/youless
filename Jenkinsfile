pipeline {
  agent any

   parameters {
      choice(
        name: 'DEPLOY_TARGET',
        choices: ['pi', 'patricia'],
        description: 'Where to deploy (maps to a Jenkins node label)'
      )
    }

  options {
    timestamps()
  }

  environment {
    APP_NAME     = 'youless'
    APP_DIR      = '/opt/youless'
    UNIT_NAME    = 'youless.service'
    DEPLOY_SCRIPT= '/usr/local/sbin/deploy-youless.sh'
  }

  stages {
    stage('Checkout') {
      agent { label "${params.DEPLOY_TARGET}" }
      steps {
        checkout scm
      }
    }

    stage('Deploy') {
      agent { label "${params.DEPLOY_TARGET}" }
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          echo "deploying to target: ${DEPLOY_TARGET} using deploy helper script ${DEPLOY_SCRIPT}"

          STAGING="${WORKSPACE}"

          # Call the privileged deploy helper (single controlled entry point)
          sudo -n "${DEPLOY_SCRIPT}" \
            --app-dir "${APP_DIR}" \
            --unit "${UNIT_NAME}" \
            --src "${STAGING}" \
            --unit-src "${STAGING}/systemd/${UNIT_NAME}" \
            --venv "${APP_DIR}/.venv" \
            --requirements "${STAGING}/src/requirements.txt"

          echo 'Wait briefly (5 sec) for service to fully start'
          sleep 5
          echo 'the wait is now over'
        '''
      }
    }

    stage('Smoke check') {
      agent { label "${params.DEPLOY_TARGET}" }
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          whoami
          sudo systemctl is-active --quiet youless.service
          sudo systemctl --no-pager --full status youless.service | sed -n '1,20p'

          # The deploy helper runs from a fixed path that the sudoers rule pins,
          # so editing deployment/deploy_youless.sh in git is a SILENT NO-OP
          # until someone installs it on this node by hand. Compare the two and
          # fail loudly, otherwise a stale helper just quietly keeps running.
          # Keep backslashes out of this block. Groovy processes escapes inside
          # ''' ... ''', so a \\ written here reaches bash as a single \ and
          # silently breaks quoting -- which is exactly how this check shipped
          # broken in build 67, failing on a paren three lines further down.
          #
          # Both sides are checked out on a Linux agent, so comparing raw bytes
          # is safe. A CRLF checkout would differ from the LF copy on the node
          # and false-positive here.
          echo 'checking the installed deploy helper matches the repo'
          repo_hash=$(sha256sum "${WORKSPACE}/deployment/deploy_youless.sh" | cut -d" " -f1)
          node_hash=$(sudo -n /usr/bin/sha256sum "${DEPLOY_SCRIPT}" | cut -d" " -f1)

          if [ "${repo_hash}" != "${node_hash}" ]; then
            echo "ERROR: ${DEPLOY_SCRIPT} does not match deployment/deploy_youless.sh"
            echo "  repo: ${repo_hash}"
            echo "  node: ${node_hash}"
            echo "The deploy above therefore ran an OUTDATED helper. Reinstall it with:"
            echo "  sudo install -m 0700 -o root -g root deployment/deploy_youless.sh ${DEPLOY_SCRIPT}"
            exit 1
          fi
          echo "deploy helper is current: ${repo_hash}"
        '''
      }
    }
  }
}
