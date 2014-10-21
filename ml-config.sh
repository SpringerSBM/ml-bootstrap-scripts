# Performs initial setup of a MarkLogic host
#
# Initialises host and then either
# - configures security - for standalone host or first (bootstrap) host of cluster; or
# - joins existing cluster at $CLUSTER_BOOTSTRAP_HOST#
#
# See README.md or check_env() for requried environment variables
#
# Based on samples in ml docs:
# http://docs.marklogic.com/guide/admin-api/cluster#chapter

AUTH="--anyauth --user ${ADMIN_USER}:${ADMIN_PASS}"
LATEST_TS="0"

check_env() {
  ENV_OK=true
  [ -n "${HOST}" ] || env_missing "HOST"
  [ -n "${LICENSE_KEY}" ] || env_missing "LICENSE_KEY"
  [ -n "${LICENSEE}" ] || env_missing "LICENSEE"
  [ -n "${ADMIN_USER}" ] || env_missing "ADMIN_USER"
  [ -n "${ADMIN_PASS}" ] || env_missing "ADMIN_PASS"
  if [ "${ENV_OK}" = false ] ; then
    exit 1
  fi
}

env_missing() {
  echo "Environment variable ${1} not set."
  ENV_OK=false
}

check_already_configured() {
  # will return 401 if security has already been setup
  local STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOST}:8001/admin/v1/timestamp")
  if [ "${STATUS}" = "401" ]; then
    echo "Exiting because already configured."
    exit 0
  fi
}


start_time() {
  echo $(curl -s $AUTH "http://${HOST}:8001/admin/v1/timestamp")
}

check_timestamp() {
  local current_ts=$(start_time)
  for i in $(seq 1 10); do
    if [ "${LATEST_TS}" == "${current_ts}" ] || [ "${current_ts}" == "" ]; then
      sleep 2
      current_ts=$(start_time)
    else
      LATEST_TS="${current_ts}"
      return 0
    fi
  done
  echo "ERROR: Failed to start"
  exit 1
}

configure() {
  echo "Configuring ${HOST} .."
  check_timestamp
  initialize
  if [ -n "${CLUSTER_BOOTSTRAP_HOST}" ]; then
    join_cluster
  else
    setup_security
  fi
}

initialize() {
  echo "Initializing .."
  curl -sS -X POST \
    -H "Content-type=application/x-www-form-urlencoded" \
    --data-urlencode "license-key=${LICENSE_KEY}" \
    --data-urlencode "licensee=${LICENSEE}" \
    "http://${HOST}:8001/admin/v1/init" > /dev/null
  check_timestamp
}

setup_security() {
  echo "Configuring security .."
  curl -sS -X POST \
    -H "Content-type: application/x-www-form-urlencoded" \
    --data-urlencode "admin-username=${ADMIN_USER}" \
    --data-urlencode "admin-password=${ADMIN_PASS}" \
    --data-urlencode "realm=public" \
    "http://${HOST}:8001/admin/v1/instance-admin" > /dev/null
  check_timestamp
}

join_cluster() {
  echo "Joining the cluster at ${CLUSTER_BOOTSTRAP_HOST} .."

  # get new host's config
  HOST_CONFIG=$(curl -sS -H "Accept: application/xml" "http://${HOST}:8001/admin/v1/server-config")
  if [ "$?" -ne 0 ]; then
    echo "ERROR: Failed to fetch server config for ${HOST}"
    exit 1
  fi

  # post it to the cluster bootstrap host and save the cluster config to a temp file
  curl -sS $AUTH -X POST \
    -H "Content-type: application/x-www-form-urlencoded" \
    -o /tmp/cluster-config.zip -d "group=Default" \
    --data-urlencode "server-config=${HOST_CONFIG}" \
    "http://${CLUSTER_BOOTSTRAP_HOST}:8001/admin/v1/cluster-config"

  if [ "$?" -ne 0 ]; then
    echo "ERROR: Failed to fetch cluster config from $BOOTSTRAP_HOST"
    exit 1
  fi
  if [ `file /tmp/cluster-config.zip | grep -cvi "zip archive data"` -eq 1 ]; then
    echo "ERROR: Failed to fetch cluster config from ${CLUSTER_BOOTSTRAP_HOST}"
    exit 1
  fi

  # post the cluster config to the new host
  curl -sS -X POST \
    -H "Content-type: application/zip" \
    --data-binary @/tmp/cluster-config.zip \
    "http://${HOST}:8001/admin/v1/cluster-config"

  check_timestamp

  echo "Added ${HOST} to cluster ${CLUSTER_BOOTSTRAP_HOST}"
}

check_env
check_already_configured
configure
