#!/usr/bin/env sh

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh
#
# Example:
#   Installing Node exporter enabling only os collector:
#     curl ... | INSTALL_NODE_EXPORTER="--collector.disable-defaults --collector.os" sh -
#   Installing Node exporter enabling only os collector:
#     curl ... | sh -s - --collector.disable-defaults --collector.os
#
# Environment variables:
#   - INSTALL_NODE_EXPORTER_SKIP_DOWNLOAD
#     If set to true will not download Node exporter hash or binary
#
#   - INSTALL_NODE_EXPORTER_FORCE_RESTART
#     If set to true will always restart the Node exporter service
#
#   - INSTALL_NODE_EXPORTER_SKIP_ENABLE
#     If set to true will not enable or start Node exporter service
#
#   - INSTALL_NODE_EXPORTER_SKIP_START
#     If set to true will not start Node exporter service
#
#   - INSTALL_NODE_EXPORTER_SKIP_FIREWALL
#     If set to true will not add firewall rules
#
#   - INSTALL_NODE_EXPORTER_SKIP_SELINUX
#     If set to true will not change SELinux context for binary
#
#   - INSTALL_NODE_EXPORTER_VERSION
#     Version of Node exporter to download from GitHub
#
#   - INSTALL_NODE_EXPORTER_BIN_DIR
#     Directory to install Node exporter binary, and uninstall script to, or use
#     /usr/local/bin as the default
#
#   - INSTALL_NODE_EXPORTER_SYSTEMD_DIR
#     Directory to install systemd service files, or use
#     /etc/systemd/system as the default
#
#   - INSTALL_NODE_EXPORTER_EXEC or script arguments
#     Command with flags to use for launching Node exporter service
#
#     The following commands result in the same behavior:
#       curl ... | INSTALL_NODE_EXPORTER_EXEC="--collector.disable-defaults --collector.os" sh -s -
#       curl ... | INSTALL_NODE_EXPORTER_EXEC="--collector.disable-defaults" sh -s - --collector.os
#       curl ... | sh -s - --collector.disable-defaults --collector.os
#

# Fail on error
set -o errexit
# Disable wildcard character expansion
set -o noglob

# ================
# CONFIGURATION
# ================
# GitHub release URL
GITHUB_URL=https://github.com/prometheus/node_exporter/releases
# GitHub API URL
GITHUB_API_URL=https://api.github.com/repos/prometheus/node_exporter/releases/latest

# ================
# LOGGER
# ================
# Fatal log message
fatal() {
  printf '[FATAL] %s\n' "$@" >&2
  exit 1
}

# Error log message
error() {
  printf '[ERROR] %s\n' "$@" >&2
}

# Info log message
info() {
  printf '[INFO] %s\n' "$@"
}

# ================
# FUNCTIONS
# ================
# Add quotes to command arguments
quote() {
  for arg in "$@"; do
    printf '%s\n' "$arg" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"
  done
}

