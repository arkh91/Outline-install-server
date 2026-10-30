#!/bin/bash
#
# Copyright 2018 The Outline Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Script to install the Outline Server docker container, a watchtower docker container
# (to automatically update the server), the Mithra key panel, and to create a new Outline user.
#
# The stock Outline server (Shadowbox) is installed unchanged, so every key stays a normal Outline key and works in
# the Outline Client. The key panel (a small service installed next to it) answers on the public API port, forwards
# everything it does not handle to Shadowbox, and adds:
#   1. traffic that is kept            (usage per key is read from kernel counters and saved on disk)
#   2. one device per key              (the newest device wins, the older one is cut off)
#   3. online / last seen              3.1 live upload / download rate per key
#   4. time limit per key              (date, duration from now, duration after first connection, or none)
#   5. usage per key                   (upload, download, total, optional data limit)
#   6. pause / resume a key            7. edit a key (name, traffic, time limit)
# Every key has a port of its own (taken from --port-range): that is what makes 2, 3 and 6 possible, because
# Shadowsocks has no handshake. Open the whole range (TCP and UDP) in your cloud firewall.
#
# You may set the following environment variables, overriding their defaults:
# SB_IMAGE: The Outline Server Docker image to install, e.g. quay.io/outline/shadowbox:nightly
# CONTAINER_NAME: Docker instance name for shadowbox (default shadowbox).
#     For multiple instances also change SHADOWBOX_DIR to an other location
#     e.g. CONTAINER_NAME=shadowbox-inst1 SHADOWBOX_DIR=/opt/outline/inst1
# SHADOWBOX_DIR: Directory for persistent Outline Server state.
# ACCESS_CONFIG: The location of the access config text file.
# SB_DEFAULT_SERVER_NAME: Default name for this server, e.g. "Outline server New York".
#     This name will be used for the server until the admins updates the name
#     via the REST API.
# SENTRY_LOG_FILE: File for writing logs which may be reported to Sentry, in case
#     of an install error. No PII should be written to this file. Intended to be set
#     only by do_install_server.sh.
# WATCHTOWER_REFRESH_SECONDS: refresh interval in seconds to check for updates,
#     defaults to 3600.
# PANEL_DIR: Directory of the key panel (default ${SHADOWBOX_DIR}/panel). Its config is PANEL_DIR/config.json
#     (edit it with: vi ${SHADOWBOX_DIR}/panel/config.json, then: systemctl restart outline-panel).
#
# Deprecated:
# SB_PUBLIC_IP: Use the --hostname flag instead
# SB_API_PORT: Use the --api-port flag instead

# Requires curl and docker to be installed (python3, iptables, conntrack are installed by this script when missing)

set -euo pipefail

# Usage: display_usage -> prints the command line flags
function display_usage() {
  cat <<EOF
Usage: install_server.sh [--hostname <hostname>] [--api-port <port>] [--keys-port <port>] [--port-range <first>-<last>]

  --hostname    The hostname to be used to access the management API and access keys
  --api-port    The port number for the management API
  --keys-port   First port of the key port range (same as --port-range <port>-<port+999>)
  --port-range  Ports for access keys, one port per key (default 20000-20999). Open it for TCP and UDP.
EOF
}

readonly SENTRY_LOG_FILE=${SENTRY_LOG_FILE:-}

# I/O conventions for this script:
# - Ordinary status messages are printed to STDOUT
# - STDERR is only used in the event of a fatal error
# - Detailed logs are recorded to this FULL_LOG, which is preserved if an error occurred.
# - The most recent error is stored in LAST_ERROR, which is never preserved.
FULL_LOG="$(mktemp -t outline_logXXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_errorXXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

# Usage: log_command <command> [args...] -> runs the command, copies its output to FULL_LOG and keeps its STDERR in LAST_ERROR
function log_command() {
  # Direct STDOUT and STDERR to FULL_LOG, and forward STDOUT.
  # The most recent STDERR output will also be stored in LAST_ERROR.
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

# Usage: log_error "text" -> prints the text in red and records it in FULL_LOG
function log_error() {
  local -r ERROR_TEXT="\033[0;31m"  # red
  local -r NO_COLOR="\033[0m"
  echo -e "${ERROR_TEXT}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

# Pretty prints text to stdout, and also writes to sentry log file if set.
# Usage: log_start_step "Doing something" -> prints "> Doing something ....... " without a newline
function log_start_step() {
  log_for_sentry "$@"
  local -r str="> $*"
  local -ir lineLength=47
  echo -n "${str}"
  local -ir numDots=$(( lineLength - ${#str} - 1 ))
  if (( numDots > 0 )); then
    echo -n " "
    for _ in $(seq 1 "${numDots}"); do echo -n .; done
  fi
  echo -n " "
}

# Prints $1 as the step name and runs the remainder as a command.
# STDOUT will be forwarded.  STDERR will be logged silently, and
# revealed only in the event of a fatal error.
# Usage: run_step "Step name" <function> [args...] -> prints OK when the function succeeds
function run_step() {
  local -r msg="$1"
  log_start_step "${msg}"
  shift 1
  if log_command "$@"; then
    echo "OK"
  else
    # Propagates the error code
    return
  fi
}

# Usage: confirm "Question?" -> asks [Y/n]; succeeds on yes / empty answer
function confirm() {
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

# Usage: command_exists docker -> succeeds when the program is installed
function command_exists {
  command -v "$@" &> /dev/null
}

# Usage: log_for_sentry "text" -> appends the text to SENTRY_LOG_FILE (if set) and FULL_LOG
function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date "+%Y-%m-%d@%H:%M:%S")] install_server.sh" "$@" >> "${SENTRY_LOG_FILE}"
  fi
  echo "$@" >> "${FULL_LOG}"
}

# Check to see if docker is installed.
# Usage: verify_docker_installed -> offers to install Docker when it is missing
function verify_docker_installed() {
  if command_exists docker; then
    return 0
  fi
  log_error "NOT INSTALLED"
  if ! confirm "Would you like to install Docker? This will run 'curl https://get.docker.com/ | sh'."; then
    exit 0
  fi
  if ! run_step "Installing Docker" install_docker; then
    log_error "Docker installation failed, please visit https://docs.docker.com/install for instructions."
    exit 1
  fi
  log_start_step "Verifying Docker installation"
  command_exists docker
}

# Usage: verify_docker_running -> succeeds when the Docker daemon answers (starts it when it is down)
function verify_docker_running() {
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)"
  local -ir RET=$?
  if (( RET == 0 )); then
    return 0
  elif [[ "${STDERR_OUTPUT}" == *"Is the docker daemon running"* ]]; then
    start_docker
    return
  fi
  return "${RET}"
}

# Usage: fetch https://example.org/ [curl flags] -> silent curl that fails on HTTP errors
function fetch() {
  curl --silent --show-error --fail "$@"
}

# Usage: install_docker -> runs the official Docker install script
function install_docker() {
  (
    # Change umask so that /usr/share/keyrings/docker-archive-keyring.gpg has the right permissions.
    # See https://github.com/Jigsaw-Code/outline-server/issues/951.
    # We do this in a subprocess so the umask for the calling process is unaffected.
    umask 0022
    fetch https://get.docker.com/ | sh
  ) >&2
}

# Usage: start_docker -> enables and starts the Docker service
function start_docker() {
  systemctl enable --now docker.service >&2
}

# Usage: docker_container_exists shadowbox -> succeeds when a container with that name exists
function docker_container_exists() {
  docker ps -a --format '{{.Names}}'| grep --quiet "^$1$"
}

# Usage: remove_shadowbox_container -> force-removes the Shadowbox container
function remove_shadowbox_container() {
  remove_docker_container "${CONTAINER_NAME}"
}

# Usage: remove_watchtower_container -> force-removes the Watchtower container
function remove_watchtower_container() {
  remove_docker_container watchtower
}

# Usage: remove_docker_container <name> -> force-removes that container
function remove_docker_container() {
  docker rm -f "$1" >&2
}

# Usage: handle_docker_container_conflict <name> <true|false> -> asks whether to replace a container whose name is taken
function handle_docker_container_conflict() {
  local -r CONTAINER_NAME="$1"
  local -r EXIT_ON_NEGATIVE_USER_RESPONSE="$2"
  local PROMPT="The container name \"${CONTAINER_NAME}\" is already in use by another container. This may happen when running this script multiple times."
  if [[ "${EXIT_ON_NEGATIVE_USER_RESPONSE}" == 'true' ]]; then
    PROMPT="${PROMPT} We will attempt to remove the existing container and restart it. Would you like to proceed?"
  else
    PROMPT="${PROMPT} Would you like to replace this container? If you answer no, we will proceed with the remainder of the installation."
  fi
  if ! confirm "${PROMPT}"; then
    if ${EXIT_ON_NEGATIVE_USER_RESPONSE}; then
      exit 0
    fi
    return 0
  fi
  if run_step "Removing ${CONTAINER_NAME} container" "remove_${CONTAINER_NAME}_container" ; then
    log_start_step "Restarting ${CONTAINER_NAME}"
    "start_${CONTAINER_NAME}"
    return $?
  fi
  return 1
}

# Set trap which publishes error tag only if there is an error.
# Usage: trap finish EXIT -> on failure prints the last error and where the full log is; on success removes the logs
function finish {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nLast error: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nSorry! Something went wrong. If you can't figure this out, please copy and paste all this output into the Outline Manager screen, and send it to us, to see if we can help you." >&2
    log_error "Full log: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}

# Usage: get_random_port -> prints a random port between 1024 and 65535
function get_random_port {
  local -i num=0  # Init to an invalid value, to prevent "unbound variable" errors.
  until (( 1024 <= num && num < 65536)); do
    num=$(( RANDOM + (RANDOM % 2) * 32768 ));
  done;
  echo "${num}";
}

# Usage: get_free_random_port -> prints a random port that is neither in the key port range nor one of the ports already chosen
function get_free_random_port() {
  local -i port
  while true; do
    port="$(get_random_port)"
    if (( port >= PORT_RANGE_START && port <= PORT_RANGE_END )); then continue; fi
    if (( port == ${API_PORT:-0} )); then continue; fi
    if (( port == ${INTERNAL_API_PORT:-0} )); then continue; fi
    echo "${port}"
    return 0
  done
}

# Usage: create_persisted_state_dir -> creates the directory for Shadowbox's persistent state
function create_persisted_state_dir() {
  readonly STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
  mkdir -p "${STATE_DIR}"
  chmod ug+rwx,g+s,o-rwx "${STATE_DIR}"
}

# Generate a secret key for access to the Management API and store it in a tag.
# 16 bytes = 128 bits of entropy should be plenty for this use.
# Usage: echo data | safe_base64 -> URL-safe base64 of stdin without trailing "="
function safe_base64() {
  # Implements URL-safe base64 of stdin, stripping trailing = chars.
  # Writes result to stdout.
  # TODO: this gives the following errors on Mac:
  #   base64: invalid option -- w
  #   tr: illegal option -- -
  local url_safe
  url_safe="$(base64 -w 0 - | tr '/+' '_-')"
  echo -n "${url_safe%%=*}"  # Strip trailing = chars
}

# Usage: generate_secret_key -> sets SB_API_PREFIX, the secret path of the management API
function generate_secret_key() {
  SB_API_PREFIX="$(head -c 16 /dev/urandom | safe_base64)"
  readonly SB_API_PREFIX
}

# Usage: generate_certificate -> creates the self-signed TLS certificate shared by Shadowbox and the key panel
function generate_certificate() {
  # Generate self-signed cert and store it in the persistent state directory.
  local -r CERTIFICATE_NAME="${STATE_DIR}/shadowbox-selfsigned"
  readonly SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
  readonly SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"
  declare -a openssl_req_flags=(
    -x509 -nodes -days 36500 -newkey rsa:4096
    -subj "/CN=${PUBLIC_HOSTNAME}"
    -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}"
  )
  openssl req "${openssl_req_flags[@]}" >&2
}

# Usage: generate_certificate_fingerprint -> writes "certSha256:<hex>" to the access config
function generate_certificate_fingerprint() {
  # Add a tag with the SHA-256 fingerprint of the certificate.
  # (Electron uses SHA-256 fingerprints: https://github.com/electron/electron/blob/9624bc140353b3771bd07c55371f6db65fd1b67e/atom/common/native_mate_converters/net_converter.cc#L60)
  # Example format: "SHA256 Fingerprint=BD:DB:C9:A4:39:5C:B3:4E:6E:CF:18:43:61:9F:07:A2:09:07:37:35:63:67"
  local CERT_OPENSSL_FINGERPRINT
  CERT_OPENSSL_FINGERPRINT="$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint)" || return
  # Example format: "BDDBC9A4395CB34E6ECF1843619F07A2090737356367"
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT="$(echo "${CERT_OPENSSL_FINGERPRINT#*=}" | tr -d :)" || return
  output_config "certSha256:${CERT_HEX_FINGERPRINT}"
}

# Usage: join , a b c -> "a,b,c" (first argument is the separator)
function join() {
  local IFS="$1"
  shift
  echo "$*"
}

# Usage: write_config -> writes Shadowbox's server config (default key port, name, hostname)
function write_config() {
  local -a config=()
  if (( FLAGS_KEYS_PORT != 0 )); then
    config+=("\"portForNewAccessKeys\": ${FLAGS_KEYS_PORT}")
  fi
  if [[ -n "${SB_DEFAULT_SERVER_NAME:-}" ]]; then
    config+=("\"name\": \"$(escape_json_string "${SB_DEFAULT_SERVER_NAME}")\"")
  fi
  config+=("\"hostname\": \"$(escape_json_string "${PUBLIC_HOSTNAME}")\"")
  echo "{$(join , "${config[@]}")}" > "${STATE_DIR}/shadowbox_server_config.json"
}

# Usage: start_shadowbox -> writes start_container.sh and runs it; Shadowbox's management API listens on a private port
#        (INTERNAL_API_PORT, closed to the outside by the panel's firewall rules); the key panel owns the public API port
function start_shadowbox() {
  # TODO(fortuna): Write API_PORT to config file,
  # rather than pass in the environment.
  local -r START_SCRIPT="${STATE_DIR}/start_container.sh"
  cat <<-EOF > "${START_SCRIPT}"
# This script starts the Outline server container ("Shadowbox").
# If you need to customize how the server is run, you can edit this script (vi "${START_SCRIPT}"), then restart with:
#
#     "${START_SCRIPT}"

set -eu

docker stop "${CONTAINER_NAME}" 2> /dev/null || true
docker rm -f "${CONTAINER_NAME}" 2> /dev/null || true

docker_command=(
  docker
  run
  -d
  --name "${CONTAINER_NAME}" --restart always --net host

  # Used by Watchtower to know which containers to monitor.
  --label 'com.centurylinklabs.watchtower.enable=true'

  # Use log rotation. See https://docs.docker.com/config/containers/logging/configure/.
  --log-driver local

  # The state that is persisted across restarts.
  -v "${STATE_DIR}:${STATE_DIR}"

  # Where the container keeps its persistent state.
  -e "SB_STATE_DIR=${STATE_DIR}"

  # Port number and path prefix used by the server manager API. This is the PRIVATE port: the key panel
  # answers on the public API port and forwards to this one.
  -e "SB_API_PORT=${INTERNAL_API_PORT}"
  -e "SB_API_PREFIX=${SB_API_PREFIX}"

  # Location of the API TLS certificate and key.
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}"
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}"

  # Where to report metrics to, if opted-in.
  -e "SB_METRICS_URL=${SB_METRICS_URL:-}"

  # The Outline server image to run.
  "${SB_IMAGE}"
)
"\${docker_command[@]}"
EOF
  chmod +x "${START_SCRIPT}"
  # Declare then assign. Assigning on declaration messes up the return code.
  local STDERR_OUTPUT
  STDERR_OUTPUT="$({ "${START_SCRIPT}" >/dev/null; } 2>&1)" && return
  readonly STDERR_OUTPUT
  log_error "FAILED"
  if docker_container_exists "${CONTAINER_NAME}"; then
    handle_docker_container_conflict "${CONTAINER_NAME}" true
    return
  else
    log_error "${STDERR_OUTPUT}"
    return 1
  fi
}

# Usage: start_watchtower -> starts the Watchtower container that keeps the Shadowbox image up to date
function start_watchtower() {
  # Start watchtower to automatically fetch docker image updates.
  # Set watchtower to refresh every 30 seconds if a custom SB_IMAGE is used (for
  # testing).  Otherwise refresh every hour.
  local -ir WATCHTOWER_REFRESH_SECONDS="${WATCHTOWER_REFRESH_SECONDS:-3600}"
  local -ar docker_watchtower_flags=(--name watchtower --log-driver local --restart always \
      -v /var/run/docker.sock:/var/run/docker.sock)
  # By itself, local messes up the return code.
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker run -d "${docker_watchtower_flags[@]}" containrrr/watchtower --cleanup --label-enable --tlsverify --interval "${WATCHTOWER_REFRESH_SECONDS}" 2>&1 >/dev/null)" && return
  readonly STDERR_OUTPUT
  log_error "FAILED"
  if docker_container_exists watchtower; then
    handle_docker_container_conflict watchtower false
    return
  else
    log_error "${STDERR_OUTPUT}"
    return 1
  fi
}

