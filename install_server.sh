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


# Script to install the Outline Server docker container, the Mithra key panel and a patched outline-ss-server ("device
# guard"), and to create a new Outline user.
#
# Every key stays a normal Outline key (ss:// access URL, works in the Outline Client) and ALL keys share ONE port, just
# like all WireGuard peers share one UDP port. What this script adds on top of the stock Outline server (Shadowbox):
#   1. traffic that is kept            (usage per key is read from outline-ss-server's counters and saved on disk)
#   2. one device per key              (the newest device wins, the older one is cut off at once - like WireGuard)
#   3. online / last seen              3.1 live upload / download rate per key
#   4. time limit per key              (date, duration from now, duration after first connection, or none)
#   5. usage per key                   (upload, download, total, optional data limit)
#   6. pause / resume a key            7. edit a key (name, traffic, time limit)
# Shadowsocks has no handshake and no inner IP, so "which device is using this key" can only be decided inside the proxy,
# where the key and the client address are known together. That is what the small patch to outline-ss-server does; this
# script builds it on your server (in a temporary Go container) and mounts it into the Shadowbox container.
# Watchtower is NOT started: an automatic image update would replace the patched binary's matching Shadowbox.
#
# You may set the following environment variables, overriding their defaults:
# SB_IMAGE: The Outline Server Docker image to install, e.g. quay.io/outline/shadowbox:stable
# CONTAINER_NAME: Docker instance name for shadowbox (default shadowbox).
#     For multiple instances also change SHADOWBOX_DIR to an other location
#     e.g. CONTAINER_NAME=shadowbox-inst1 SHADOWBOX_DIR=/opt/outline/inst1
# SHADOWBOX_DIR: Directory for persistent Outline Server state.
# ACCESS_CONFIG: The location of the access config text file.
# SB_DEFAULT_SERVER_NAME: Default name for this server, e.g. "Outline server New York".
# SENTRY_LOG_FILE: File for writing logs which may be reported to Sentry, in case
#     of an install error. No PII should be written to this file. Intended to be set
#     only by do_install_server.sh.
# PANEL_DIR: Directory of the key panel (default ${SHADOWBOX_DIR}/panel). Its config is PANEL_DIR/config.json
#     (edit it with: vi ${SHADOWBOX_DIR}/panel/config.json, then: systemctl restart outline-panel).
# GUARD_IMAGE: Docker image used once to compile the patched outline-ss-server (default golang:1.23-alpine).
# GUARD_DIR: Where the patched binary is kept (default ${SHADOWBOX_DIR}/guard).
#
# Deprecated:
# SB_PUBLIC_IP: Use the --hostname flag instead
# SB_API_PORT: Use the --api-port flag instead

# Requires curl and docker to be installed (python3 is installed by this script when missing)

set -euo pipefail