# Add indentation and trailing slash to quoted args except last one
# Also don't add trailing slash to command if no args are given
quote_indent() {
  _arg_count=1

  if [ $# -ge 1 ]; then
    printf ' \\\n'
  fi

  for _arg in "$@"; do
    if [ $_arg_count -eq $# ]; then
      printf '\t%s' "$(quote "$_arg")"
    else
      printf '\t%s \\\n' "$(quote "$_arg")"
    fi
    _arg_count=$((_arg_count + 1))
  done
}

# Escape most punctuation characters, except quotes, forward slash, and space
escape() {
  printf '%s' "$@" | sed -e 's/\([][!#$%&()*;<=>?\_`{|}]\)/\\\1/g;'
}

# Escape double quotes
escape_dq() {
  printf '%s' "$@" | sed -e 's/"/\\"/g'
}

# Define needed environment variables
setup_env() {
  # Command args
  case "$1" in
    -* | "")
      _cmd_node_exporter=
      ;;
      # Command provided
    *)
      _cmd_node_exporter=$1
      shift
      ;;
  esac

  CMD_NODE_EXPORTER_EXEC="$_cmd_node_exporter$(quote_indent "$@")"

  # use sudo if not already root
  SUDO=sudo
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=
  fi

  # Use binary install directory if defined or create default
  if [ -n "$INSTALL_NODE_EXPORTER_BIN_DIR" ]; then
    BIN_DIR="$INSTALL_NODE_EXPORTER_BIN_DIR"
  else
    # Use /usr/local/bin if root can write to it, otherwise use /opt/bin if it exists
    BIN_DIR=/usr/local/bin
    if ! $SUDO sh -c "touch $BIN_DIR/node_exporter-ro-test && rm -rf $BIN_DIR/node_exporter-ro-test"; then
      if [ -d /opt/bin ]; then
        BIN_DIR=/opt/bin
      fi
    fi
  fi

  # Set related files from system name
  SERVICE_NODE_EXPORTER=node_exporter.service
  UNINSTALL_NODE_EXPORTER_SH="$BIN_DIR/node_exporter.uninstall.sh"
  KILLALL_NODE_EXPORTER_SH="$BIN_DIR/node_exporter.killall.sh"

  # Extract port when address is specified or use default
  if test "${CMD_NODE_EXPORTER_EXEC#*"--web.listen-address="}" != "$CMD_NODE_EXPORTER_EXEC"; then
    NODE_EXPORTER_PORT=$(echo "$CMD_NODE_EXPORTER_EXEC" \
      | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g' \
      | sed -e 's/.*--web.listen-address=\(.*\)[[:space:]].*/\1/' \
      | sed 's/[^0-9]*//g')
    info "Listening port '$NODE_EXPORTER_PORT'"
  else
    NODE_EXPORTER_PORT=9100
  fi

  # Use systemd directory if defined or create default
  if [ -n "$INSTALL_NODE_EXPORTER_SYSTEMD_DIR" ]; then
    SYSTEMD_DIR="$INSTALL_NODE_EXPORTER_SYSTEMD_DIR"
  else
    SYSTEMD_DIR=/etc/systemd/system
  fi

  # Use service or environment location depending on systemd/openrc
  case $INIT_SYSTEM in
    openrc)
      $SUDO mkdir -p /etc/node_exporter
      FILE_NODE_EXPORTER_SERVICE=/etc/init.d/node_exporter
      ;;
    upstart)
      $SUDO mkdir -p /etc/node_exporter
      FILE_NODE_EXPORTER_SERVICE=/etc/init/node_exporter.conf
      ;;
    systemd)
      FILE_NODE_EXPORTER_SERVICE=$SYSTEMD_DIR/$SERVICE_NODE_EXPORTER
      ;;
    *)
      fatal "Unknown init system '$INIT_SYSTEM'"
      ;;
  esac

  # Get hash of config & exec for currently installed Node exporter
  PRE_INSTALL_HASHES=$(get_installed_hashes)
}

# Verify architecture
verify_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    amd64 | x86_64) ARCH=amd64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    armv5*) ARCH=armv5 ;;
    armv6*) ARCH=armv6 ;;
    armv7*) ARCH=armv7 ;;
    mips) ARCH=mips ;;
    mipsle) ARCH=mipsle ;;
    mips64) ARCH=mips64 ;;
    mips64le) ARCH=mips64le ;;
    ppc64) ARCH=ppc64 ;;
    ppc64le) ARCH=ppc64le ;;
    s390x) ARCH=s390x ;;
    i386) ARCH=386 ;;
    # Not supported
    *) fatal "Architecture '$ARCH' not supported" ;;
  esac
}

# Verify Operating System
verify_os() {
  OS=$(uname -s)
  case $OS in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    NetBSD) OS=netbsd ;;
    OpenBSD) OS=openbsd ;;
    # Not supported
    *) fatal "OS '$OS' not supported" ;;
  esac
}

