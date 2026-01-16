#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# Configuration variables
DIRECTION=""
NUMBER="1"
PG_HOST=
PG_PORT=
PG_DBNAME=
PG_USERNAME=
SKIP_TESTS=false
IS_QUIET=false

HELP_TEXT="Execute PostgreSQL migration scripts in sequential order.

Usage: $(basename "$0") [options]

Options:
  -h, --help              Show this help text and exit
  -u, --up [NUM]          Migrate up NUM versions (default: $NUMBER, accepts 'all')
  -d, --down [NUM]        Migrate down NUM versions (default: $NUMBER, accepts 'all')
  -H, --host HOST         PostgreSQL host
  -p, --port PORT         PostgreSQL port
  -D, --dbname DBNAME     PostgreSQL database name
  -U, --username USER     PostgreSQL username
  -s, --skip-tests        Skip execution of test scripts
  -q, --quiet             Enable quiet mode
"

# Parse command-line options
TEMP=$(getopt -o hu::d::H:p:D:U:sq --long help,up::,down::,host:,port:,dbname:,username:,skip-tests,quiet -n "$(basename "$0")" -- "$@")
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi
eval set -- "$TEMP"

while true; do
   case "$1" in
      -h | --help )        echo "$HELP_TEXT"; exit 0 ;;
      -u | --up )
         DIRECTION="up"
         if [ -n "$2" ] && [ "$2" != "--" ]; then
            NUMBER="$2"
         fi
         shift 2 ;;
      -d | --down )
         DIRECTION="down"
         if [ -n "$2" ] && [ "$2" != "--" ]; then
            NUMBER="$2"
         fi
         shift 2 ;;
      -H | --host )        PG_HOST="$2"; shift 2 ;;
      -p | --port )        PG_PORT="$2"; shift 2 ;;
      -D | --dbname )      PG_DBNAME="$2"; shift 2 ;;
      -U | --username )    PG_USERNAME="$2"; shift 2 ;;
      -s | --skip-tests )  SKIP_TESTS=true; shift ;;
      -q | --quiet )       IS_QUIET=true; shift ;;
      -- )                 shift; break ;;
      * )                  break ;;
   esac
done

# Handle remaining positional argument (for --up all / --down all with space)
if [ -n "$1" ] && ([ "$1" = "all" ] || [[ "$1" =~ ^[0-9]+$ ]]); then
   NUMBER="$1"
fi

# Build database client command options
DB_HOST_OPT=
DB_PORT_OPT=
DB_DBNAME_OPT=
DB_USERNAME_OPT=

if [ "x$PG_HOST" != "x" ]; then
   DB_HOST_OPT="-h $PG_HOST"
fi
if [ "x$PG_PORT" != "x" ]; then
   DB_PORT_OPT="-p $PG_PORT"
fi
if [ "x$PG_DBNAME" != "x" ]; then
   DB_DBNAME_OPT="-d $PG_DBNAME"
fi
if [ "x$PG_USERNAME" != "x" ]; then
   DB_USERNAME_OPT="-U $PG_USERNAME"
fi

# Construct full database client command
DB_CLIENT="psql"
DB_CMD="$DB_CLIENT $DB_HOST_OPT $DB_PORT_OPT $DB_USERNAME_OPT $DB_DBNAME_OPT"

if ! $IS_QUIET; then
   echo "DIRECTION:$DIRECTION"
   echo "NUMBER:$NUMBER"
   echo "PG_HOST:$PG_HOST"
   echo "PG_PORT:$PG_PORT"
   echo "PG_DBNAME:$PG_DBNAME"
   echo "PG_USERNAME:$PG_USERNAME"
   echo "SKIP_TESTS:$SKIP_TESTS"
   echo "IS_QUIET:$IS_QUIET"
   echo "DB_HOST_OPT:$DB_HOST_OPT"
   echo "DB_PORT_OPT:$DB_PORT_OPT"
   echo "DB_DBNAME_OPT:$DB_DBNAME_OPT"
   echo "DB_USERNAME_OPT:$DB_USERNAME_OPT"
   echo "DB_CLIENT:$DB_CLIENT"
   echo "DB_CMD:$DB_CMD"
fi

# Validate number
if [ "$NUMBER" != "all" ]; then
   if ! [[ "$NUMBER" =~ ^[0-9]+$ ]] || [ "$NUMBER" -lt 1 ]; then
      echo "Error: Number must be a positive integer or 'all'; got $NUMBER" >&2
      exit 1
   fi
fi

# Get sorted list of migration files
# Support both padded (01_, 02_) and non-padded (1_, 2_) version prefixes
if [ "$DIRECTION" = "up" ]; then
   MIGRATION_FILES=($(ls -1 [0-9]*_*.up.sql 2>/dev/null))
else
   MIGRATION_FILES=($(ls -1 [0-9]*_*.down.sql 2>/dev/null))
fi