# Usage: display_usage -> prints the command line flags
function display_usage() {
  cat <<EOF
Usage: install_server.sh [--hostname <hostname>] [--api-port <port>] [--keys-port <port>]

  --hostname    The hostname to be used to access the management API and access keys
  --api-port    The port number for the management API
  --keys-port   The ONE port all access keys use (TCP and UDP). Default: random, chosen by Outline.
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

# Usage: get_free_random_port -> prints a random port that is not one of the ports already chosen
function get_free_random_port() {
  local -i port
  while true; do
    port="$(get_random_port)"
    if (( port == ${API_PORT:-0} )); then continue; fi
    if (( port == ${INTERNAL_API_PORT:-0} )); then continue; fi
    if (( port == ${FLAGS_KEYS_PORT:-0} )); then continue; fi
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
#        (INTERNAL_API_PORT, only used by the key panel on this machine); the key panel owns the public API port
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

  # Use log rotation. See https://docs.docker.com/config/containers/logging/configure/.
  --log-driver local

  # The state that is persisted across restarts.
  -v "${STATE_DIR}:${STATE_DIR}"

  # The patched outline-ss-server (device guard) replaces the stock binary of the image.
  -v "${GUARD_BIN}:${SS_BIN_IN_IMAGE}:ro"

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

# Usage: create_first_user -> creates the first access key (through the panel; it uses the one shared key port)
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
provider) that is preventing incoming connections to port ${API_PORT} and to the key port ${KEYS_PORT}."
  else
    FIREWALL_STATUS="\
If you have connection problems, it may be that your router or cloud provider
blocks inbound connections, even though your machine seems to allow them."
  fi
  FIREWALL_STATUS="\
${FIREWALL_STATUS}

Make sure to open the following ports on your firewall, router or cloud provider:
- Management port ${API_PORT}, for TCP
- Access key port ${KEYS_PORT} (shared by all keys), for TCP and UDP
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
# Device guard (patched outline-ss-server)
# ---------------------------------------------------------------------------------------------------------------------

readonly SS_BIN_IN_IMAGE="/opt/outline-server/bin/outline-ss-server"

# Usage: detect_ss_version -> sets SS_VERSION (e.g. v1.7.3): the outline-ss-server release that SB_IMAGE was built with,
#        read from the Go build info of the binary inside the image
function detect_ss_version() {
  mkdir -p "${GUARD_DIR}"
  if ! docker run --rm --entrypoint cat "${SB_IMAGE}" "${SS_BIN_IN_IMAGE}" > "${GUARD_DIR}/ss-original"; then
    log_error "Could not read ${SS_BIN_IN_IMAGE} from ${SB_IMAGE}: this image is not a Shadowbox image this script knows."
    return 1
  fi
  local info
  info="$(docker run --rm -v "${GUARD_DIR}:/w:ro" "${GUARD_IMAGE}" go version -m /w/ss-original)" || return 1
  SS_VERSION="$(awk '($1 == "dep" || $1 == "mod") && $2 ~ /Jigsaw-Code\/outline-ss-server$/ { print $3; exit }' <<<"${info}")"
  rm -f "${GUARD_DIR}/ss-original"
  if [[ ! "${SS_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "The outline-ss-server inside ${SB_IMAGE} is not a Jigsaw-Code/outline-ss-server release (found: '${SS_VERSION}'), so the device guard patch does not fit it. Use SB_IMAGE=<an image built with outline-ss-server v1.7.x>."
    return 1
  fi
}

# Usage: build_guard -> compiles outline-ss-server ${SS_VERSION} with the device guard patch into ${GUARD_BIN}
#        (skipped when the same version and patch were already built)
function build_guard() {
  mkdir -p "${GUARD_DIR}"
  cat > "${GUARD_DIR}/guard.patch" <<'OUTLINE_GUARD_PATCH_END'
diff -uN a/cmd/outline-ss-server/main.go b/cmd/outline-ss-server/main.go
--- a/cmd/outline-ss-server/main.go	2026-10-29 19:39:16.168557849 -0700
+++ b/cmd/outline-ss-server/main.go	2026-10-29 19:44:26.535116277 -0700
@@ -379,6 +379,8 @@
 
 	if flags.MetricsAddr != "" {
 		http.Handle("/metrics", promhttp.Handler())
+		http.Handle("/guard/keys", service.DefaultDeviceGuard.Handler())
+		http.Handle("/guard/keys/", service.DefaultDeviceGuard.Handler())
 		go func() {
 			slog.Error("Failed to run metrics server. Aborting.", "err", http.ListenAndServe(flags.MetricsAddr, nil))
 		}()
diff -uN a/service/deviceguard.go b/service/deviceguard.go
--- a/service/deviceguard.go	1969-12-31 16:00:00.000000000 -0800
+++ b/service/deviceguard.go	2026-10-29 19:44:26.540516278 -0700
@@ -0,0 +1,372 @@
+// Copyright 2026 Mithra Corp.
+//
+// Licensed under the Apache License, Version 2.0 (the "License");
+// you may not use this file except in compliance with the License.
+// You may obtain a copy of the License at
+//
+//      http://www.apache.org/licenses/LICENSE-2.0
+//
+// Unless required by applicable law or agreed to in writing, software
+// distributed under the License is distributed on an "AS IS" BASIS,
+// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
+// See the License for the specific language governing permissions and
+// limitations under the License.
+
+package service
+
+import (
+	"encoding/json"
+	"net/http"
+	"net/netip"
+	"os"
+	"sort"
+	"strconv"
+	"strings"
+	"sync"
+	"time"
+)
+
+// DeviceGuard adds two things Shadowsocks does not have on its own:
+//
+//  1. One device per access key. A device is a client address (IPv4 address, or the /64 of an IPv6 address, so that
+//     privacy-address rotation is still one device). The newest device wins: when a key is used from a new device,
+//     every connection of the previous device is closed and that device is refused until the new device has been
+//     gone for releaseAfter. This is how WireGuard behaves when two devices share one key.
+//  2. A block switch per access key (paused / over data limit / expired), applied at once to new and open connections.
+//
+// A connection only counts as a device after it authenticated with the key's cipher, so scanners and active probes
+// can never push a real user off.
+//
+// The guard is a process-wide singleton (DefaultDeviceGuard) so that it survives configuration reloads, which
+// replace the handlers. It is controlled over HTTP (see Handler); a controller that restarts should push its
+// settings again when StartedAt changes.
+type DeviceGuard struct {
+	mu            sync.Mutex
+	keys          map[string]*keyGuard
+	startedAt     time.Time
+	defaultSingle bool
+	releaseAfter  time.Duration
+	now           func() time.Time
+	nextSession   uint64
+}
+
+type guardSession struct {
+	device string
+	kill   func()
+}
+
+type keyGuard struct {
+	blocked     bool
+	single      *bool // nil: use the guard's default
+	owner       string
+	ownerIdle   time.Time // when the owner's last session closed; zero while it has sessions
+	blockedDevs map[string]time.Time
+	sessions    map[uint64]*guardSession
+	lastSeen    time.Time
+}
+
+// DefaultDeviceGuard is the guard used by the TCP and UDP handlers.
+// Environment: OUTLINE_GUARD_SINGLE_DEVICE=0 turns one-device-per-key off by default (it can still be set per key),
+// OUTLINE_GUARD_RELEASE_SECONDS (default 60) is how long a device must be gone before a refused device may return.
+var DefaultDeviceGuard = NewDeviceGuardFromEnv()
+
+// NewDeviceGuard creates a guard. Usage: NewDeviceGuard(true, time.Minute).
+func NewDeviceGuard(defaultSingle bool, releaseAfter time.Duration) *DeviceGuard {
+	return &DeviceGuard{
+		keys:          make(map[string]*keyGuard),
+		startedAt:     time.Now(),
+		defaultSingle: defaultSingle,
+		releaseAfter:  releaseAfter,
+		now:           time.Now,
+	}
+}
+
+// NewDeviceGuardFromEnv creates a guard configured from the environment (see DefaultDeviceGuard).
+//
+// Usage: g := NewDeviceGuardFromEnv()
+func NewDeviceGuardFromEnv() *DeviceGuard {
+	single := os.Getenv("OUTLINE_GUARD_SINGLE_DEVICE") != "0"
+	release := 60 * time.Second
+	if v, err := strconv.Atoi(os.Getenv("OUTLINE_GUARD_RELEASE_SECONDS")); err == nil && v >= 0 {
+		release = time.Duration(v) * time.Second
+	}
+	return NewDeviceGuard(single, release)
+}
+
+// DeviceID turns a client address into the identity of its device: an IPv4 address as is, an IPv6 address as its /64
+// prefix, an IPv4-mapped IPv6 address as the IPv4 address. It returns "" for an invalid address.
+//
+// Usage: id := DeviceID(netip.MustParseAddr("2001:db8::1")) // "2001:db8::/64"
+func DeviceID(addr netip.Addr) string {
+	if !addr.IsValid() {
+		return ""
+	}
+	addr = addr.Unmap()
+	if addr.Is6() {
+		p, err := addr.Prefix(64)
+		if err != nil {
+			return ""
+		}
+		return p.String()
+	}
+	return addr.String()
+}
+
+// keyLocked returns the state of a key, creating it. The caller must hold g.mu.
+//
+// Usage: k := g.keyLocked("3") // with g.mu held
+func (g *DeviceGuard) keyLocked(id string) *keyGuard {
+	k := g.keys[id]
+	if k == nil {
+		k = &keyGuard{blockedDevs: map[string]time.Time{}, sessions: map[uint64]*guardSession{}}
+		g.keys[id] = k
+	}
+	return k
+}
+
+// singleLocked tells whether one-device-per-key applies to a key. The caller must hold g.mu.
+//
+// Usage: if g.singleLocked(k) { ... } // with g.mu held
+func (g *DeviceGuard) singleLocked(k *keyGuard) bool {
+	if k.single != nil {
+		return *k.single
+	}
+	return g.defaultSingle
+}
+
+// ownerSessionsLocked counts the open sessions of the key's owner. The caller must hold g.mu.
+//
+// Usage: n := k.ownerSessionsLocked() // with the guard lock held
+func (k *keyGuard) ownerSessionsLocked() int {
+	n := 0
+	for _, s := range k.sessions {
+		if s.device == k.owner {
+			n++
+		}
+	}
+	return n
+}
+
+// Register is called once a connection (TCP) or association (UDP) has authenticated with key keyID from client.
+// It returns whether the connection may go on. kill must close the connection; the guard calls it when the device is
+// pushed out or the key is blocked. The returned release function must be called when the connection ends.
+// A client whose address is not valid is let through untracked (unless the key is blocked).
+//
+// Usage: release, ok, why := g.Register(keyID, clientIP, func() { conn.Close() }); defer release()
+func (g *DeviceGuard) Register(keyID string, client netip.Addr, kill func()) (release func(), ok bool, reason string) {
+	dev := DeviceID(client)
+	var toKill []func()
+	g.mu.Lock()
+	now := g.now()
+	k := g.keyLocked(keyID)
+	k.lastSeen = now
+	if k.blocked {
+		g.mu.Unlock()
+		return func() {}, false, "key_blocked"
+	}
+	if dev == "" {
+		g.mu.Unlock()
+		return func() {}, true, ""
+	}
+	if g.singleLocked(k) {
+		// The owner has been gone long enough: the key is free again and refused devices may come back.
+		if k.owner != "" && k.ownerSessionsLocked() == 0 && !k.ownerIdle.IsZero() && now.Sub(k.ownerIdle) >= g.releaseAfter {
+			k.owner = ""
+			k.blockedDevs = map[string]time.Time{}
+		}
+		if _, refused := k.blockedDevs[dev]; refused {
+			g.mu.Unlock()
+			return func() {}, false, "device_blocked"
+		}
+		if k.owner != "" && k.owner != dev {
+			// A new device: the newest wins. The previous device is cut off and refused from now on.
+			k.blockedDevs[k.owner] = now
+			for id, s := range k.sessions {
+				if s.device != dev {
+					toKill = append(toKill, s.kill)
+					delete(k.sessions, id)
+				}
+			}
+		}
+		k.owner = dev
+		k.ownerIdle = time.Time{}
+	}
+	g.nextSession++
+	id := g.nextSession
+	k.sessions[id] = &guardSession{device: dev, kill: kill}
+	g.mu.Unlock()
+
+	for _, f := range toKill {
+		if f != nil {
+			f()
+		}
+	}
+	var once sync.Once
+	return func() {
+		once.Do(func() {
+			g.mu.Lock()
+			defer g.mu.Unlock()
+			k := g.keys[keyID]
+			if k == nil {
+				return
+			}
+			delete(k.sessions, id)
+			if k.owner != "" && k.ownerSessionsLocked() == 0 {
+				k.ownerIdle = g.now()
+			}
+		})
+	}, true, ""
+}
+
+// Allowed is the cheap per-packet check for an association that is already open (UDP): it is false when the key is
+// blocked or the device has been pushed out since the association was created.
+//
+// Usage: if !g.Allowed(keyID, clientIP) { drop the packet }
+func (g *DeviceGuard) Allowed(keyID string, client netip.Addr) bool {
+	dev := DeviceID(client)
+	g.mu.Lock()
+	defer g.mu.Unlock()
+	k := g.keys[keyID]
+	if k == nil {
+		return true
+	}
+	if k.blocked {
+		return false
+	}
+	if dev == "" || !g.singleLocked(k) {
+		return true
+	}
+	_, refused := k.blockedDevs[dev]
+	return !refused
+}
+
+// SetBlocked blocks or unblocks a key. Blocking closes all its open connections at once.
+//
+// Usage: g.SetBlocked("3", true) // pause; false resumes
+func (g *DeviceGuard) SetBlocked(keyID string, blocked bool) {
+	var toKill []func()
+	g.mu.Lock()
+	k := g.keyLocked(keyID)
+	k.blocked = blocked
+	if blocked {
+		for id, s := range k.sessions {
+			toKill = append(toKill, s.kill)
+			delete(k.sessions, id)
+		}
+		k.ownerIdle = g.now()
+	}
+	g.mu.Unlock()
+	for _, f := range toKill {
+		if f != nil {
+			f()
+		}
+	}
+}
+
+// SetSingleDevice turns one-device-per-key on or off for a key; nil goes back to the guard's default.
+// Turning it off forgets the owner and the refused devices.
+//
+// Usage: off := false; g.SetSingleDevice("3", &off) // nil = default
+func (g *DeviceGuard) SetSingleDevice(keyID string, single *bool) {
+	g.mu.Lock()
+	defer g.mu.Unlock()
+	k := g.keyLocked(keyID)
+	k.single = single
+	if !g.singleLocked(k) {
+		k.owner = ""
+		k.blockedDevs = map[string]time.Time{}
+	}
+}
+
+// Forget drops everything known about a key (call it when the key is deleted).
+//
+// Usage: g.Forget("3")
+func (g *DeviceGuard) Forget(keyID string) {
+	g.SetBlocked(keyID, true)
+	g.mu.Lock()
+	delete(g.keys, keyID)
+	g.mu.Unlock()
+}
+
+// KeyStatus is what the HTTP interface reports about one key.
+type KeyStatus struct {
+	Blocked        bool     `json:"blocked"`
+	SingleDevice   bool     `json:"singleDevice"`
+	Owner          string   `json:"owner"`
+	Sessions       int      `json:"sessions"`
+	BlockedDevices []string `json:"blockedDevices"`
+	LastSeen       int64    `json:"lastSeen"`
+}
+
+// Snapshot returns the state of every key the guard has seen or been told about.
+//
+// Usage: for id, st := range g.Snapshot() { ... }
+func (g *DeviceGuard) Snapshot() map[string]KeyStatus {
+	g.mu.Lock()
+	defer g.mu.Unlock()
+	out := make(map[string]KeyStatus, len(g.keys))
+	for id, k := range g.keys {
+		devs := make([]string, 0, len(k.blockedDevs))
+		for d := range k.blockedDevs {
+			devs = append(devs, d)
+		}
+		sort.Strings(devs)
+		var seen int64
+		if !k.lastSeen.IsZero() {
+			seen = k.lastSeen.Unix()
+		}
+		out[id] = KeyStatus{Blocked: k.blocked, SingleDevice: g.singleLocked(k), Owner: k.owner,
+			Sessions: len(k.sessions), BlockedDevices: devs, LastSeen: seen}
+	}
+	return out
+}
+
+// Handler serves the control interface. Mount it on the (local) metrics address:
+//
+//	GET    /guard/keys        -> {"startedAt": unix, "defaultSingleDevice": bool, "keys": {"<id>": KeyStatus, ...}}
+//	PUT    /guard/keys/<id>   {"blocked": bool, "singleDevice": bool|null}  (either field may be left out)
+//	DELETE /guard/keys/<id>   forget the key
+func (g *DeviceGuard) Handler() http.Handler {
+	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		path := strings.Trim(strings.TrimPrefix(r.URL.Path, "/guard/keys"), "/")
+		w.Header().Set("Content-Type", "application/json")
+		switch {
+		case path == "" && r.Method == http.MethodGet:
+			json.NewEncoder(w).Encode(map[string]any{
+				"startedAt":           g.startedAt.Unix(),
+				"defaultSingleDevice": g.defaultSingle,
+				"keys":                g.Snapshot(),
+			})
+		case path != "" && !strings.Contains(path, "/") && r.Method == http.MethodPut:
+			var body struct {
+				Blocked      *bool           `json:"blocked"`
+				SingleDevice json.RawMessage `json:"singleDevice"`
+			}
+			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
+				http.Error(w, `{"error":"invalid JSON"}`, http.StatusBadRequest)
+				return
+			}
+			if body.SingleDevice != nil {
+				var single *bool
+				if string(body.SingleDevice) != "null" {
+					var b bool
+					if err := json.Unmarshal(body.SingleDevice, &b); err != nil {
+						http.Error(w, `{"error":"singleDevice must be true, false or null"}`, http.StatusBadRequest)
+						return
+					}
+					single = &b
+				}
+				g.SetSingleDevice(path, single)
+			}
+			if body.Blocked != nil {
+				g.SetBlocked(path, *body.Blocked)
+			}
+			w.WriteHeader(http.StatusNoContent)
+		case path != "" && !strings.Contains(path, "/") && r.Method == http.MethodDelete:
+			g.Forget(path)
+			w.WriteHeader(http.StatusNoContent)
+		default:
+			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
+		}
+	})
+}
diff -uN a/service/tcp.go b/service/tcp.go
--- a/service/tcp.go	2026-10-29 19:39:16.162498601 -0700
+++ b/service/tcp.go	2026-10-29 19:44:26.529820718 -0700
@@ -345,6 +345,12 @@
 		h.absorbProbe(outerConn, connMetrics, authErr.Status, proxyMetrics)
 		return authErr
 	}
+	// Device guard: one device per key, and paused/limited/expired keys are cut at once.
+	releaseGuard, allowed, reason := DefaultDeviceGuard.Register(id, remoteIP(outerConn), func() { outerConn.Close() })
+	if !allowed {
+		return onet.NewConnectionError("ERR_DEVICE_GUARD", "Connection refused by device guard: "+reason, nil)
+	}
+	defer releaseGuard()
 	connMetrics.AddAuthenticated(id)
 
 	// Read target address and dial it.
diff -uN a/service/udp.go b/service/udp.go
--- a/service/udp.go	2026-10-29 19:39:16.165503995 -0700
+++ b/service/udp.go	2026-10-29 19:44:26.533021590 -0700
@@ -188,8 +188,17 @@
 				if err != nil {
 					return onet.NewConnectionError("ERR_CREATE_SOCKET", "Failed to create UDP socket", err)
 				}
-				targetConn = nm.Add(clientAddr, clientConn, cryptoKey, udpConn, keyID)
+				releaseGuard, allowed, reason := DefaultDeviceGuard.Register(keyID, ip, func() { udpConn.Close() })
+				if !allowed {
+					udpConn.Close()
+					return onet.NewConnectionError("ERR_DEVICE_GUARD", "Packet refused by device guard: "+reason, nil)
+				}
+				targetConn = nm.Add(clientAddr, clientConn, cryptoKey, udpConn, keyID, releaseGuard)
 			} else {
+				// Already-open association: drop packets once the key is blocked or the device was pushed out.
+				if !DefaultDeviceGuard.Allowed(targetConn.keyID, clientAddr.(*net.UDPAddr).AddrPort().Addr()) {
+					return onet.NewConnectionError("ERR_DEVICE_GUARD", "Packet refused by device guard", nil)
+				}
 				unpackStart := time.Now()
 				textData, err := shadowsocks.Unpack(nil, cipherData, targetConn.cryptoKey)
 				timeToCipher := time.Since(unpackStart)
@@ -364,13 +373,16 @@
 	return nil
 }
 