# Verify architecture and os are supported
verify_arch_os() {
  case $OS in
    linux)
      case $ARCH in
        amd64 | arm64 | armv5 | armv6 | armv7 | mips | mipsle | mips64 | mips64le | ppc64 | ppc64le | s390x | 386) return ;;
      esac
      ;;
    darwin)
      case $ARCH in
        amd64 | arm64) return ;;
      esac
      ;;
    netbsd)
      case $ARCH in
        386 | amd64) return ;;
      esac
      ;;
    openbsd)
      case $ARCH in
        amd64) return ;;
      esac
      ;;
    # Not supported
    *) fatal "OS '$OS' not supported" ;;
  esac

  # Not supported
  fatal "Architecture '$ARCH' on OS '$OS' not supported"
}

# Verify init system
verify_init_system() {
  # OpenRC
  if [ -x /sbin/openrc-run ]; then
    INIT_SYSTEM=openrc
    return
  fi
  # UpStart
  case $(/sbin/init --version) in
    *upstart*)
      INIT_SYSTEM=upstart
      return
      ;;
  esac
  # systemd
  if [ -x /bin/systemctl ] || type systemctl > /dev/null 2>&1; then
    INIT_SYSTEM=systemd
    return
  fi

  # Not supported
  fatal 'No supported init system found (OpenRC, upstart or systemd)'
}

# Check command is installed
# @param $1 Command name
check_cmd() {
  command -v "$1" > /dev/null 2>&1
}

# Assert command is installed
# @param $1 Command name
assert_cmd() {
  check_cmd "$1" || fatal "Command '$1' not found"
}

# Verify firewall
verify_firewall_cmd() {
  # Cycle firewall commands
  for _cmd in "$@"; do
    # Check if exists
    if command -v "$_cmd" > /dev/null 2>&1; then
      # Found
      FIREWALL=$_cmd
      return
    fi
  done

  # Not found
  fatal "Unable to find any firewall command in list '$*'"
}

# Verify downloader command is installed
verify_downloader_cmd() {
  # Cycle downloader commands
  for _cmd in "$@"; do
    # Check if exists
    if command -v "$_cmd" > /dev/null 2>&1; then
      # Found
      DOWNLOADER=$_cmd
      return
    fi
  done

  # Not found
  fatal "Unable to find any downloader command in list '$*'"
}

# Check if skip firewall environment variable set
can_skip_firewall() {
  if [ "$INSTALL_NODE_EXPORTER_SKIP_FIREWALL" != true ]; then
    return 1
  fi
}

# Chekc if skip selinux environment variable set
can_skip_selinux() {
  if [ "$INSTALL_NODE_EXPORTER_SKIP_SELINUX" != true ]; then
    return 1
  fi
}

# Check if skip download environment variable set
can_skip_download() {
  if [ "$INSTALL_NODE_EXPORTER_SKIP_DOWNLOAD" != true ]; then
    return 1
  fi
}

# Verify system
verify_system() {
  # Arch and OS
  verify_arch
  verify_os
  verify_arch_os
  # Commands
  assert_cmd chmod
  assert_cmd chown
  assert_cmd grep
  assert_cmd mktemp
  assert_cmd rm
  assert_cmd sed
  assert_cmd sha256sum
  assert_cmd tar
  assert_cmd tee
  # Init system
  verify_init_system
  # Firewall
  can_skip_firewall || verify_firewall_cmd firewall-cmd ufw iptables
  # Downloader
  can_skip_download || verify_downloader_cmd curl wget
}

# Verify an executable Node exporter binary is installed
verify_node_exporter_is_executable() {
  if [ ! -x "$BIN_DIR/node_exporter" ]; then
    fatal "Executable Node exporter binary not found at '$BIN_DIR/node_exporter'"
  fi
}

