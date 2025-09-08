# env.sh - Environment Variable Loader for Project 4
# This script loads environment variables based on the specified environment.
# Usage: load_env <environment_name>
# Example: load_env dev

load_env() {
    local env_name="$1"
    local env_file="env/${env_name}"

    if [ -f "$env_file" ]; then
        # shellcheck source=/dev/null
        . "$env_file"
    else
        echo "Error: Environment file '$env_file' not found."
        exit 1
    fi

    export BACKUP_SRC
    export BACKUP_DEST
    export RETENTION_DAYS
    export LOG_LEVEL
}
