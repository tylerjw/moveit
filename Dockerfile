# This dockerfile can be configured via --build-arg
# Build context must be the /moveit root folder for COPY.
# Example build command:
# export DOCKER_BUILDKIT=1
# export UPSTREAM_MIXINS="debug ccache"
# export TARGET_MIXINS="debug ccache coverage"
# export DOWNSTREAM_MIXINS="debug ccache"
# docker build -t moveit:latest \
#   --build-arg UPSTREAM_MIXINS \
#   --build-arg TARGET_MIXINS \
#   --build-arg DOWNSTREAM_MIXINS \
#   --build-arg ROS_REPO="ros" \
#   --build-arg BUILDKIT_INLINE_CACHE=1 ./
ARG FROM_IMAGE=ros:noetic-ros-base
ARG UPSTREAM_MIXINS="release ccache"
ARG TARGET_MIXINS="release ccache"
ARG DOWNSTREAM_MIXINS="release ccache"
ARG ROS_REPO="ros"
ARG UPSTREAM_WS=/root/moveit/upstream
ARG TARGET_WS=/root/moveit/target
ARG DOWNSTREAM_WS=/root/moveit/downstream
ARG FAIL_ON_BUILD_FAILURE=True

# multi-stage for caching
FROM $FROM_IMAGE AS cacher

# install dependencies
RUN apt-get update && apt-get install -qq -y \
      wget git sudo python3-vcstool && \
    rm -rf /var/lib/apt/lists/*

# clone upstream workspace
ARG UPSTREAM_WS
WORKDIR $UPSTREAM_WS/src
COPY ./tools/upstream.rosinstall ../
RUN vcs import --skip-existing . < ../upstream.rosinstall && \
    find ./src/ -name ".git" | xargs rm -rf

# copy target workspace
ARG TARGET_WS
WORKDIR $TARGET_WS
COPY ./ ./src/moveit

# clone downstream workspace
ARG DOWNSTREAM_WS
WORKDIR $DOWNSTREAM_WS/src
COPY ./tools/downstream.rosinstall ../
RUN vcs import --skip-existing . < ../downstream.rosinstall && \
    find ./src/ -name ".git" | xargs rm -rf

# copy manifests for caching
WORKDIR /root/moveit
RUN mkdir -p /tmp/root/moveit && \
    find ./ -name "package.xml" | \
      xargs cp --parents -t /tmp/root/moveit && \
    find ./ -name "CATKIN_IGNORE" | \
      xargs cp --parents -t /tmp/root/moveit || true

# multi-stage for building
FROM $FROM_IMAGE AS builder
ARG DEBIAN_FRONTEND=noninteractive

# install build dependencies
ARG ROS_REPO
RUN echo "deb http://packages.ros.org/$ROS_REPO/ubuntu `lsb_release -cs` main" | \
      tee /etc/apt/sources.list.d/ros1-latest.list && \
    apt-get update && apt-get install -qq -y \
      clang clang-format-10 clang-tidy clang-tools ccache lcov \
      wget git sudo ninja-build python3-vcstool \
      python3-colcon-common-extensions python3-colcon-mixin && \
      /usr/sbin/update-ccache-symlinks && \
      colcon mixin add default https://raw.githubusercontent.com/colcon/colcon-mixin-repository/master/index.yaml && \
      colcon mixin update default && \
    rm -rf /var/lib/apt/lists/*

# install upstream dependencies
ARG UPSTREAM_WS
WORKDIR $UPSTREAM_WS
COPY --from=cacher /tmp/$UPSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    apt-get update && rosdep install -q -y \
      --from-paths src --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build upstream source
ARG UPSTREAM_MIXINS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $UPSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    colcon build \
      --symlink-install \
      --cmake-args -G Ninja \
      --catkin-skip-building-tests \
      --mixin $UNDERLAY_MIXINS \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

# install target dependencies
ARG UPSTREAM_WS
ARG TARGET_WS
WORKDIR $TARGET_WS
COPY --from=cacher /tmp/$TARGET_WS ./
RUN . $UPSTREAM_WS/install/setup.sh && \
    apt-get update && rosdep install -q -y \
      --from-paths src $UPSTREAM_WS/src \
      --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build target source
ARG UPSTREAM_WS
ARG TARGET_WS
ARG TARGET_MIXINS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $TARGET_WS ./
RUN . $UPSTREAM_WS/install/setup.sh && \
    colcon build \
      --symlink-install \
      --cmake-args -G Ninja \
      --mixin $TARGET_MIXINS \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

# install downstream dependencies
ARG UPSTREAM_WS
ARG TARGET_WS
ARG DOWNSTREAM_WS
WORKDIR $DOWNSTREAM_WS
COPY --from=cacher /tmp/$DOWNSTREAM_WS ./
RUN . $TARGET_WS/install/setup.sh && \
    apt-get update && rosdep install -q -y \
      --from-paths src $UPSTREAM_WS/src $TARGET_WS/src \
      --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build downstream source
ARG UPSTREAM_WS
ARG TARGET_WS
ARG DOWNSTREAM_MIXINS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $DOWNSTREAM_WS ./
RUN . $TARGET_WS/install/setup.sh && \
    colcon build \
      --symlink-install \
      --cmake-args -G Ninja \
      --mixin $DOWNSTREAM_MIXINS \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

# test target build
ARG RUN_TESTS
ARG FAIL_ON_TEST_FAILURE=True
ARG TARGET_WS
WORKDIR $TARGET_WS
RUN if [ -n "$RUN_TESTS" ]; then \
        . install/setup.sh && \
        colcon test && \
        colcon test-result \
          || ([ -z "$FAIL_ON_TEST_FAILURE" ] || exit 1) \
    fi
