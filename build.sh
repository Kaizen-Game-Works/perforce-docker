#!/bin/bash
set -e

# Image names
IMAGE_P4D="kaizengameworks/helix-p4d"
IMAGE_SWARM="kaizengameworks/helix-swarm"

BUILDER_NAME="p4d-builder"

# If our named builder exists, use it
if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "Using existing builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
else
    # Find an existing docker driver builder and strip '*'
    EXISTING_DOCKER_BUILDER=$(docker buildx ls \
        | awk '$2=="docker"{print $1}' \
        | sed 's/\*$//' \
        | head -n1)

    if [ -n "$EXISTING_DOCKER_BUILDER" ]; then
        echo "Using existing docker driver builder: $EXISTING_DOCKER_BUILDER"
        docker buildx use "$EXISTING_DOCKER_BUILDER"
    else
        echo "Creating builder $BUILDER_NAME with docker driver"
        docker buildx create --name "$BUILDER_NAME" --driver docker --use
    fi
fi

echo "Building $IMAGE_P4D..."
docker buildx build --no-cache --load --progress=plain --tag  "$IMAGE_P4D" ./helix-p4d

echo "Building $IMAGE_SWARM..."
docker buildx build --no-cache --load --progress=plain --tag "$IMAGE_SWARM" ./helix-swarm

echo "Both images built successfully and loaded into docker images:"
echo "  - $IMAGE_P4D"
echo "  - $IMAGE_SWARM"