# Waits for the service to be up and healthy
# Usage: wait_shadowbox -> returns when Shadowbox answers on its private API port
function wait_shadowbox() {
  # We use insecure connection because our threat model doesn't include localhost port
  # interception and our certificate doesn't have localhost as a subject alternative name
  until fetch --insecure "${LOCAL_SB_URL}/access-keys" >/dev/null; do sleep 1; done
}

# Usage: wait_panel -> returns when the key panel answers on the public API port (gives up after 90 s and shows its log)
function wait_panel() {
  local -i waited=0
  until fetch --insecure "${LOCAL_API_URL}/access-keys" >/dev/null 2>&1; do
    sleep 1
    waited=$(( waited + 1 ))
    if (( waited >= 90 )); then
      log_error "The key panel did not start. Its log:"
      journalctl -u outline-panel --no-pager -n 30 >&2 || true
      return 1
    fi
  done
}

# Usage: create_first_user -> creates the first access key (through the panel, so it gets a port of its own)
function create_first_user() {
  fetch --insecure --request POST "${LOCAL_API_URL}/access-keys" >&2
}

# Usage: output_config "name:value" -> appends a line to the access config file
function output_config() {
  echo "$@" >> "${ACCESS_CONFIG}"
}

# Usage: add_api_url_to_config -> writes "apiUrl:<public API url>" to the access config
function add_api_url_to_config() {
  output_config "apiUrl:${PUBLIC_API_URL}"
}

# Usage: check_firewall -> sets FIREWALL_STATUS: tells whether the API port can be reached from outside and which ports to open
function check_firewall() {
  if ! fetch --max-time 5 --cacert "${SB_CERTIFICATE_FILE}" "${PUBLIC_API_URL}/access-keys" >/dev/null; then
     log_error "BLOCKED"
     FIREWALL_STATUS="\
You won’t be able to access it externally, despite your server being correctly
set up, because there's a firewall (in this machine, your router or cloud
provider) that is preventing incoming connections to port ${API_PORT} and to the key ports ${PORT_RANGE_START}-${PORT_RANGE_END}."
  else
    FIREWALL_STATUS="\
If you have connection problems, it may be that your router or cloud provider
blocks inbound connections, even though your machine seems to allow them."
  fi
  FIREWALL_STATUS="\
${FIREWALL_STATUS}

Make sure to open the following ports on your firewall, router or cloud provider:
- Management port ${API_PORT}, for TCP
- Access key ports ${PORT_RANGE_START}-${PORT_RANGE_END} (one port per key), for TCP and UDP
"
}

# Usage: set_hostname -> sets PUBLIC_HOSTNAME to the server's external IPv4 address
function set_hostname() {
  # These are URLs that return the client's apparent IP address.
  # We have more than one to try in case one starts failing
  # (e.g. https://github.com/Jigsaw-Code/outline-server/issues/776).
  local -ar urls=(
    'https://icanhazip.com/'
    'https://ipinfo.io/ip'
    'https://domains.google.com/checkip'
  )
  for url in "${urls[@]}"; do
    PUBLIC_HOSTNAME="$(fetch --ipv4 "${url}")" && return
  done
  echo "Failed to determine the server's IP address.  Try using --hostname <server IP>." >&2
  return 1
}

# ---------------------------------------------------------------------------------------------------------------------
# Key panel
# ---------------------------------------------------------------------------------------------------------------------

# Usage: panel_pkg <python3|iptables|conntrack|ss> -> prints the package that provides it for this system's package manager
function panel_pkg() {
  case "$1:${PKG_MANAGER}" in
    python3:pacman)      echo python ;;
    python3:*)           echo python3 ;;
    iptables:*)          echo iptables ;;
    conntrack:apt-get)   echo conntrack ;;
    conntrack:*)         echo conntrack-tools ;;
    ss:dnf|ss:yum)       echo iproute ;;
    ss:*)                echo iproute2 ;;
  esac
}

# Usage: install_panel_requirements -> installs python3, iptables, conntrack and ss (iproute2) when they are missing
function install_panel_requirements() {
  local -a missing=()
  local tool
  for tool in python3 iptables conntrack ss; do
    command_exists "${tool}" || missing+=("${tool}")
  done
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  PKG_MANAGER=""
  for tool in apt-get dnf yum apk pacman zypper; do
    if command_exists "${tool}"; then PKG_MANAGER="${tool}"; break; fi
  done
  if [[ -z "${PKG_MANAGER}" ]]; then
    log_error "Please install these first, then run this script again: ${missing[*]}"
    return 1
  fi
  local -a packages=()
  for tool in "${missing[@]}"; do
    packages+=("$(panel_pkg "${tool}")")
  done
  case "${PKG_MANAGER}" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" >&2 ;;
    dnf|yum) "${PKG_MANAGER}" install -y -q "${packages[@]}" >&2 ;;
    apk)     apk add --quiet "${packages[@]}" >&2 ;;
    pacman)  pacman -S --noconfirm --needed "${packages[@]}" >&2 ;;
    zypper)  zypper --non-interactive install "${packages[@]}" >&2 ;;
  esac
  modprobe nf_conntrack 2>/dev/null || true
  for tool in python3 iptables conntrack; do
    command_exists "${tool}" || { log_error "Could not install ${tool}"; return 1; }
  done
}

