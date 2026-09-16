#!/usr/bin/env bash
#
# pve-guest-disk-alert installer
#
# Copyright (C) 2026 KittDoesntCode
# SPDX-License-Identifier: AGPL-3.0-only
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# This program is distributed WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Downloads and installs pve-guest-disk-alert from:
#   https://github.com/KittDoesntCode/pve-guest-disk-alert
#
# Default behavior:
#   - Downloads the script and systemd unit files from the main branch.
#   - Validates the Bash script and systemd units before installation.
#   - Creates root-owned backups of existing installed files.
#   - Installs the monitor, systemd service, and systemd timer.
#   - Creates the protected state directory.
#   - Reloads systemd.
#   - Enables and starts the timer.
#
# Safer invocation:
#   curl -fL --proto '=https' --tlsv1.2 \
#     -o install.sh \
#     https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh
#   less install.sh
#   sudo bash install.sh
#
# Convenience invocation:
#   curl -fsSL --proto '=https' --tlsv1.2 \
#     https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh \
#     | sudo bash
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'

# ------------------------------------------------------------------------------
# Release source configuration
# ------------------------------------------------------------------------------

readonly REPOSITORY_OWNER='KittDoesntCode'
readonly REPOSITORY_NAME='pve-guest-disk-alert'
readonly REPOSITORY_BRANCH='main'
readonly RAW_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY_OWNER}/${REPOSITORY_NAME}/${REPOSITORY_BRANCH}"

readonly SCRIPT_FILE='pve-guest-disk-alert'
readonly SERVICE_FILE='pve-guest-disk-alert.service'
readonly TIMER_FILE='pve-guest-disk-alert.timer'

# ------------------------------------------------------------------------------
# Installation destinations
# ------------------------------------------------------------------------------

readonly INSTALL_SCRIPT='/usr/local/sbin/pve-guest-disk-alert'
readonly INSTALL_SERVICE='/etc/systemd/system/pve-guest-disk-alert.service'
readonly INSTALL_TIMER='/etc/systemd/system/pve-guest-disk-alert.timer'
readonly STATE_DIRECTORY='/var/lib/pve-guest-disk-alert'

readonly PROGRAM_NAME="${0##*/}"

TEMP_DIRECTORY=''
BACKUP_DIRECTORY=''
ENABLE_TIMER=true
DRY_RUN=false
REFRESH_ONLY=false

# ------------------------------------------------------------------------------
# Logging and error handling
# ------------------------------------------------------------------------------

log_info() {
    printf '%s: INFO: %s\n' "$PROGRAM_NAME" "$*"
}

log_warning() {
    printf '%s: WARNING: %s\n' "$PROGRAM_NAME" "$*" >&2
}

log_error() {
    printf '%s: ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2
}

fatal() {
    log_error "$*"
    exit 1
}

