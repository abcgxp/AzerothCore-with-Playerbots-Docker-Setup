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

function ask_user() {
    read -p "$1 (y/n): " choice
    case "$choice" in
        y|Y ) return 0;;
        * ) return 1;;
    esac
}

function require_sudo_invocation() {
    if [ "$EUID" -ne 0 ] || [ -z "${SUDO_USER:-}" ] || [ -z "${SUDO_UID:-}" ] || [ -z "${SUDO_GID:-}" ]; then
        log_error "Run this script with sudo from your normal user account."
        log_info "Use: sudo ./setup.sh"
        exit 1
    fi

    CALLING_USER="$SUDO_USER"
    CALLING_UID="$SUDO_UID"
    CALLING_GID="$SUDO_GID"
}

function load_os_release() {
    if [ ! -r /etc/os-release ]; then
        log_error "Unable to detect Linux distribution. /etc/os-release was not found."
        exit 1
    fi

    . /etc/os-release
}

function os_like() {
    [[ " ${ID_LIKE:-} " == *" $1 "* ]]
}

function is_arch_family() {
    [[ "${ID:-}" == "arch" ]] || os_like "arch"
}

function is_debian_family() {
    [[ "${ID:-}" == "debian" ]] || os_like "debian"
}

function is_ubuntu_family() {
    [[ "${ID:-}" == "ubuntu" ]] || os_like "ubuntu"
}

