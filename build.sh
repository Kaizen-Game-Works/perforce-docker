#!/bin/bash
set -e

# Image names
IMAGE_P4D="kaizengameworks/helix-p4d"
IMAGE_SWARM="kaizengameworks/helix-swarm"

# Create builder if it doesn't exist
if ! docker buildx inspect p4d-builder >/dev/null 2>&1; then
	# Use the 'docker' driver which supports userns
	docker buildx create --name p4d-builder --driver docker
fi

docker buildx use p4d-builder

# Build first image (helix-p4d)
docker buildx build --no-cache --load --tag "$IMAGE_P4D" ./helix-p4d

# Build second image (helix-swarm)
docker buildx build --no-cache --load --tag "$IMAGE_SWARM" ./helix-swarm

echo "Both images built successfully and loaded into docker images: $IMAGE_P4D, $IMAGE_SWARM"
