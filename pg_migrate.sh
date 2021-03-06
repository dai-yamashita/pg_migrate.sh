#!/bin/bash
#
# PostgreSQL schema migration manager
# https://github.com/zenwalker/pg_migrate.sh/tree/v2.0

set -e
[[ -f .env ]] && source .env

MIGRATIONS_DIR="migrations"
MIGRATIONS_TABLE="schema_version"

POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_HOST=${POSTGRES_HOST:-127.0.0.1}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
export PGPASSWORD="$POSTGRES_PASSWORD"

alias psql="psql -qtAX -v ON_ERROR_STOP=1 -U $POSTGRES_USER -h $POSTGRES_HOST -p $POSTGRES_PORT -d $POSTGRES_DB"
shopt -s expand_aliases

#######################################
# Makes sure schema_version table exists.
# Globals:
#   MIGRATIONS_TABLE
# Arguments:
#    None
# Outputs:
#   Log information
#######################################
create_migrations_table() {
    migrations_table_exists=`psql -c "SELECT to_regclass('$MIGRATIONS_TABLE');"`

    if  [[ ! $migrations_table_exists ]]; then
        echo "Creating $MIGRATIONS_TABLE table"
        psql -c "CREATE TABLE $MIGRATIONS_TABLE (version BIGINT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
    fi
}

#######################################
# Returs current schema version from the database.
# Globals
#   MIGRATIONS_TABLE
# Arguments:
#   None
# Outputs:
#   Current schema version
#######################################
get_current_version() {
    psql -c "SELECT COALESCE(MAX(version), 0) FROM $MIGRATIONS_TABLE;"
}

#######################################
# Extracts version number from filename.
# Arguments:
#   Filename (0001_create_table.sql)
# Outputs:
#   Version number (1)
#######################################
parse_version() {
    echo -n $1 | sed "s/^0*//" | sed "s/_.*//"
}

#######################################
# Returns latest version from migration files.
# Globals
#   MIGRATIONS_DIR
# Outputs:
#   A version number (1)
#######################################
get_latest_version() {
    cd "$MIGRATIONS_DIR"
    migration_files=`ls *.sql | sort -Vr`
    parse_version ${migration_files[0]}
}

#######################################
# Upgrades database schema to given version.
# Globals:
#   MIGRATIONS_DIR
#   MIGRATIONS_TABLE
# Arguments:
#   Current database schema version
#   Desired database schema version
# Outputs:
#   Log information
#######################################
upgrade() {
    current_version=$1
    target_version=$2

    cd "$MIGRATIONS_DIR"
    migration_files=`ls *.up.sql | sort -V`

    for file in $migration_files; do
        file_version=`parse_version $file`

        # Skip files that are already applied
        (( $file_version <= $current_version )) && continue

        # Stop when target version is reached
        (( $file_version > $target_version )) && break

        echo "Applying $file"
        psql < $file
        psql -c "INSERT INTO $MIGRATIONS_TABLE (version) VALUES ($file_version);"
    done
}

########################################
# Downgrades database schema to given version.
# Globals:
#   MIGRATIONS_DIR
#   MIGRATIONS_TABLE
# Arguments:
#   Current database schema version
#   Desired database schema version
# Outputs:
#   Log information
########################################
downgrade() {
    current_version=$1
    target_version=$2

    cd "$MIGRATIONS_DIR"
    migration_files=`ls *.down.sql | sort -Vr`

    for file in $migration_files; do
        file_version=`parse_version $file`

        # Skip files that have not been applied
        (( $file_version > $current_version )) && continue

        # Stop when target version is reached
        (( $file_version <= $target_version )) && break

        echo "Applying $file"
        psql < $file
        psql -c "DELETE FROM $MIGRATIONS_TABLE WHERE version = $file_version;"
    done
}

########################################
# Decides which action to perform.
# Arguments:
#   Target database version to upgrade or downgrade
# Outputs:
#   Execution log
########################################
main() {
    create_migrations_table

    current_version=`get_current_version`
    echo "Current schema version: $current_version"

    latest_version=`get_latest_version`
    target_version=${1:-$latest_version}

    if (( $target_version > $current_version )); then
        echo "Upgrading to: $target_version"
        echo "-----------------------------"
        upgrade $current_version $target_version
    elif (( $target_version < $current_version)); then
        echo "Downgrading to: $target_version"
        echo "-------------------------------"
        downgrade $current_version $target_version
    else
        echo "Nothing to apply"
    fi
}

main "$@"