function require_supported_distro() {
    if is_arch_family || is_ubuntu_family || is_debian_family; then
        return 0
    fi

    log_error "Unsupported Linux distribution: ${PRETTY_NAME:-unknown}"
    log_info "This script currently supports Debian-based, Ubuntu-based, and Arch-based systems."
    exit 1
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
        log_warn "Unable to detect the system timezone automatically. Leaving TZ unchanged in src/.env."
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
    DOCKER_DB_ROOT_PASSWORD="${DOCKER_DB_ROOT_PASSWORD:-password}"
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

function install_optional_modules_from_catalog() {
    local modules_file module_name repo_url
    modules_file="$1"

    if [ ! -f "$modules_file" ]; then
        log_warn "Module catalog not found: $modules_file"
        return 0
    fi

    while read -r module_name repo_url; do
        if [[ -z "$module_name" || "$module_name" == \#* ]]; then
            continue
        fi

        if [ -d "${module_name}" ]; then
            log_info "${module_name} already exists. Skipping."
            continue
        fi

        if ask_user "Install ${module_name}?"; then
            log_info "Cloning ${module_name}."
            git clone "${repo_url}"
        fi
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

function install_mysql_client() {
    log_step "Checking MySQL client"

    if command -v mysql &> /dev/null; then
        log_info "MySQL client is already installed."
        return 0
    fi

    log_info "MySQL client is not installed. Installing MariaDB client now."

    if is_arch_family; then
        pacman -Syu --needed --noconfirm mariadb-clients
    else
        apt update
        apt install -y mariadb-client
    fi
}

function install_docker() {
    log_step "Checking Docker"

    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        log_info "Docker CLI and Compose are already installed."
        return 0
    fi

    log_info "Docker or Docker Compose is missing. Installing Docker now."

    if is_arch_family; then
        pacman -Syu --needed --noconfirm docker docker-compose
    else
        local docker_repo distro_codename

        if is_ubuntu_family; then
            docker_repo="ubuntu"
            distro_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        else
            docker_repo="debian"
            distro_codename="${VERSION_CODENAME:-}"
        fi

        if [ -z "$distro_codename" ]; then
            log_error "Unable to determine the distro codename for the Docker repository."
            exit 1
        fi

        apt update
        apt-get install -y ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_repo} \
          ${distro_codename} stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
}

function ensure_docker_access() {
    log_step "Ensuring Docker is usable"

    if command -v systemctl &> /dev/null; then
        log_info "Trying to enable and start the Docker service."
        systemctl enable --now docker &> /dev/null || systemctl start docker &> /dev/null || true
    fi

    if getent group docker &> /dev/null && ! id -nG "$CALLING_USER" | grep -qw docker; then
        usermod -aG docker "$CALLING_USER"
        log_warn "Added ${CALLING_USER} to the docker group."
        log_info "Log out and back in, then rerun sudo ./setup.sh."
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose is still unavailable after installation."
        log_info "Please verify that the Docker packages installed successfully and rerun sudo ./setup.sh."
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker is installed, but the Docker daemon is not reachable."
        log_info "Make sure the Docker service is running, then rerun sudo ./setup.sh."
        exit 1
    fi
}

function prepare_host_directories() {
    log_step "Preparing local configuration folders"
    mkdir -p wotlk/etc wotlk/logs
    restore_azeroth_ownership
    log_info "Prepared AzerothCore folders with UID:GID ${DOCKER_USER_ID}:${DOCKER_GROUP_ID}."
}

function docker_compose_in_project() {
    (
        cd azerothcore-wotlk || exit 1
        docker compose "$@"
    )
}

function detect_primary_ip() {
    local detected_ip

    if command -v ip &> /dev/null; then
        detected_ip=$(ip route get 1.1.1.1 2> /dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [ -z "$detected_ip" ]; then
        detected_ip=$(hostname -i 2> /dev/null | awk '{print $1}')
    fi

    if [ -z "$detected_ip" ] && command -v getent &> /dev/null; then
        detected_ip=$(getent ahostsv4 "$(hostname)" 2> /dev/null | awk 'NR==1 {print $1}')
    fi

    if [ -z "$detected_ip" ]; then
        log_error "Unable to determine the host IP address automatically."
        exit 1
    fi

    echo "$detected_ip"
}

function wait_for_mysql() {
    local max_attempts=60
    local attempt=1

    log_step "Waiting for MySQL"

    until docker_compose_in_project exec -T -e MYSQL_PWD="$DOCKER_DB_ROOT_PASSWORD" ac-database mysql -h 127.0.0.1 -uroot -e "SELECT 1" &> /dev/null; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            log_error "Timed out waiting for MySQL inside the ac-database container."
            log_info "Current container status:"
            docker_compose_in_project ps || true
            log_info "Recent ac-database logs:"
            docker_compose_in_project logs --tail=50 ac-database || true
            exit 1
        fi

        log_info "MySQL is not ready yet. Retrying in 5 seconds (${attempt}/${max_attempts})."
        sleep 5
        attempt=$((attempt + 1))
    done

    log_info "MySQL is available."
}

function print_post_install_summary() {
    echo ""
    echo "Setup complete."
    echo "Server IP for your WoW client: $ip_address"
    echo "Set your client realmlist.wtf to: set realmlist $ip_address"
    echo "Config files are available in the wotlk folder."

    if ask_user "Attach to the worldserver console now to create your first account?"; then
        echo "Use these commands once attached:"
        echo "account create <username> <password>"
        echo "account set gmlevel <username> 3 -1"
        echo "Detach with Ctrl+p followed by Ctrl+q when you are done."
        docker attach ac-worldserver
    fi
}

require_sudo_invocation
load_os_release
require_supported_distro
update_env_timezone
load_setup_env
install_mysql_client
install_docker
ensure_docker_access
prepare_host_directories

# Check if Azeroth Core is installed
if [ -d "azerothcore-wotlk" ]; then
    log_step "Refreshing existing AzerothCore checkout"
    destination_dir="data/sql/custom"
    
    world=$destination_dir"/db_world/"
    chars=$destination_dir"/db_characters/"
    auth=$destination_dir"/db_auth/"
    
    cd azerothcore-wotlk
    
    rm -rf $world/*.sql
    rm -rf $chars/*.sql
    rm -rf $auth/*.sql
    
    cd ..
    
    copy_project_runtime_files
    restore_azeroth_ownership
    cd azerothcore-wotlk
else
    if ask_user "Download and install AzerothCore Playerbots?"; then
        log_step "Cloning AzerothCore Playerbots"
        git clone https://github.com/liyunfan1223/azerothcore-wotlk.git --branch=Playerbot
        copy_project_runtime_files
        cd azerothcore-wotlk/modules
        log_info "Cloning mod-playerbots."
        git clone https://github.com/liyunfan1223/mod-playerbots.git --branch=master
        cd ..
        restore_azeroth_ownership
    else
        log_warn "Aborting."
        exit 1
    fi
fi

if ask_user "Install modules?"; then
    log_step "Installing optional modules"

    cd modules
    install_optional_modules_from_catalog ../../src/module-repos.txt
    cd ..

fi

log_step "Building and starting Docker containers"
docker compose up -d --build

cd ..

prepare_host_directories
sync_config_templates
apply_module_specific_config
restore_azeroth_ownership

if [ "${SYNCED_CONFIG_COUNT:-0}" -gt 0 ] || [ "${MODULE_CONFIG_UPDATED:-0}" -gt 0 ]; then
    log_step "Restarting containers to pick up newly created config files"
    docker_compose_in_project restart ac-authserver ac-worldserver
fi

# Directory for custom SQL files
custom_sql_dir="src/sql"
auth="acore_auth"
world="acore_world"
chars="acore_characters"

log_step "Detecting host IP address"
ip_address=$(detect_primary_ip)
log_info "Detected host IP address: $ip_address"
wait_for_mysql

# Temporary SQL file
temp_sql_file="/tmp/temp_custom_sql.sql"

# Function to execute SQL files with IP replacement
function execute_sql() {
    local db_name=$1
    local sql_files=("$custom_sql_dir/$db_name"/*.sql)

    if [ -e "${sql_files[0]}" ]; then
        for custom_sql_file in "${sql_files[@]}"; do
            echo "Executing $custom_sql_file"
            temp_sql_file=$(mktemp)
            if [[ "$(basename "$custom_sql_file")" == "update_realmlist.sql" ]]; then
                sed -e "s/{{IP_ADDRESS}}/$ip_address/g" "$custom_sql_file" > "$temp_sql_file"
            else
                cp "$custom_sql_file" "$temp_sql_file"
            fi
            docker_compose_in_project exec -T -e MYSQL_PWD="$DOCKER_DB_ROOT_PASSWORD" ac-database mysql -h 127.0.0.1 -uroot "$db_name" < "$temp_sql_file"
        done
    else
        echo "No SQL files found in $custom_sql_dir/$db_name, skipping..."
    fi
}

# Run custom SQL files
log_step "Running custom SQL files"
execute_sql "$auth"
execute_sql "$world"
execute_sql "$chars"

# Clean up temporary file
rm "$temp_sql_file"
restore_azeroth_ownership

print_post_install_summary
