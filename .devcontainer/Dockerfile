ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:25.12-py3
FROM ${BASE_IMAGE}

# -----------------------------------------------------------------------------
# Build args / environment
# -----------------------------------------------------------------------------
ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=ubuntu
ARG USER_UID=1000
ARG USER_GID=1000
ARG MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

# -----------------------------------------------------------------------------
# OS packages (dev tools + X11/Vulkan runtime deps for Isaac Sim GUI)
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    iproute2 \
    libglu1-mesa \
    locales \
    libvulkan1 \
    mesa-vulkan-drivers \
    sudo \
    vulkan-tools \
    xauth \
    zsh \
    x11-apps \
    mesa-utils \
  && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Vulkan ICD setup (ensure paths exist for NVIDIA Container Toolkit mounts)
# -----------------------------------------------------------------------------
# The NVIDIA Container Toolkit mounts the host's Vulkan ICD JSON(s) into common
# locations (often `/usr/share/vulkan/icd.d`). Ensure these directories exist so
# the mount can succeed even if the base image doesn’t ship them.
RUN set -eux; \
  mkdir -p /usr/share/vulkan/icd.d /etc/vulkan/icd.d; \
  if [ ! -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then \
    printf '%s\n' \
      '{' \
      '  "file_format_version": "1.0.1",' \
      '  "ICD": {' \
      '    "library_path": "libGLX_nvidia.so.0",' \
      '    "api_version": "1.1.0"' \
      '  }' \
      '}' \
      > /usr/share/vulkan/icd.d/nvidia_icd.json; \
  fi

# -----------------------------------------------------------------------------
# Locales
# -----------------------------------------------------------------------------
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# User + sudo + GPU access groups (video/render)
# -----------------------------------------------------------------------------
RUN set -eux; \
  if ! getent group render >/dev/null 2>&1; then \
    if ! getent group 993 >/dev/null 2>&1; then groupadd --gid 993 render; else groupadd render; fi; \
  fi; \
  if id -u "${USERNAME}" >/dev/null 2>&1; then \
    : "User ${USERNAME} already exists; configuring it"; \
  else \
    if getent passwd "${USER_UID}" >/dev/null 2>&1; then \
      echo "ERROR: USER_UID ${USER_UID} already exists in the base image; set USERNAME to that existing user (e.g. 'ubuntu') or choose a different USER_UID." >&2; \
      exit 1; \
    fi; \
    if getent group "${USER_GID}" >/dev/null 2>&1; then \
      existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
      user_group="${existing_group}"; \
    else \
      groupadd --gid "${USER_GID}" "${USERNAME}"; \
      user_group="${USERNAME}"; \
    fi; \
    useradd --uid "${USER_UID}" --gid "${user_group}" -m -s /usr/bin/zsh "${USERNAME}"; \
  fi; \
  usermod -s /usr/bin/zsh "${USERNAME}"; \
  usermod -aG video,render "${USERNAME}" || true; \
  echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
  chmod 0440 "/etc/sudoers.d/${USERNAME}"

# -----------------------------------------------------------------------------
# Miniconda bootstrap (only if base image doesn't already include it)
# -----------------------------------------------------------------------------
RUN set -eux; \
  if [ ! -x /opt/conda/bin/conda ]; then \
    curl -fsSL "${MINICONDA_URL}" -o /tmp/miniconda.sh; \
    bash /tmp/miniconda.sh -b -p /opt/conda; \
    rm -f /tmp/miniconda.sh; \
  fi; \
  /opt/conda/bin/conda config --system --set auto_activate_base false; \
  /opt/conda/bin/conda clean -afy
ENV PATH=/opt/conda/bin:$PATH

# -----------------------------------------------------------------------------
# Workspace directory ownership (VS Code bind-mount target)
# -----------------------------------------------------------------------------
RUN set -eux; \
  mkdir -p /workspaces/BEHAVIOR-1K; \
  user_group="$(id -gn "${USERNAME}")"; \
  chown -R "${USERNAME}":"${user_group}" /workspaces

# -----------------------------------------------------------------------------
# X11 helper script (auto-detect DISPLAY and validate connectivity)
# -----------------------------------------------------------------------------
USER root
RUN cat >/usr/local/bin/xrun <<'SH' && chmod +x /usr/local/bin/xrun
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: xrun <command> [args...]" >&2
  exit 2
fi

if [[ -z "${XAUTHORITY:-}" && -f "/home/ubuntu/.Xauthority" ]]; then
  export XAUTHORITY="/home/ubuntu/.Xauthority"
fi

display_num_from_display() {
  local disp="$1"
  local rest="${disp}"
  if [[ "${disp}" == *:* ]]; then
    rest="${disp#*:}"
  fi
  local display_num="${rest%%.*}"
  if [[ -n "${display_num}" && "${display_num}" =~ ^[0-9]+$ ]]; then
    echo "${display_num}"
    return 0
  fi
  return 1
}

has_unix_socket() {
  local display_num="$1"
  [[ -S "/tmp/.X11-unix/X${display_num}" ]]
}

can_connect_display() {
  local disp="$1"
  # Expect DISPLAY like: localhost:12.0 or :0
  local host="localhost"
  local rest="${disp}"
  if [[ "${disp}" == *:* ]]; then
    host="${disp%%:*}"
    rest="${disp#*:}"
  fi
  local display_num="${rest%%.*}"
  if [[ -z "${display_num}" ]]; then
    return 1
  fi
  local port=$((6000 + display_num))
  # Bash /dev/tcp works if the port is open; auth is handled by XAUTHORITY.
  (exec 3<>"/dev/tcp/${host:-localhost}/${port}") >/dev/null 2>&1
}

if [[ -n "${DISPLAY:-}" ]]; then
  if dn="$(display_num_from_display "${DISPLAY}")" && has_unix_socket "${dn}"; then
    exec "$@"
  fi
  if can_connect_display "${DISPLAY}"; then
    exec "$@"
  fi
fi

# Best-effort: auto-detect an active SSH X11-forwarding port (6010-6099).
port="$(
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\\1/p' \
    | awk '$1>=6010 && $1<=6099' | sort -n | tail -n 1
)"

