#!/usr/bin/env bash
#
# create_app_dataset.sh
#
# A helper for TrueNAS SCALE (Electric Eel+) that
# creates a parent dataset + optional children under the “Apps”
# preset and sets sane NFSv4 ACLs for host-path Docker/K8s apps.
#
# IMPORTANT: This script requires root privileges to execute midclt
# commands and set file ownership/permissions. Please run it with 'sudo'.
#
# FEATURES
# --------
# • Uses the middleware CLI (`midclt`), not bare `zfs`.
# • Idempotent – re-runs safely skip dataset *creation* if they already exist.
# • By default, ACLs/ownership are only applied to *newly created* datasets.
#   Use `--force-acl` to re-apply ACLs to existing datasets.
# • `--dry-run` previews JSON payloads without touching your system,
#   accurately reflecting whether ACLs would be applied or skipped.
# • Optional `--encrypt` will:
#   - create the main app dataset as a new ZFS encryption root
#   - create child datasets inheriting that encryption
#   - use AES-256-GCM with an auto-generated key stored by TrueNAS for unlock.
# • Configurable ZFS pool and root dataset via flags **or** a one-time dot-file.
# • The configuration dot-file (.create_app_dataset.conf) is created/read
#   in the *same directory* as the script itself.
# • Dependency check for `jq`.
# • Colorful, readable log output.
#
# USAGE
# -----
#   sudo ./create_app_dataset.sh [options] <app_name> [child1 child2 …]
#
# Options
#   -p, --pool  <name>    ZFS pool (overrides default / config file)
#   -r, --root  <name>    Parent dataset root (e.g. appdata)
#   -f, --force-acl       Force application of ACLs and ownership,
#                         even if datasets already exist.
#   -e, --encrypt         Create <app_name> as a new encrypted dataset
#                         (AES-256-GCM, auto-generated key). Child datasets
#                         will inherit encryption.
#   --dry-run             Show what would happen, make no changes
#   -h, --help            Print this help and exit
#
# Example
#   sudo ./create_app_dataset.sh immich config data upload
#   ⇒ Creates (or ensures):
#     Pool/apps-config/immich
#     Pool/apps-config/immich/config
#     Pool/apps-config/immich/data
#     Pool/apps-config/immich/upload
#   The script will remember "Pool" as your pool name and "apps-config" as your root dataset for future runs.
#
# Example (re-applying ACLs to existing datasets):
#   sudo ./create_app_dataset.sh --force-acl immich config data upload
#
# Example (encrypted app tree):
#   sudo ./create_app_dataset.sh --encrypt immich config data upload
#   ⇒ Pool/apps-config/immich is an encryption root with its own key,
#      children inherit that encryption.
#
# ENCRYPTION NOTES
# ----------------
# • `--encrypt` only applies when creating the <app_name> dataset itself.
#   - That dataset is created with `"encryption": true` and
#     `"encryption_options": {"generate_key": true, "algorithm": "AES-256-GCM"}`.
#   - Children are created with `"inherit_encryption": true`.
# • If the parent dataset already exists (and maybe is already encrypted),
#   we will skip creation and therefore skip setting encryption on it again.
# • If you later add NEW child datasets under an encrypted parent,
#   you should also pass `--encrypt` so those children get `"inherit_encryption": true`.
#
# CONFIG FILE
# -----------
# This script uses a configuration file to save your preferred ZFS Pool and
# Parent Dataset Root. By default, it's located in the *same directory* as
# this script, e.g., /path/to/script/.create_app_dataset.conf
#
# Example content of the config file:
#   POOL_NAME="Pool"
#   PARENT_DATASET_ROOT="apps-config"
#
# -------------------------------------------------------------

set -euo pipefail

# ---------- Color helpers ----------
RED='\033[0;31m'    # For errors
GREEN='\033[0;32m'  # For success messages
YELLOW='\033[0;33m' # For warnings and dry-run messages
CYAN='\033[0;36m'   # For general informational messages
NC='\033[0m'        # No Color (resets to default)

