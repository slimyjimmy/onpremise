#!/usr/bin/env bash
set -e

if [[ -n "$MSYSTEM" ]]; then
  echo "Seems like you are using an MSYS2-based system (such as Git Bash) which is not supported. Please use WSL instead.";
  exit 1
fi

# Thanks to https://unix.stackexchange.com/a/145654/108960
log_file="sentry_install_log-`date +'%Y-%m-%d_%H-%M-%S'`.txt"
exec &> >(tee -a "$log_file")
if [ "$GITHUB_ACTIONS" = "true" ]; then
  _group="::group::"
  _endgroup="::endgroup::"
else
  _group="▶ "
  _endgroup=""
fi

echo "${_group}Defining variables and helpers ..."
# Read .env for default values with a tip o' the hat to https://stackoverflow.com/a/59831605/90297
t=$(mktemp) && export -p > "$t" && set -a && . ./.env && set +a && . "$t" && rm "$t" && unset t

source ./install/docker-aliases.sh

MIN_DOCKER_VERSION='19.03.6'
MIN_COMPOSE_VERSION='1.24.1'
MIN_RAM_HARD=3800 # MB
MIN_RAM_SOFT=7800 # MB
MIN_CPU_HARD=2
MIN_CPU_SOFT=4

# Increase the default 10 second SIGTERM timeout
# to ensure celery queues are properly drained
# between upgrades as task signatures may change across
# versions
STOP_TIMEOUT=60 # seconds
SENTRY_CONFIG_PY='sentry/sentry.conf.py'
SENTRY_CONFIG_YML='sentry/config.yml'
SYMBOLICATOR_CONFIG_YML='symbolicator/config.yml'
RELAY_CONFIG_YML='relay/config.yml'
RELAY_CREDENTIALS_JSON='relay/credentials.json'
SENTRY_EXTRA_REQUIREMENTS='sentry/requirements.txt'
MINIMIZE_DOWNTIME=
echo $_endgroup

echo "${_group}Parsing command line ..."
show_help() {
  cat <<EOF
Usage: $0 [options]

Install Sentry with /usr/local/bin/docker-compose.

Options:
 -h, --help             Show this message and exit.
 --no-user-prompt       Skips the initial user creation prompt (ideal for non-interactive installs).
 --minimize-downtime    EXPERIMENTAL: try to keep accepting events for as long as possible while upgrading.
                        This will disable cleanup on error, and might leave your installation in partially upgraded state.
                        This option might not reload all configuration, and is only meant for in-place upgrades.
EOF
}

while (( $# )); do
  case "$1" in
    -h | --help) show_help; exit;;
    --no-user-prompt) SKIP_USER_PROMPT=1;;
    --minimize-downtime) MINIMIZE_DOWNTIME=1;;
    --) ;;
    *) echo "Unexpected argument: $1. Use --help for usage information."; exit 1;;
  esac
  shift
done
echo "${_endgroup}"

echo "${_group}Setting up error handling ..."
# Courtesy of https://stackoverflow.com/a/2183063/90297
trap_with_arg() {
  func="$1" ; shift
  for sig ; do
    trap "$func $sig "'$LINENO' "$sig"
  done
}

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [[ "$DID_CLEAN_UP" -eq 1 ]]; then
    return 0;
  fi
  DID_CLEAN_UP=1

  if [[ "$1" != "EXIT" ]]; then
    echo "An error occurred, caught SIG$1 on line $2";

    if [[ -n "$MINIMIZE_DOWNTIME" ]]; then
      echo "*NOT* cleaning up, to clean your environment run \"/usr/local/bin/docker-compose stop\"."
    else
      echo "Cleaning up..."
    fi
  fi

  if [[ -z "$MINIMIZE_DOWNTIME" ]]; then
    $dc stop -t $STOP_TIMEOUT &> /dev/null
  fi
}
trap_with_arg cleanup ERR INT TERM EXIT
echo "${_endgroup}"

echo "${_group}Checking minimum requirements ..."
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
COMPOSE_VERSION=$($dc --version | sed 's/usr/local/bin/docker-compose version \(.\{1,\}\),.*/\1/')
RAM_AVAILABLE_IN_DOCKER=$(docker run --rm busybox free -m 2>/dev/null | awk '/Mem/ {print $2}');
CPU_AVAILABLE_IN_DOCKER=$(docker run --rm busybox nproc --all);