# Create temporary directory and cleanup
setup_tmp() {
  TMP_DIR=$(mktemp -d -t node_exporter.XXXXXXXX)
  TMP_HASH="$TMP_DIR/node_exporter.hash"
  TMP_ARCHIVE="$TMP_DIR/node_exporter.archive"
  TMP_BIN="$TMP_DIR/node_exporter.bin"

  cleanup() {
    _exit_code=$?
    [ "$_exit_code" -eq 0 ] || error "Install script exited with code $_exit_code"
    set +o errexit
    trap - EXIT
    rm -rf "$TMP_DIR"
    exit $_exit_code
  }
  trap cleanup INT EXIT
}

# Use provided version or obtain from latest release
get_release_version() {
  if [ -n "$INSTALL_NODE_EXPORTER_VERSION" ]; then
    VERSION_NODE_EXPORTER=$INSTALL_NODE_EXPORTER_VERSION
  else
    info "Finding latest release"
    case $DOWNLOADER in
      curl) VERSION_NODE_EXPORTER=$(curl -L -f -s -S $GITHUB_API_URL) || fatal "Download '$GITHUB_API_URL' failed" ;;
      wget) VERSION_NODE_EXPORTER=$(wget -q -O - $GITHUB_API_URL 2>&1) || fatal "Download '$GITHUB_API_URL' failed" ;;
      *) fatal "Invalid downloader '$DOWNLOADER'" ;;
    esac
    VERSION_NODE_EXPORTER=$(echo "$VERSION_NODE_EXPORTER" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  fi

  info "Using $VERSION_NODE_EXPORTER as release"
}

# Download a file
download() {
  [ $# -eq 2 ] || fatal "Download requires exactly 2 arguments but '$#' found"

  # Download
  case $DOWNLOADER in
    curl)
      curl --fail --silent --location --output "$1" "$2" || fatal "Download '$2' failed"
      ;;
    wget)
      wget --quiet --output-document="$1" "$2" || fatal "Download '$2' failed"
      ;;
    *)
      fatal "Unknown downloader '$DOWNLOADER'"
      ;;
  esac
}

# Download hash
download_hash() {
  _hash_url=$GITHUB_URL/download/$VERSION_NODE_EXPORTER/sha256sums.txt

  info "Downloading hash '$_hash_url'"
  download "$TMP_HASH" "$_hash_url"
  HASH_ARCHIVE_EXPECTED=$(grep " $RELEASE_ARCHIVE" "$TMP_HASH")
  HASH_ARCHIVE_EXPECTED=${HASH_ARCHIVE_EXPECTED%%[[:blank:]]*}
}

# Download archive
download_archive() {
  _archive_url=$GITHUB_URL/download/$VERSION_NODE_EXPORTER/$RELEASE_ARCHIVE

  info "Downloading archive '$_archive_url'"
  download "$TMP_ARCHIVE" "$_archive_url"
  HASH_ARCHIVE=$(sha256sum "$TMP_ARCHIVE")
  HASH_ARCHIVE=${HASH_ARCHIVE%%[[:blank:]]*}
}

# Verify downloaded archive hash
verify_archive() {
  info "Verifying archive download '$TMP_ARCHIVE'"
  if [ "$HASH_ARCHIVE_EXPECTED" != "$HASH_ARCHIVE" ]; then
    fatal "Download sha256 does not match '$HASH_ARCHIVE_EXPECTED', got '$HASH_ARCHIVE'"
  fi
}

# Extract archive
extract_archive() {
  info "Extracting archive '$TMP_ARCHIVE'"
  tar xzf "$TMP_ARCHIVE" -C "$TMP_DIR" --strip-components 1 "$RELEASE_NAME/node_exporter" || fatal "Error extracting archive '$TMP_ARCHIVE'"
  mv "$TMP_DIR/node_exporter" "$TMP_BIN"

  info "Extracted binary '$TMP_BIN'"
  HASH_BIN_EXPECTED=$(sha256sum "$TMP_BIN")
  HASH_BIN_EXPECTED=${HASH_BIN_EXPECTED%%[[:blank:]]*}
}