# Usage: check_port_ranges -> stops when the key port range is invalid or overlaps the API ports; warns when it overlaps
#        the ports Linux hands out to outgoing connections
function check_port_ranges() {
  if (( PORT_RANGE_START < 1024 || PORT_RANGE_END > 65535 || PORT_RANGE_START >= PORT_RANGE_END )); then
    log_error "Invalid --port-range ${PORT_RANGE_START}-${PORT_RANGE_END}: use two ports from 1024 to 65535, first below last."
    return 1
  fi
  if (( API_PORT >= PORT_RANGE_START && API_PORT <= PORT_RANGE_END )); then
    log_error "The API port ${API_PORT} lies inside the key port range ${PORT_RANGE_START}-${PORT_RANGE_END}: choose another --api-port or --port-range."
    return 1
  fi
  local eph_lo=32768 eph_hi=60999
  if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
    read -r eph_lo eph_hi < /proc/sys/net/ipv4/ip_local_port_range || true
  fi
  if (( PORT_RANGE_START <= eph_hi && PORT_RANGE_END >= eph_lo )); then
    log_error "Note: ${PORT_RANGE_START}-${PORT_RANGE_END} overlaps the ports used for outgoing connections (${eph_lo}-${eph_hi}); a key port may then be busy. A range below ${eph_lo} is safer."
  fi
}

# Usage: open_key_ports -> opens the API port and the key port range in ufw or firewalld when one of them is active
function open_key_ports() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${API_PORT}/tcp" >&2
    ufw allow "${PORT_RANGE_START}:${PORT_RANGE_END}/tcp" >&2
    ufw allow "${PORT_RANGE_START}:${PORT_RANGE_END}/udp" >&2
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${API_PORT}/tcp" >&2
    firewall-cmd --permanent --add-port="${PORT_RANGE_START}-${PORT_RANGE_END}/tcp" >&2
    firewall-cmd --permanent --add-port="${PORT_RANGE_START}-${PORT_RANGE_END}/udp" >&2
    firewall-cmd --reload >&2
  fi
}

# Usage: write_panel_files -> writes panel.py, config.json and the two systemd units
function write_panel_files() {
  readonly PANEL_DIR="${PANEL_DIR:-${SHADOWBOX_DIR}/panel}"
  mkdir -p "${PANEL_DIR}"
  chmod 700 "${PANEL_DIR}"
  local -r PYTHON_BIN="$(command -v python3)"

  cat > "${PANEL_DIR}/panel.py" <<'OUTLINE_PANEL_PY_END'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# outline-panel - key manager that sits in front of the stock Outline server (Shadowbox).
#
# What it adds on top of Shadowbox (every key stays a normal Outline key: the ss:// access URL works in the Outline Client):
#   1. Traffic that is kept: per-key totals are read from kernel counters and saved to disk, so they survive restarts.
#   2. One device per key: every key owns its own port; the newest device (client address) wins, the older one is cut off.
#   3. Online / last seen: derived from the last traffic on the key's port (Shadowsocks has no handshake).
#   3.1 Live upload / download rate per key.
#   4. Time limit: a date, a duration from now, a duration after the first connection, or none.
#   5. Usage per key: upload, download, total, with an optional data limit.
#   6. Pause / resume.   7. Edit (name, traffic, time limit) - PATCH /access-keys/<id>.
#
# The panel answers on the public API port with Outline's own URL layout (https://host:port/<secret>/access-keys ...).
# Routes it does not know are forwarded unchanged to Shadowbox, which listens on a private port.
#
# Needs: python3 (3.6+), iptables (+ ip6tables), conntrack. Standard library only.
# Config: /opt/outline/panel/config.json (edit it with: vi /opt/outline/panel/config.json), state: state.json next to it.

import calendar
import collections
import datetime
import ipaddress
import json
import logging
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

VERSION = '1.0.0'
log = logging.getLogger('outline-panel')

DEFAULTS = {
    'listen_port': 0,                 # public API port (the one in the Outline Manager access config)
    'api_prefix': '',                 # secret path prefix, as in Outline
    'cert_file': '', 'key_file': '',  # the same self-signed certificate Shadowbox uses (same certSha256)
    'shadowbox_port': 0,              # private Shadowbox API port (127.0.0.1)
    'state_file': '/opt/outline/panel/state.json',
    'port_range': [20000, 20999],     # one port per key, taken from this range
    'sample_seconds': 2.0,            # how often counters and flows are read
    'online_window_seconds': 180,     # "online" = traffic within this many seconds
    'owner_release_seconds': 60,      # an idle owner gives up its key after this long (blocked devices may return)
    'min_reply_bytes': 800,           # a TCP flow counts as a real device only after the server sent it this much
    'single_device': True,            # default for new keys
    'save_seconds': 10,
}


# ----------------------------------------------------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------------------------------------------------

class ApiError(Exception):
    # Usage: raise ApiError(400, "invalid traffic") -> answered to the client as {"error": "..."} with that status
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


# Usage: run(["iptables", "-S"], input_text=None) -> (returncode, stdout, stderr); 127 when the program is missing
def run(cmd, input_text=None, timeout=25):
    try:
        p = subprocess.run(cmd, input=input_text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, '', 'not found: ' + cmd[0]
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout: ' + ' '.join(cmd)


# Usage: iso(1790000000) -> "2026-09-22T..Z"; iso(0) -> None
def iso(ts):
    if not ts:
        return None
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


# Usage: server_clock(ts) -> "2026-11-25 14:29" - the moment on this server's own clock / time zone
def server_clock(ts):
    return time.strftime('%Y-%m-%d %H:%M', time.localtime(ts))


# Usage: parse_traffic("20G") -> 20000000000; "unlimited" / 0 / None -> 0; None for anything invalid.
#        K M G T are decimal (as the app shows them), KiB MiB GiB TiB are 1024-based, a plain number is bytes.
#        Also accepts Outline's {"bytes": N}.
def parse_traffic(v):
    if v is None or v is False:
        return 0
    if isinstance(v, dict):
        if 'bytes' not in v:
            return None
        v = v['bytes']
        if v is None:
            return 0
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v) if 0 <= v <= 10 ** 18 and float(v).is_integer() else None
    if not isinstance(v, str):
        return None
    t = v.strip()
    if re.match(r'^(|0|unlimited|none|off|no)$', t, re.I):
        return 0
    m = re.match(r'^(\d+(?:\.\d+)?)\s*([kmgt]?)(i?)b?$', t, re.I)
    if not m:
        return None
    power = {'': 0, 'k': 1, 'm': 2, 'g': 3, 't': 4}[m.group(2).lower()]
    n = int(round(float(m.group(1)) * (1024 if m.group(3) else 1000) ** power))
    return n if n <= 10 ** 18 else None


# Usage: parse_duration("30d") -> "30d"; "1 month" -> "1m"; "2y" -> "24m"; 12 -> "12d"; "never" / None -> ""
#        Units: h hours, d days, w weeks, m calendar months, y years. Raises ApiError(400) when invalid.
def parse_duration(v):
    bad = ApiError(400, 'invalid time limit: use "30d", "12h", "2w", "1m" (month), "1y" or "never"')
    if v is None or v is False:
        return ''
    if isinstance(v, bool):
        raise bad
    if isinstance(v, int):
        if 0 < v < 10000:
            return '%dd' % v
        if v == 0:
            return ''
        raise bad
    if not isinstance(v, str):
        raise bad
    t = v.strip().lower()
    if t in ('', '0', 'never', 'none', 'off', 'no', 'unlimited'):
        return ''
    m = re.match(r'^(\d{1,4})\s*(h|hours?|d|days?|w|weeks?|m|mo|mon|months?|y|yrs?|years?)$', t)
    if not m or int(m.group(1)) < 1:
        raise bad
    n, unit = int(m.group(1)), m.group(2)[0]
    if unit == 'y':
        if n * 12 >= 10000:
            raise bad
        return '%dm' % (n * 12)
    return '%d%s' % (n, unit)


# Usage: add_duration(epoch, "1m") -> epoch + 1 calendar month (UTC, clamped: Jan 31 + 1m = Feb 28); h/d/w are plain seconds
def add_duration(ts, spec):
    n, unit = int(spec[:-1]), spec[-1]
    if unit == 'h':
        return int(ts) + n * 3600
    if unit == 'd':
        return int(ts) + n * 86400
    if unit == 'w':
        return int(ts) + n * 604800
    dt = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
    t = dt.month - 1 + n
    year, month = dt.year + t // 12, t % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return calendar.timegm(dt.replace(year=year, month=month, day=day).timetuple())


# Usage: local_epoch("2026-12-31 18:00:00") -> epoch of that wall-clock time on THIS server; ApiError(400) if it does not exist
def local_epoch(wall):
    try:
        t = time.strptime(wall, '%Y-%m-%d %H:%M:%S')
        e = int(time.mktime(t[:8] + (-1,)))
    except (ValueError, OverflowError):
        raise ApiError(400, 'invalid date: ' + wall)
    if time.strftime('%Y-%m-%d %H:%M', time.localtime(e)) != wall[:16]:
        raise ApiError(400, 'that time does not exist on this server (clock change): ' + wall)
    return e


# Usage: end_on("2026-12-31") -> end of that day (23:59:59, server time); "2026-12-31 18:00"; "2026-12-31T18:00:00Z" / "+02:00" are exact
def end_on(text):
    t = str(text).strip()
    m = re.match(r'^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2})(?::(\d{2}))?)?$', t)
    if m:
        return local_epoch('%s %s:%s' % (m.group(1), m.group(2) or '23:59', m.group(3) or ('00' if m.group(2) else '59')))
    m = re.match(r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?(Z|[+-]\d\d:\d\d)$', t)
    if m:
        try:
            e = calendar.timegm((int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)),
                                 int(m.group(6) or 0)))
        except (ValueError, OverflowError):
            raise ApiError(400, 'invalid date: ' + t)
        if m.group(7) != 'Z':
            off = int(m.group(7)[1:3]) * 3600 + int(m.group(7)[4:6]) * 60
            e -= off if m.group(7)[0] == '+' else -off
        return e
    raise ApiError(400, 'invalid date: use "2026-12-31", "2026-12-31 18:00" (server time) or an ISO time with Z / +02:00')


# Usage: traffic_from({"traffic": "20G"}) -> 20000000000; None when the body sets no limit; ApiError(400) when invalid.
#        Also {"limit": {"bytes": N}} (Outline), {"dataLimit": N}, {"dataLimitBytes": N}; "unlimited" / 0 = no limit.
def traffic_from(body):
    for name in ('traffic', 'limit', 'dataLimit', 'dataLimitBytes'):
        if name in body:
            n = parse_traffic(body[name])
            if n is None:
                raise ApiError(400, 'invalid traffic: use "20G", "500M", a number of bytes or "unlimited"')
            return n
    return None


