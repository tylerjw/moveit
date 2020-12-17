# This dockerfile can be configured via --build-arg
# Build context must be the /moveit root folder for COPY.
# Example build command:
# export DOCKER_BUILDKIT=1
# docker build -t moveit:latest \
#   --build-arg CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release" \
#   --build-arg ROS_REPO="ros" \
#   --build-arg BUILDKIT_INLINE_CACHE=1 ./
ARG FROM_IMAGE=ros:noetic-ros-base
ARG CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release"
ARG ROS_REPO="ros"
ARG UPSTREAM_WS=/root/moveit/upstream
ARG TARGET_WS=/root/moveit/target
ARG DOWNSTREAM_WS=/root/moveit/downstream
ARG FAIL_ON_BUILD_FAILURE=True
ARG CATKIN_DEBS="python3-catkin-tools python3-osrf-pycommon"
ARG CC=""
ARG CXX=""

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
ARG CATKIN_DEBS
RUN apt-get update && apt-get install -qq -y \
      clang clang-format-10 clang-tidy clang-tools ccache lcov \
      $CATKIN_DEBS && \
    rm -rf /var/lib/apt/lists/*

# Set compiler using enviroment variable
ENV CC $CC
ENV CXX $CXX

# install upstream dependencies
ARG UPSTREAM_WS
ARG ROS_REPO
WORKDIR $UPSTREAM_WS
COPY --from=cacher /tmp/$UPSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    echo "deb http://packages.ros.org/$ROS_REPO/ubuntu `lsb_release -cs` main" | \
      tee /etc/apt/sources.list.d/ros1-latest.list && \
    apt-get update && rosdep install -q -y \
      --from-paths src --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build upstream source
ARG CMAKE_ARGS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $UPSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    catkin config --extend /opt/ros/$ROS_DISTRO --install --cmake-args $CMAKE_ARGS && \
    catkin build --limit-status-rate 0.001 --no-notify \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

# install target dependencies
ARG UPSTREAM_WS
ARG TARGET_WS
ARG ROS_REPO
WORKDIR $TARGET_WS
COPY --from=cacher /tmp/$TARGET_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    . $UPSTREAM_WS/install/setup.sh && \
    echo "deb http://packages.ros.org/$ROS_REPO/ubuntu `lsb_release -cs` main" | \
      tee /etc/apt/sources.list.d/ros1-latest.list && \
    apt-get update && rosdep install -q -y \
      --from-paths src --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build target source
ARG UPSTREAM_WS
ARG TARGET_WS
ARG CMAKE_ARGS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $TARGET_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    . $UPSTREAM_WS/install/setup.sh && \
    catkin config --extend $UPSTREAM_WS/install --install --cmake-args $CMAKE_ARGS && \
    catkin build --limit-status-rate 0.001 --no-notify \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

# install downstream dependencies
ARG UPSTREAM_WS
ARG TARGET_WS
ARG DOWNSTREAM_WS
ARG ROS_REPO
WORKDIR $DOWNSTREAM_WS
COPY --from=cacher /tmp/$DOWNSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    . $UPSTREAM_WS/install/setup.sh && \
    . $TARGET_WS/install/setup.sh && \
    echo "deb http://packages.ros.org/$ROS_REPO/ubuntu `lsb_release -cs` main" | \
      tee /etc/apt/sources.list.d/ros1-latest.list && \
    apt-get update && rosdep install -q -y \
      --from-paths src --ignore-src && \
    rm -rf /var/lib/apt/lists/*

# build downstream source
ARG UPSTREAM_WS
ARG TARGET_WS
ARG CMAKE_ARGS
ARG FAIL_ON_BUILD_FAILURE
COPY --from=cacher $DOWNSTREAM_WS ./
RUN . /opt/ros/$ROS_DISTRO/setup.sh && \
    . $UPSTREAM_WS/install/setup.sh && \
    . $TARGET_WS/install/setup.sh && \
    catkin config --extend $TARGET_WS/install --install --cmake-args $CMAKE_ARGS && \
    catkin build --limit-status-rate 0.001 --no-notify \
      || ([ -z "$FAIL_ON_BUILD_FAILURE" ] || exit 1)

