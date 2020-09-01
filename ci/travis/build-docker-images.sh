#!/usr/bin/env bash

# This script builds docker images on CI.
# This script MUST be sourced to capture env variables
set -e
set -x

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE:-$0}")"; pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR"/../../; pwd)
DOCKER_USERNAME="raytravisbot"
WHEEL="$(basename "$ROOT_DIR"/.whl/*cp37m-manylinux*)"

docker_push() {
    if [[ "$TRAVIS_PULL_REQUEST" == "false" ]]; then
        docker push "$@"
    else
        echo "Skipping docker push because it's in PR environment."
    fi
}
build_and_push_tags() {
    # $1 image-name, also used as the directory where the Dockerfile lives (e.g. base-deps)
    # $2 tag for image (e.g. hahs of commit)
    for GPU in "" "-gpu" 
    do 
        BASE_IMAGE=$(if [ "$GPU" ]; then echo "nvidia/cuda:11.0-cudnn8-runtime-ubuntu18.04"; else echo "ubuntu:focal"; fi;)
        FULL_NAME_WITH_TAG="rayproject/$1:$2$GPU"
        LATEST_FULL_NAME_WITH_TAG="rayproject/$1:latest$GPU"
        docker build --no-cache --build-arg GPU="$GPU" --build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg WHEEL_PATH=".whl/$WHEEL" -t "$FULL_NAME_WITH_TAG" /"$ROOT_DIR"/docker/"$1"
        
        docker tag "$FULL_NAME_WITH_TAG" "$LATEST_FULL_NAME_WITH_TAG"

        docker_push "$FULL_NAME_WITH_TAG"
        docker_push "$LATEST_FULL_NAME_WITH_TAG"
    done
}

build_or_pull_base_images() {
    docker pull rayproject/base-deps:latest
    TAG=$(date +%F_%H-00)
    
    age=$(docker inspect -f '{{ .Created }}' rayproject/base-deps:latest)
    # Build if older than 2 weeks, files have been edited in this PR OR branch release
    if [[  $(date -d "-14 days" +%F) > $(date -d "$age" +%F) || \
        "$RAY_CI_DOCKER_AFFECTED" == "1" || \
        "$RAY_CI_PYTHON_DEPENDENCIES_AFFECTED" == "1" || \
         "$TRAVIS_BRANCH" != "master"
        ]]; then
        cp -r "$ROOT_DIR"/.whl "$ROOT_DIR"/docker/ray-deps/.whl
        for IMAGE in "base-deps" "ray-deps"
        do
            build_and_push_tags "$IMAGE" "$TAG"
        done

    else
        echo "Just pulling images"
    fi

}

# We will only build and push when we are building branch build.
if [[ "$TRAVIS" == "true" ]]; then

    if [[ "$TRAVIS_PULL_REQUEST" == "false" ]]; then
        echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
        echo "Docker affected:$RAY_CI_DOCKER_AFFECTED"
        echo "Python dependencies affected:$RAY_CI_PYTHON_DEPENDENCIES_AFFECTED"
    else
        if [[ "$RAY_CI_DOCKER_AFFECTED" == "0" ]]; then
            echo "Skipping docker build in PR build because dockerfile didn't change."
            exit 0
        fi
    fi

    commit_sha=$(echo "$TRAVIS_COMMIT" | head -c 6)
    cp -r "$ROOT_DIR"/.whl "$ROOT_DIR"/docker/ray/.whl
    cp "$ROOT_DIR"/python/requirements.txt "$ROOT_DIR"/docker/autoscaler/requirements.txt
    cp "$ROOT_DIR"/python/requirements_autoscaler.txt "$ROOT_DIR"/docker/autoscaler/requirements_autoscaler.txt

    build_or_pull_base_images


    build_and_push_tags "ray" "$commit_sha"

    build_and_push_tags "autoscaler" "$commit_sha"
 

    # We have a branch build, e.g. release/v0.7.0
    if [[ "$TRAVIS_BRANCH" != "master" ]]; then
       # Replace / in branch name to - so it is legal tag name
       normalized_branch_name=$(echo "$TRAVIS_BRANCH" | sed -e "s/\//-/")

       for IMAGE in "base-deps" "ray-deps" "ray" "autoscaler"
       do
            for GPU in "" "-gpu"
            do
                docker tag "rayproject/$IMAGE:latest$GPU" "rayproject/$IMAGE:$normalized_branch_name$GPU"
                docker_push  "rayproject/$IMAGE:$normalized_branch_name$GPU"
            done
       done 
    fi
fi