log_info()    { printf '%b%s%b\n'  "$CYAN" "$*" "$NC"; }
log_warn()    { printf '%bWARNING:%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error()   { printf '%bERROR:%b   %s\n' "$RED" "$NC" "$*" >&2; }
log_success() { printf '%b%s%b\n'  "$GREEN" "$*" "$NC"; }
log_dryrun()  { printf '%bDRY RUN:%b %s\n' "$YELLOW" "$NC" "$*"; }

# ---------- Defaults ----------
# Default values for ZFS pool and root dataset. These can be overridden by
# the configuration file or command-line arguments.
POOL_NAME="Pool"
PARENT_DATASET_ROOT="apps-config"

# TrueNAS SCALE default user/group for applications. These are hardcoded as
# TrueNAS SCALE typically ensures their existence.
APPS_USER="apps"
APPS_GROUP="apps"

# Determine the script's directory at runtime. This allows the config file
# to reside alongside the script, regardless of where it's executed from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Configuration file to store persistent settings for POOL_NAME and PARENT_DATASET_ROOT.
# This file will be created/updated in the same directory as the script.
CONFIG_FILE="${SCRIPT_DIR}/.create_app_dataset.conf"

# --- Global Variables ---
DRY_RUN=false
FORCE_ACL=false # Flag to control ACL re-application on existing datasets
ENCRYPT_DATASETS=false  # Flag to enable ZFS encryption on datasets
CREATED_DATASETS=() # Keep track of datasets created in this run for potential cleanup
DRY_RUN_WOULD_CREATE_DATASETS=() # Tracks datasets that *would* be created in a dry run

# ---------- Helper Functions ----------

# Function to load configuration from file
load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        log_info "Loading configuration from ${CONFIG_FILE}..."
        # Read key=value pairs, export them as variables
        while IFS='=' read -r key value; do
            case "$key" in
                POOL_NAME) POOL_NAME="${value//\"/}" ;; # Remove quotes
                PARENT_DATASET_ROOT) PARENT_DATASET_ROOT="${value//\"/}" ;; # Remove quotes
            esac
        done < "${CONFIG_FILE}"
    else
        log_warn "Configuration file not found at ${CONFIG_FILE}. Using default values."
    fi
}

# Function to save current configuration to file
save_config() {
    log_info "Saving current configuration to ${CONFIG_FILE}..."
    {
        echo "POOL_NAME=\"${POOL_NAME}\""
        echo "PARENT_DATASET_ROOT=\"${PARENT_DATASET_ROOT}\""
    } > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}" # Restrict permissions for security
}

# Function to validate dataset names against ZFS naming conventions.
# ZFS dataset names can contain alphanumeric characters, underscores, hyphens, and periods.
validate_dataset_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid dataset name '$name'. ZFS dataset names can only contain alphanumeric characters, underscores, hyphens, and periods."
    exit 1
  fi
}

# Function to check if the specified ZFS pool exists.
# This check is crucial and runs even in dry-run mode.
check_pool_exists() {
  local pool_name="$1"
  log_info "Verifying if ZFS pool '${pool_name}' exists on TrueNAS..."

  # Check if the pool exists using midclt pool.query
  # jq -e '.[0]' ensures that it returns 0 (success) only if an element is found
  if ! midclt call pool.query '[["name", "=", "'"${pool_name}"'"]]' | jq -e '.[0]' &>/dev/null; then
    log_error "Error: ZFS Pool '${pool_name}' not found on your TrueNAS system."
    log_error "Please ensure the pool exists and is spelled correctly."
    exit 1
  fi
  log_success "ZFS Pool '${pool_name}' found."
}

# Function to check if a dataset exists using zfs list.
dataset_exists() {
  local ds="$1"
  zfs list -H -o name "${ds}" >/dev/null 2>&1
}

# Function to confirm the parent root dataset exists or prompt for creation.
# Now takes app_name as an argument for a more specific warning message.
confirm_parent_root_dataset() {
  local full_root_path="$1"
  local app_name_for_message="$2" # Argument for the app name

  log_info "Checking if parent root dataset '${full_root_path}' exists..."

  if ! dataset_exists "${full_root_path}"; then
    log_warn "Parent root dataset '${full_root_path}' not found."
    # Updated message to include the specific app name
    log_warn "If you proceed, TrueNAS will automatically create '${full_root_path}'"
    log_warn "with the 'Apps' preset properties as an intermediate dataset when creating '${full_root_path}/${app_name_for_message}'."

    if "${DRY_RUN}"; then
      log_dryrun "In dry-run mode, we would prompt for confirmation here."
      log_dryrun "Assuming 'yes' for dry-run purposes, but a real run would ask for explicit confirmation."
      log_info "Proceeding with dry run."
      return 0 # Allow dry run to continue
    fi

    printf "%bDo you want to proceed and allow creation of '${full_root_path}'? (y/N): %b" "$YELLOW" "$NC"
    read -r response
    response=${response,,} # Convert to lowercase
    if [[ "$response" != "y" ]]; then
      log_error "Operation cancelled by user. Parent root dataset not confirmed."
      exit 1
    fi
    log_success "User confirmed. Proceeding to create/ensure datasets."
  else
    log_success "Parent root dataset '${full_root_path}' found."
  fi
}