if [ ${#MIGRATION_FILES[@]} -eq 0 ]; then
   echo "Error: No migration files found in current directory" >&2
   exit 1
fi

# Sort files by numeric version (handles both 1_ and 01_ formats)
# Create associative array: version -> filename
declare -A VERSION_MAP
for FILE in "${MIGRATION_FILES[@]}"; do
   # Extract version number (handles 1_, 01_, 001_, etc.)
   # NOTE keep this assignment strictly integer to prevent SQL injection
   FILE_VERSION=$(echo "$FILE" | grep -o "^[0-9]\+" | sed 's/^0*//')
   if [ -z "$FILE_VERSION" ]; then
      FILE_VERSION=0
   fi
   VERSION_MAP[$FILE_VERSION]="$FILE"
done

# Get sorted version numbers
SORTED_VERSIONS=($(printf '%s\n' "${!VERSION_MAP[@]}" | sort -n))

# Build sorted file list
MIGRATION_FILES=()
if [ "$DIRECTION" = "up" ]; then
   # Ascending order for up migrations
   for VERSION in "${SORTED_VERSIONS[@]}"; do
      MIGRATION_FILES+=("${VERSION_MAP[$VERSION]}")
   done
else
   # Descending order for down migrations
   for ((i=${#SORTED_VERSIONS[@]}-1; i>=0; i--)); do
      MIGRATION_FILES+=("${VERSION_MAP[${SORTED_VERSIONS[$i]}]}")
   done
fi

# Function to get and print current migration version and dirty state;
get_version_state() {
   local VERSION_STATE_QUERY="SELECT version, dirty FROM pgstream.schema_migrations ORDER BY version DESC LIMIT 1"
   local VERSION_STATE=$($DB_CMD -t -c "$VERSION_STATE_QUERY" 2>/dev/null)

   # Parse the result (format: "version | t" or "version | f")
   CURRENT_VERSION=$(echo "$VERSION_STATE" | awk '{print $1}' | tr -d ' ')
   IS_DIRTY=$(echo "$VERSION_STATE" | awk '{print $3}' | tr -d ' ')

   # Validate and set defaults
   if [ -z "$CURRENT_VERSION" ] || ! [[ "$CURRENT_VERSION" =~ ^-?[0-9]+$ ]]; then
      # Table doesn't exist yet or is empty
      CURRENT_VERSION=-1
      IS_DIRTY="false"
   fi

   # Normalize IS_DIRTY to "true" or "false"
   if [ "$IS_DIRTY" = "t" ]; then
      IS_DIRTY="true"
   else
      IS_DIRTY="false"
   fi
   echo "Database version: $CURRENT_VERSION"
   echo "Dirty: $IS_DIRTY"
}

# Get initial version state
get_version_state

# If no direction specified, just show version and exit
if [ -z "$DIRECTION" ]; then
   exit 0
fi

# Check if database is in dirty state (block migrations)
if [ "$IS_DIRTY" = "true" ]; then
   echo "Error: Database is in dirty state at version $CURRENT_VERSION" >&2
   echo "A previous migration failed and left the database in an inconsistent state." >&2
   echo "" >&2
   echo "To fix this:" >&2
   echo "  1. Manually inspect and fix any database issues from the failed migration" >&2
   echo "  2. Clear the dirty flag with:" >&2
   echo "     UPDATE pgstream.schema_migrations SET dirty = false WHERE version = $CURRENT_VERSION;" >&2
   echo "  3. Re-run migrations" >&2
   exit 1
fi

if ! $IS_QUIET; then
   echo "Current database version: $CURRENT_VERSION"
fi

# Filter migration files based on current version and direction
FILTERED_FILES=()
if [ "$DIRECTION" = "up" ]; then
   # For up migrations, only include files with version > current version
   for MIGRATION_FILE in "${MIGRATION_FILES[@]}"; do
      # NOTE keep this assignment strictly integer to prevent SQL injection
      FILE_VERSION=$(echo "$MIGRATION_FILE" | grep -o "^[0-9]\+" | sed 's/^0*//')
      if [ -z "$FILE_VERSION" ]; then
         FILE_VERSION=0
      fi
      if [ $FILE_VERSION -gt $CURRENT_VERSION ]; then
         FILTERED_FILES+=("$MIGRATION_FILE")
      fi
   done
else
   # For down migrations, only include files with version <= current version
   for MIGRATION_FILE in "${MIGRATION_FILES[@]}"; do
      # NOTE keep this assignment strictly integer to prevent SQL injection
      FILE_VERSION=$(echo "$MIGRATION_FILE" | grep -o "^[0-9]\+" | sed 's/^0*//')
      if [ -z "$FILE_VERSION" ]; then
         FILE_VERSION=0
      fi
      if [ $FILE_VERSION -le $CURRENT_VERSION ]; then
         FILTERED_FILES+=("$MIGRATION_FILE")
      fi
   done
fi

MIGRATION_FILES=("${FILTERED_FILES[@]}")

if [ ${#MIGRATION_FILES[@]} -eq 0 ]; then
   if ! $IS_QUIET; then
      echo "No pending migrations to execute"
   fi
   exit 0
fi

# Determine how many migrations to execute
if [ "$NUMBER" = "all" ]; then
   COUNT=${#MIGRATION_FILES[@]}
else
   COUNT=$NUMBER
   if [ $COUNT -gt ${#MIGRATION_FILES[@]} ]; then
      COUNT=${#MIGRATION_FILES[@]}
   fi
fi

# Execute migrations
EXECUTED=0
for ((i=0; i<$COUNT; i++)); do
   MIGRATION_FILE="${MIGRATION_FILES[$i]}"

   if ! $IS_QUIET; then
      echo "Executing: $MIGRATION_FILE"
   fi

   # Extract version number from filename
   # NOTE keep this assignment strictly integer to prevent SQL injection
   FILE_VERSION=$(echo "$MIGRATION_FILE" | grep -o "^[0-9]\+" | sed 's/^0*//')
   if [ -z "$FILE_VERSION" ]; then
      FILE_VERSION=0
   fi

   # Set dirty flag to true before migration (safety mechanism)
   if [ "$DIRECTION" = "up" ]; then
      DIRTY_QUERY="BEGIN; DELETE FROM pgstream.schema_migrations; INSERT INTO pgstream.schema_migrations (version, dirty) VALUES ($FILE_VERSION, true); COMMIT;"
   else
      # For down migration, mark the version we're rolling back from as dirty
      DIRTY_QUERY="BEGIN; DELETE FROM pgstream.schema_migrations; INSERT INTO pgstream.schema_migrations (version, dirty) VALUES ($FILE_VERSION, true); COMMIT;"
   fi
   $DB_CMD -c "$DIRTY_QUERY" > /dev/null 2>&1

   # Execute migration
   $DB_CMD -f "$MIGRATION_FILE" -v ON_ERROR_STOP=1
   MIGRATION_EXIT_CODE=$?

   if [ $MIGRATION_EXIT_CODE -ne 0 ]; then
      echo "Error: Migration failed: $MIGRATION_FILE" >&2
      echo "Database is now in dirty state (version $FILE_VERSION, dirty=true)" >&2
      echo "Fix the issue and either:" >&2
      echo "  1. Manually set dirty=false: UPDATE pgstream.schema_migrations SET dirty=false WHERE version=$FILE_VERSION;" >&2
      echo "  2. Re-run this migration script after fixing the problem" >&2
      exit 1
   fi

   # Clear dirty flag after successful migration
   if [ "$DIRECTION" = "up" ]; then
      # Set version to current, dirty to false
      CLEAN_QUERY="UPDATE pgstream.schema_migrations SET dirty = false WHERE version = $FILE_VERSION;"
   else
      # For down migration, set version to previous migration (FILE_VERSION - 1)
      PREV_VERSION=$((FILE_VERSION - 1))
      if [ $PREV_VERSION -lt 0 ]; then
         # If going below 0, remove all entries
         CLEAN_QUERY="DELETE FROM pgstream.schema_migrations;"
      else
         CLEAN_QUERY="BEGIN; DELETE FROM pgstream.schema_migrations; INSERT INTO pgstream.schema_migrations (version, dirty) VALUES ($PREV_VERSION, false); COMMIT;"
      fi
   fi
   $DB_CMD -c "$CLEAN_QUERY" > /dev/null 2>&1

   EXECUTED=$((EXECUTED + 1))

   # Execute test script if not skipped
   if ! $SKIP_TESTS; then
      # Extract version number for test file lookup
      VERSION=$(echo "$MIGRATION_FILE" | grep -o "^[0-9]\+" | sed 's/^0*//')
      if [ -z "$VERSION" ]; then
         VERSION=0
      fi

      if [ "$DIRECTION" = "up" ]; then
         # Look for test file with same version (supports both padded and non-padded)
         TEST_FILE="${VERSION}_*.test.sql"
         # Also try zero-padded version
         PADDED_VERSION=$(printf "%02d" $VERSION)
         TEST_FILES=($(ls -1 ${VERSION}_*.test.sql ${PADDED_VERSION}_*.test.sql 2>/dev/null | head -1))
      else
         # For down migrations, test with (version - 1)
         PREV_VERSION=$((VERSION - 1))
         if [ $PREV_VERSION -ge 0 ]; then
            PADDED_PREV=$(printf "%02d" $PREV_VERSION)
            TEST_FILES=($(ls -1 ${PREV_VERSION}_*.test.sql ${PADDED_PREV}_*.test.sql 2>/dev/null | head -1))
         else
            TEST_FILES=()
         fi
      fi

      if [ ${#TEST_FILES[@]} -gt 0 ]; then
         TEST_FILE_PATH="${TEST_FILES[0]}"
         if ! $IS_QUIET; then
            echo "Executing: $TEST_FILE_PATH"
         fi

         $DB_CMD -f "$TEST_FILE_PATH" -v ON_ERROR_STOP=1
         if [ $? -ne 0 ]; then
            echo "Error: Test failed: $TEST_FILE_PATH" >&2
            exit 1
         fi
      fi
   fi
done

if ! $IS_QUIET; then
   echo "Successfully executed $EXECUTED migration(s) $DIRECTION"
fi

# Re-query and display final version state
get_version_state
