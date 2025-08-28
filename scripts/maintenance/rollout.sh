#!/usr/bin/env bash

set -eou pipefail

GIT_BRANCH=${GIT_BRANCH:-main}

echo "Deploying git branch $GIT_BRANCH, docker tag $DOCKER_TAG"

send_slack_message() {
    escaped_message=$(echo "$@" | jq -Rsa .)
    curl -s -o /dev/null -XPOST "$SLACK_WEBHOOK" -d '{
      "blocks": [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": '"$escaped_message"'
          }
        }
      ]
    }'
}

# send a failure message if this script errors for any reason
handle_error() {
    send_slack_message "🚨 Roll out failed 🚨"
    exit 1
}
trap 'handle_error' ERR

# update .env variables
# we don't want different service deployments to cause collisions
# or restarting docker daemon or the VM to reset a service to its main tag
# so maintain which docker tag was last deployed using .env
update_env() {
    VAR_NAME="$1"
    VALUE="$2"
    if grep -Eq "^${VAR_NAME}=" .env; then
        sed -i "s/^$VAR_NAME=.*/$VAR_NAME=$VALUE/" .env
    else
        echo "${VAR_NAME}=${VALUE}" | tee -a .env
    fi
}

docker_compose() {
    docker compose \
      -f docker-compose.yaml \
      -f "docker-compose.$HOSTNAME.yaml" \
      "$@"
}

cd /opt/linderman || exit 1

export $(grep = .env | grep -v '"' | xargs)

# TODO link right to PRs
send_slack_message "Rolling out <https://github.com/${GIT_REPO}/tree/${GIT_BRANCH}|${GIT_REPO#*/}:${DOCKER_TAG}> to \`${DOMAIN%%.*}\` :rocket: :shipit: :rocket:"

# specify which docker services to pull/restart based on the app/repo being deployed
DOCKER_SERVICES=("traefik" "rollout")
if [ "$GIT_REPO" = "lehigh-university-libraries/folio-offline-shelf-reading" ]; then
  update_env "SHELF_READING_TAG" "${DOCKER_TAG}"
  DOCKER_SERVICES=("shelf-reading")
elif [ "$GIT_REPO" = "lehigh-university-libraries/folio-shelving-order" ]; then
  update_env "SHELVING_ORDER_TAG" "${DOCKER_TAG}"
  DOCKER_SERVICES=("folio-shelving-order")
elif [ "$GIT_REPO" = "lehigh-university-libraries/linderman" ]; then
  git fetch origin
  git reset --hard
  git checkout "$GIT_BRANCH"
  git pull origin "$GIT_BRANCH"
else
  echo "Unknown repo: $GIT_REPO"
  exit 1
fi

./scripts/maintenance/create-secrets.sh

docker_compose pull --quiet "${DOCKER_SERVICES[@]}"
docker_compose build --quiet

# TODO if relevant, put app into read-only mode, we're about to restart any containers we pulled

docker_compose up \
  --remove-orphans \
  --wait \
  --pull missing \
  --quiet-pull \
  "${DOCKER_SERVICES[@]}" \
  -d

# TODO any app specific maintenance tasks

echo "ensuring all containers are online"
docker_compose up \
  --remove-orphans \
  --wait \
  --pull missing \
  --quiet-pull \
  "${DOCKER_SERVICES[@]}" \
  -d

send_slack_message "Roll out complete 🎉"

# TODO any app specific post deployment tasks