#
# build_create_payload
# --------------------
# Generates the JSON payload for `pool.dataset.create` with/without encryption.
#
# Args:
#   $1 = dataset_full_path (e.g. Pool/apps-config/immich[/config])
#   $2 = is_child ("true"/"false")
#
# Behavior:
#   - If ENCRYPT_DATASETS=false:
#         normal Apps preset, no encryption fields
#   - If ENCRYPT_DATASETS=true AND is_child=="false":
#         create new encryption root with its own key
#   - If ENCRYPT_DATASETS=true AND is_child=="true":
#         inherit encryption from parent
#
build_create_payload() {
    local dataset_full_path="$1"
    local is_child="$2"

    if "${ENCRYPT_DATASETS}"; then
        if [ "${is_child}" = "false" ]; then
            # Parent: new encryption root
            # Note: inherit_encryption must be explicitly false when creating a new encryption root
            cat <<EOF
{
  "name": "${dataset_full_path}",
  "type": "FILESYSTEM",
  "share_type": "APPS",
  "acltype": "NFSV4",
  "aclmode": "PASSTHROUGH",
  "inherit_encryption": false,
  "encryption": true,
  "encryption_options": {
    "generate_key": true,
    "algorithm": "AES-256-GCM"
  }
}
EOF
        else
            # Child: inherit encryption
            cat <<EOF
{
  "name": "${dataset_full_path}",
  "type": "FILESYSTEM",
  "share_type": "APPS",
  "acltype": "NFSV4",
  "aclmode": "PASSTHROUGH",
  "inherit_encryption": true
}
EOF
        fi
    else
        # No encryption
        cat <<EOF
{
  "name": "${dataset_full_path}",
  "type": "FILESYSTEM",
  "share_type": "APPS",
  "acltype": "NFSV4",
  "aclmode": "PASSTHROUGH"
}
EOF
    fi
}


# Function to create a dataset using TrueNAS middleware.
# It checks for existence before creation to ensure idempotence.
#
# Args:
#   $1 = dataset_full_path
#   $2 = is_child ("true"/"false")
#
create_dataset() {
  local dataset_full_path="$1"
  local is_child="$2"

  log_info "Checking if dataset ${dataset_full_path} already exists..."

  if dataset_exists "${dataset_full_path}"; then
    log_success "Dataset ${dataset_full_path} already exists. Skipping creation."
  else
    log_warn "Creating dataset ${dataset_full_path} with Apps preset..."
    local create_json_payload
    create_json_payload="$(build_create_payload "${dataset_full_path}" "${is_child}")"

    if ! "${DRY_RUN}"; then
      midclt call pool.dataset.create "${create_json_payload}"
      CREATED_DATASETS+=("${dataset_full_path}") # Add to list for potential cleanup
    else
      log_dryrun "Would create dataset ${dataset_full_path}."
      log_dryrun "Create JSON payload:"
      echo "${create_json_payload}" | jq .
      DRY_RUN_WOULD_CREATE_DATASETS+=("${dataset_full_path}")
    fi
  fi
}

