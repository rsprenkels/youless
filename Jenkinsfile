pipeline {
  agent { label 'patricia' }

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
      steps {
        checkout scm
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          set -euo pipefail

          # Example: copy the workspace contents to a staging dir (optional)
          # If you deploy directly from workspace, you can skip staging.
          STAGING="$(mktemp -d)"
          trap 'rm -rf "$STAGING"' EXIT

          rsync -a --delete \
            --exclude ".git/" \
            ./ "$STAGING/"

          # Call the privileged deploy helper (single controlled entry point)
          sudo -n "${DEPLOY_SCRIPT}" \
            --app-dir "${APP_DIR}" \
            --unit "${UNIT_NAME}" \
            --src "${STAGING}" \
            --unit-src "${STAGING}/systemd/${UNIT_NAME}" \
            --venv "${APP_DIR}/.venv" \
            --requirements "${STAGING}/requirements.txt"
        '''
      }
    }

    stage('Smoke check') {
      steps {
        sh '''
          set -euo pipefail
          systemctl is-active --quiet youless.service
          systemctl --no-pager --full status youless.service | sed -n '1,20p'
        '''
      }
    }
  }
}