# Check hash against installed version
installed_hash_matches() {
  if [ -x "$BIN_DIR/node_exporter" ]; then
    _hash_bin_installed=$(sha256sum "$BIN_DIR/node_exporter")
    _hash_bin_installed=${_hash_bin_installed%%[[:blank:]]*}
    if [ "$HASH_BIN_EXPECTED" = "$_hash_bin_installed" ]; then
      return 0
    fi
  fi
  return 1
}

# Setup permissions and move binary to system directory
setup_binary() {
  chmod 755 "$TMP_BIN"
  info "Installing Node exporter to '$BIN_DIR/node_exporter'"
  $SUDO chown root:root "$TMP_BIN"
  $SUDO mv -f "$TMP_BIN" "$BIN_DIR/node_exporter"
}

# Download and verify
download_and_verify() {
  if can_skip_download; then
    info 'Skipping Node exporter download and verify'
    verify_node_exporter_is_executable
    return
  fi

  setup_tmp
  get_release_version

  RELEASE_NAME=node_exporter-$(echo "$VERSION_NODE_EXPORTER" | sed 's/^v//').$OS-$ARCH
  RELEASE_ARCHIVE="$RELEASE_NAME.tar.gz"

  download_hash
  download_archive
  verify_archive
  extract_archive

  if installed_hash_matches; then
    info 'Skipping binary setup, installed Node exporter matches hash'
    return
  fi

  setup_binary
}

# Create killall script
create_killall() {
  info "Creating killall script '$KILLALL_NODE_EXPORTER_SH'"
  $SUDO tee "$KILLALL_NODE_EXPORTER_SH" > /dev/null << \EOF
#!/usr/bin/env sh
[ $(id -u) -eq 0 ] || exec sudo $0 $@

set -x

[ -s '/etc/systemd/system/node_exporter.service' ] && systemctl stop node_exporter.service

[ -x '/etc/init.d/node_exporter' ] && /etc/init.d/node_exporter stop

do_unmount_and_remove() {
  set +x
  while read -r _ path _; do
    case "$path" in $1*) echo "$path" ;; esac
  done < /proc/self/mounts | sort -r | xargs -r -t -n 1 sh -c 'umount "$0" && rm -rf "$0"'
  set -x
}
do_unmount_and_remove '/run/node_exporter'
EOF
  $SUDO chmod 755 "$KILLALL_NODE_EXPORTER_SH"
  $SUDO chown root:root "$KILLALL_NODE_EXPORTER_SH"
}

# Create uninstall script
create_uninstall() {
  info "Creating uninstall script '$UNINSTALL_NODE_EXPORTER_SH'"
  $SUDO tee "$UNINSTALL_NODE_EXPORTER_SH" > /dev/null << EOF
#!/usr/bin/env sh
set -x
[ \$(id -u) -eq 0 ] || exec sudo \$0 \$@

$KILLALL_NODE_EXPORTER_SH

if command -v systemctl; then
  systemctl disable node_exporter
  systemctl reset-failed node_exporter
  systemctl daemon-reload
fi
if command -v rc-update; then
  rc-update delete node_exporter default
fi

rm -f "$FILE_NODE_EXPORTER_SERVICE"

remove_uninstall() {
  rm -f "$UNINSTALL_NODE_EXPORTER_SH"
}
trap remove_uninstall EXIT

rm -rf /etc/node_exporter
rm -rf /run/node_exporter
rm -f "$BIN_DIR/node_exporter"
rm -f "$KILLALL_NODE_EXPORTER_SH"
EOF
  $SUDO chmod 755 "$UNINSTALL_NODE_EXPORTER_SH"
  $SUDO chown root:root "$UNINSTALL_NODE_EXPORTER_SH"
}

# Disable current service if loaded
systemd_disable() {
  $SUDO systemctl disable node_exporter > /dev/null 2>&1 || true
  $SUDO rm -f "/etc/systemd/system/$SERVICE_NODE_EXPORTER" || true
}

