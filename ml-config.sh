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

get_timestamp() {
    set +e
    serverTimestamp=`curl -s ${AUTH} "http://${HOST}:8001/admin/v1/timestamp"`
    set -e
    echo "${serverTimestamp}"
}

poll_until_timestamp_changes() {
  local originalTimestamp=$1
  for i in $(seq 1 10); do
    latestTimestamp=`get_timestamp`
    if [ "${latestTimestamp}" == "" ] || [ "${latestTimestamp}" == "${originalTimestamp}" ] ; then
      printf '.'
      sleep 2
    else
      echo "Restart confirmed"
      return 0
    fi
  done
  echo "ERROR: Unable to confirm server restart within the allotted time."
  exit 1
}

configure() {
  echo "Configuring ${HOST} .."
  latest_ts=`get_timestamp`
  initialize
  poll_until_timestamp_changes "${latest_ts}"
  latest_ts=`get_timestamp`
  if [ -n "${CLUSTER_BOOTSTRAP_HOST}" ]; then
    join_cluster
  else
    setup_security
  fi
  poll_until_timestamp_changes "${latest_ts}"
  setup_availability_zone
}

initialize() {
  echo "Initializing .."
  curl -sS -X POST \
    -H "Content-type=application/x-www-form-urlencoded" \
    --data-urlencode "license-key=${LICENSE_KEY}" \
    --data-urlencode "licensee=${LICENSEE}" \
    "http://${HOST}:8001/admin/v1/init" > /dev/null
}

setup_security() {
  echo "Configuring security .."
  curl -sS -X POST \
    -H "Content-type: application/x-www-form-urlencoded" \
    --data-urlencode "admin-username=${ADMIN_USER}" \
    --data-urlencode "admin-password=${ADMIN_PASS}" \
    --data-urlencode "realm=public" \
    "http://${HOST}:8001/admin/v1/instance-admin" > /dev/null
}

# Setup availability zone
# http://docs.marklogic.com/REST/PUT/manage/v2/hosts/%5Bid-or-name%5D/properties
setup_availability_zone() {
  if [ "${AVAILABILITY_ZONE}" ]; then
    echo "Setting availability zone to '${AVAILABILITY_ZONE}'"
    local STATUS=$(
      curl -s ${AUTH} -o /dev/null -w "%{http_code}" \
        -X PUT -d "{ \"zone\":\"${AVAILABILITY_ZONE}\" }" \
        -H "Content-type: application/json" \
        http://${HOST}:8002/manage/v2/hosts/${HOST}/properties
    )
    if [ "${STATUS}" != "204" ]; then
      echo "Failed setting availability zone. Return code: $STATUS"
      if [ "$1" == "attempt2" ]; then
        exit 1
      else
        # this seems flaky so try again
        echo "Trying again .."
        sleep 2
        setup_availability_zone "attempt2"
      fi
    fi
  fi
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

  echo "Added ${HOST} to cluster ${CLUSTER_BOOTSTRAP_HOST}"
}

function poll_until_up() {
  for attempt in `seq 1 10`
  do 
  	if `nc $HOST 8001 </dev/null &> /dev/null`; then
  		return
  	fi
  	sleep 1
  done
  echo "Unable to connect to $HOST:8001 after 10 tries."
  exit 1
}

check_env
poll_until_up
check_already_configured
configure