# Usage: expiry_from(body, now) -> None (nothing set) | ("none",) | ("at", epoch) | ("after", "30d").
#        Body: "expires": "30d" | "1m" | "never" | a date;  "expiresOn": "2026-12-31 18:00";  "expiresAfterFirstConnection": "30d"
def expiry_from(body, now):
    if 'expiresAfterFirstConnection' in body:
        d = parse_duration(body['expiresAfterFirstConnection'])
        return ('none',) if d == '' else ('after', d)
    if 'expiresOn' in body:
        v = body['expiresOn']
        if v is None or (isinstance(v, str) and v.strip().lower() in ('', 'never', 'none', 'off', 'no', 'unlimited')):
            return ('none',)
        if not isinstance(v, str):
            raise ApiError(400, 'expiresOn must be a date string')
        e = end_on(v)
        if e <= now:
            raise ApiError(400, 'end time is in the past')
        return ('at', e)
    if 'expires' in body:
        v = body['expires']
        try:
            d = parse_duration(v)
            return ('none',) if d == '' else ('at', add_duration(now, d))
        except ApiError:
            if not isinstance(v, str):
                raise
            e = end_on(v)
            if e <= now:
                raise ApiError(400, 'end time is in the past')
            return ('at', e)
    return None


# Usage: device_id("203.0.113.5") -> "203.0.113.5"; an IPv6 address -> its /64 ("2001:db8:1:2::/64", so privacy-address
#        rotation is one device); "::ffff:1.2.3.4" -> "1.2.3.4"; None for loopback / junk
def device_id(addr):
    try:
        ip = ipaddress.ip_address(addr.split('%')[0])
    except ValueError:
        return None
    if ip.is_loopback or ip.is_unspecified:
        return None
    if ip.version == 6:
        if ip.ipv4_mapped:
            return str(ip.ipv4_mapped)
        return str(ipaddress.IPv6Network((int(ip) >> 64 << 64, 64)))
    return str(ip)


# Usage: parse_conntrack(line) -> {"proto","state","src","dport","reply_bytes","unreplied"} for a tcp/udp line of `conntrack -L`
def parse_conntrack(line):
    toks = line.split()
    if len(toks) < 4 or toks[0] not in ('tcp', 'udp'):
        return None
    pairs = re.findall(r'\b(src|dst|sport|dport|packets|bytes)=(\S+)', line)
    starts = [i for i, (k, _) in enumerate(pairs) if k == 'src']
    if len(starts) < 2:
        return None
    orig, reply = {}, {}
    for k, v in pairs[:starts[1]]:
        orig.setdefault(k, v)
    for k, v in pairs[starts[1]:]:
        reply.setdefault(k, v)
    try:
        dport = int(orig['dport'])
        rbytes = int(reply['bytes']) if 'bytes' in reply else None
    except (KeyError, ValueError):
        return None
    return {'proto': toks[0], 'state': toks[3] if '=' not in toks[3] else '', 'src': orig.get('src', ''),
            'dport': dport, 'reply_bytes': rbytes, 'unreplied': '[UNREPLIED]' in line}


# Usage: flow_qualified(flow, 800) -> True when the flow is a real, authenticated device and not a scanner / probe:
#        UDP: the server answered; TCP: established and the server sent at least min_reply_bytes back
def flow_qualified(f, min_reply_bytes):
    if f['proto'] == 'udp':
        return not f['unreplied']
    if f['state'] != 'ESTABLISHED':
        return False
    return True if f['reply_bytes'] is None else f['reply_bytes'] >= min_reply_bytes


# ----------------------------------------------------------------------------------------------------------------------
# firewall: counters (usage), guard (pause / limit / expiry / second device) - own chains, never touches other rules
# ----------------------------------------------------------------------------------------------------------------------

class Netfilter(object):
    # Usage: Netfilter() -> controls the chains OLP-GUARD / OLP-GUARD-OUT (blocks) and OLP-IN / OLP-OUT (byte counters)
    #        for IPv4 and IPv6; the jumps sit at the top of INPUT and OUTPUT.
    G_IN, G_OUT, C_IN, C_OUT = 'OLP-GUARD', 'OLP-GUARD-OUT', 'OLP-IN', 'OLP-OUT'

    # Usage: Netfilter() -> finds which of iptables / ip6tables work on this machine and whether conntrack is installed
    def __init__(self):
        self.fams = []
        for fam, binary in (('4', 'iptables'), ('6', 'ip6tables')):
            if all(shutil.which(b) for b in (binary, binary + '-save', binary + '-restore')):
                if run([binary, '-w', '-S'])[0] == 0:
                    self.fams.append(fam)
        self.has_conntrack = shutil.which('conntrack') is not None
        self.conntrack_warned = False

    # Usage: self._bin("4") -> "iptables"
    def _bin(self, fam):
        return 'iptables' if fam == '4' else 'ip6tables'

    # Usage: self._ipt("4", ["-S", "INPUT"]) -> (rc, out, err)
    def _ipt(self, fam, args):
        return run([self._bin(fam), '-w'] + args)

    # Usage: self._restore("4", "*filter\n...COMMIT\n") -> True on success (retries while another program holds the xtables lock)
    def _restore(self, fam, text):
        for _ in range(5):
            rc, _, err = run([self._bin(fam) + '-restore', '--noflush'], input_text=text)
            if rc == 0:
                return True
            if 'lock' not in err.lower():
                break
            time.sleep(0.5)
        log.error('%s-restore failed: %s', self._bin(fam), err.strip())
        return False

    # Usage: self.setup() -> creates the four chains and puts their jumps first in INPUT / OUTPUT (re-run to repair). True if it changed anything.
    #        Also adds one harmless counting rule on connection state: the kernel only tracks connections (conntrack) once some
    #        rule needs it, and the one-device rule needs to see who is connected.
    def setup(self):
        changed = False
        for fam in self.fams:
            for ch in (self.G_IN, self.G_OUT, self.C_IN, self.C_OUT):
                if self._ipt(fam, ['-L', ch, '-n'])[0] != 0:
                    self._ipt(fam, ['-N', ch])
                    changed = True
            hook = ['-m', 'conntrack', '--ctstate', 'NEW']
            if self._ipt(fam, ['-C', self.C_IN] + hook)[0] != 0:
                self._ipt(fam, ['-A', self.C_IN] + hook)
                changed = True
            for parent, chains in (('INPUT', [self.G_IN, self.C_IN]), ('OUTPUT', [self.G_OUT, self.C_OUT])):
                rules = [l.split() for l in self._ipt(fam, ['-S', parent])[1].splitlines() if l.startswith('-A ' + parent + ' ')]
                head = [r for r in rules[:len(chains)]]
                if head == [['-A', parent, '-j', c] for c in chains]:
                    continue
                for c in chains:
                    for _ in range(10):
                        if self._ipt(fam, ['-D', parent, '-j', c])[0] != 0:
                            break
                for c in reversed(chains):
                    self._ipt(fam, ['-I', parent, '1', '-j', c])
                changed = True
        return changed

    # Usage: self._saved("4") -> {(chain, proto, port): (packets, bytes)} for the counter rules, from iptables-save -c
    def _saved(self, fam):
        out = run([self._bin(fam) + '-save', '-c', '-t', 'filter'])[1]
        res = {}
        for line in out.splitlines():
            m = re.match(r'^\[(\d+):(\d+)\] -A (OLP-IN|OLP-OUT) -p (tcp|udp)(?: -m (?:tcp|udp))? --(?:dport|sport) (\d+)\s*$', line)
            if m:
                res[(m.group(3), m.group(4), int(m.group(5)))] = (int(m.group(1)), int(m.group(2)))
        return res

    # Usage: self.sync_counters([20001, 20002]) -> makes the counting rules exist for exactly these key ports
    #        (counters of existing rules are kept)
    def sync_counters(self, ports):
        ports = set(ports)
        for fam in self.fams:
            have = set(self._saved(fam))
            want = set()
            for p in ports:
                for proto in ('tcp', 'udp'):
                    want.add((self.C_IN, proto, p))
                    want.add((self.C_OUT, proto, p))
            for ch, proto, p in have - want:
                self._ipt(fam, ['-D', ch, '-p', proto, '--dport' if ch == self.C_IN else '--sport', str(p)])
            missing = sorted(want - have)
            if missing:
                text = '*filter\n' + ''.join('-A %s -p %s --%s %d\n' % (ch, proto, 'dport' if ch == self.C_IN else 'sport', p)
                                             for ch, proto, p in missing) + 'COMMIT\n'
                self._restore(fam, text)

    # Usage: self.read_counters() -> {port: {"in4": bytes from clients, "out4": bytes to clients, "in6": ..., "out6": ...}}
    def read_counters(self):
        res = {}
        for fam in self.fams:
            for (ch, _proto, port), (_pk, nbytes) in self._saved(fam).items():
                d = res.setdefault(port, {})
                name = ('in' if ch == self.C_IN else 'out') + fam
                d[name] = d.get(name, 0) + nbytes
        return res

    # Usage: self.apply_guard(8443, {20003}, {20001: {"203.0.113.9"}}) -> atomically rebuilds the guard chains:
    #        the private Shadowbox port is closed to the outside, whole keys are cut (paused / limit / expired),
    #        and blocked devices are cut on their key's port (TCP gets a reset, UDP is dropped).
    def apply_guard(self, protect_port, block_ports, block_devs):
        ok = True
        for fam in self.fams:
            lin, lout = [], []
            if protect_port:
                lin.append('-A %s ! -i lo -p tcp --dport %d -j DROP' % (self.G_IN, protect_port))
            for p in sorted(block_ports):
                lin.append('-A %s -p tcp --dport %d -j REJECT --reject-with tcp-reset' % (self.G_IN, p))
                lin.append('-A %s -p udp --dport %d -j DROP' % (self.G_IN, p))
                lout.append('-A %s -p tcp --sport %d -j DROP' % (self.G_OUT, p))
                lout.append('-A %s -p udp --sport %d -j DROP' % (self.G_OUT, p))
            for p in sorted(block_devs):
                for dev in sorted(block_devs[p]):
                    if (':' in dev) != (fam == '6'):
                        continue
                    lin.append('-A %s -s %s -p tcp --dport %d -j REJECT --reject-with tcp-reset' % (self.G_IN, dev, p))
                    lin.append('-A %s -s %s -p udp --dport %d -j DROP' % (self.G_IN, dev, p))
                    lout.append('-A %s -d %s -p tcp --sport %d -j DROP' % (self.G_OUT, dev, p))
                    lout.append('-A %s -d %s -p udp --sport %d -j DROP' % (self.G_OUT, dev, p))
            text = ('*filter\n:%s - [0:0]\n:%s - [0:0]\n-F %s\n-F %s\n' % (self.G_IN, self.G_OUT, self.G_IN, self.G_OUT)
                    + '\n'.join(lin + lout) + ('\n' if lin or lout else '') + 'COMMIT\n')
            ok = self._restore(fam, text) and ok
        return ok

    # Usage: self.read_flows({20001, 20002}) -> {port: {device: qualified}} from conntrack, or None when conntrack cannot be read
    def read_flows(self, ports, min_reply_bytes):
        if not self.has_conntrack or not ports:
            return None
        res = {p: {} for p in ports}
        got = False
        for fam in ('ipv4', 'ipv6'):
            if fam == 'ipv6' and '6' not in self.fams:
                continue
            rc, out, _ = run(['conntrack', '-L', '-f', fam])
            if rc != 0:
                continue
            got = True
            for line in out.splitlines():
                f = parse_conntrack(line)
                if not f or f['dport'] not in res:
                    continue
                dev = device_id(f['src'])
                if dev:
                    q = flow_qualified(f, min_reply_bytes)
                    res[f['dport']][dev] = res[f['dport']].get(dev, False) or q
        if not got and not self.conntrack_warned:
            self.conntrack_warned = True
            log.warning('conntrack cannot be read: one-device-per-key is paused (modprobe nf_conntrack?)')
        return res if got else None

    # Usage: self.kill("203.0.113.9", 20001) -> best effort: drops tracked flows and closes server-side sockets of that device on that port
    def kill(self, dev, port):
        if self.has_conntrack and '/' not in dev:
            for proto in ('tcp', 'udp'):
                run(['conntrack', '-D', '-p', proto, '--orig-src', dev, '--orig-port-dst', str(port)])
        if shutil.which('ss'):
            run(['ss', '-K', '-t', 'state', 'established', '( sport = :%d and dst %s )' % (port, dev)])

    # Usage: self.protect_conntrack() -> turns on per-flow byte accounting so scanners can be told from real clients
    def protect_conntrack(self):
        try:
            with open('/proc/sys/net/netfilter/nf_conntrack_acct', 'w') as f:
                f.write('1')
        except OSError:
            pass


