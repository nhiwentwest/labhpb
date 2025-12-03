#!/usr/bin/env bash
set -euo pipefail

# Lab 2 + Lab 3 setup script for VM1 (server + etcd + gRPC)
# - Installs system dependencies (Python, etcd, tooling)
# - Sets up Python virtualenv and installs pip packages
# - Optionally generates gRPC Python code from proto/monitor.proto
# - Creates a systemd unit to run the monitoring gRPC server
#
# Usage:
#   sudo bash vm1_lab_setup.sh
#   sudo GRPC_PORT=50051 ETCD_PORT=2379 bash vm1_lab_setup.sh
#
# Notes:
# - Script assumes it is placed in the project root that is shared between VM1 and VM2.
# - Idempotent as much as possible: safe to re-run.

GRPC_PORT="${GRPC_PORT:-50051}"
ETCD_PORT="${ETCD_PORT:-2379}"

# Resolve project root to directory containing this script
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_ENV_DIR="${PY_ENV_DIR:-${APP_ROOT}/.venv}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-/etc/systemd/system/monitor-server.service}"
PROFILE_SNIPPET="${PROFILE_SNIPPET:-/etc/profile.d/monitor-lab.sh}"

info() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

# Require root
if [[ "${EUID}" -ne 0 ]]; then
  err "Please run as root (sudo)."
  exit 1
fi

_autodetect_ip() {
  local ip=""
  if ip route get 1.1.1.1 >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  fi
  if [[ -z "${ip}" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  echo "${ip}"
}

install_deps() {
  info "Updating apt and installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential pkg-config python3-dev \
    python3 python3-venv python3-pip \
    git tmux \
    etcd-server \
    sysstat ifstat \
    ufw ca-certificates curl
}

create_venv_and_install() {
  if [[ ! -d "${PY_ENV_DIR}" ]]; then
    info "Creating Python virtualenv at ${PY_ENV_DIR}..."
    python3 -m venv "${PY_ENV_DIR}"
  else
    info "Using existing virtualenv at ${PY_ENV_DIR}"
  fi

  # shellcheck disable=SC1090
  source "${PY_ENV_DIR}/bin/activate"

  pip install --upgrade pip setuptools wheel

  if [[ -f "${APP_ROOT}/requirements.txt" ]]; then
    info "Installing Python packages from requirements.txt..."
    pip install -r "${APP_ROOT}/requirements.txt"
  else
    info "requirements.txt not found, installing minimal required packages..."
    pip install "protobuf==3.20.3" "grpcio==1.48.2" "grpcio-tools==1.48.2" etcd3
  fi
}

generate_proto_if_present() {
  local proto_file="${APP_ROOT}/proto/monitor.proto"

  if [[ ! -f "${proto_file}" ]]; then
    warn "Proto file ${proto_file} not found; skipping gRPC code generation."
    return
  fi

  info "Generating gRPC Python code from ${proto_file}..."
  mkdir -p "${APP_ROOT}/server" "${APP_ROOT}/agent"

  # shellcheck disable=SC1090
  source "${PY_ENV_DIR}/bin/activate"

  python -m grpc_tools.protoc \
    -I "${APP_ROOT}/proto" \
    --python_out="${APP_ROOT}/server" \
    --grpc_python_out="${APP_ROOT}/server" \
    "${proto_file}"
}

install_profile_snippet() {
  cat > "${PROFILE_SNIPPET}" <<EOF
# Convenience env for Lab 2/3 monitor project
export MONITOR_LAB_ROOT=${APP_ROOT}
export PATH=\$PATH:${PY_ENV_DIR}/bin
EOF
}

install_systemd_unit() {
  local this_ip="$1"

  if [[ ! -d "${APP_ROOT}" ]]; then
    err "APP_ROOT directory ${APP_ROOT} does not exist."
    exit 1
  fi

  cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Distributed System Monitor gRPC Server (Lab 2/3)
After=network-online.target etcd.service
Wants=network-online.target etcd.service

[Service]
Type=simple
WorkingDirectory=${APP_ROOT}
Environment=PYTHONUNBUFFERED=1
ExecStart=${PY_ENV_DIR}/bin/python -m server.server_main --bind ${this_ip}:${GRPC_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

maybe_open_firewall() {
  if ufw status 2>/dev/null | grep -qi active; then
    info "UFW active: allowing gRPC port ${GRPC_PORT} and etcd port ${ETCD_PORT}..."
    ufw allow "${GRPC_PORT}"/tcp || true
    ufw allow "${ETCD_PORT}"/tcp || true
  else
    info "UFW not active; skipping firewall changes."
  fi
}

show_current() {
  local this_ip="$(_autodetect_ip)"
  local svc_state="(unknown)"

  if systemctl list-unit-files 2>/dev/null | grep -q "^monitor-server.service"; then
    svc_state="$(systemctl is-enabled monitor-server 2>/dev/null || echo "not-enabled") / $(systemctl is-active monitor-server 2>/dev/null || echo "inactive")"
  fi

  echo "================ CURRENT CONFIG (VM1 LAB) ================"
  echo "APP_ROOT:          ${APP_ROOT}"
  echo "PY_ENV_DIR:        ${PY_ENV_DIR}"
  echo "THIS_IP:           ${this_ip}"
  echo "GRPC_PORT:         ${GRPC_PORT}"
  echo "ETCD_PORT:         ${ETCD_PORT}"
  echo "Systemd unit:      ${SYSTEMD_UNIT}"
  echo "Server service:    ${svc_state}"
  echo "Profile snippet:   ${PROFILE_SNIPPET}"
  echo "=========================================================="
}

main() {
  local mode="${1:-}"

  if [[ "${mode}" == "--show" ]]; then
    show_current
    exit 0
  fi

  install_deps
  create_venv_and_install
  install_profile_snippet

  # etcd-server is typically packaged as 'etcd' service on Ubuntu
  if systemctl list-unit-files 2>/dev/null | grep -q "^etcd.service"; then
    info "Enabling and starting etcd.service..."
    systemctl enable --now etcd.service || warn "Failed to enable/start etcd.service; please check logs."
  else
    warn "etcd.service not found. Ensure etcd is installed and running for Lab 3."
  fi

  generate_proto_if_present

  local autodetected_ip
  autodetected_ip="$(_autodetect_ip)"
  echo
  echo "Detected THIS_IP: ${autodetected_ip}"
  read -r -p "Use this IP for gRPC bind? [${autodetected_ip}] (enter to accept or type different IP): " input_ip || true
  local this_ip="${input_ip:-${autodetected_ip}}"

  install_systemd_unit "${this_ip}"
  maybe_open_firewall

  echo
  echo "==================== SUMMARY (VM1 LAB) ==================="
  echo "APP_ROOT:          ${APP_ROOT}"
  echo "PY_ENV_DIR:        ${PY_ENV_DIR}"
  echo "THIS_IP:           ${this_ip}"
  echo "GRPC_PORT:         ${GRPC_PORT}"
  echo "ETCD_PORT:         ${ETCD_PORT}"
  echo "Systemd unit:      ${SYSTEMD_UNIT}"
  echo
  echo "Next steps:"
  echo "- Ensure server code exists at: server/server_main.py (Python module 'server.server_main')."
  echo "- Start gRPC server: sudo systemctl enable monitor-server && sudo systemctl start monitor-server"
  echo "- View logs:          sudo journalctl -u monitor-server -f"
  echo "=========================================================="
}

main "$@"