-func (m *natmap) Add(clientAddr net.Addr, clientConn net.PacketConn, cryptoKey *shadowsocks.EncryptionKey, targetConn net.PacketConn, keyID string) *natconn {
+func (m *natmap) Add(clientAddr net.Addr, clientConn net.PacketConn, cryptoKey *shadowsocks.EncryptionKey, targetConn net.PacketConn, keyID string, release func()) *natconn {
 	connMetrics := m.metrics.AddUDPNatEntry(clientAddr, keyID)
 	entry := m.set(clientAddr.String(), targetConn, cryptoKey, keyID, connMetrics)
 
 	m.running.Add(1)
 	go func() {
 		timedCopy(clientAddr, clientConn, entry, keyID, m.logger)
+		if release != nil {
+			release()
+		}
 		connMetrics.RemoveNatEntry()
 		if pc := m.del(clientAddr.String()); pc != nil {
 			pc.Close()
OUTLINE_GUARD_PATCH_END
  local stamp
  stamp="${SS_VERSION}-$(sha256sum "${GUARD_DIR}/guard.patch" | cut -c1-16)"
  if [[ -x "${GUARD_BIN}" && "$(cat "${GUARD_DIR}/stamp" 2>/dev/null || true)" == "${stamp}" ]]; then
    return 0
  fi
  rm -f "${GUARD_BIN}" "${GUARD_DIR}/stamp"
  log_command docker run --rm -v "${GUARD_DIR}:/out" -e "SS_VERSION=${SS_VERSION}" -e CGO_ENABLED=0 "${GUARD_IMAGE}" sh -ec '
    apk add --no-cache git >/dev/null
    git clone --quiet --depth 1 --branch "${SS_VERSION}" https://github.com/Jigsaw-Code/outline-ss-server /src
    cd /src
    git apply --whitespace=nowarn /out/guard.patch
    go build -ldflags="-s -w -X main.version=embedded-guard" -o /out/outline-ss-server ./cmd/outline-ss-server
  ' >&2 || { log_error "Compiling the device guard failed (needs internet access to github.com and the Go module proxy)."; return 1; }
  # Smoke test: the binary must run (static, no libc needed).
  docker run --rm -v "${GUARD_DIR}:/w:ro" alpine /w/outline-ss-server -version >/dev/null || return 1
  echo "${stamp}" > "${GUARD_DIR}/stamp"
}

# Usage: prepare_guard -> detects the ss-server version of SB_IMAGE, then builds the patched binary (GUARD_BIN)
function prepare_guard() {
  docker pull "${SB_IMAGE}" >&2
  detect_ss_version
  build_guard
}

# Usage: remove_v1_firewall -> removes the iptables chains and the boot unit of the earlier port-per-key version of the panel
#        (nothing happens when they do not exist)
function remove_v1_firewall() {
  if [[ -f /etc/systemd/system/outline-panel-firewall.service ]]; then
    systemctl disable --now outline-panel-firewall.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/outline-panel-firewall.service
    systemctl daemon-reload
  fi
  local ipt chain parent
  for ipt in iptables ip6tables; do
    command_exists "${ipt}" || continue
    for parent in INPUT OUTPUT; do
      for chain in OLP-GUARD OLP-GUARD-OUT OLP-IN OLP-OUT; do
        while "${ipt}" -w -D "${parent}" -j "${chain}" 2>/dev/null; do :; done
      done
    done
    for chain in OLP-GUARD OLP-GUARD-OUT OLP-IN OLP-OUT; do
      "${ipt}" -w -F "${chain}" 2>/dev/null && "${ipt}" -w -X "${chain}" 2>/dev/null || true
    done
  done
}

# Usage: disable_watchtower -> removes a Watchtower container left by an earlier install: it would update Shadowbox to an image
#        whose outline-ss-server no longer matches the patched binary
function disable_watchtower() {
  if docker_container_exists watchtower; then
    docker rm -f watchtower >/dev/null
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Key panel
# ---------------------------------------------------------------------------------------------------------------------

# Usage: install_panel_requirements -> installs python3 when it is missing
function install_panel_requirements() {
  command_exists python3 && return 0
  local pm="" tool
  for tool in apt-get dnf yum apk pacman zypper; do
    if command_exists "${tool}"; then pm="${tool}"; break; fi
  done
  if [[ -z "${pm}" ]]; then
    log_error "Please install python3 first, then run this script again."
    return 1
  fi
  case "${pm}" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >&2 ;;
    dnf|yum) "${pm}" install -y -q python3 >&2 ;;
    apk)     apk add --quiet python3 >&2 ;;
    pacman)  pacman -S --noconfirm --needed python >&2 ;;
    zypper)  zypper --non-interactive install python3 >&2 ;;
  esac
  command_exists python3 || { log_error "Could not install python3"; return 1; }
}

