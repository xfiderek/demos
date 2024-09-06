# Copyright 2024 Blazej Fiderek (xfiderek)
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# The vast portion of this dockerfile's code is based on spaceros moveit2 demo from spaceros docker repository
FROM osrf/space-ros:latest

ARG DEBIAN_FRONTEND=noninteractive

#############################################################################################################
#############################################################################################################
# START BUILD MOVEIT2 DEPENDENCY                                                                            #
# THE CODE BELOW IS TAKEN FROM https://github.com/space-ros/docker/blob/humble-2024.07.0/moveit2/Dockerfile #
# IN FUTURE, IT SHOULD BE REPLACED WITH SPACEROS/MOVEIT2 STACK                                              #
#############################################################################################################
#############################################################################################################

# Clone all space-ros sources
RUN mkdir ${SPACEROS_DIR}/src \
  && vcs import ${SPACEROS_DIR}/src < ${SPACEROS_DIR}/exact.repos

# Define key locations
ENV MOVEIT2_DIR=${HOME_DIR}/moveit2

# Make sure the latest versions of packages are installed
# Using Docker BuildKit cache mounts for /var/cache/apt and /var/lib/apt ensures that
# the cache won't make it into the built image but will be maintained between steps.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  sudo apt-get update
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  sudo apt-get dist-upgrade -y
RUN rosdep update

# Install the various build and test tools
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  sudo apt install -y \
  build-essential \
  clang-format \
  cmake \
  git \
  libbullet-dev \
  python3-colcon-common-extensions \
  python3-flake8 \
  python3-pip \
  python3-pytest-cov \
  python3-rosdep \
  python3-setuptools \
  python3-vcstool \
  wget

# Install some pip packages needed for testing
RUN python3 -m pip install -U \
  argcomplete \
  flake8-blind-except \
  flake8-builtins \
  flake8-class-newline \
  flake8-comprehensions \
  flake8-deprecated \
  flake8-docstrings \
  flake8-import-order \
  flake8-quotes \
  pytest-repeat \
  pytest-rerunfailures \
  pytest

# Get the MoveIt2 source code
WORKDIR ${HOME_DIR}
RUN sudo git clone https://github.com/ros-planning/moveit2.git -b ${ROSDISTRO} moveit2/src
RUN cd ${MOVEIT2_DIR}/src \
  && sudo git clone https://github.com/ros-planning/moveit2_tutorials.git -b ${ROSDISTRO}

# Update the ownership of the source files (had to use sudo above to work around
# a possible inherited 'insteadof' from the host that forces use of ssh
RUN sudo chown -R ${USERNAME}:${USERNAME} ${MOVEIT2_DIR}

# Get rosinstall_generator
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  sudo apt-get update -y && sudo apt-get install -y python3-rosinstall-generator

# Generate repos file for moveit2 dependencies, excluding packages from Space ROS core.
COPY --chown=${USERNAME}:${USERNAME} moveit2_docker_deps/moveit2-pkgs.txt /tmp/
COPY --chown=${USERNAME}:${USERNAME} moveit2_docker_deps/excluded-pkgs.txt /tmp/
RUN rosinstall_generator \
  --rosdistro ${ROSDISTRO} \
  --deps \
  --exclude-path ${SPACEROS_DIR}/src \
  --exclude $(cat /tmp/excluded-pkgs.txt) -- \
  -- $(cat /tmp/moveit2-pkgs.txt) \
  > /tmp/moveit2_generated_pkgs.repos

# Get the repositories required by MoveIt2, but not included in Space ROS
WORKDIR ${MOVEIT2_DIR}
RUN vcs import src < /tmp/moveit2_generated_pkgs.repos
COPY --chown=${USERNAME}:${USERNAME} moveit2_docker_deps/moveit2_deps.repos /tmp/
RUN vcs import src < /tmp/moveit2_deps.repos

# Update the ownership of the source files (had to use sudo above to work around
# a possible inherited 'insteadof' from the host that forces use of ssh
RUN sudo chown -R ${USERNAME}:${USERNAME} ${MOVEIT2_DIR}

# Install system dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  /bin/bash -c 'source ${SPACEROS_DIR}/install/setup.bash' \
 && rosdep install --from-paths ../spaceros/src src --ignore-src --rosdistro ${ROSDISTRO} -r -y --skip-keys "console_bridge generate_parameter_library fastcdr fastrtps rti-connext-dds-5.3.1 urdfdom_headers rmw_connextdds ros_testing rmw_connextdds rmw_fastrtps_cpp rmw_fastrtps_dynamic_cpp composition demo_nodes_py lifecycle rosidl_typesupport_fastrtps_cpp rosidl_typesupport_fastrtps_c ikos diagnostic_aggregator diagnostic_updater joy qt_gui rqt_gui rqt_gui_py"

# Apply a patch to octomap_msgs to work around a build issue
COPY --chown=${USERNAME}:${USERNAME} moveit2_docker_deps/octomap_fix.diff ./src/octomap_msgs
RUN cd src/octomap_msgs && git apply octomap_fix.diff

# Build MoveIt2
RUN /bin/bash -c 'source ${SPACEROS_DIR}/install/setup.bash \
  && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON --event-handlers desktop_notification- status-'

# Add a couple sample GUI apps for testing
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  sudo apt-get install -y \
  firefox \
  glmark2 \
  libcanberra-gtk3-0 \
  libpci-dev \
  xauth \
  xterm


# Setup the entrypoint
COPY ./moveit2_docker_deps/entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

#############################################################################################################
#############################################################################################################
# FINISHED BUILDING MOVEIT2 DEPENDENCY                                                                      #
#############################################################################################################
#############################################################################################################

#############################################################################################################
#############################################################################################################
# NOW ADD WORKSPACE WITH CANADARM MOVEIT2 CODE AND TRICK PLUGIN                                             #
#############################################################################################################
#############################################################################################################

# upgrade the following packages to make RVIZ work.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \ 
    sudo apt-get update && sudo apt-get install -y \
    mesa-libgallium \
    libdrm-amdgpu1 \
    libdrm-common \
    libdrm-intel1 \
    libdrm-radeon1 \
    libdrm2 \
    libegl-mesa0 \
    libgbm1 \
    libgl1-mesa-dev \
    libglapi-mesa \
    libglx-mesa0 \
    liborc-0.4-0 \
    libpq5 \
    linux-libc-dev \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    mesa-vulkan-drivers

ENV TRICK_DEMO_WS=/opt/ros_trick_demo_ws

WORKDIR ${TRICK_DEMO_WS}
COPY --chown=spaceros-user:space-ros-user ros_src ${TRICK_DEMO_WS}/src

RUN /bin/bash -c 'source ${MOVEIT2_DIR}/install/setup.bash \
   && colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON --event-handlers desktop_notification- status-'
RUN rm -rf build log src