# Compare dot-separated strings - function below is inspired by https://stackoverflow.com/a/37939589/808368
function ver () { echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'; }

# Thanks to https://stackoverflow.com/a/25123013/90297 for the quick `sed` pattern
function ensure_file_from_example {
  if [[ -f "$1" ]]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1" | sed 's/\.[^.]*$/.example&/') "$1"
  fi
}

if [[ "$(ver $DOCKER_VERSION)" -lt "$(ver $MIN_DOCKER_VERSION)" ]]; then
  echo "FAIL: Expected minimum Docker version to be $MIN_DOCKER_VERSION but found $DOCKER_VERSION"
  exit 1
fi

if [[ "$(ver $COMPOSE_VERSION)" -lt "$(ver $MIN_COMPOSE_VERSION)" ]]; then
  echo "FAIL: Expected minimum /usr/local/bin/docker-compose version to be $MIN_COMPOSE_VERSION but found $COMPOSE_VERSION"
  exit 1
fi

if [[ "$CPU_AVAILABLE_IN_DOCKER" -lt "$MIN_CPU_HARD" ]]; then
  echo "FAIL: Required minimum CPU cores available to Docker is $MIN_CPU_HARD, found $CPU_AVAILABLE_IN_DOCKER"
  exit 1
elif [[ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_CPU_SOFT" ]]; then
  echo "WARN: Recommended minimum CPU cores available to Docker is $MIN_CPU_SOFT, found $CPU_AVAILABLE_IN_DOCKER"
fi

if [[ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM_HARD" ]]; then
  echo "FAIL: Required minimum RAM available to Docker is $MIN_RAM_HARD MB, found $RAM_AVAILABLE_IN_DOCKER MB"
  exit 1
elif [[ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM_SOFT" ]]; then
  echo "WARN: Recommended minimum RAM available to Docker is $MIN_RAM_SOFT MB, found $RAM_AVAILABLE_IN_DOCKER MB"
fi

#SSE4.2 required by Clickhouse (https://clickhouse.yandex/docs/en/operations/requirements/)
# On KVM, cpuinfo could falsely not report SSE 4.2 support, so skip the check. https://github.com/ClickHouse/ClickHouse/issues/20#issuecomment-226849297
IS_KVM=$(docker run --rm busybox grep -c 'Common KVM processor' /proc/cpuinfo || :)
if [[ "$IS_KVM" -eq 0 ]]; then
  SUPPORTS_SSE42=$(docker run --rm busybox grep -c sse4_2 /proc/cpuinfo || :)
  if [[ "$SUPPORTS_SSE42" -eq 0 ]]; then
    echo "FAIL: The CPU your machine is running on does not support the SSE 4.2 instruction set, which is required for one of the services Sentry uses (Clickhouse). See https://git.io/JvLDt for more info."
    exit 1
  fi
fi
echo "${_endgroup}"

echo "${_group}Creating volumes for persistent storage ..."
echo "Created $(docker volume create --name=sentry-data)."
echo "Created $(docker volume create --name=sentry-postgres)."
echo "Created $(docker volume create --name=sentry-redis)."
echo "Created $(docker volume create --name=sentry-zookeeper)."
echo "Created $(docker volume create --name=sentry-kafka)."
echo "Created $(docker volume create --name=sentry-clickhouse)."
echo "Created $(docker volume create --name=sentry-symbolicator)."
echo "${_endgroup}"

echo "${_group}Ensuring files from examples ..."
ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example $SENTRY_EXTRA_REQUIREMENTS
ensure_file_from_example $SYMBOLICATOR_CONFIG_YML
ensure_file_from_example $RELAY_CONFIG_YML
echo "${_endgroup}"

echo "${_group}Generating secret key ..."
if grep -xq "system.secret-key: '!!changeme!!'" $SENTRY_CONFIG_YML ; then
  # This is to escape the secret key to be used in sed below
  # Note the need to set LC_ALL=C due to BSD tr and sed always trying to decode
  # whatever is passed to them. Kudos to https://stackoverflow.com/a/23584470/90297
  SECRET_KEY=$(export LC_ALL=C; head /dev/urandom | tr -dc "a-z0-9@#%^&*(-_=+)" | head -c 50 | sed -e 's/[\/&]/\\&/g')
  sed -i -e 's/^system.secret-key:.*$/system.secret-key: '"'$SECRET_KEY'"'/' $SENTRY_CONFIG_YML
  echo "Secret key written to $SENTRY_CONFIG_YML"
fi
echo "${_endgroup}"

echo "${_group}Replacing TSDB ..."
replace_tsdb() {
  if (
    [[ -f "$SENTRY_CONFIG_PY" ]] &&
    ! grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"
  ); then
    # Do NOT indent the following string as it would be reflected in the end result,
    # breaking the final config file. See getsentry/onpremise#624.
    tsdb_settings="\
SENTRY_TSDB = \"sentry.tsdb.redissnuba.RedisSnubaTSDB\"

# Automatic switchover 90 days after $(date). Can be removed afterwards.
SENTRY_TSDB_OPTIONS = {\"switchover_timestamp\": $(date +%s) + (90 * 24 * 3600)}\
"

    if grep -q 'SENTRY_TSDB_OPTIONS = ' "$SENTRY_CONFIG_PY"; then
      echo "Not attempting automatic TSDB migration due to presence of SENTRY_TSDB_OPTIONS"
    else
      echo "Attempting to automatically migrate to new TSDB"
      # Escape newlines for sed
      tsdb_settings="${tsdb_settings//$'\n'/\\n}"
      cp "$SENTRY_CONFIG_PY" "$SENTRY_CONFIG_PY.bak"
      sed -i -e "s/^SENTRY_TSDB = .*$/${tsdb_settings}/g" "$SENTRY_CONFIG_PY" || true

      if grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"; then
        echo "Migrated TSDB to Snuba. Old configuration file backed up to $SENTRY_CONFIG_PY.bak"
        return
      fi

      echo "Failed to automatically migrate TSDB. Reverting..."
      mv "$SENTRY_CONFIG_PY.bak" "$SENTRY_CONFIG_PY"
      echo "$SENTRY_CONFIG_PY restored from backup."
    fi

    echo "WARN: Your Sentry configuration uses a legacy data store for time-series data. Remove the options SENTRY_TSDB and SENTRY_TSDB_OPTIONS from $SENTRY_CONFIG_PY and add:"
    echo ""
    echo "$tsdb_settings"
    echo ""
    echo "For more information please refer to https://github.com/getsentry/onpremise/pull/430"
  fi
}

replace_tsdb
echo "${_endgroup}"

echo "${_group}Fetching and updating Docker images ..."
# We tag locally built images with an '-onpremise-local' suffix. /usr/local/bin/docker-compose pull tries to pull these too and
# shows a 404 error on the console which is confusing and unnecessary. To overcome this, we add the stderr>stdout
# redirection below and pass it through grep, ignoring all lines having this '-onpremise-local' suffix.
$dc pull -q --ignore-pull-failures 2>&1 | grep -v -- -onpremise-local || true

# We may not have the set image on the repo (local images) so allow fails
docker pull ${SENTRY_IMAGE} || true;
echo "${_endgroup}"

echo "${_group}Building and tagging Docker images ..."
echo ""
$dc build --force-rm
echo ""
echo "Docker images built."
echo "${_endgroup}"

echo "${_group}Turning things off ..."
if [[ -n "$MINIMIZE_DOWNTIME" ]]; then
  # Stop everything but relay and nginx
  $dc rm -fsv $($dc config --services | grep -v -E '^(nginx|relay)$')
else
  # Clean up old stuff and ensure nothing is working while we install/update
  # This is for older versions of on-premise:
  $dc -p onpremise down -t $STOP_TIMEOUT --rmi local --remove-orphans
  # This is for newer versions
  $dc down -t $STOP_TIMEOUT --rmi local --remove-orphans
fi
echo "${_endgroup}"

echo "${_group}Setting up Zookeeper ..."
ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2 | wc -l | tr -d '[:space:]'')
if [[ "$ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS" -eq 1 ]]; then
  ZOOKEEPER_LOG_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/log/version-2/* | wc -l | tr -d '[:space:]'')
  ZOOKEEPER_SNAPSHOT_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2/* | wc -l | tr -d '[:space:]'')
  # This is a workaround for a ZK upgrade bug: https://issues.apache.org/jira/browse/ZOOKEEPER-3056
  if [[ "$ZOOKEEPER_LOG_FILE_COUNT" -gt 0 ]] && [[ "$ZOOKEEPER_SNAPSHOT_FILE_COUNT" -eq 0 ]]; then
    $dcr -v $(pwd)/zookeeper:/temp zookeeper bash -c 'cp /temp/snapshot.0 /var/lib/zookeeper/data/version-2/snapshot.0'
    $dc run -d -e ZOOKEEPER_SNAPSHOT_TRUST_EMPTY=true zookeeper
  fi
fi
echo "${_endgroup}"

echo "${_group}Bootstrapping and migrating Snuba ..."
$dcr snuba-api bootstrap --no-migrate --force
$dcr snuba-api migrations migrate --force
echo "${_endgroup}"

echo "${_group}Creating additional Kafka topics ..."
# NOTE: This step relies on `kafka` being available from the previous `snuba-api bootstrap` step
# XXX(BYK): We cannot use auto.create.topics as Confluence and Apache hates it now (and makes it very hard to enable)
EXISTING_KAFKA_TOPICS=$($dcr kafka kafka-topics --list --bootstrap-server kafka:9092 2>/dev/null)
NEEDED_KAFKA_TOPICS="ingest-attachments ingest-transactions ingest-events"
for topic in $NEEDED_KAFKA_TOPICS; do
  if ! echo "$EXISTING_KAFKA_TOPICS" | grep -wq $topic; then
    $dcr kafka kafka-topics --create --topic $topic --bootstrap-server kafka:9092
    echo ""
  fi
done
echo "${_endgroup}"

echo "${_group}Ensuring proper PostgreSQL version ..."
# Very naively check whether there's an existing sentry-postgres volume and the PG version in it
if [[ -n "$(docker volume ls -q --filter name=sentry-postgres)" && "$(docker run --rm -v sentry-postgres:/db busybox cat /db/PG_VERSION 2>/dev/null)" == "9.5" ]]; then
  docker volume rm sentry-postgres-new || true
  # If this is Postgres 9.5 data, start upgrading it to 9.6 in a new volume
  docker run --rm \
  -v sentry-postgres:/var/lib/postgresql/9.5/data \
  -v sentry-postgres-new:/var/lib/postgresql/9.6/data \
  tianon/postgres-upgrade:9.5-to-9.6

  # Get rid of the old volume as we'll rename the new one to that
  docker volume rm sentry-postgres
  docker volume create --name sentry-postgres
  # There's no rename volume in Docker so copy the contents from old to new name
  # Also append the `host all all all trust` line as `tianon/postgres-upgrade:9.5-to-9.6`
  # doesn't do that automatically.
  docker run --rm -v sentry-postgres-new:/from -v sentry-postgres:/to alpine ash -c \
    "cd /from ; cp -av . /to ; echo 'host all all all trust' >> /to/pg_hba.conf"
  # Finally, remove the new old volume as we are all in sentry-postgres now
  docker volume rm sentry-postgres-new
fi
echo "${_endgroup}"

echo "${_group}Setting up database ..."
if [[ -n "$CI" || "$SKIP_USER_PROMPT" == 1 ]]; then
  $dcr web upgrade --noinput
  echo ""
  echo "Did not prompt for user creation due to non-interactive shell."
  echo "Run the following command to create one yourself (recommended):"
  echo ""
  echo "  /usr/local/bin/docker-compose run --rm web createuser"
  echo ""
else
  $dcr web upgrade
fi
echo "${_endgroup}"

echo "${_group}Migrating file storage ..."
SENTRY_DATA_NEEDS_MIGRATION=$(docker run --rm -v sentry-data:/data alpine ash -c "[ ! -d '/data/files' ] && ls -A1x /data | wc -l || true")
if [[ -n "$SENTRY_DATA_NEEDS_MIGRATION" ]]; then
  # Use the web (Sentry) image so the file owners are kept as sentry:sentry
  # The `\"` escape pattern is to make this compatible w/ Git Bash on Windows. See #329.
  $dcr --entrypoint \"/bin/bash\" web -c \
    "mkdir -p /tmp/files; mv /data/* /tmp/files/; mv /tmp/files /data/files; chown -R sentry:sentry /data"
fi
echo "${_endgroup}"

echo "${_group}Generating Relay credentials ..."
if [[ ! -f "$RELAY_CREDENTIALS_JSON" ]]; then

  # We need the ugly hack below as `relay generate credentials` tries to read the config and the credentials
  # even with the `--stdout` and `--overwrite` flags and then errors out when the credentials file exists but
  # not valid JSON. We hit this case as we redirect output to the same config folder, creating an empty
  # credentials file before relay runs.
  $dcr --no-deps -v $(pwd)/$RELAY_CONFIG_YML:/tmp/config.yml relay --config /tmp credentials generate --stdout > "$RELAY_CREDENTIALS_JSON"
  echo "Relay credentials written to $RELAY_CREDENTIALS_JSON"
  echo "${_endgroup}"
fi

echo "${_group}Setting up GeoIP integration ..."
source ./install/geoip.sh
echo "${_endgroup}"

if [[ "$MINIMIZE_DOWNTIME" ]]; then
  echo "${_group}Waiting for Sentry to start ..."
  # Start the whole setup, except nginx and relay.
  $dc up -d --remove-orphans $($dc config --services | grep -v -E '^(nginx|relay)$')
  $dc exec -T nginx service nginx reload

  docker run --rm --network="${COMPOSE_PROJECT_NAME}_default" alpine ash \
    -c 'while [[ "$(wget -T 1 -q -O- http://web:9000/_health/)" != "ok" ]]; do sleep 0.5; done'

  # Make sure everything is up. This should only touch relay and nginx
  $dc up -d
  echo "${_endgroup}"
else
  echo ""
  echo "-----------------------------------------------------------------"
  echo ""
  echo "You're all done! Run the following command to get Sentry running:"
  echo ""
  echo "  /usr/local/bin/docker-compose up -d"
  echo ""
  echo "-----------------------------------------------------------------"
  echo ""
fi
