# AzerothCore with Playerbots Docker Setup

This repository is an updated continuation of the original [`coc0nut/AzerothCore-with-Playerbots-Docker-Setup`](https://github.com/coc0nut/AzerothCore-with-Playerbots-Docker-Setup). That project provided a helpful starting point, but it has not been actively maintained for a few years. This repo keeps the same goal, updates the install flow, and adds more automation so it is easier to deploy and maintain a Playerbots-based AzerothCore server today.

The goal of this project is simple: provide a turn-key way to stand up AzerothCore with Playerbots and a set of optional but useful modules, with as little manual Docker and config work as possible.

## What This Repository Does

This repository does not contain AzerothCore itself. Instead, it provides the scripts, Docker overrides, SQL helpers, and config workflow needed to:

- Install Docker if it is missing
- Clone the Playerbot AzerothCore branch
- Clone `mod-playerbots`
- Optionally clone additional modules from a shared module list
- Build and start the Docker services
- Create local host-side config folders under `wotlk/`
- Copy missing `*.conf.dist` templates to real `*.conf` files automatically
- Apply a few module-specific config requirements automatically
- Import this repo's custom SQL files
- Give you a repeatable way to reload modules later without reinstalling everything

## Recommended Environment

This project is intended to run on a Linux machine dedicated to AzerothCore.

Supported families:

- Debian-based systems
- Ubuntu-based systems
- Arch-based systems

Recommended setup:

- Use a clean VM or fresh Linux install
- Use the VM only for AzerothCore and related management
- Run the install and reload scripts with `sudo`
- Let the scripts restore AzerothCore file ownership back to the user who invoked them

Why a clean VM is recommended:

- Docker, database files, and world data can consume a lot of disk space
- It keeps your AzerothCore environment isolated from other software
- Troubleshooting is much easier when the machine only has one purpose
- File ownership and Docker permission issues are much less common on a clean system

## Included Modules

The install flow always pulls:

- [AzerothCore Playerbot branch](https://github.com/liyunfan1223/azerothcore-wotlk.git)
- [mod-playerbots](https://github.com/liyunfan1223/mod-playerbots)

Optional modules are managed through `src/module-repos.txt`:

- `mod-aoe-loot`
- `mod-learn-spells`
- `mod-fireworks-on-level`
- `mod-individual-progression`
- `mod-npc-enchanter`
- `mod-assistant`
- `mod-quest-loot-party`

You can add more modules later by editing `src/module-repos.txt` and running `sudo ./reload_modules.sh`.

## Folder Layout

After installation, the important folders are:

- `azerothcore-wotlk/`
  This is the cloned AzerothCore Docker project and module source tree.
- `wotlk/etc/`
  This is your host-side live config directory. Edit configs here, not inside the containers.
- `wotlk/etc/modules/`
  This is where module config files live on the host.
- `wotlk/logs/`
  This stores host-side logs from the Docker setup.
- `src/sql/`
  This repository's custom SQL files that are imported by `setup.sh`.

Important note:

- `*.conf.dist` files are templates
- `*.conf` files are the real active configs
- The scripts will create missing `.conf` files from `.conf.dist`, but they will not overwrite existing real configs

## First-Time Installation

Clone the repository and run the installer:

```bash
git clone https://github.com/abcgxp/AzerothCore-with-Playerbots-Docker-Setup.git
cd AzerothCore-with-Playerbots-Docker-Setup
chmod +x *.sh
sudo ./setup.sh
```

The installer will:

1. Detect your Linux distribution
2. Detect your timezone
3. Install the MySQL client if needed
4. Install Docker if needed
5. Make sure Docker is actually usable
6. Create `wotlk/etc` and `wotlk/logs`
7. Clone AzerothCore Playerbots if it is not already present
8. Ask whether you want to install optional modules
9. Build and start the Docker services
10. Wait for MySQL inside the database container
11. Copy missing config templates into real config files
12. Apply required config changes for some modules
13. Run this repo's custom SQL
14. Print the server IP and offer to attach you to the worldserver console

## How the Scripts Work

### `setup.sh`

Use this for the first install, or when you want to refresh the main project without deleting everything.

What it does:

- Handles Docker and MySQL client installation
- Clones AzerothCore Playerbots if missing
- Clones `mod-playerbots`
- Optionally clones extra modules from `src/module-repos.txt`
- Builds and starts the Docker stack
- Copies missing config templates into active config files
- Imports custom SQL
- Updates the realm IP in the auth database

Use it when:

- You are installing for the first time
- You deleted `azerothcore-wotlk/`
- You want to rebuild from the current repo state

### `reload_modules.sh`

Use this when the server is already installed and you want to pull in newly added modules from the shared module list without rerunning the full first-time install flow.

What it does:

- Refreshes runtime Docker files
- Reads `src/module-repos.txt`
- Clones any listed modules that are not already present
- Rebuilds the Docker services
- Copies missing `*.conf.dist` files into real `*.conf` files
- Applies module-specific config requirements
- Restarts the world/auth services if config changes were made

Use it when:

- You added new module entries to `src/module-repos.txt`
- You pulled a newer version of this repository and want any new optional modules
- You want to rebuild after changing the shared module catalog

### `start_stop_acore.sh`

This is a simple toggle script for the three main containers:

- `ac-worldserver`
- `ac-authserver`
- `ac-database`

If they are running, it stops them. If they are stopped, it starts them.

### `sqldump.sh`

Use this to create database backups or recover them later.

What it supports:

- Backup of `acore_auth`
- Backup of `acore_characters`
- Backup of `acore_world`
- Backup of `acore_playerbots`
- Recovery from a dated SQL dump

It stores backups under:

- `sql_dumps/acore_auth/`
- `sql_dumps/acore_characters/`
- `sql_dumps/acore_world/`
- `sql_dumps/acore_playerbots/`

### `clear_custom_sql.sh`

Use this if you want to remove the custom SQL files copied into the AzerothCore Docker project.

This is helpful when:

- You removed a module
- You want to stop reapplying old custom SQL
- You want a cleaner rebuild before rerunning setup

### `uninstall.sh`

Use this to tear the project down.

What it does:

- Stops the Docker Compose project
- Prunes Docker images
- Optionally removes the Docker volumes
- Deletes `azerothcore-wotlk/`
- Clears `wotlk/*`

If you keep the volumes, a later reinstall behaves more like an update than a fresh start.

## Config Workflow

This repository is designed so you can edit configs on the host instead of inside containers.

Main server configs:

- `wotlk/etc/worldserver.conf`
- `wotlk/etc/authserver.conf`
- `wotlk/etc/dbimport.conf`

Module configs:

- `wotlk/etc/modules/*.conf`

How config files appear:

1. The Docker project or modules provide `*.conf.dist` template files
2. The scripts check `wotlk/etc` and `wotlk/etc/modules`
3. If a real `.conf` file does not exist yet, the script copies the `.conf.dist` file to `.conf`
4. If a real `.conf` file already exists, it is left alone

That means you can safely edit your host-side `.conf` files and rerun the scripts without losing those changes.

## Module-Specific Behavior

### `mod-individual-progression`

This module requires two `worldserver.conf` settings to function correctly:

- `EnablePlayerSettings = 1`
- `DBC.EnforceItemAttributes = 0`

If `mod-individual-progression` is present, `setup.sh` and `reload_modules.sh` will ensure those values are set in:

- `wotlk/etc/worldserver.conf`

## Updating Later

There are two common update paths.

### Pull in newly added modules

If this repository's module list changes later, run:

```bash
sudo ./reload_modules.sh
```

This is the preferred way to pick up new optional modules added after your original install.

### Rebuild the whole stack without deleting volumes

If you want to update the environment more broadly:

1. Run `./uninstall.sh`
2. When asked whether to delete volumes, choose `n`
3. Run `sudo ./setup.sh` again

That keeps your data volumes and behaves more like an update/rebuild.

## Post-Installation Steps

When installation finishes, you still need to do a few normal AzerothCore tasks.

### 1. Attach to the worldserver console

If you did not let `setup.sh` attach automatically, run:

```bash
docker attach ac-worldserver
```

### 2. Create an account

Inside the worldserver console:

```text
.account create your-username your-password
.account set gmlevel your-username 3 -1
```

Detach from the console without stopping the server:

```text
Ctrl+p, then Ctrl+q
```

### 3. Update your WoW client realmlist

Edit your `realmlist.wtf` and set it to the server IP printed by `setup.sh`:

```text
set realmlist your_server_ip
```

### 4. Confirm server ports

By default, the Docker stack publishes the standard ports used by auth/world services. If clients cannot connect, check:

```bash
cd azerothcore-wotlk
docker compose ps
```

## Basic Day-2 Operations

Start or stop the server:

```bash
./start_stop_acore.sh
```

Reload newly added modules:

```bash
./reload_modules.sh
```

Backup the databases:

```bash
./sqldump.sh
```

Remove custom SQL files from the Docker project:

```bash
./clear_custom_sql.sh
```

Uninstall:

```bash
./uninstall.sh
```

## Troubleshooting Notes

### Docker permission issues

Run `setup.sh` and `reload_modules.sh` with `sudo`. If Docker says your user cannot access the daemon outside those scripts, log out and back in after being added to the `docker` group.

### MySQL wait timeout

The scripts now check MySQL from inside the `ac-database` container instead of relying on the host LAN IP. If MySQL still times out, inspect:

```bash
cd azerothcore-wotlk
docker compose ps
docker compose logs --tail=100 ac-database
```

### Missing module config warnings

If you see warnings like `Missing property ...`, it usually means the module is installed but its active `.conf` file did not exist yet or a required setting was not present. The config template sync in `setup.sh` and `reload_modules.sh` is meant to reduce that problem significantly.

### Line ending issues after copying from Windows

If Linux shows errors involving `$'\r'`, the files were copied with Windows line endings. Re-clone on Linux or normalize line endings before running the scripts.

## Reference

- [AzerothCore Home](https://www.azerothcore.org/wiki/home)
- [AzerothCore Docker Guide](https://www.azerothcore.org/wiki/install-with-docker)
- [AzerothCore Module Installation Guide](https://www.azerothcore.org/wiki/installing-a-module)