# Usage: read_keys_port -> sets KEYS_PORT: the one port new access keys use (asked from Shadowbox through the panel)
function read_keys_port() {
  KEYS_PORT="$(fetch --insecure "${LOCAL_API_URL}/server" | grep -o '"portForNewAccessKeys": *[0-9]*' | grep -o '[0-9]*$' || true)"
  if [[ -z "${KEYS_PORT}" ]]; then
    KEYS_PORT="$(fetch --insecure "${LOCAL_API_URL}/access-keys" | grep -o '"port": *[0-9]*' | head -n 1 | grep -o '[0-9]*$' || true)"
  fi
  [[ -n "${KEYS_PORT}" ]]
}

# Usage: open_ports -> opens the API port and the key port in ufw or firewalld when one of them is active
function open_ports() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${API_PORT}/tcp" >&2
    ufw allow "${KEYS_PORT}/tcp" >&2
    ufw allow "${KEYS_PORT}/udp" >&2
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${API_PORT}/tcp" >&2
    firewall-cmd --permanent --add-port="${KEYS_PORT}/tcp" >&2
    firewall-cmd --permanent --add-port="${KEYS_PORT}/udp" >&2
    firewall-cmd --reload >&2
  fi
}

# Usage: write_panel_files -> writes panel.py, config.json and the systemd unit
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
# All keys share ONE port (like WireGuard's single UDP port) and every key stays a normal Outline key:
# the ss:// access URL works in the Outline Client.
#
# What it adds on top of Shadowbox:
#   1. Traffic that is kept: per-key totals come from the byte counters of the patched outline-ss-server and are saved to
#      disk, so they survive restarts of the server, of Docker and of the VPS.
#   2. One device per key: enforced inside the patched outline-ss-server ("device guard"): the newest device (client address)
#      wins, the older one is cut off at once - the same way WireGuard drops the first device when a second one uses the key.
#   3. Online / last seen: derived from the last traffic of the key (Shadowsocks has no handshake).
#   3.1 Live upload / download rate per key.
#   4. Time limit: a date, a duration from now, a duration after the first connection, or none.
#   5. Usage per key: upload, download, total, with an optional data limit.
#   6. Pause / resume.   7. Edit (name, traffic, time limit) - PATCH /access-keys/<id>.
#
# The panel answers on the public API port with Outline's own URL layout (https://host:port/<secret>/access-keys ...).
# Routes it does not know are forwarded unchanged to Shadowbox, which listens on a private port.
#
# Needs: python3 (3.6+), the patched outline-ss-server (see install_server.sh). Standard library only.
# Config: /opt/outline/panel/config.json (edit it with: vi /opt/outline/panel/config.json), state: state.json next to it.

