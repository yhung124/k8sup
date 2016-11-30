#!/bin/bash

function get_alive_etcd_member_size(){
  local MEMBER_LIST="$1"
  local MEMBER_CLIENT_ADDR_LIST="$(echo "${MEMBER_LIST}" | jq -r ".members[].clientURLs[0]")"
  local ALIVE_ETCD_MEMBER_SIZE="0"
  local MEMBER

  for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
    if curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
      ((ALIVE_ETCD_MEMBER_SIZE++))
    fi
  done
  echo "${ALIVE_ETCD_MEMBER_SIZE}"
}

function main(){
  source "/root/.bashrc" || exit 1
  local IPADDR="${EX_IPADDR}" && unset EX_IPADDR
  local ETCD_CLIENT_PORT="${EX_ETCD_CLIENT_PORT}" && unset EX_ETCD_CLIENT_PORT
  local K8S_VERSION="${EX_K8S_VERSION}" && unset EX_K8S_VERSION
  local CLUSTER_ID="${EX_CLUSTER_ID}" && unset EX_CLUSTER_ID
  local SUBNET_ID_AND_MASK="${EX_SUBNET_ID_AND_MASK}" && unset EX_SUBNET_ID_AND_MASK
  local NODE_NAME="${EX_NODE_NAME}" && unset EX_NODE_NAME
  local IP_AND_MASK="${EX_IP_AND_MASK}" && unset EX_IP_AND_MASK
  local K8S_REGISTRY="${EX_REGISTRY}" && unset EX_REGISTRY

  local MEMBER_LIST
  local MEMBER_CLIENT_ADDR_LIST
  local MEMBER_SIZE
  local MEMBER
  local MEMBER_DISCONNECTED
  local MEMBER_FAILED
  local MEMBER_REMOVED
  local MAX_ETCD_MEMBER_SIZE
  local HEALTH_CHECK_INTERVAL="60"
  local UNHEALTH_COUNT="0"
  local UNHEALTH_COUNT_THRESHOLD="3"
  local IPPORT_PATTERN="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:[0-9]\{1,5\}"
  local LOCKER_ETCD_KEY="k8sup/cluster/etcd-rejoining"
  local MEMBER_REMOVED_KEY="k8sup/cluster/member-removed"
  local ETCD_MEMBER_SIZE_STATUS
  local ETCD_PROXY
  local DISCOVERY_RESULTS
  local ETCD_NODE_LIST
  local PROXY_OPT
  local FORCED_WORKER_LABEL

  echo "Running etcd-maintainer.sh ..."

  while true; do

#    # Do not maintain foced workers
#    until FORCED_WORKER_LABEL="$(curl -sf http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/registry/minions/${IPADDR})"; do
#      sleep 1
#    done
#    FORCED_WORKER_LABEL="$(echo "${FORCED_WORKER_LABEL}" | jq -r '.node.value' | jq -r '.metadata.labels | .["cdxvirt/k8s_forced_worker"]')"
#    if [[ "${FORCED_WORKER_LABEL}" == "true" ]]; then
#      sleep "${HEALTH_CHECK_INTERVAL}"
#      continue
#    fi

    MAX_ETCD_MEMBER_SIZE=""
    MEMBER_CLIENT_ADDR_LIST=""
    until [[ -n "${MAX_ETCD_MEMBER_SIZE}" ]] && [[ -n "${MEMBER_CLIENT_ADDR_LIST}" ]]; do
      # Monitoring etcd member size and check if it match the max etcd member size
      MAX_ETCD_MEMBER_SIZE="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
                            | jq -r '.node.value')"
      MEMBER_LIST="$(curl -sf "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/members")"
      MEMBER_CLIENT_ADDR_LIST="$(echo "${MEMBER_LIST}" | jq -r ".members[].clientURLs[0]" | grep -o "${IPPORT_PATTERN}")"
      if [[ -z "${MAX_ETCD_MEMBER_SIZE}" ]] || [[ -z "${MEMBER_CLIENT_ADDR_LIST}" ]]; then
        echo "Getting 'MAX_ETCD_MEMBER_SIZE' and 'MEMBER_CLIENT_ADDR_LIST'..." 1>&2
        sleep 1
      fi
    done
    if [[ "${MAX_ETCD_MEMBER_SIZE}" -lt "3" ]]; then
      # Prevent the cap of etcd member size less then 3
      MAX_ETCD_MEMBER_SIZE="3"
      curl -s "http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/k8sup/cluster/max_etcd_member_size" \
        -XPUT -d value="${MAX_ETCD_MEMBER_SIZE}" 1>&2
    fi
    MEMBER_SIZE="$(get_alive_etcd_member_size "${MEMBER_LIST}")"
    if [[ "${MEMBER_SIZE}" -eq "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="equal"
    elif [[ "${MEMBER_SIZE}" -lt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      ETCD_MEMBER_SIZE_STATUS="lesser"
    elif [[ "${MEMBER_SIZE}" -gt "${MAX_ETCD_MEMBER_SIZE}" ]]; then
      local ETCD_MEMBER_SIZE_STATUS="greater"
    fi

    DISCOVERY_RESULTS="<nil>"
    until [[ -z "$(echo "${DISCOVERY_RESULTS}" | grep '<nil>')" ]]; do
      DISCOVERY_RESULTS="$(go run /go/dnssd/browsing.go | grep -w "NetworkID=${SUBNET_ID_AND_MASK}")"
    done
    ETCD_NODE_LIST="$(echo "${DISCOVERY_RESULTS}" | grep -w "clusterID=${CLUSTER_ID}" | awk '{print $2}')"
    ETCD_NODE_SIZE="$(echo "${ETCD_NODE_LIST}" | wc -l)"

    if [[ "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" \
       && "$((${MEMBER_SIZE} % 2))" == "0" \
       && "${MEMBER_SIZE}" -eq "${ETCD_NODE_SIZE}" ]]; then
      PROXY_OPT="--proxy"
    else
      PROXY_OPT=""
    fi

    # Get this node is etcd member or proxy
    if [[ "${MEMBER_CLIENT_ADDR_LIST}" == *"${IPADDR}:${ETCD_CLIENT_PORT}"* ]]; then
      ETCD_PROXY="off"
    else
      ETCD_PROXY="on"
    fi

    # Monitoring all etcd members and try to get one of the failed member
    for MEMBER in ${MEMBER_DISCONNECTED}; do
      if [[ -z "$(echo "${MEMBER_CLIENT_ADDR_LIST}" | grep -w "${MEMBER}")" ]]; then
        MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER}/d)"
      fi
    done
    for MEMBER in ${MEMBER_CLIENT_ADDR_LIST}; do
      if ! curl -s -m 3 "${MEMBER}/health" &>/dev/null; then
        MEMBER_DISCONNECTED="${MEMBER_DISCONNECTED}"$'\n'"${MEMBER}"
      else
        MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER}/d)"
      fi
    done
    MEMBER_FAILED="$(echo "${MEMBER_DISCONNECTED}" \
     | grep -v '^$' \
     | sort \
     | uniq -c \
     | awk "\$1>=${UNHEALTH_COUNT_THRESHOLD}{print \$2}" | head -n 1 | cut -d ':' -f 1)"

    # If a failed member existing or member size does not match the cap,
    # try to adjust the member size by turns this node to member or proxy,
    # but only one node can do this at the same time.

    if [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "off" ]] \
       || [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "greater" && "${ETCD_PROXY}" == "on" ]] \
       || [[ -z "${MEMBER_FAILED}" && -z "${PROXY_OPT}" && "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "on" \
          && "$((${MEMBER_SIZE} % 2))" == "1" \
          && "$((${ETCD_NODE_SIZE} - ${MEMBER_SIZE}))" -le "1" ]]; then
      sleep "${HEALTH_CHECK_INTERVAL}"
      continue
    else
      # Lock
      local LOCKER_URL="http://127.0.0.1:${ETCD_CLIENT_PORT}/v2/keys/${LOCKER_ETCD_KEY}"
      if [[ "$(curl -sf "${LOCKER_URL}" | jq -r '.node.value')" == "${IPADDR}" ]] \
         || curl -sf "${LOCKER_URL}?prevExist=false" \
            -XPUT -d value="${IPADDR}" 1>&2; then

        if [[ -n "${MEMBER_FAILED}" ]]; then
          # Set the remote failed etcd member to exit the etcd cluster
          /go/kube-down --exit-remote-etcd="${MEMBER_FAILED}"

          # Remove the failed member that has been repaced from the list
          MEMBER_DISCONNECTED="$(echo "${MEMBER_DISCONNECTED}" | sed /.*${MEMBER_FAILED}/d)"
        fi

        if [[ -z "${MEMBER_DISCONNECTED}" ]]; then
          if [[ "${ETCD_MEMBER_SIZE_STATUS}" == "lesser" && "${ETCD_PROXY}" == "on" ]] \
             || [[ "${ETCD_MEMBER_SIZE_STATUS}" == "greater" && "${ETCD_PROXY}" == "off" ]] \
             || [[ -n "${PROXY_OPT}" ]]; then

            # Stop local k8s service
            docker stop k8sup-kubelet || true
            docker rm -f k8sup-kubelet || true

            # Re-join etcd cluster
            /go/entrypoint.sh --rejoin-etcd ${PROXY_OPT}

            # Start local k8s service
            if [[ -n "${K8S_REGISTRY}" ]]; then
              local REGISTRY_OPTION="--registry=${K8S_REGISTRY}"
            fi
            /go/kube-up --ip="${IPADDR}" --version="${K8S_VERSION}" ${REGISTRY_OPTION}
          fi
        fi

        # Unlock
        until curl -sf "${LOCKER_URL}?prevValue=${IPADDR}" \
          -XDELETE 1>&2; do
            sleep 1
        done
      fi
    fi

    # If etcd is up but DNS-SD is down, try to run it again
    if curl -s -m 3 "http://127.0.0.1:${ETCD_CLIENT_PORT}/health" &>/dev/null \
       && [[ -z "$(ps aux | grep 'registering.go' | grep -v 'grep')" ]]; then
      bash -c "go run /go/dnssd/registering.go \"${NODE_NAME}\" \"${IP_AND_MASK}\" \"${ETCD_CLIENT_PORT}\" \"${CLUSTER_ID}\"" &
    fi

    sleep "${HEALTH_CHECK_INTERVAL}"
  done
}

main "$@"