cleanup() {
    local exit_status=$?

    if [[ -n "$TEMP_DIRECTORY" && -d "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'fatal "Installation interrupted."' INT TERM HUP

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [OPTIONS]

Downloads and installs pve-guest-disk-alert from:

  https://github.com/${REPOSITORY_OWNER}/${REPOSITORY_NAME}

Options:
  --branch NAME       Install from a different repository branch.
                      Default: ${REPOSITORY_BRANCH}

  --no-enable         Install files but do not enable/start the timer.

  --refresh           Reinstall files and reload systemd, but do not alter
                      whether the timer is enabled/running.

  --dry-run           Download and validate files, but do not install,
                      reload systemd, or change timer state.

  --help              Show this help.

Examples:
  ${PROGRAM_NAME}

  ${PROGRAM_NAME} --no-enable

  ${PROGRAM_NAME} --branch develop --no-enable

  ${PROGRAM_NAME} --refresh

  ${PROGRAM_NAME} --dry-run
EOF
}

# ------------------------------------------------------------------------------
# Command and privilege checks
# ------------------------------------------------------------------------------

require_command() {
    local command_name="$1"

    command -v "$command_name" >/dev/null 2>&1 \
        || fatal "Required command not found: ${command_name}"
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fatal 'Run this installer as root, for example: sudo bash install.sh'
}

check_system() {
    local required_command

    require_root

    for required_command in \
        bash \
        curl \
        date \
        install \
        mkdir \
        mktemp \
        rm \
        systemctl \
        systemd-analyze \
        uname
    do
        require_command "$required_command"
    done

    [[ -d /run/systemd/system ]] \
        || fatal 'This host does not appear to be running systemd.'

    if ! command -v qm >/dev/null 2>&1 || ! command -v pct >/dev/null 2>&1; then
        log_warning 'qm and/or pct were not found. This may not be a Proxmox VE node.'
    fi

    if [[ "$(uname -s)" != 'Linux' ]]; then
        fatal 'This installer is intended for Linux/Proxmox VE hosts.'
    fi
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------

parse_arguments() {
    local branch_override=''

    while (( $# > 0 )); do
        case "$1" in
            --branch)
                (( $# >= 2 )) || fatal '--branch requires a branch name.'
                branch_override="$2"
                shift 2
                ;;
            --no-enable)
                ENABLE_TIMER=false
                shift
                ;;
            --refresh)
                REFRESH_ONLY=true
                ENABLE_TIMER=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                ENABLE_TIMER=false
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
    done

    if [[ -n "$branch_override" ]]; then
        [[ "$branch_override" =~ ^[A-Za-z0-9._/-]+$ ]] \
            || fatal 'Branch names may contain only letters, numbers, dot, underscore, slash, and hyphen.'

        RAW_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY_OWNER}/${REPOSITORY_NAME}/${branch_override}"
    fi
}

# ------------------------------------------------------------------------------
# Download and validation
# ------------------------------------------------------------------------------

download_file() {
    local file_name="$1"
    local output_path="${TEMP_DIRECTORY}/${file_name}"
    local url="${RAW_BASE_URL}/${file_name}"

    log_info "Downloading ${file_name}."

    curl \
        --fail \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --connect-timeout 15 \
        --max-time 120 \
        --retry 3 \
        --retry-delay 2 \
        --output "$output_path" \
        "$url"

    [[ -s "$output_path" ]] \
        || fatal "Downloaded file is empty: ${file_name}"
}

validate_downloads() {
    local script_path="${TEMP_DIRECTORY}/${SCRIPT_FILE}"
    local service_path="${TEMP_DIRECTORY}/${SERVICE_FILE}"
    local timer_path="${TEMP_DIRECTORY}/${TIMER_FILE}"

    log_info 'Validating downloaded Bash script.'
    bash -n "$script_path"

    log_info 'Validating downloaded systemd units.'
    systemd-analyze verify "$service_path" "$timer_path"

    # Basic content checks prevent accidentally installing an HTML error page or
    # unrelated file if repository layout/names are changed.
    grep -q '^#!/usr/bin/env bash$' "$script_path" \
        || fatal "${SCRIPT_FILE} does not appear to be the expected Bash script."

    grep -q '^\[Service\]$' "$service_path" \
        || fatal "${SERVICE_FILE} does not appear to be a systemd service unit."

    grep -q '^\[Timer\]$' "$timer_path" \
        || fatal "${TIMER_FILE} does not appear to be a systemd timer unit."

    grep -q '^ExecStart=/usr/local/sbin/pve-guest-disk-alert$' "$service_path" \
        || fatal "${SERVICE_FILE} does not use the expected script path."

    grep -q '^Unit=pve-guest-disk-alert.service$' "$timer_path" \
        || fatal "${TIMER_FILE} does not reference the expected service."
}

# ------------------------------------------------------------------------------
# Backup and installation
# ------------------------------------------------------------------------------

backup_existing_file() {
    local installed_file="$1"

    [[ -e "$installed_file" ]] || return 0

    cp -a -- "$installed_file" "$BACKUP_DIRECTORY/"
    log_info "Backed up ${installed_file}."
}

create_backup_directory() {
    local timestamp

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_DIRECTORY="/root/pve-guest-disk-alert-backup-${timestamp}"

    install -d -o root -g root -m 0700 "$BACKUP_DIRECTORY"
}

install_files() {
    local script_source="${TEMP_DIRECTORY}/${SCRIPT_FILE}"
    local service_source="${TEMP_DIRECTORY}/${SERVICE_FILE}"
    local timer_source="${TEMP_DIRECTORY}/${TIMER_FILE}"

    create_backup_directory

    backup_existing_file "$INSTALL_SCRIPT"
    backup_existing_file "$INSTALL_SERVICE"
    backup_existing_file "$INSTALL_TIMER"

    log_info "Installing ${INSTALL_SCRIPT}."
    install -o root -g root -m 0750 "$script_source" "$INSTALL_SCRIPT"

    log_info "Installing ${INSTALL_SERVICE}."
    install -o root -g root -m 0644 "$service_source" "$INSTALL_SERVICE"

    log_info "Installing ${INSTALL_TIMER}."
    install -o root -g root -m 0644 "$timer_source" "$INSTALL_TIMER"

    log_info "Creating state directory ${STATE_DIRECTORY}."
    install -d -o root -g root -m 0700 "$STATE_DIRECTORY"
}

validate_installed_files() {
    log_info 'Validating installed Bash script.'
    bash -n "$INSTALL_SCRIPT"

    log_info 'Reloading systemd unit definitions.'
    systemctl daemon-reload

    log_info 'Validating installed systemd units.'
    systemd-analyze verify "$INSTALL_SERVICE" "$INSTALL_TIMER"
}

# ------------------------------------------------------------------------------
# Timer control
# ------------------------------------------------------------------------------

timer_was_enabled() {
    systemctl is-enabled --quiet "$TIMER_FILE"
}

timer_was_active() {
    systemctl is-active --quiet "$TIMER_FILE"
}

enable_timer() {
    log_info "Enabling and starting ${TIMER_FILE}."
    systemctl enable --now "$TIMER_FILE"

    log_info 'Installed timer schedule:'
    systemctl list-timers "$TIMER_FILE" --all --no-pager || true
}

restore_timer_state() {
    local was_enabled="$1"
    local was_active="$2"

    if [[ "$was_enabled" == true ]]; then
        log_info "Restoring enabled state for ${TIMER_FILE}."
        systemctl enable "$TIMER_FILE"
    else
        systemctl disable "$TIMER_FILE" >/dev/null 2>&1 || true
    fi

    if [[ "$was_active" == true ]]; then
        log_info "Restoring active state for ${TIMER_FILE}."
        systemctl start "$TIMER_FILE"
    else
        systemctl stop "$TIMER_FILE" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    local previous_timer_enabled=false
    local previous_timer_active=false

    parse_arguments "$@"
    check_system

    TEMP_DIRECTORY="$(mktemp -d /tmp/pve-guest-disk-alert-install.XXXXXXXX)"
    chmod 0700 "$TEMP_DIRECTORY"

    log_info "Source: ${RAW_BASE_URL}"
    log_info "Temporary download directory: ${TEMP_DIRECTORY}"

    download_file "$SCRIPT_FILE"
    download_file "$SERVICE_FILE"
    download_file "$TIMER_FILE"
    validate_downloads

    if [[ "$DRY_RUN" == true ]]; then
        log_info 'Dry run completed successfully. No files were installed.'
        exit 0
    fi

    if timer_was_enabled; then
        previous_timer_enabled=true
    fi

    if timer_was_active; then
        previous_timer_active=true
    fi

    install_files
    validate_installed_files

    if [[ "$REFRESH_ONLY" == true ]]; then
        restore_timer_state "$previous_timer_enabled" "$previous_timer_active"
        log_info 'Refresh completed successfully.'
    elif [[ "$ENABLE_TIMER" == true ]]; then
        enable_timer
        log_info 'Installation completed successfully.'
    else
        log_info 'Installation completed successfully; timer was not enabled.'
        log_info "Enable it after testing with: systemctl enable --now ${TIMER_FILE}"
    fi

    printf '\n'
    printf 'Installed script:  %s\n' "$INSTALL_SCRIPT"
    printf 'Installed service: %s\n' "$INSTALL_SERVICE"
    printf 'Installed timer:   %s\n' "$INSTALL_TIMER"
    printf 'State directory:   %s\n' "$STATE_DIRECTORY"

    if [[ -n "$BACKUP_DIRECTORY" ]]; then
        printf 'Backup directory:  %s\n' "$BACKUP_DIRECTORY"
    fi

    printf '\n'
    printf 'Recommended validation commands:\n'
    printf '  %s --threshold 90 --dry-run --verbose\n' "$INSTALL_SCRIPT"
    printf '  systemctl status %s --no-pager\n' "$TIMER_FILE"
    printf '  systemctl list-timers %s --all\n' "$TIMER_FILE"
    printf '  journalctl -u %s --since today --no-pager\n' "$SERVICE_FILE"
}

main "$@"