# Function to apply NFSv4 ACLs and Unix ownership.
# It sets owner/group to 'apps:apps' and provides full control for the apps user.
apply_acl() {
  local dataset_full_path="$1"
  local mount_path="/mnt/${dataset_full_path}"
  local just_created_in_this_run=false
  local would_be_created_in_dry_run=false

  # Define acl_json here so it's available for both dry run and actual run
  local acl_json
  acl_json=$(cat <<EOF
{
  "path": "${mount_path}",
  "dacl": [
    {
      "tag": "OWNER@",
      "perms": {"BASIC": "FULL_CONTROL"},
      "flags": {"BASIC": "INHERIT"},
      "type": "ALLOW"
    },
    {
      "tag": "GROUP@",
      "perms": {"BASIC": "MODIFY"},
      "flags": {"BASIC": "INHERIT"},
      "type": "ALLOW"
    },
    {
      "tag": "GROUP",
      "id": "builtin_users",
      "perms": {"BASIC": "MODIFY"},
      "flags": {"BASIC": "INHERIT"},
      "type": "ALLOW"
    },
    {
      "tag": "GROUP",
      "id": "builtin_administrators",
      "perms": {"BASIC": "FULL_CONTROL"},
      "flags": {"BASIC": "INHERIT"},
      "type": "ALLOW"
    }
  ],
  "options": {
    "recursive": true,  # Apply ACLs recursively to existing files/directories within the path.
    "traverse": false,  # Only relevant for inherited ACLs when listing, not for setting directly.
    "stripacl": true    # IMPORTANT: Clear existing ACLs before applying new ones to prevent conflicts.
  }
}
EOF
) # The closing parenthesis for command substitution must be directly after EOF

  # Check if this dataset was just created in the current (actual) run
  if [[ " ${CREATED_DATASETS[*]} " =~ " ${dataset_full_path} " ]]; then
    just_created_in_this_run=true
  fi

  # Check if this dataset *would be* created in a dry run (if we are in dry run mode)
  if "${DRY_RUN}"; then
    if [[ " ${DRY_RUN_WOULD_CREATE_DATASETS[*]} " =~ " ${dataset_full_path} " ]]; then
      would_be_created_in_dry_run=true
    fi
  fi

  # --- Dry Run Logic ---
  if "${DRY_RUN}"; then
    if "${would_be_created_in_dry_run}"; then
      log_dryrun "Would apply ACL and chown ${APPS_USER}:${APPS_GROUP} to ${mount_path} (dataset would be newly created in this dry run)."
      log_dryrun "ACL JSON payload (note: this is a dry run; ACL would be applied):"
      printf '%s\n' "${acl_json}"
    elif "${FORCE_ACL}"; then
      log_dryrun "Would apply ACL and chown ${APPS_USER}:${APPS_GROUP} to ${mount_path} (dataset existed, --force-acl used)."
      log_dryrun "ACL JSON payload (note: this is a dry run; ACL would be applied):"
      printf '%s\n' "${acl_json}"
    else
      log_dryrun "Dataset ${dataset_full_path} already exists (on the real system) and --force-acl was not specified. Would skip ACL application."
    fi
    return # Exit dry run path
  fi

  # --- Actual Run Logic ---
  if "${just_created_in_this_run}"; then
    log_info "Applying ACL and Unix ownership to ${mount_path} (newly created dataset)..."
    # Proceed with midclt call and chown
  elif "${FORCE_ACL}"; then
    log_info "Applying ACL and Unix ownership to ${mount_path} (dataset existed, --force-acl used)..."
    # Proceed with midclt call and chown
  else
    log_info "Dataset ${dataset_full_path} already exists and --force-acl was not specified. Skipping ACL application."
    return # Skip ACL application
  fi

  # This part only executes if just_created_in_this_run or FORCE_ACL is true
  # Adding a small wait loop for the mount path to appear after dataset creation.
  # This addresses a potential (rare) race condition.
  for _ in {1..30}; do
    [[ -d "$mount_path" ]] && break;
    sleep 0.1;
  done
  if [[ ! -d "$mount_path" ]]; then
      log_error "Mount point ${mount_path} did not appear after dataset creation. Cannot apply ACLs."
      exit 1
  fi
  midclt call filesystem.setacl "${acl_json}"
  # Manually set Unix ownership for the UI's basic "Permissions" fields and general compatibility.
  # This aligns the dataset with the TrueNAS SCALE 'apps' user and 'apps' group.
  chown "${APPS_USER}:${APPS_GROUP}" "${mount_path}"
}

