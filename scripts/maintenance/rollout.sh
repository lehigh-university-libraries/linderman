#!/usr/bin/env bash

set -eou pipefail

GIT_BRANCH=${GIT_BRANCH:-main}
DRUPAL_DOCKER_TAG=${DOCKER_TAG:-main}

echo "Deploying git branch $GIT_BRANCH, docker tag $DRUPAL_DOCKER_TAG"
export DRUPAL_DOCKER_TAG

send_slack_message() {
    escaped_message=$(echo "$@" | jq -Rsa .)
    curl -s -o /dev/null -XPOST "$SLACK_WEBHOOK" -d '{
      "msg": '"$escaped_message"'
    }'
}

handle_error() {
    send_slack_message "🚨 Roll out failed 🚨"
    exit 1
}

trap 'handle_error' ERR

docker_compose() {
    docker compose \
      -f docker-compose.yaml \
      -f "docker-compose.$HOSTNAME.yaml" \
      "$@"
}

cd /opt/linderman
git fetch origin

send_slack_message "Rolling out changes to https://$DOMAIN :rocket: :shipit: :rocket:"

git reset --hard
git checkout "$GIT_BRANCH"
git pull origin "$GIT_BRANCH"

docker_compose pull --quiet

# TODO if relevant, put app into read-only mode

docker_compose up \
  --remove-orphans \
  --wait \
  --pull missing \
  --quiet-pull \
  -d

# TODO any app specific maintenance tasks

echo "ensuring all containers are online"
docker_compose up \
  --remove-orphans \
  --wait \
  --pull missing \
  --quiet-pull \
  -d

send_slack_message "Roll out complete 🎉"

# TODO any app specific post deployment tasks
