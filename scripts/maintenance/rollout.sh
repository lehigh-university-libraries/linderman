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

docker_compose() {
    docker compose \
      -f docker-compose.yaml \
      -f "docker-compose.$HOSTNAME.yaml" \
      "$@"
}

cd /opt/linderman || exit 1

# TODO link right to PRs
send_slack_message "Rolling out <https://github.com/${GIT_REPO}/tree/${GIT_BRANCH}|${GIT_REPO#*/}:${DOCKER_TAG}> to \`${DOMAIN%%.*}\` :rocket: :shipit: :rocket:"

if [ "$GIT_REPO" = "lehigh-university-libraries/folio-offline-shelf-reading" ]; then
  SHELF_READING_TAG=${DOCKER_TAG}
  export SHELF_READING_TAG
elif [ "$GIT_REPO" = "lehigh-university-libraries/linderman" ]; then
  git fetch origin
  git reset --hard
  git checkout "$GIT_BRANCH"
  git pull origin "$GIT_BRANCH"
else
  echo "Unknown repo: $GIT_REPO"
  exit 1
fi

# TODO - there is an edge case here where if our ten minute timer
# that is checking for a GHA runner image update and a deployment happen
# at the same time this job will timeout
# Though the deployment should work OK, but we should fix this if we trip over it
docker_compose pull --quiet

# TODO if relevant, put app into read-only mode, we're about to restart any containers we pulled

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