# Function to handle errors. Called by trap ERR.
cleanup_on_error() {
  echo "" >&2 # Add a newline for separation in error output
  log_error "Script failed."
  if [ ${#CREATED_DATASETS[@]} -gt 0 ]; then
    log_warn "Datasets potentially created in this run:"
    for ds in "${CREATED_DATASETS[@]}"; do
      echo -e "${RED}  - /mnt/${ds}${NC}" >&2
    done
    echo "" >&2
    log_warn "Please inspect these datasets in the TrueNAS UI or via 'zfs list' and manually clean up if necessary."
  else
    log_warn "No datasets were created by this script before the error occurred."
  fi
  exit 1 # Exit with a non-zero status to indicate failure
}

# Trap errors to call cleanup_on_error function.
trap cleanup_on_error ERR

# ---------- Main Execution ----------

# Early check: Ensure the script is run as root, as midclt and chown require elevated privileges.
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root or with 'sudo'."
    exit 1
fi

# Check for jq dependency first
if ! command -v jq >/dev/null 2>&1; then
    log_error "'jq' is required for this script to function. TrueNAS SCALE generally discourages installing packages directly on the host OS, as this can affect system stability and future upgrades."
    exit 1
fi

# Load previously saved configuration
load_config

# --- Argument Parsing (Revised as per ChatGPT's suggestion for flexibility) ---
DRY_RUN=false
FORCE_ACL=false
ENCRYPT_DATASETS=false
# Use temporary variables for pool/root overrides to avoid affecting config load until after parsing.
# The global POOL_NAME and PARENT_DATASET_ROOT are initially from load_config.
# These local overrides will take precedence if set by CLI.
local_pool_name_cli=""
local_parent_dataset_root_cli=""

positional_args_collected=()

while (($#)); do
  case "$1" in
    -p|--pool)
      shift # Consume the flag itself
      [[ $# -lt 1 ]] && { log_error "$1 needs an argument."; exit 1; }
      local_pool_name_cli="$1"; shift # Consume the argument for the flag's value
      ;;
    -r|--root)
      shift # Consume the flag itself
      [[ $# -lt 1 ]] && { log_error "$1 needs an argument."; exit 1; }
      local_parent_dataset_root_cli="$1"; shift # Consume the argument for the flag's value
      ;;
    -f|--force-acl)
      FORCE_ACL=true; shift ;;
    -e|--encrypt)
      ENCRYPT_DATASETS=true; shift ;;
    --dry-run)
      DRY_RUN=true;  shift ;;
    -h|--help)
      sed -n '/^# USAGE/,/^# CONFIG FILE/p' "$0" | sed '1d;$d;s/^# //'
      exit 0 ;;
    --) shift; break ;;            # explicit end-of-options marker
    -*) log_error "Unknown option: $1"; exit 1 ;; # Catch any other unknown flags
    *)  positional_args_collected+=("$1"); shift ;; # Collect positional arguments
  esac
done

# If there were any arguments left after a '--' (explicit end of options),
# they are also positional arguments. This covers cases like "script -- arg1 arg2"
positional_args_collected+=("$@")

# Re-set the script's positional parameters ($1, $2, etc.) to only
# contain the arguments that are indeed positional (app_name and children).
set -- "${positional_args_collected[@]}"
# --- End of Argument Parsing Block ---


# Apply CLI overrides if present. These take precedence over config file defaults.
if [ -n "${local_pool_name_cli}" ]; then
    POOL_NAME="${local_pool_name_cli}"
fi
if [ -n "${local_parent_dataset_root_cli}" ]; then
    PARENT_DATASET_ROOT="${local_parent_dataset_root_cli}"
fi


# Validate that POOL_NAME and PARENT_DATASET_ROOT are set (either by default, config, or CLI)
if [ -z "${POOL_NAME}" ] || [ -z "${PARENT_DATASET_ROOT}" ]; then
    log_error "ZFS Pool Name or Parent Dataset Root is not set."
    log_error "Please configure them in the script, in ${CONFIG_FILE}, or via -p/-r flags."
    exit 1
fi