if [[ -n "${port}" ]]; then
  display_num=$((port - 6000))
  export DISPLAY="localhost:${display_num}.0"
  if has_unix_socket "${display_num}" || can_connect_display "${DISPLAY}"; then
    exec "$@"
  fi
fi

echo "xrun: Could not determine a working DISPLAY." >&2
echo "Hint: connect with 'ssh -Y' and ensure X11 works on the host: xeyes" >&2
exit 1
SH

# -----------------------------------------------------------------------------
# Switch to non-root user for development
# -----------------------------------------------------------------------------
USER ${USERNAME}

ENV HOME=/home/${USERNAME}
WORKDIR /workspaces/BEHAVIOR-1K

# -----------------------------------------------------------------------------
# Shell UX + conda env paths (kept under $HOME for better caching)
# -----------------------------------------------------------------------------
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
RUN mkdir -p "$HOME/.conda/pkgs" "$HOME/.conda/envs"
RUN cat >> "$HOME/.zshrc" <<'ZSH'

# XDG runtime dir (some graphics / Vulkan tooling warns if unset in containers)
export XDG_RUNTIME_DIR="/tmp/runtime-$USER"
mkdir -p "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
chmod 700 "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true

# Conda (Miniconda)
if [ -f /opt/conda/etc/profile.d/conda.sh ]; then
  export CONDA_PKGS_DIRS="$HOME/.conda/pkgs"
  export CONDA_ENVS_PATH="$HOME/.conda/envs"
  . /opt/conda/etc/profile.d/conda.sh
fi
ZSH

# -----------------------------------------------------------------------------
# Default shell for subsequent RUN steps and interactive terminals
# -----------------------------------------------------------------------------
SHELL ["/usr/bin/zsh", "-lc"]