# ----------------------------------------------------------------------------------------------------------------------
# Shadowbox client
# ----------------------------------------------------------------------------------------------------------------------

class Shadowbox(object):
    # Usage: Shadowbox(port, prefix) -> talks to the private Shadowbox API on 127.0.0.1
    def __init__(self, port, prefix):
        self.port, self.prefix = port, prefix

    # Usage: self.request("POST", "/access-keys", {"name": "x"}) -> (status, content_type, body_bytes); ApiError(502) if unreachable
    def request(self, method, path, body=None, raw=None, ctype='application/json'):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        try:
            conn = http.client.HTTPSConnection('127.0.0.1', self.port, timeout=20, context=ssl._create_unverified_context())
            headers = {'Content-Type': ctype} if data is not None else {}
            conn.request(method, '/' + self.prefix + path, body=data, headers=headers)
            r = conn.getresponse()
            payload = r.read()
            result = (r.status, r.getheader('Content-Type') or 'application/json', payload)
            conn.close()
            return result
        except (OSError, http.client.HTTPException, ssl.SSLError) as e:
            raise ApiError(502, 'Outline server (Shadowbox) is not answering: %s' % e)

    # Usage: self.json("GET", "/access-keys") -> parsed JSON of a 2xx answer; ApiError with Shadowbox's status otherwise
    def json(self, method, path, body=None):
        st, _, data = self.request(method, path, body)
        if st >= 300:
            raise ApiError(st, data.decode('utf-8', 'replace')[:300] or 'Shadowbox error')
        return json.loads(data.decode()) if data else None

    # Usage: self.keys() -> list of Shadowbox's access keys (id, name, password, port, method, accessUrl)
    def keys(self):
        return self.json('GET', '/access-keys').get('accessKeys', [])


# ----------------------------------------------------------------------------------------------------------------------
# the panel: state, accounting, policies, one-device rule
# ----------------------------------------------------------------------------------------------------------------------

# Usage: new_record(20001, True) -> the stored state of one key
def new_record(port, managed, single=True):
    return {'port': port, 'managed': managed, 'created': int(time.time()), 'up': 0, 'down': 0, 'raw': {},
            'last_seen': 0, 'first_connected': 0, 'paused': False, 'limit': 0, 'expires_at': 0, 'expires_after': '',
            'single_device': single, 'owner': '', 'owner_active': 0, 'blocked': {}, 'first_seen': {}}