# Validate input arguments (app_name and child datasets) *earlier*
if [ $# -lt 1 ]; then
  log_error "Missing <app_name> argument."
  # Adjusting sed command to get usage from new header
  sed -n '/^# USAGE/,/^# CONFIG FILE/p' "$0" | sed '1d;$d;s/^# //'
  exit 1
fi

PARENT_APP_NAME="$1"
validate_dataset_name "${PARENT_APP_NAME}"
shift
CHILD_DATASET_NAMES=("$@") # Optional sub-dataset names (e.g., config, data, logs)

for child in "${CHILD_DATASET_NAMES[@]}"; do
  validate_dataset_name "$child"
done


# --- PRE-FLIGHT CHECK: Verify Pool Existence ---
check_pool_exists "${POOL_NAME}"

# --- PRE-FLIGHT CHECK: Confirm Parent Root Dataset (with user interaction) ---
# Now passing PARENT_APP_NAME to confirm_parent_root_dataset
confirm_parent_root_dataset "${POOL_NAME}/${PARENT_DATASET_ROOT}" "${PARENT_APP_NAME}"

# Save the current configuration (CLI flags will override loaded ones if present)
# Check if the script's directory is writable before attempting to save the config file.
if [ ! -w "${SCRIPT_DIR}" ] && [ ! -f "${CONFIG_FILE}" ]; then
    log_warn "Script directory (${SCRIPT_DIR}) is not writable, and config file does not exist."
    log_warn "Configuration will NOT be saved persistently. You will need to use -p and -r flags"
    log_warn "or manually edit the default values in the script header for future runs."
elif [ ! -w "${SCRIPT_DIR}" ] && [ -f "${CONFIG_FILE}" ]; then
    log_warn "Script directory (${SCRIPT_DIR}) is not writable. Cannot update existing config file."
    log_warn "Changes from -p/-r flags will NOT be saved persistently."
else
    save_config
fi

# Explicitly ensure the PARENT_DATASET_ROOT exists if it was confirmed for creation.
# This fixes the [EINVAL] error where midclt needs intermediate parents to exist.
local_full_root_path="${POOL_NAME}/${PARENT_DATASET_ROOT}"
if ! dataset_exists "${local_full_root_path}"; then
    log_info "Creating missing parent root dataset '${local_full_root_path}' with Apps preset..."
    create_root_json_payload="{\"name\": \"${local_full_root_path}\", \"type\": \"FILESYSTEM\", \"share_type\": \"APPS\", \"acltype\": \"NFSV4\", \"aclmode\": \"PASSTHROUGH\"}"
    if ! "${DRY_RUN}"; then
        midclt call pool.dataset.create "${create_root_json_payload}"
        CREATED_DATASETS+=("${local_full_root_path}") # Track it for potential cleanup if subsequent steps fail
    else
        log_dryrun "Would create intermediate root dataset ${local_full_root_path}."
        log_dryrun "Root Create JSON payload:"
        echo "${create_root_json_payload}" | jq .
        DRY_RUN_WOULD_CREATE_DATASETS+=("${local_full_root_path}")
    fi
fi


if "${DRY_RUN}"; then
  log_dryrun "--- DRY RUN MODE ENABLED ---"
  log_dryrun "No changes will be made to your TrueNAS system."
  log_dryrun "Encryption requested? ${ENCRYPT_DATASETS}"
  log_dryrun "---------------------------"
fi


BASE_PATH="${POOL_NAME}/${PARENT_DATASET_ROOT}/${PARENT_APP_NAME}"

# 1) Create Parent Dataset (e.g., Pool/apps-config/parent)
#    is_child = "false" (this is where we may start a new encryption root if --encrypt)
create_dataset "${BASE_PATH}" "false"

# 2) Create Any Child Datasets
for child in "${CHILD_DATASET_NAMES[@]}"; do
  create_dataset "${BASE_PATH}/${child}" "true"
done

# 3) Apply ACL to Parent Dataset (conditionally)
apply_acl "${BASE_PATH}"

# 4) Apply ACL to each Child Dataset (conditionally)
for child in "${CHILD_DATASET_NAMES[@]}"; do
  apply_acl "${BASE_PATH}/${child}"
done

echo # Newline for separation
if "${DRY_RUN}"; then
  log_success "DRY RUN COMPLETE – no changes were made."
else
  log_success "All datasets created and configured."
fi
echo "Pool             : ${POOL_NAME}"
echo "Root dataset     : ${PARENT_DATASET_ROOT}"
echo "Parent dataset   : /mnt/${BASE_PATH}"
if [ ${#CHILD_DATASET_NAMES[@]} -gt 0 ]; then
  echo "Child datasets   : $(IFS=', '; echo "${CHILD_DATASET_NAMES[*]}")"
fi
echo "Encrypted root?  : ${ENCRYPT_DATASETS}"
echo "Ownership        : ${APPS_USER}:${APPS_GROUP}"
echo "(Tip: save defaults in ${CONFIG_FILE} or use -p/-r flags to configure.)"

exit 0