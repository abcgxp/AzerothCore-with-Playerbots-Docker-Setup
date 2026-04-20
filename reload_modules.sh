#!/bin/bash

function log_step() {
    echo ""
    echo "==> $1"
}

function log_info() {
    echo "[INFO] $1"
}

function log_warn() {
    echo "[WARN] $1"
}

function log_error() {
    echo "[ERROR] $1" >&2
}

function require_sudo_invocation() {
    if [ "$EUID" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ -z "${SUDO_UID:-}" ] || [ -z "${SUDO_GID:-}" ]; then
        log_error "Run this script with sudo from your normal user account."
        log_info "Use: sudo ./reload_modules.sh"
        exit 1
    fi

    CALLING_USER="$SUDO_USER"
    CALLING_UID="$SUDO_UID"
    CALLING_GID="$SUDO_GID"
}

function detect_timezone() {
    if [ -f /etc/timezone ]; then
        cat /etc/timezone
        return 0
    fi

    if command -v timedatectl &> /dev/null; then
        local timezone
        timezone=$(timedatectl show --property=Timezone --value 2> /dev/null)
        if [ -n "$timezone" ]; then
            echo "$timezone"
            return 0
        fi
    fi

    if [ -L /etc/localtime ]; then
        readlink /etc/localtime | sed 's#^.*/zoneinfo/##'
        return 0
    fi

    return 1
}

function update_env_timezone() {
    DETECTED_TIMEZONE=$(detect_timezone)

    if [ -z "$DETECTED_TIMEZONE" ]; then
        log_warn "Unable to detect the system timezone automatically. Using the TZ value already present in src/.env."
        return 0
    fi

    log_info "Using detected system timezone: $DETECTED_TIMEZONE"
}

function load_setup_env() {
    local normalized_env_file
    normalized_env_file=$(mktemp)

    tr -d '\r' < src/.env > "$normalized_env_file"

    set -a
    . "$normalized_env_file"
    set +a

    rm -f "$normalized_env_file"

    if [ -n "$DETECTED_TIMEZONE" ]; then
        TZ="$DETECTED_TIMEZONE"
    fi

    DOCKER_USER_ID="$CALLING_UID"
    DOCKER_GROUP_ID="$CALLING_GID"
}

function write_runtime_env_file() {
    local source_env_file target_env_file temp_env_file
    source_env_file="$1"
    target_env_file="$2"
    temp_env_file=$(mktemp)

    tr -d '\r' < "$source_env_file" > "$temp_env_file"

    if [ -n "${TZ:-}" ]; then
        sed -i "s|^TZ=.*$|TZ=$TZ|" "$temp_env_file"
    fi

    cp "$temp_env_file" "$target_env_file"
    rm -f "$temp_env_file"
}

function copy_project_runtime_files() {
    write_runtime_env_file src/.env azerothcore-wotlk/.env
    cp src/*.yml azerothcore-wotlk/
}

function restore_azeroth_ownership() {
    local target_path

    for target_path in azerothcore-wotlk wotlk sql_dumps; do
        if [ -e "$target_path" ]; then
            chown -R "${CALLING_UID}:${CALLING_GID}" "$target_path"
        fi
    done
}

function docker_compose_in_project() {
    (
        cd azerothcore-wotlk || exit 1
        docker compose "$@"
    )
}

function prepare_host_directories() {
    log_step "Preparing local configuration folders"
    mkdir -p wotlk/etc wotlk/logs
    restore_azeroth_ownership
}

function install_optional_modules_from_catalog() {
    local modules_file module_name repo_url
    modules_file="$1"

    if [ ! -f "$modules_file" ]; then
        log_error "Module catalog not found: $modules_file"
        exit 1
    fi

    while read -r module_name repo_url; do
        if [[ -z "$module_name" || "$module_name" == \#* ]]; then
            continue
        fi

        if [ -d "${module_name}" ]; then
            log_info "${module_name} already exists. Skipping."
            continue
        fi

        log_info "Cloning ${module_name}."
        git clone "${repo_url}"
    done < "$modules_file"
}

function sync_config_templates() {
    local config_dir template_file config_file
    SYNCED_CONFIG_COUNT=0

    for config_dir in wotlk/etc wotlk/etc/modules; do
        if [ ! -d "$config_dir" ]; then
            continue
        fi

        while IFS= read -r -d '' template_file; do
            config_file="${template_file%.dist}"
            if [ ! -f "$config_file" ]; then
                cp "$template_file" "$config_file"
                SYNCED_CONFIG_COUNT=$((SYNCED_CONFIG_COUNT + 1))
                log_info "Created $(basename "$config_file") from template."
            fi
        done < <(find "$config_dir" -maxdepth 1 -type f -name '*.conf.dist' -print0)
    done

    if [ "$SYNCED_CONFIG_COUNT" -eq 0 ]; then
        log_info "All config files already exist. No templates needed to be copied."
    else
        log_info "Created ${SYNCED_CONFIG_COUNT} config file(s) from templates."
    fi
}

function ensure_worldserver_config_setting() {
    local config_file setting_name setting_value escaped_name
    config_file="$1"
    setting_name="$2"
    setting_value="$3"
    escaped_name="${setting_name//./\\.}"

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    if grep -Eq "^[[:space:]]*${escaped_name}[[:space:]]*=[[:space:]]*${setting_value}[[:space:]]*$" "$config_file"; then
        return 0
    fi

    if grep -Eq "^[[:space:]]*${escaped_name}[[:space:]]*=" "$config_file"; then
        sed -i -E "s|^[[:space:]]*${escaped_name}[[:space:]]*=.*$|${setting_name} = ${setting_value}|" "$config_file"
    else
        printf "\n%s = %s\n" "$setting_name" "$setting_value" >> "$config_file"
    fi

    MODULE_CONFIG_UPDATED=1
    log_info "Ensured ${setting_name} = ${setting_value} in $(basename "$config_file")."
}

function apply_module_specific_config() {
    local worldserver_config
    worldserver_config="wotlk/etc/worldserver.conf"
    MODULE_CONFIG_UPDATED=0

    if [ -d "azerothcore-wotlk/modules/mod-individual-progression" ]; then
        log_step "Applying module-specific config requirements"
        ensure_worldserver_config_setting "$worldserver_config" "EnablePlayerSettings" "1"
        ensure_worldserver_config_setting "$worldserver_config" "DBC.EnforceItemAttributes" "0"
    fi
}

require_sudo_invocation
update_env_timezone
load_setup_env

if [ ! -d "azerothcore-wotlk" ]; then
    log_error "azerothcore-wotlk was not found. Run ./setup.sh first."
    exit 1
fi

log_step "Refreshing runtime Docker files"
copy_project_runtime_files
restore_azeroth_ownership
prepare_host_directories

log_step "Downloading newly added optional modules"
cd azerothcore-wotlk/modules
install_optional_modules_from_catalog ../../src/module-repos.txt
cd ../..

log_step "Rebuilding Docker services"
docker_compose_in_project up -d --build

prepare_host_directories
sync_config_templates
apply_module_specific_config
restore_azeroth_ownership

if [ "${SYNCED_CONFIG_COUNT:-0}" -gt 0 ] || [ "${MODULE_CONFIG_UPDATED:-0}" -gt 0 ]; then
    log_step "Restarting containers to pick up newly created config files"
    docker_compose_in_project restart ac-authserver ac-worldserver
fi

log_info "Module reload completed."