class Panel(object):
    # Usage: Panel(cfg, netfilter, shadowbox) -> loads state.json; call tick() every sample_seconds and the api_* methods per request
    def __init__(self, cfg, nf, sb):
        self.cfg, self.nf, self.sb = cfg, nf, sb
        self.lock = threading.RLock()
        self.state = {'version': 1, 'keys': {}, 'cursor': 0}
        self.dirty = False
        self.last_save = 0
        self.hist = {}
        self.sb_keys = []
        self.sb_time = 0
        self.synced_ports = None
        self.guard_sig = None
        self.last_repair = 0
        self.kill_list = []
        self.started = time.time()
        self.load()

    # Usage: self.load() -> reads state.json (an unreadable file is kept as state.json.bad and the panel starts empty)
    def load(self):
        path = self.cfg['state_file']
        try:
            with open(path) as f:
                st = json.load(f)
            if isinstance(st.get('keys'), dict):
                self.state = st
                for k in st['keys'].values():
                    for name, val in new_record(0, True).items():
                        k.setdefault(name, val)
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            log.error('state file unreadable, moved to %s.bad', path)
            try:
                os.replace(path, path + '.bad')
            except OSError:
                pass

    # Usage: self.save() -> writes state.json atomically
    def save(self):
        path = self.cfg['state_file']
        tmp = path + '.tmp'
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(tmp, 'w') as f:
                json.dump(self.state, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
            self.dirty = False
            self.last_save = time.time()
        except OSError as e:
            log.error('cannot save state: %s', e)

    # Usage: self.status_of(rec, now) -> "paused" | "limit" | "expired" | "active" (what blocks the key, in that order)
    def status_of(self, k, now):
        if k['paused']:
            return 'paused'
        if k['limit'] and k['up'] + k['down'] >= k['limit']:
            return 'limit'
        if k['expires_at'] and now >= k['expires_at']:
            return 'expired'
        return 'active'

    # Usage: self.refresh_keys(force=False) -> re-reads Shadowbox's key list (at most every 30 s) and adopts / forgets keys
    def refresh_keys(self, force=False):
        if not force and time.time() - self.sb_time < 30:
            return
        keys = self.sb.keys()
        with self.lock:
            self.sb_keys, self.sb_time = keys, time.time()
            count = collections.Counter(k['port'] for k in keys)
            ids = set()
            for k in keys:
                ids.add(str(k['id']))
                rec = self.state['keys'].get(str(k['id']))
                shared = count[k['port']] > 1
                if rec is None:
                    rec = self.state['keys'][str(k['id'])] = new_record(k['port'], not shared, self.cfg['single_device'])
                    log.info('adopted key %s on port %s (%s)', k['id'], k['port'], 'managed' if not shared else 'shared port')
                    self.dirty = True
                if rec['port'] != k['port'] or rec['managed'] == shared:
                    rec['port'], rec['managed'] = k['port'], not shared
                    self.dirty = True
            for kid in list(self.state['keys']):
                rec = self.state['keys'][kid]
                if kid in ids:
                    rec['gone'] = 0
                    continue
                # a key is forgotten only after it was missing from three lists in a row (guards against a half-started Shadowbox)
                rec['gone'] = rec.get('gone', 0) + 1
                if rec['gone'] >= 3:
                    del self.state['keys'][kid]
                    self.hist.pop(kid, None)
                    self.dirty = True

    # Usage: self.alloc_port(extra_used=set()) -> the next free port of the range (round robin, so a port is not reused at once)
    def alloc_port(self, extra_used=()):
        lo, hi = self.cfg['port_range']
        used = set(extra_used) | {k['port'] for k in self.state['keys'].values()} | {k['port'] for k in self.sb_keys}
        size = hi - lo + 1
        for i in range(size):
            port = lo + (self.state.get('cursor', 0) + i) % size
            if port in used:
                continue
            ok = True
            for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                s = socket.socket(socket.AF_INET, kind)
                try:
                    s.bind(('0.0.0.0', port))
                except OSError:
                    ok = False
                finally:
                    s.close()
            if ok:
                self.state['cursor'] = (port - lo + 1) % size
                return port
        raise ApiError(507, 'no free port left in %d-%d: widen port_range in config.json' % (lo, hi))

    # Usage: self._update_devices(k, flows, now) -> one-device rule. Devices with real traffic on the key's port are compared:
    #        the newest wins, every other device is blocked on that port (and listed in k["blocked"]) until the winner is idle
    #        for owner_release_seconds. Returns True when the blocked list or the owner changed.
    def _update_devices(self, k, flows, now):
        cur = {d for d, q in (flows or {}).items() if q and d not in k['blocked']}
        seen = k['first_seen']
        for d in cur:
            seen.setdefault(d, now)
        for d in list(seen):
            if d not in cur:
                del seen[d]
        changed = False
        owner = k['owner']
        idle = now - k['owner_active'] > self.cfg['owner_release_seconds']
        if owner and idle and not cur:
            # the owner left and nobody else is here: the key is free again
            k['owner'], k['blocked'] = '', {}
            return True
        if owner and idle and k['blocked']:
            # the owner is quiet: devices that were pushed out may come back (the first one back becomes the owner)
            k['blocked'] = {}
            changed = True
        if cur:
            winner = max(sorted(cur), key=lambda d: (seen[d], d == owner))
            losers = set(cur) - {winner}
            if owner and owner != winner:
                losers.add(owner)
            for d in losers:
                if d not in k['blocked']:
                    k['blocked'][d] = int(now)
                    self.kill_list.append((d, k['port']))
                    changed = True
                    log.info('port %s: device %s replaced by %s', k['port'], d, winner)
            if owner != winner:
                k['owner'], k['owner_active'] = winner, now
                changed = True
            k['blocked'].pop(winner, None)
            while len(k['blocked']) > 50:
                k['blocked'].pop(min(k['blocked'], key=k['blocked'].get))
        return changed

    # Usage: self._tick_key(id, rec, counters, flows, now) -> adds the traffic since the last sample, updates last seen /
    #        first connection / expiry start and the one-device rule of one key
    def _tick_key(self, kid, k, counters, flows, now):
        traffic = 0
        if counters is not None:
            for name in ('in4', 'in6', 'out4', 'out6'):
                cur, last = counters.get(name, 0), k['raw'].get(name, 0)
                delta = cur - last if cur >= last else cur
                k['raw'][name] = cur
                if delta:
                    k['up' if name.startswith('in') else 'down'] += delta
                    traffic += delta
        real = flows is None or any(q for d, q in flows.items() if d not in k['blocked'])
        if traffic and real:
            k['last_seen'], k['owner_active'] = int(now), now
            if not k['first_connected']:
                k['first_connected'] = int(now)
                if k['expires_after'] and not k['expires_at']:
                    k['expires_at'] = add_duration(k['first_connected'], k['expires_after'])
                    log.info('key %s: first connection, ends %s', kid, server_clock(k['expires_at']))
        if traffic:
            self.dirty = True
        if k['single_device'] and flows is not None and self._update_devices(k, flows, now):
            self.dirty = True
            self.guard_sig = None

    # Usage: self._apply_guard() -> pushes the current blocks to the firewall when they changed
    def _apply_guard(self, now):
        block_ports, block_devs = set(), {}
        for k in self.state['keys'].values():
            if not k['managed']:
                continue
            if self.status_of(k, now) != 'active':
                block_ports.add(k['port'])
            elif k['single_device'] and k['blocked']:
                block_devs[k['port']] = set(k['blocked'])
        sig = (sorted(block_ports), sorted((p, sorted(d)) for p, d in block_devs.items()))
        if sig != self.guard_sig:
            if self.nf.apply_guard(self.cfg['shadowbox_port'], block_ports, block_devs):
                self.guard_sig = sig

    # Usage: self.tick() -> one sample: counters, flows, policies, firewall. Called every sample_seconds by the background thread.
    def tick(self):
        now = time.time()
        try:
            self.refresh_keys()
        except ApiError as e:
            log.debug('key list not refreshed: %s', e.message)
        with self.lock:
            managed = {i: k for i, k in self.state['keys'].items() if k['managed']}
            ports = sorted({k['port'] for k in managed.values()})
            if now - self.last_repair > 30:
                self.last_repair = now
                if self.nf.setup():
                    self.synced_ports, self.guard_sig = None, None
            if self.synced_ports != ports:
                self.nf.sync_counters(ports)
                self.synced_ports = ports
            counters = self.nf.read_counters()
            flows = self.nf.read_flows(set(ports), self.cfg['min_reply_bytes'])
            self.kill_list = []
            for kid, k in managed.items():
                self._tick_key(kid, k, counters.get(k['port'], {}), None if flows is None else flows.get(k['port'], {}), now)
                h = self.hist.setdefault(kid, collections.deque(maxlen=12))
                h.append((now, k['up'], k['down']))
            self._apply_guard(now)
            for dev, port in self.kill_list:
                self.nf.kill(dev, port)
            if self.dirty and now - self.last_save >= self.cfg['save_seconds']:
                self.save()

    # Usage: self.rate(kid, now) -> (upload bytes/s, download bytes/s) over about the last 10 s
    def rate(self, kid, now):
        h = [e for e in self.hist.get(kid, ()) if e[0] >= now - 10]
        if len(h) < 2 or now - h[-1][0] > 3 * self.cfg['sample_seconds'] + 1:
            return 0, 0
        dt = h[-1][0] - h[0][0]
        return (max(0, int((h[-1][1] - h[0][1]) / dt)), max(0, int((h[-1][2] - h[0][2]) / dt))) if dt > 0 else (0, 0)

    # Usage: self.view(sb_key, transfer, now) -> one key as returned by the API (Outline fields + panel fields)
    def view(self, sk, transfer, now):
        kid = str(sk['id'])
        k = self.state['keys'].get(kid) or new_record(sk['port'], False)
        out = dict(sk)
        status = self.status_of(k, now) if k['managed'] else 'unmanaged'
        up, down = (k['up'], k['down']) if k['managed'] else (None, None)
        total = k['up'] + k['down'] if k['managed'] else transfer.get(kid, 0)
        ur, dr = self.rate(kid, now) if k['managed'] else (0, 0)
        online = bool(k['last_seen'] and now - k['last_seen'] <= self.cfg['online_window_seconds'])
        out.update({
            'managed': k['managed'], 'status': status, 'paused': k['paused'], 'blocked': status in ('paused', 'limit', 'expired'),
            'createdAt': iso(k['created']),
            'uploadBytes': up, 'downloadBytes': down, 'totalBytes': total,
            'dataLimitBytes': k['limit'], 'dataLimit': {'bytes': k['limit']} if k['limit'] else None,
            'limitReached': status == 'limit',
            'expiresAt': iso(k['expires_at']), 'expiresAtServer': server_clock(k['expires_at']) if k['expires_at'] else None,
            'expiresAfterFirstConnection': k['expires_after'] or None, 'firstConnectedAt': iso(k['first_connected']),
            'expired': status == 'expired',
            'online': online, 'lastSeen': iso(k['last_seen']), 'lastHandshake': iso(k['last_seen']),
            'lastSeenSecondsAgo': int(now - k['last_seen']) if k['last_seen'] else None,
            'liveUploadBps': ur if online else 0, 'liveDownloadBps': dr if online else 0,
            'singleDevice': k['single_device'], 'clientDevice': k['owner'] or None,
            'blockedDevices': sorted(k['blocked']),
        })
        return out

    # Usage: self.transfer() -> {id: bytes} - Shadowbox's own totals, used only for keys that share a port (not managed)
    def transfer(self):
        if not any(not k['managed'] for k in self.state['keys'].values()):
            return {}
        try:
            return {str(i): b for i, b in (self.sb.json('GET', '/metrics/transfer') or {}).get('bytesTransferredByUserId', {}).items()}
        except ApiError:
            return {}

    # Usage: self.all_views(force=True) -> (list of key views, totals dict); force=False reuses the key list read within 30 s
    def all_views(self, force=True):
        self.refresh_keys(force=force)
        now = time.time()
        with self.lock:
            tr = self.transfer()
            views = [self.view(sk, tr, now) for sk in self.sb_keys]
        t = {'uploadBytes': 0, 'downloadBytes': 0, 'totalBytes': 0, 'liveUploadBps': 0, 'liveDownloadBps': 0, 'online': 0}
        for v in views:
            t['uploadBytes'] += v['uploadBytes'] or 0
            t['downloadBytes'] += v['downloadBytes'] or 0
            t['totalBytes'] += v['totalBytes'] or 0
            t['liveUploadBps'] += v['liveUploadBps']
            t['liveDownloadBps'] += v['liveDownloadBps']
            t['online'] += 1 if v['online'] else 0
        return views, t

    # Usage: self.server_info() -> panel facts added to /server and to every list answer
    def server_info(self):
        off = -(time.altzone if time.localtime().tm_isdst > 0 else time.timezone) // 60
        return {'panelVersion': VERSION, 'portRange': self.cfg['port_range'], 'onlineWindowSeconds': self.cfg['online_window_seconds'],
                'serverTime': iso(int(time.time())), 'serverClock': server_clock(time.time()),
                'utcOffset': '%s%02d:%02d' % ('-' if off < 0 else '+', abs(off) // 60, abs(off) % 60),
                'usageSource': 'kernel byte counters per key port (saved to disk)',
                'deviceDetection': 'conntrack' if self.nf.has_conntrack else 'unavailable',
                'features': ['usage', 'online', 'live-rate', 'time-limit', 'data-limit', 'pause', 'edit', 'single-device']}

    # Usage: self.record(kid) -> the stored state of a managed key; ApiError 404 unknown / 409 when it shares a port
    def record(self, kid, need_managed=True):
        self.refresh_keys(force=True)
        k = self.state['keys'].get(str(kid))
        if k is None:
            raise ApiError(404, 'no such key')
        if need_managed and not k['managed']:
            raise ApiError(409, 'this key shares its port with other keys, so it cannot be limited or paused: '
                                'POST /access-keys/%s/migrate-port gives it a port of its own (its access URL changes)' % kid)
        return k

    # Usage: self.parse_policy(body) -> validated changes from a request body: traffic, expiry, paused, singleDevice
    def parse_policy(self, body):
        ch = {}
        t = traffic_from(body)
        if t is not None:
            ch['limit'] = t
        e = expiry_from(body, time.time())
        if e is not None:
            ch['expiry'] = e
        for field, name in (('paused', 'paused'), ('singleDevice', 'single_device')):
            if field in body:
                if not isinstance(body[field], bool):
                    raise ApiError(400, field + ' must be true or false')
                ch[name] = body[field]
        return ch

    # Usage: self.apply_policy(rec, changes) -> stores validated changes and makes the firewall follow
    def apply_policy(self, k, ch):
        if 'limit' in ch:
            k['limit'] = ch['limit']
        if 'paused' in ch:
            k['paused'] = ch['paused']
        if 'single_device' in ch:
            k['single_device'] = ch['single_device']
            if not ch['single_device']:
                k['owner'], k['blocked'], k['first_seen'] = '', {}, {}
        if 'expiry' in ch:
            e = ch['expiry']
            if e[0] == 'none':
                k['expires_at'], k['expires_after'] = 0, ''
            elif e[0] == 'at':
                k['expires_at'], k['expires_after'] = e[1], ''
            else:
                k['expires_after'] = e[1]
                k['expires_at'] = add_duration(k['first_connected'], e[1]) if k['first_connected'] else 0
        self.dirty, self.guard_sig = True, None
        self._apply_guard(time.time())
        self.save()

    # Usage: self.api_create({"name": "Sima", "traffic": "20G", "expires": "30d"}) -> (201, key view) - a new key on its own port
    def api_create(self, body):
        ch = self.parse_policy(body)
        sbody = {k: body[k] for k in ('name', 'method', 'password') if k in body}
        self.refresh_keys(force=True)
        tried = set()
        for _ in range(6):
            with self.lock:
                port = self.alloc_port(tried)
            sbody['port'] = port
            st, _, data = self.sb.request('POST', '/access-keys', sbody)
            if st in (200, 201):
                break
            if st == 409:
                tried.add(port)
                continue
            raise ApiError(st, data.decode('utf-8', 'replace')[:300])
        else:
            raise ApiError(409, 'could not find a usable port')
        sk = json.loads(data.decode())
        with self.lock:
            rec = self.state['keys'][str(sk['id'])] = new_record(sk['port'], True, self.cfg['single_device'])
            self.sb_keys = [k for k in self.sb_keys if k['id'] != sk['id']] + [sk]
            self.apply_policy(rec, ch)
            ports = sorted({k['port'] for k in self.state['keys'].values() if k['managed']})
            self.nf.sync_counters(ports)
            self.synced_ports = ports
            view = self.view(sk, {}, time.time())
        return 201, view

    # Usage: self.api_delete("3") -> (204, None) - removes the key from Shadowbox, the firewall and the state
    def api_delete(self, kid):
        self.record(kid, need_managed=False)
        st, _, data = self.sb.request('DELETE', '/access-keys/' + str(kid))
        if st >= 300 and st != 404:
            raise ApiError(st, data.decode('utf-8', 'replace')[:300])
        with self.lock:
            self.state['keys'].pop(str(kid), None)
            self.hist.pop(str(kid), None)
            self.sb_keys = [k for k in self.sb_keys if str(k['id']) != str(kid)]
            self.synced_ports, self.guard_sig, self.dirty = None, None, True
            self._apply_guard(time.time())
            self.save()
        return 204, None

    # Usage: self.api_edit("3", {"name": "Sima", "traffic": "30G", "expires": "30d"}) -> (200, key view).
    #        Edits any of: name, traffic / limit, expires / expiresOn / expiresAfterFirstConnection, paused, singleDevice.
    def api_edit(self, kid, body):
        k = self.record(kid, need_managed=any(f != 'name' for f in body))
        ch = self.parse_policy(body)
        if 'name' in body:
            if not isinstance(body['name'], str):
                raise ApiError(400, 'name must be text')
            self.sb.json('PUT', '/access-keys/%s/name' % kid, {'name': body['name']})
        with self.lock:
            if ch:
                self.apply_policy(k, ch)
            self.refresh_keys(force=True)
        return 200, self.api_get(kid)[1]

    # Usage: self.api_get("3") -> (200, key view)
    def api_get(self, kid):
        views, _ = self.all_views()
        for v in views:
            if str(v['id']) == str(kid):
                return 200, v
        raise ApiError(404, 'no such key')

    # Usage: self.api_reset("3") -> (200, key view) - sets the usage of the key back to zero (a limit-blocked key works again)
    def api_reset(self, kid):
        k = self.record(kid)
        with self.lock:
            k['up'] = k['down'] = 0
            self.dirty, self.guard_sig = True, None
            self._apply_guard(time.time())
            self.save()
        return self.api_get(kid)

    # Usage: self.api_migrate("3", {"port": 20010}) -> (200, key view) - gives a shared-port key a port of its own
    #        (same id, name and password; only the port in its access URL changes)
    def api_migrate(self, kid, body):
        k = self.record(kid, need_managed=False)
        old = next((s for s in self.sb_keys if str(s['id']) == str(kid)), None)
        if old is None:
            raise ApiError(404, 'no such key')
        with self.lock:
            port = int(body.get('port') or self.alloc_port())
        spec = {'name': old.get('name', ''), 'method': old.get('method'), 'password': old.get('password'), 'port': port}
        self.sb.json('DELETE', '/access-keys/' + str(kid))
        try:
            self.sb.json('PUT', '/access-keys/' + str(kid), spec)
        except ApiError:
            spec['port'] = old['port']
            self.sb.json('PUT', '/access-keys/' + str(kid), spec)
            raise ApiError(502, 'Shadowbox refused the new port; the key was restored unchanged')
        with self.lock:
            k['port'], k['managed'] = port, True
            self.synced_ports, self.guard_sig, self.dirty = None, None, True
            self.save()
        return self.api_get(kid)


# ----------------------------------------------------------------------------------------------------------------------
# HTTP API (same URL layout as Outline: https://host:port/<secret>/access-keys ...)
# ----------------------------------------------------------------------------------------------------------------------

KEY = r'(?:access-)?keys'
ID = r'([^/]+)'


class Handler(BaseHTTPRequestHandler):
    # Usage: served by PanelServer, one instance per request; routes are matched in route() and everything else is forwarded
    server_version = 'outline-panel/' + VERSION
    timeout = 30

    # Usage: (called by the server) finishes the TLS handshake in this request's own thread so a silent client cannot block others
    def setup(self):
        self.request.do_handshake()
        BaseHTTPRequestHandler.setup(self)

    # Usage: (called by the server) keeps the log quiet except for errors
    def log_message(self, fmt, *args):
        pass

    # Usage: self.send_json(200, {...}) -> writes a JSON answer (204 = no body)
    def send_json(self, status, obj):
        data = b'' if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        if status != 204:
            self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    # Usage: self.read_body() -> (raw bytes, parsed JSON dict or {}); ApiError(400) for broken JSON, 413 over 1 MB
    def read_body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > 1 << 20:
            raise ApiError(413, 'body too large')
        raw = self.rfile.read(n) if n else b''
        if not raw.strip():
            return raw, {}
        try:
            obj = json.loads(raw.decode())
        except ValueError:
            return raw, None
        return raw, obj if isinstance(obj, dict) else {}

    # Usage: self.route(method, path) -> (status, object) for a panel route, or None when the request is not ours
    def route(self, method, path, body):
        p = self.server.panel
        m = lambda pat: re.match('^' + pat + '/?$', path)
        if method == 'GET':
            if m(''):
                return self.listing('keys')
            if m('/keys'):
                return self.listing('keys')
            if m('/access-keys'):
                return self.listing('accessKeys')
            r = m('/' + KEY + '/' + ID)
            if r:
                return p.api_get(r.group(1))
            if m('/live'):
                views, t = p.all_views(force=False)
                return 200, {'timestamp': iso(int(time.time())), 'totals': t, 'keys': [
                    {'id': v['id'], 'online': v['online'], 'liveUploadBps': v['liveUploadBps'], 'liveDownloadBps': v['liveDownloadBps'],
                     'uploadBytes': v['uploadBytes'], 'downloadBytes': v['downloadBytes']} for v in views]}
            if m('/usage') or m('/usage/' + ID):
                views, t = p.all_views()
                r = m('/usage/' + ID)
                if r:
                    views = [v for v in views if str(v['id']) == r.group(1)]
                    if not views:
                        raise ApiError(404, 'no such key')
                    return 200, views[0]
                return 200, {'timestamp': iso(int(time.time())), 'totals': t, 'keys': views}
            if m('/metrics/transfer'):
                views, _ = p.all_views()
                return 200, {'bytesTransferredByUserId': {str(v['id']): v['totalBytes'] or 0 for v in views}}
            if m('/server'):
                st, _, data = p.sb.request('GET', '/server')
                info = json.loads(data.decode()) if st == 200 else {}
                info.update(p.server_info())
                return 200, info
            return None
        if method == 'POST':
            if m('/' + KEY):
                return p.api_create(body or {})
            r = m('/' + KEY + '/' + ID + '/(pause|resume)')
            if r:
                return p.api_edit(r.group(1), {'paused': r.group(2) == 'pause'})
            r = m('/' + KEY + '/' + ID + '/reset-usage')
            if r:
                return p.api_reset(r.group(1))
            r = m('/' + KEY + '/' + ID + '/migrate-port')
            if r:
                return p.api_migrate(r.group(1), body or {})
            return None
        r = m('/' + KEY + '/' + ID)
        if method == 'DELETE' and r:
            return p.api_delete(r.group(1))
        if method == 'PATCH' and r:
            return p.api_edit(r.group(1), body or {})
        r = m('/' + KEY + '/' + ID + '/(limit|data-limit|expiry|paused)')
        if r and method in ('PUT', 'DELETE'):
            what, kid = r.group(2), r.group(1)
            if method == 'DELETE':
                body = {'expiresOn': 'never'} if what == 'expiry' else {'traffic': 'unlimited'}
                if what == 'paused':
                    body = {'paused': False}
            elif what == 'paused' and 'paused' not in (body or {}):
                raise ApiError(400, 'paused must be true or false')
            p.api_edit(kid, body or {})
            return 204, None
        return None

    # Usage: self.listing("accessKeys") -> (200, {"server","timestamp","count","totals",<field>: [key views]})
    def listing(self, field):
        p = self.server.panel
        views, totals = p.all_views()
        return 200, {'server': p.server_info(), 'timestamp': iso(int(time.time())), 'count': len(views), 'totals': totals, field: views}

    # Usage: self.forward(method, path, raw) -> sends the request unchanged to Shadowbox and relays its answer
    def forward(self, method, path, raw):
        st, ctype, data = self.server.panel.sb.request(method, path, raw=raw if raw else None,
                                                       ctype=self.headers.get('Content-Type', 'application/json'))
        self.send_response(st)
        if data:
            self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    # Usage: self.handle_any() -> checks the secret prefix, runs the panel route or forwards to Shadowbox
    def handle_any(self):
        prefix = '/' + self.server.cfg['api_prefix']
        full = self.path.split('?')[0]
        if full != prefix and not full.startswith(prefix + '/'):
            return self.send_json(404, {'error': 'not found'})
        path = full[len(prefix):]
        qs = self.path[len(full):]
        try:
            raw, body = self.read_body()
            if body is None:
                # not JSON: ours to refuse when it is a panel write route, otherwise Shadowbox decides
                if re.match(r'^/' + KEY + r'(/[^/]+(/(limit|data-limit|expiry|paused|pause|resume|reset-usage|migrate-port))?)?/?$', path):
                    raise ApiError(400, 'body is not valid JSON')
                res = None
            else:
                res = self.route(self.command, path, body)
            if res is None:
                return self.forward(self.command, path + qs, raw)
            return self.send_json(*res)
        except ApiError as e:
            return self.send_json(e.status, {'error': e.message})
        except Exception:
            log.exception('request failed: %s %s', self.command, path)
            return self.send_json(500, {'error': 'internal error'})

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = handle_any


class PanelServer(ThreadingMixIn, HTTPServer):
    # Usage: PanelServer(cfg, panel) -> TLS server on the public API port, IPv4 + IPv6
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    # Usage: PanelServer(cfg, panel) -> binds the public API port (dual-stack) and loads the TLS certificate
    def __init__(self, cfg, panel):
        self.cfg, self.panel = cfg, panel
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(cfg['cert_file'], cfg['key_file'])
        try:
            self.address_family = socket.AF_INET6
            HTTPServer.__init__(self, ('::', cfg['listen_port']), Handler)
        except OSError:
            self.address_family = socket.AF_INET
            HTTPServer.__init__(self, ('0.0.0.0', cfg['listen_port']), Handler)

    # Usage: (called by the server) makes the IPv6 socket dual-stack
    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        HTTPServer.server_bind(self)

    # Usage: (called by the server) accepts a plain socket and wraps it for TLS; the handshake happens in the request thread
    def get_request(self):
        sock, addr = self.socket.accept()
        sock.settimeout(15)
        return self.ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    # Usage: (called by the server) a failed handshake or a dropped client is not worth a stack trace
    def handle_error(self, request, client_address):
        log.debug('connection error from %s: %s', client_address[0], sys.exc_info()[1])


# ----------------------------------------------------------------------------------------------------------------------
# entry points
# ----------------------------------------------------------------------------------------------------------------------

# Usage: load_config("/opt/outline/panel/config.json") -> DEFAULTS overlaid with the file
def load_config(path):
    cfg = dict(DEFAULTS)
    with open(path) as f:
        cfg.update(json.load(f))
    return cfg


# Usage: firewall_restore(cfg) -> rebuilds counters and blocks from state.json alone (runs before Docker starts at boot)
def firewall_restore(cfg):
    nf = Netfilter()
    panel = Panel(cfg, nf, None)
    nf.setup()
    nf.protect_conntrack()
    nf.sync_counters(sorted({k['port'] for k in panel.state['keys'].values() if k['managed']}))
    panel.guard_sig = None
    panel._apply_guard(time.time())
    log.info('firewall restored for %d keys', len(panel.state['keys']))


# Usage: serve(cfg) -> runs the sampling thread and the HTTPS API until SIGTERM / SIGINT
def serve(cfg):
    nf = Netfilter()
    if not nf.fams:
        log.error('iptables is not usable: install iptables and run as root')
        sys.exit(1)
    nf.setup()
    nf.protect_conntrack()
    panel = Panel(cfg, nf, Shadowbox(cfg['shadowbox_port'], cfg['api_prefix']))
    stop = threading.Event()

    def loop():
        # Usage: (thread) sample forever; a failed sample is logged and retried
        while not stop.is_set():
            try:
                panel.tick()
            except Exception:
                log.exception('sample failed')
            stop.wait(cfg['sample_seconds'])

    threading.Thread(target=loop, daemon=True).start()
    server = PanelServer(cfg, panel)

    def shutdown(*_):
        # Usage: (signal handler) saves the usage and stops the API
        stop.set()
        with panel.lock:
            panel.save()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    log.info('outline-panel %s on port %d, key ports %d-%d, conntrack: %s', VERSION, cfg['listen_port'],
             cfg['port_range'][0], cfg['port_range'][1], nf.has_conntrack)
    server.serve_forever()
    with panel.lock:
        panel.save()


# Usage: python3 panel.py [serve|firewall-restore|version] [--config /opt/outline/panel/config.json]
def main():
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    args = sys.argv[1:]
    path = os.environ.get('OUTLINE_PANEL_CONFIG', '/opt/outline/panel/config.json')
    if '--config' in args:
        path = args[args.index('--config') + 1]
    cmd = next((a for a in args if a in ('serve', 'firewall-restore', 'version')), 'serve')
    if cmd == 'version':
        print(VERSION)
        return
    cfg = load_config(path)
    if cmd == 'firewall-restore':
        firewall_restore(cfg)
    else:
        serve(cfg)


if __name__ == '__main__':
    main()
OUTLINE_PANEL_PY_END
  chmod 700 "${PANEL_DIR}/panel.py"

  # Rewritten on every run (the API secret, ports and certificate change); keys, usage and limits live in state.json and are kept.
  cat > "${PANEL_DIR}/config.json" <<EOF
{
  "listen_port": ${API_PORT},
  "api_prefix": "${SB_API_PREFIX}",
  "cert_file": "${SB_CERTIFICATE_FILE}",
  "key_file": "${SB_PRIVATE_KEY_FILE}",
  "shadowbox_port": ${INTERNAL_API_PORT},
  "state_file": "${PANEL_DIR}/state.json",
  "port_range": [${PORT_RANGE_START}, ${PORT_RANGE_END}],
  "online_window_seconds": 180,
  "owner_release_seconds": 60,
  "single_device": true
}
EOF

  cat > /etc/systemd/system/outline-panel-firewall.service <<EOF
[Unit]
Description=Outline panel: restore key blocks and counters before Docker starts
Before=docker.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PYTHON_BIN} -I ${PANEL_DIR}/panel.py firewall-restore --config ${PANEL_DIR}/config.json

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/outline-panel.service <<EOF
[Unit]
Description=Outline panel (usage, time limits, pause, one device per key)
After=network-online.target docker.service outline-panel-firewall.service
Wants=network-online.target outline-panel-firewall.service

[Service]
Type=simple
ExecStart=${PYTHON_BIN} -I ${PANEL_DIR}/panel.py serve --config ${PANEL_DIR}/config.json
Restart=always
RestartSec=3
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
}