import calendar
import collections
import datetime
import json
import logging
import os
import re
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

VERSION = '2.0.0'
log = logging.getLogger('outline-panel')

DEFAULTS = {
    'listen_port': 0,                 # public API port (the one in the Outline Manager access config)
    'api_prefix': '',                 # secret path prefix, as in Outline
    'cert_file': '', 'key_file': '',  # the same self-signed certificate Shadowbox uses (same certSha256)
    'shadowbox_port': 0,              # private Shadowbox API port (127.0.0.1)
    'ss_metrics_port': 0,             # outline-ss-server metrics / guard port (127.0.0.1); 0 = find it automatically
    'state_file': '/opt/outline/panel/state.json',
    'sample_seconds': 2.0,            # how often the byte counters are read
    'online_window_seconds': 180,     # "online" = traffic within this many seconds
    'single_device': True,            # default for new keys (the guard itself starts from OUTLINE_GUARD_SINGLE_DEVICE)
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

# ----------------------------------------------------------------------------------------------------------------------
# outline-ss-server: byte counters + device guard (both on its local metrics port)
# ----------------------------------------------------------------------------------------------------------------------

class SsServer(object):
    # Usage: SsServer(cfg) -> talks to the patched outline-ss-server on 127.0.0.1:<metrics port>
    def __init__(self, cfg):
        self.port = int(cfg.get('ss_metrics_port') or 0)
        self.fixed = bool(self.port)
        self.proc_dir = '/proc'

    # Usage: self.find_port() -> the -metrics port of the running outline-ss-server (read from /proc/*/cmdline), or 0
    def find_port(self):
        try:
            pids = [p for p in os.listdir(self.proc_dir) if p.isdigit()]
        except OSError:
            return 0
        for pid in pids:
            try:
                with open('%s/%s/cmdline' % (self.proc_dir, pid), 'rb') as f:
                    args = f.read().decode('utf-8', 'replace').split('\0')
            except OSError:
                continue
            if not args or os.path.basename(args[0]) != 'outline-ss-server':
                continue
            for i, a in enumerate(args):
                val = a.split('=', 1)[1] if a.startswith(('-metrics=', '--metrics=')) else (args[i + 1] if a in ('-metrics', '--metrics') and i + 1 < len(args) else '')
                m = re.search(r':(\d+)$', val)
                if m:
                    return int(m.group(1))
        return 0

    # Usage: self._call("GET", "/metrics") -> (status, text); None when the server cannot be reached (the port is searched again)
    def _call(self, method, path, body=None):
        if not self.port and not self.fixed:
            self.port = self.find_port()
        if not self.port:
            return None
        try:
            conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
            data = json.dumps(body).encode() if body is not None else None
            conn.request(method, path, body=data, headers={'Content-Type': 'application/json'} if data else {})
            r = conn.getresponse()
            text = r.read().decode('utf-8', 'replace')
            conn.close()
            return r.status, text
        except (OSError, http.client.HTTPException):
            if not self.fixed:
                self.port = 0
            return None

    # Usage: self.usage() -> {key id: [upload bytes, download bytes]} from shadowsocks_data_bytes (client<->proxy, TCP + UDP);
    #        None when the server cannot be reached. Upload = what the client sent (dir c>p), download = what it received (c<p).
    def usage(self):
        res = self._call('GET', '/metrics')
        if res is None or res[0] != 200:
            return None
        out = {}
        for line in res[1].splitlines():
            if 'data_bytes{' not in line or line.startswith('#') or 'per_location' in line:
                continue
            m = re.match(r'^\w*data_bytes\{([^}]*)\}\s+(\S+)', line)
            if not m:
                continue
            lab = dict(re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', m.group(1)))
            kid, d = lab.get('access_key'), lab.get('dir')
            if not kid or d not in ('c>p', 'c<p'):
                continue
            try:
                val = int(float(m.group(2)))
            except ValueError:
                continue
            out.setdefault(kid, [0, 0])[0 if d == 'c>p' else 1] += val
        return out

    # Usage: self.guard() -> {"startedAt", "defaultSingleDevice", "keys": {id: {...}}} of the device guard; None if unreachable
    #        (also None for a plain, unpatched outline-ss-server)
    def guard(self):
        res = self._call('GET', '/guard/keys')
        if res is None or res[0] != 200:
            return None
        try:
            return json.loads(res[1])
        except ValueError:
            return None

    # Usage: self.set_guard("3", {"blocked": True, "singleDevice": True}) -> True when the guard accepted it
    def set_guard(self, kid, payload):
        res = self._call('PUT', '/guard/keys/' + kid, payload)
        return res is not None and res[0] in (200, 204)

    # Usage: self.forget_guard("3") -> drops everything the guard knows about a deleted key
    def forget_guard(self, kid):
        self._call('DELETE', '/guard/keys/' + kid)


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
# the panel: state, accounting, policies
# ----------------------------------------------------------------------------------------------------------------------

# Usage: new_record(True) -> the stored state of one key
def new_record(single=True):
    return {'created': int(time.time()), 'up': 0, 'down': 0, 'raw': [0, 0],
            'last_seen': 0, 'first_connected': 0, 'paused': False, 'limit': 0, 'expires_at': 0, 'expires_after': '',
            'single_device': single}


class Panel(object):
    # Usage: Panel(cfg, ss_server, shadowbox) -> loads state.json; call tick() every sample_seconds and the api_* methods per request
    def __init__(self, cfg, ss, sb):
        self.cfg, self.ss, self.sb = cfg, ss, sb
        self.lock = threading.RLock()
        self.state = {'version': 2, 'keys': {}}
        self.dirty = False
        self.last_save = 0
        self.hist = {}
        self.sb_keys = []
        self.sb_time = 0
        self.guard_info = {}        # last answer of the guard: id -> status
        self.guard_started = None   # startedAt of the guard we last configured (a change = ss-server restarted)
        self.guard_sent = {}        # id -> (blocked, single) last pushed
        self.guard_ok = False
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
                    for name, val in new_record().items():
                        k.setdefault(name, val)
                    if not isinstance(k.get('raw'), list):
                        k['raw'] = [0, 0]      # a v1 state file (port-per-key counters): totals are kept, raw baseline restarts
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
            ids = set()
            for k in keys:
                kid = str(k['id'])
                ids.add(kid)
                if kid not in self.state['keys']:
                    self.state['keys'][kid] = new_record(self.cfg['single_device'])
                    log.info('adopted key %s', kid)
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
                    self.guard_sent.pop(kid, None)
                    self.ss.forget_guard(kid)
                    self.dirty = True

    # Usage: self._tick_key(id, rec, [up, down] or None, now) -> adds the traffic since the last sample (a counter that went
    #        down = ss-server restarted: the new value is all new traffic) and updates last seen / first connection / expiry start
    def _tick_key(self, kid, k, counter, now):
        traffic = 0
        if counter is not None:
            for i, name in enumerate(('up', 'down')):
                cur, last = counter[i], k['raw'][i]
                delta = cur - last if cur >= last else cur
                k['raw'][i] = cur
                if delta:
                    k[name] += delta
                    traffic += delta
        if traffic:
            k['last_seen'] = int(now)
            self.dirty = True
            if not k['first_connected']:
                k['first_connected'] = int(now)
                if k['expires_after'] and not k['expires_at']:
                    k['expires_at'] = add_duration(k['first_connected'], k['expires_after'])
                    log.info('key %s: first connection, ends %s', kid, server_clock(k['expires_at']))

    # Usage: self._sync_guard(now) -> reads the guard and pushes blocked / singleDevice for every key whose wanted value
    #        differs from what the guard has (or all keys after an ss-server restart, detected by a new startedAt)
    def _sync_guard(self, now):
        g = self.ss.guard()
        self.guard_ok = g is not None
        if g is None:
            self.guard_info = {}
            return
        self.guard_info = g.get('keys') or {}
        if g.get('startedAt') != self.guard_started:
            self.guard_started, self.guard_sent = g.get('startedAt'), {}
        for kid, k in self.state['keys'].items():
            want = (self.status_of(k, now) != 'active', bool(k['single_device']))
            have = self.guard_info.get(kid)
            if self.guard_sent.get(kid) == want and (have is None or (have.get('blocked'), have.get('singleDevice')) == want):
                continue
            if self.ss.set_guard(kid, {'blocked': want[0], 'singleDevice': want[1]}):
                self.guard_sent[kid] = want

    # Usage: self.tick() -> one sample: counters, policies, guard. Called every sample_seconds by the background thread.
    def tick(self):
        now = time.time()
        try:
            self.refresh_keys()
        except ApiError as e:
            log.debug('key list not refreshed: %s', e.message)
        with self.lock:
            usage = self.ss.usage()
            for kid, k in self.state['keys'].items():
                if usage is not None:
                    if kid not in usage:
                        k['raw'] = [0, 0]      # no counter at all = a fresh ss-server process (or a key without traffic yet)
                    self._tick_key(kid, k, usage.get(kid), now)
                h = self.hist.setdefault(kid, collections.deque(maxlen=12))
                h.append((now, k['up'], k['down']))
            self._sync_guard(now)
            if self.dirty and now - self.last_save >= self.cfg['save_seconds']:
                self.save()

    # Usage: self.rate(kid, now) -> (upload bytes/s, download bytes/s) over about the last 10 s
    def rate(self, kid, now):
        h = [e for e in self.hist.get(kid, ()) if e[0] >= now - 10]
        if len(h) < 2 or now - h[-1][0] > 3 * self.cfg['sample_seconds'] + 1:
            return 0, 0
        dt = h[-1][0] - h[0][0]
        return (max(0, int((h[-1][1] - h[0][1]) / dt)), max(0, int((h[-1][2] - h[0][2]) / dt))) if dt > 0 else (0, 0)

    # Usage: self.view(sb_key, now) -> one key as returned by the API (Outline fields + panel fields)
    def view(self, sk, now):
        kid = str(sk['id'])
        k = self.state['keys'].get(kid) or new_record()
        out = dict(sk)
        status = self.status_of(k, now)
        ur, dr = self.rate(kid, now)
        online = bool(k['last_seen'] and now - k['last_seen'] <= self.cfg['online_window_seconds'])
        gi = self.guard_info.get(kid) or {}
        out.update({
            'managed': True, 'status': status, 'paused': k['paused'], 'blocked': status in ('paused', 'limit', 'expired'),
            'createdAt': iso(k['created']),
            'uploadBytes': k['up'], 'downloadBytes': k['down'], 'totalBytes': k['up'] + k['down'],
            'dataLimitBytes': k['limit'], 'dataLimit': {'bytes': k['limit']} if k['limit'] else None,
            'limitReached': status == 'limit',
            'expiresAt': iso(k['expires_at']), 'expiresAtServer': server_clock(k['expires_at']) if k['expires_at'] else None,
            'expiresAfterFirstConnection': k['expires_after'] or None, 'firstConnectedAt': iso(k['first_connected']),
            'expired': status == 'expired',
            'online': online, 'lastSeen': iso(k['last_seen']), 'lastHandshake': iso(k['last_seen']),
            'lastSeenSecondsAgo': int(now - k['last_seen']) if k['last_seen'] else None,
            'liveUploadBps': ur if online else 0, 'liveDownloadBps': dr if online else 0,
            'singleDevice': k['single_device'], 'clientDevice': gi.get('owner') or None,
            'blockedDevices': gi.get('blockedDevices') or [], 'openConnections': gi.get('sessions', 0),
        })
        return out

    # Usage: self.all_views(force=True) -> (list of key views, totals dict); force=False reuses the key list read within 30 s
    def all_views(self, force=True):
        self.refresh_keys(force=force)
        now = time.time()
        with self.lock:
            views = [self.view(sk, now) for sk in self.sb_keys]
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
        return {'panelVersion': VERSION, 'onlineWindowSeconds': self.cfg['online_window_seconds'],
                'serverTime': iso(int(time.time())), 'serverClock': server_clock(time.time()),
                'utcOffset': '%s%02d:%02d' % ('-' if off < 0 else '+', abs(off) // 60, abs(off) % 60),
                'usageSource': 'outline-ss-server byte counters per key (saved to disk)',
                'singlePort': True, 'deviceGuard': 'active' if self.guard_ok else 'unavailable',
                'features': ['usage', 'online', 'live-rate', 'time-limit', 'data-limit', 'pause', 'edit', 'single-device']}

    # Usage: self.record(kid) -> the stored state of a key; ApiError 404 when unknown
    def record(self, kid):
        self.refresh_keys(force=True)
        k = self.state['keys'].get(str(kid))
        if k is None:
            raise ApiError(404, 'no such key')
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

    # Usage: self.apply_policy(rec, changes) -> stores validated changes and pushes them to the guard at once
    def apply_policy(self, k, ch):
        if 'limit' in ch:
            k['limit'] = ch['limit']
        if 'paused' in ch:
            k['paused'] = ch['paused']
        if 'single_device' in ch:
            k['single_device'] = ch['single_device']
        if 'expiry' in ch:
            e = ch['expiry']
            if e[0] == 'none':
                k['expires_at'], k['expires_after'] = 0, ''
            elif e[0] == 'at':
                k['expires_at'], k['expires_after'] = e[1], ''
            else:
                k['expires_after'] = e[1]
                k['expires_at'] = add_duration(k['first_connected'], e[1]) if k['first_connected'] else 0
        self.dirty = True
        self._sync_guard(time.time())
        self.save()

    # Usage: self.api_create({"name": "Sima", "traffic": "20G", "expires": "30d"}) -> (201, key view) - a new key on the shared port
    def api_create(self, body):
        ch = self.parse_policy(body)
        sbody = {k: body[k] for k in ('name', 'method', 'password') if k in body}
        st, _, data = self.sb.request('POST', '/access-keys', sbody)
        if st not in (200, 201):
            raise ApiError(st, data.decode('utf-8', 'replace')[:300])
        sk = json.loads(data.decode())
        with self.lock:
            rec = self.state['keys'][str(sk['id'])] = new_record(self.cfg['single_device'])
            self.sb_keys = [k for k in self.sb_keys if k['id'] != sk['id']] + [sk]
            self.apply_policy(rec, ch)
            view = self.view(sk, time.time())
        return 201, view

    # Usage: self.api_delete("3") -> (204, None) - removes the key from Shadowbox, the guard and the state
    def api_delete(self, kid):
        self.record(kid)
        st, _, data = self.sb.request('DELETE', '/access-keys/' + str(kid))
        if st >= 300 and st != 404:
            raise ApiError(st, data.decode('utf-8', 'replace')[:300])
        with self.lock:
            self.state['keys'].pop(str(kid), None)
            self.hist.pop(str(kid), None)
            self.guard_sent.pop(str(kid), None)
            self.sb_keys = [k for k in self.sb_keys if str(k['id']) != str(kid)]
            self.dirty = True
            self.ss.forget_guard(str(kid))
            self.save()
        return 204, None

    # Usage: self.api_edit("3", {"name": "Sima", "traffic": "30G", "expires": "30d"}) -> (200, key view).
    #        Edits any of: name, traffic / limit, expires / expiresOn / expiresAfterFirstConnection, paused, singleDevice.
    def api_edit(self, kid, body):
        k = self.record(kid)
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
            self.dirty = True
            self._sync_guard(time.time())
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
                if re.match(r'^/' + KEY + r'(/[^/]+(/(limit|data-limit|expiry|paused|pause|resume|reset-usage))?)?/?$', path):
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


# Usage: serve(cfg) -> runs the sampling thread and the HTTPS API until SIGTERM / SIGINT
def serve(cfg):
    panel = Panel(cfg, SsServer(cfg), Shadowbox(cfg['shadowbox_port'], cfg['api_prefix']))
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
    log.info('outline-panel %s on port %d (single shared key port, device guard in outline-ss-server)', VERSION, cfg['listen_port'])
    server.serve_forever()
    with panel.lock:
        panel.save()


# Usage: python3 panel.py [serve|version] [--config /opt/outline/panel/config.json]
def main():
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    args = sys.argv[1:]
    path = os.environ.get('OUTLINE_PANEL_CONFIG', '/opt/outline/panel/config.json')
    if '--config' in args:
        path = args[args.index('--config') + 1]
    cmd = next((a for a in args if a in ('serve', 'version')), 'serve')
    if cmd == 'version':
        print(VERSION)
        return
    serve(load_config(path))


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
  "online_window_seconds": 180,
  "single_device": true
}
EOF

  cat > /etc/systemd/system/outline-panel.service <<EOF
[Unit]
Description=Outline panel (usage, time limits, pause, one device per key)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PYTHON_BIN} -I ${PANEL_DIR}/panel.py serve --config ${PANEL_DIR}/config.json
Restart=always
RestartSec=3
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
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

  log_for_sentry "Setting API port"
  API_PORT="${FLAGS_API_PORT}"
  if (( API_PORT == 0 )); then
    API_PORT=${SB_API_PORT:-$(get_free_random_port)}
  fi
  readonly API_PORT
  INTERNAL_API_PORT="$(get_free_random_port)"
  readonly INTERNAL_API_PORT
  readonly ACCESS_CONFIG="${ACCESS_CONFIG:-${SHADOWBOX_DIR}/access.txt}"
  readonly SB_IMAGE="${SB_IMAGE:-quay.io/outline/shadowbox:stable}"
  readonly GUARD_IMAGE="${GUARD_IMAGE:-golang:1.23-alpine}"
  readonly GUARD_DIR="${GUARD_DIR:-${SHADOWBOX_DIR}/guard}"
  readonly GUARD_BIN="${GUARD_DIR}/outline-ss-server"

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
  run_step "Building the device guard (patched outline-ss-server, first run takes a few minutes)" prepare_guard
  run_step "Removing old port-per-key firewall rules (if any)" remove_v1_firewall
  run_step "Generating secret key" generate_secret_key
  run_step "Generating TLS certificate" generate_certificate
  run_step "Generating SHA-256 certificate fingerprint" generate_certificate_fingerprint
  run_step "Writing config" write_config
  run_step "Writing key panel files" write_panel_files

  # Watchtower is not started (see the header), and one left by an earlier install is removed.
  run_step "Disabling automatic image updates" disable_watchtower
  run_step "Starting Shadowbox" start_shadowbox

  readonly PUBLIC_API_URL="https://${PUBLIC_HOSTNAME}:${API_PORT}/${SB_API_PREFIX}"
  readonly LOCAL_API_URL="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  readonly LOCAL_SB_URL="https://localhost:${INTERNAL_API_PORT}/${SB_API_PREFIX}"
  run_step "Waiting for Outline server to be healthy" wait_shadowbox
  run_step "Starting key panel" start_panel
  run_step "Waiting for key panel" wait_panel
  run_step "Creating first user" create_first_user
  run_step "Reading the shared key port" read_keys_port
  run_step "Opening ports (ufw / firewalld if active)" open_ports
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
- Key port: ${KEYS_PORT} (TCP + UDP), shared by all keys
- Guard:    outline-ss-server ${SS_VERSION} + device guard (${GUARD_BIN})
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

# Usage: parse_flags "$@" -> reads --hostname, --api-port and --keys-port into FLAGS_*
function parse_flags() {
  local params
  params="$(getopt --longoptions hostname:,api-port:,keys-port: -n "$0" -- "$0" "$@")"
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

# Usage: main "$@" -> installs the Outline server, the device guard and the key panel
function main() {
  trap finish EXIT
  declare FLAGS_HOSTNAME=""
  declare -i FLAGS_API_PORT=0
  declare -i FLAGS_KEYS_PORT=0
  parse_flags "$@"
  install_shadowbox
}

main "$@"
