pipeline {
  agent { label 'patricia' }

  options {
    timestamps()
  }

  environment {
    APP_NAME     = 'youless'
    APP_DIR      = '/opt/youless_test'
    UNIT_NAME    = 'youless.service'
    DEPLOY_SCRIPT= '/usr/local/sbin/deploy-youless.sh'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Deploy') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail

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
      steps {
        sh '''#!/bin/bash
          set -euo pipefail

          sudo systemctl is-active --quiet youless.service
          sudo systemctl --no-pager --full status youless.service | sed -n '1,20p'
        '''
      }
    }
  }
}