# Usage: start_panel_firewall -> installs the firewall unit and runs it, so a paused / limited key stays blocked from the first second
function start_panel_firewall() {
  systemctl daemon-reload
  systemctl enable outline-panel-firewall.service >&2
  systemctl restart outline-panel-firewall.service
}

# Usage: start_panel -> enables and (re)starts the key panel service
function start_panel() {
  systemctl enable outline-panel.service >&2
  systemctl restart outline-panel.service
}

# Usage: install_shadowbox -> the whole installation (called by main)
install_shadowbox() {
  local MACHINE_TYPE
  MACHINE_TYPE="$(uname -m)"
  if [[ "${MACHINE_TYPE}" != "x86_64" ]]; then
    log_error "Unsupported machine type: ${MACHINE_TYPE}. Please run this script on a x86_64 machine"
    exit 1
  fi
  if ! command_exists systemctl; then
    log_error "systemd is required (the key panel runs as a systemd service)."
    exit 1
  fi

  # Make sure we don't leak readable files to other users.
  umask 0007

  export CONTAINER_NAME="${CONTAINER_NAME:-shadowbox}"

  run_step "Verifying that Docker is installed" verify_docker_installed
  run_step "Verifying that Docker daemon is running" verify_docker_running
  run_step "Installing key panel requirements" install_panel_requirements

  log_for_sentry "Creating Outline directory"
  export SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
  mkdir -p "${SHADOWBOX_DIR}"
  chmod u+s,ug+rwx,o-rwx "${SHADOWBOX_DIR}"

  log_for_sentry "Setting key port range"
  if [[ -n "${FLAGS_PORT_RANGE}" ]]; then
    PORT_RANGE_START="${FLAGS_PORT_RANGE%-*}"
    PORT_RANGE_END="${FLAGS_PORT_RANGE#*-}"
  elif (( FLAGS_KEYS_PORT != 0 )); then
    PORT_RANGE_START="${FLAGS_KEYS_PORT}"
    PORT_RANGE_END=$(( FLAGS_KEYS_PORT + 999 > 65535 ? 65535 : FLAGS_KEYS_PORT + 999 ))
  else
    PORT_RANGE_START=20000
    PORT_RANGE_END=20999
  fi
  readonly PORT_RANGE_START PORT_RANGE_END

  log_for_sentry "Setting API port"
  API_PORT="${FLAGS_API_PORT}"
  if (( API_PORT == 0 )); then
    API_PORT=${SB_API_PORT:-$(get_free_random_port)}
  fi
  readonly API_PORT
  INTERNAL_API_PORT="$(get_free_random_port)"
  readonly INTERNAL_API_PORT
  run_step "Checking the key port range" check_port_ranges
  readonly ACCESS_CONFIG="${ACCESS_CONFIG:-${SHADOWBOX_DIR}/access.txt}"
  readonly SB_IMAGE="${SB_IMAGE:-quay.io/outline/shadowbox:stable}"

  PUBLIC_HOSTNAME="${FLAGS_HOSTNAME:-${SB_PUBLIC_IP:-}}"
  if [[ -z "${PUBLIC_HOSTNAME}" ]]; then
    run_step "Setting PUBLIC_HOSTNAME to external IP" set_hostname
  fi
  readonly PUBLIC_HOSTNAME

  # If $ACCESS_CONFIG is already populated, make a backup before clearing it.
  log_for_sentry "Initializing ACCESS_CONFIG"
  if [[ -s "${ACCESS_CONFIG}" ]]; then
    # Note we can't do "mv" here as do_install_server.sh may already be tailing
    # this file.
    cp "${ACCESS_CONFIG}" "${ACCESS_CONFIG}.bak" && true > "${ACCESS_CONFIG}"
  fi

  # Make a directory for persistent state
  run_step "Creating persistent state dir" create_persisted_state_dir
  run_step "Generating secret key" generate_secret_key
  run_step "Generating TLS certificate" generate_certificate
  run_step "Generating SHA-256 certificate fingerprint" generate_certificate_fingerprint
  run_step "Writing config" write_config
  run_step "Writing key panel files" write_panel_files
  run_step "Opening ports (ufw / firewalld if active)" open_key_ports
  run_step "Starting key panel firewall" start_panel_firewall

  # TODO(dborkan): if the script fails after docker run, it will continue to fail
  # as the names shadowbox and watchtower will already be in use.  Consider
  # deleting the container in the case of failure (e.g. using a trap, or
  # deleting existing containers on each run).
  run_step "Starting Shadowbox" start_shadowbox
  # TODO(fortuna): Don't wait for Shadowbox to run this.
  run_step "Starting Watchtower" start_watchtower

  readonly PUBLIC_API_URL="https://${PUBLIC_HOSTNAME}:${API_PORT}/${SB_API_PREFIX}"
  readonly LOCAL_API_URL="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  readonly LOCAL_SB_URL="https://localhost:${INTERNAL_API_PORT}/${SB_API_PREFIX}"
  run_step "Waiting for Outline server to be healthy" wait_shadowbox
  run_step "Starting key panel" start_panel
  run_step "Waiting for key panel" wait_panel
  run_step "Creating first user" create_first_user
  run_step "Adding API URL to config" add_api_url_to_config

  FIREWALL_STATUS=""
  run_step "Checking host firewall" check_firewall

  # Echos the value of the specified field from ACCESS_CONFIG.
  # e.g. if ACCESS_CONFIG contains the line "certSha256:1234",
  # calling $(get_field_value certSha256) will echo 1234.
  # Usage: get_field_value certSha256 -> the value stored in ACCESS_CONFIG for that field
  function get_field_value {
    grep "$1" "${ACCESS_CONFIG}" | sed "s/$1://"
  }

  # Output JSON.  This relies on apiUrl and certSha256 (hex characters) requiring
  # no string escaping.  TODO: look for a way to generate JSON that doesn't
  # require new dependencies.
  cat <<END_OF_SERVER_OUTPUT

CONGRATULATIONS! Your Outline server is up and running.

To manage your Outline server, please copy the following line (including curly
brackets) into Step 2 of the Outline Manager interface:

$(echo -e "\033[1;32m{\"apiUrl\":\"$(get_field_value apiUrl)\",\"certSha256\":\"$(get_field_value certSha256)\"}\033[0m")

Key panel (usage, time limit, pause, edit, one device per key) is running as the service outline-panel:
- API:      GET ${PUBLIC_API_URL}/access-keys   (same URL and certificate as Outline Manager uses)
- Key ports: ${PORT_RANGE_START}-${PORT_RANGE_END}, one per key
- Logs:     journalctl -u outline-panel -f
- Settings: vi ${PANEL_DIR}/config.json   (then: systemctl restart outline-panel)

${FIREWALL_STATUS}
END_OF_SERVER_OUTPUT
} # end of install_shadowbox

