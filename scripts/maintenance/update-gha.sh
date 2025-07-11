#!/usr/bin/env bash

set -eou pipefail

# helper function for docker compose commands
docker_compose() {
    docker compose \
      -f docker-compose.yaml \
      -f "docker-compose.$HOSTNAME.yaml" \
      "$@"
}


# Our GitHub Actions runner docker image is maintained at https://github.com/lehigh-university-libraries/docker-builds
# When that docker image gets updated, we want to automatically receive updates
# we can not roll out those updates with GitHub PRs without weird timeouts happening
# because GitHub runners container would be restarted on a rollout, causing the GitHub Action workflow to hang
# so instead we just check for updates and handle those as they come
RUNNER_CONTAINER="github-actions-runner"
RUNNER_IMAGE=$(docker_compose config "$RUNNER_CONTAINER" --format json | jq -r '.services["'"${RUNNER_CONTAINER}"'"].image')

# helper function to check there are no jobs running on our runner
ensure_idle() {
    if docker_compose logs --tail 1 "$RUNNER_CONTAINER" | grep -q "Running job"; then
        echo "Running a job"
        exit 0
    fi
}

# we want to bail if there is a job running
# because the job very well could be performing docker compose actions
# and if we pull an image it will cause that job to fail unexpectedly
ensure_idle

echo "Checking for image update..."

CURRENT_IMAGE_ID=$(docker images --format "{{.ID}}" "$RUNNER_IMAGE")
docker pull "$RUNNER_IMAGE" --quiet
NEW_IMAGE_ID=$(docker images --format "{{.ID}}" "$RUNNER_IMAGE")

if [ "$CURRENT_IMAGE_ID" = "$NEW_IMAGE_ID" ]; then
    echo "No new image"
    exit 0
fi

# a job may have started since we pulled
ensure_idle

echo "New image pulled, restarting runner..."
docker_compose up \
  "$RUNNER_CONTAINER" \
  -d