# Compose firewall rule
firewall_rule() {
  _firewall_path=$(command -v "$FIREWALL" 2>&1 || :)

  case $FIREWALL in
    firewall-cmd)
      printf "%s\n%s\n" \
        "$_firewall_path --add-port=$NODE_EXPORTER_PORT/tcp --permanent" \
        "$_firewall_path --reload"
      ;;
    ufw)
      printf "%s\n" \
        "$_firewall_path allow $NODE_EXPORTER_PORT/tcp"
      ;;
    iptables)
      printf "%s\n" \
        "$_firewall_path -A INPUT -p tcp --dport $NODE_EXPORTER_PORT -m state --state NEW -j ACCEPT"
      ;;
    *) fatal "Unknown firewall '$FIREWALL'" ;;
  esac
}

# Write openrc service file
create_openrc_service_file() {
  LOG_FILE=/var/log/node_exporter.log

  info "openrc: Creating service file '$FILE_NODE_EXPORTER_SERVICE'"
  $SUDO tee "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
#!/sbin/openrc-run

description="Node exporter"

depend() {
  need net
  need localmount
  use dns
  after firewall
}
EOF

  if ! can_skip_firewall; then
    _firewall=$(firewall_rule)
    $SUDO tee -a "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
start_pre() {
  $_firewall
}
EOF
  fi

  $SUDO tee -a "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
supervisor=supervise-daemon
name=node_exporter
command="$BIN_DIR/node_exporter"
command_args="$(escape_dq "$CMD_NODE_EXPORTER_EXEC") >> $LOG_FILE 2>&1"

output_log=$LOG_FILE
error_log=$LOG_FILE

pidfile="/var/run/node_exporter.pid"
respawn_delay=5
respawn_max=0

set -o allexport
if [ -f /etc/environment ]; then source /etc/environment; fi
set +o allexport
EOF
  $SUDO chmod 0755 "$FILE_NODE_EXPORTER_SERVICE"

  $SUDO tee /etc/logrotate.d/node_exporter > /dev/null << EOF
$LOG_FILE {
	missingok
	notifempty
	copytruncate
}
EOF
}

# Write systemd service file
create_systemd_service_file() {
  info "systemd: Creating service file '$FILE_NODE_EXPORTER_SERVICE'"
  $SUDO tee "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
[Unit]
Description=Node exporter
Documentation=https://github.com/prometheus/node_exporter
After=local-fs.target network-online.target network.target
Wants=local-fs.target network-online.target network.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
KillMode=process
Delegate=yes
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStart=$BIN_DIR/node_exporter $CMD_NODE_EXPORTER_EXEC
EOF

  if ! can_skip_firewall; then
    _firewall=""

    # Prepend 'ExecStartPre=-' to each rule
    while read -r _rule; do
      _firewall="$_firewall
ExecStartPre=-$_rule"
    done << EOF
$(firewall_rule)
EOF

    $SUDO tee -a "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
$_firewall
EOF
  fi
}

# Write upstart service file
create_upstart_service_file() {
  info "upstart: Creating service file '$FILE_NODE_EXPORTER_SERVICE'"
  $SUDO tee "$FILE_NODE_EXPORTER_SERVICE" > /dev/null << EOF
description "Node exporter"
start on runlevel [2345]
stop on runlevel [!2345]

respawn
respawn limit unlimited

exec $BIN_DIR/node_exporter $CMD_NODE_EXPORTER_EXEC
EOF
}

# Write service file
create_service_file() {
  case $INIT_SYSTEM in
    openrc) create_openrc_service_file ;;
    upstart) create_upstart_service_file ;;
    systemd) create_systemd_service_file ;;
    *) fatal "Unknown init system '$INIT_SYSTEM'" ;;
  esac
}