# Usage: is_valid_port 8443 -> succeeds when the value is a port number from 1 to 65535
function is_valid_port() {
  (( 0 < "$1" && "$1" <= 65535 ))
}

# Usage: escape_json_string 'a "quoted" text' -> prints the text escaped for use inside a JSON string
function escape_json_string() {
  local input=$1
  for ((i = 0; i < ${#input}; i++)); do
    local char="${input:i:1}"
    local escaped="${char}"
    case "${char}" in
      $'"' ) escaped="\\\"";;
      $'\\') escaped="\\\\";;
      *)
        if [[ "${char}" < $'\x20' ]]; then
          case "${char}" in
            $'\b') escaped="\\b";;
            $'\f') escaped="\\f";;
            $'\n') escaped="\\n";;
            $'\r') escaped="\\r";;
            $'\t') escaped="\\t";;
            *) escaped=$(printf "\u%04X" "'${char}")
          esac
        fi;;
    esac
    echo -n "${escaped}"
  done
}

# Usage: parse_flags "$@" -> reads --hostname, --api-port, --keys-port and --port-range into FLAGS_*
function parse_flags() {
  local params
  params="$(getopt --longoptions hostname:,api-port:,keys-port:,port-range: -n "$0" -- "$0" "$@")"
  eval set -- "${params}"

  while (( $# > 0 )); do
    local flag="$1"
    shift
    case "${flag}" in
      --hostname)
        FLAGS_HOSTNAME="$1"
        shift
        ;;
      --api-port)
        FLAGS_API_PORT=$1
        shift
        if ! is_valid_port "${FLAGS_API_PORT}"; then
          log_error "Invalid value for ${flag}: ${FLAGS_API_PORT}" >&2
          exit 1
        fi
        ;;
      --keys-port)
        FLAGS_KEYS_PORT=$1
        shift
        if ! is_valid_port "${FLAGS_KEYS_PORT}"; then
          log_error "Invalid value for ${flag}: ${FLAGS_KEYS_PORT}" >&2
          exit 1
        fi
        ;;
      --port-range)
        FLAGS_PORT_RANGE=$1
        shift
        if [[ ! "${FLAGS_PORT_RANGE}" =~ ^[0-9]+-[0-9]+$ ]]; then
          log_error "Invalid value for ${flag}: ${FLAGS_PORT_RANGE} (use <first>-<last>, e.g. 20000-20999)" >&2
          exit 1
        fi
        ;;
      --)
        break
        ;;
      *) # This should not happen
        log_error "Unsupported flag ${flag}" >&2
        display_usage >&2
        exit 1
        ;;
    esac
  done
  if (( FLAGS_API_PORT != 0 && FLAGS_API_PORT == FLAGS_KEYS_PORT )); then
    log_error "--api-port must be different from --keys-port" >&2
    exit 1
  fi
  return 0
}

# Usage: main "$@" -> installs the Outline server, Watchtower and the key panel
function main() {
  trap finish EXIT
  declare FLAGS_HOSTNAME=""
  declare -i FLAGS_API_PORT=0
  declare -i FLAGS_KEYS_PORT=0
  declare FLAGS_PORT_RANGE=""
  parse_flags "$@"
  install_shadowbox
}

main "$@"