# Get hashes of the current Node exporter bin and service files
get_installed_hashes() {
  $SUDO sha256sum "$BIN_DIR/node_exporter" "$FILE_NODE_EXPORTER_SERVICE" 2>&1 || true
}

# Enable systemd service
systemd_enable() {
  info "systemd: Enabling node_exporter unit"
  $SUDO systemctl enable "$FILE_NODE_EXPORTER_SERVICE" > /dev/null
  $SUDO systemctl daemon-reload > /dev/null
}
# Start systemd service
systemd_start() {
  info "systemd: Starting node_exporter"
  $SUDO systemctl restart node_exporter
  # Wait an arbitrary amount of time for service to load
  sleep 1
  systemctl is-active --quiet node_exporter || fatal "systemd: Error starting node_exporter"

}

# Enable openrc service
openrc_enable() {
  info "openrc: Enabling node_exporter service for default runlevel"
  $SUDO rc-update add node_exporter default > /dev/null
}
# Start openrc service
openrc_start() {
  info "openrc: Starting node_exporter"
  $SUDO "$FILE_NODE_EXPORTER_SERVICE" restart
  # Wait an arbitrary amount of time for service to load
  sleep 1
  rc-service --quiet node_exporter status || fatal "openrc: Error starting node_exporter"
}

# Start upstart service
upstart_start() {
  info "upstart: Starting node_exporter"
  $SUDO initctl start node_exporter
  # Wait an arbitrary amount of time for service to load
  sleep 1
  initctl status node_exporter || fatal "upstart: Error starting node_exporter"
}

# relabel to executable if SElinux is installed
setup_selinux() {
  if can_skip_selinux; then
    info 'Skipping SELinux setup'
    return
  fi

  if check_cmd getenforce; then
    if check_cmd semanage; then
      semanage fcontext -D "$BIN_DIR/node_exporter"
      semanage fcontext -a -t bin_t "$BIN_DIR/node_exporter"
      restorecon -v "$BIN_DIR/node_exporter"
    else
      error "Cannot setup SELinux context for binary '$BIN_DIR/node_exporter'. Please install 'policycoreutils-python-utils' package then re-run this script"
      if check_cmd chcon; then
        info "Trying non permanent SELinux labeling. This won't survive a FS relabeling"
        if ! chcon -t bin_t "$BIN_DIR/node_exporter"; then
          error "Cannot set context of binary '$BIN_DIR/node_exporter'"
        else
          info "Temporary SELinux context set for '$BIN_DIR/node_exporter'"
        fi
      fi
    fi
  fi

}

# Startup service
service_enable_and_start() {
  [ "$INSTALL_NODE_EXPORTER_SKIP_ENABLE" = true ] && return
  case $INIT_SYSTEM in
    openrc) openrc_enable ;;
    systemd) systemd_enable ;;
    upstart) # runlevels already defined in /etc/init/node_exporter.conf
     ;;
    *) fatal "Unknown init system '$INIT_SYSTEM'" ;;
  esac

  [ "$INSTALL_NODE_EXPORTER_SKIP_START" = true ] && return
  POST_INSTALL_HASHES=$(get_installed_hashes)
  if [ "$PRE_INSTALL_HASHES" = "$POST_INSTALL_HASHES" ] && [ "$INSTALL_NODE_EXPORTER_FORCE_RESTART" != true ]; then
    info 'No change detected so skipping service start'
    return
  fi
  case $INIT_SYSTEM in
    openrc) openrc_start ;;
    upstart) upstart_start ;;
    systemd) systemd_start ;;
    *) fatal "Unknown init system '$INIT_SYSTEM'" ;;
  esac

  return 0
}

# ================
# MAIN
# ================
# Re-evaluate args to include env command
eval set -- "$(escape "$INSTALL_NODE_EXPORTER_EXEC") $(quote "$@")"
# Run
{
  verify_system
  setup_env "$@"
  download_and_verify
  setup_selinux
  create_killall
  create_uninstall
  systemd_disable
  create_service_file
  service_enable_and_start
}
