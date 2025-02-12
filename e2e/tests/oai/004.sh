#!/bin/bash
#!/usr/bin/env bash
# SPDX-license-identifier: Apache-2.0
##############################################################################
# Copyright (c) 2024 The Nephio Authors.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################

## TEST METADATA
## TEST-NAME: Deploy OAI E1 Split RAN Network Functions
##

set -o pipefail
set -o errexit
set -o nounset
[[ ${DEBUG:-false} != "true" ]] || set -o xtrace

# shellcheck source=e2e/defaults.env
source "$E2EDIR/defaults.env"

# shellcheck source=e2e/lib/k8s.sh
source "${LIBDIR}/k8s.sh"

# shellcheck source=e2e/lib/kpt.sh
source "${LIBDIR}/kpt.sh"

function _wait_for_ran {
    kubeconfig=$1
    wait_msg=$2
    link_name=$3

    info "waiting for $link_name link to be established"
    timeout=600

    temp_file=$(mktemp)
    kubectl logs "$(kubectl get pods -n oai-ran-cucp --kubeconfig "$kubeconfig" -l app.kubernetes.io/name=oai-gnb-cu-cp -o jsonpath='{.items[*].metadata.name}')" -n oai-ran-cucp -c gnbcucp --kubeconfig "$kubeconfig" > temp_file
    while grep -q "$wait_msg" temp_file;status=$?; [[ $status != 0 ]]
    	do
        	if [[ $timeout -lt 0 ]]; then
            		kubectl logs -l app.kubernetes.io/name=oai-gnb-cu-cp -n oai-ran-cucp -c gnbcucp --kubeconfig "$kubeconfig" --tail 50
            		error "Timed out waiting for $link_name link to be established"
        	fi
        	timeout=$((timeout - 5))
        	sleep 5
		kubectl logs "$(kubectl get pods -n oai-ran-cucp --kubeconfig "$kubeconfig" -l app.kubernetes.io/name=oai-gnb-cu-cp -o jsonpath='{.items[*].metadata.name}')" -n oai-ran-cucp -c gnbcucp --kubeconfig "$kubeconfig" > temp_file
    done
    debug "timeout: $timeout"
    rm "${temp_file}"
}

function _wait_for_n2_link {
    _wait_for_ran "$1" "Received NGAP_REGISTER_GNB_CNF: associated AMF" "N2"
}

function _wait_for_e1_link {
    # Connection between CU-CP and CU-UP
    _wait_for_ran "$1" "e1ap_send_SETUP_RESPONSE" "E1"
}

function _wait_for_f1_link {
    # Connection between DU and CU-CP
    _wait_for_ran "$1" "Cell Configuration ok" "F1"
}

k8s_apply "$TESTDIR/004-ran-cucp.yaml"

for nf in du cuup; do
    cat <<EOF | kubectl apply -f -
apiVersion: config.porch.kpt.dev/v1alpha1
kind: PackageVariant
metadata:
  name: oai-$nf
spec:
  upstream:
    repo: catalog-workloads-oai-ran
    package: pkg-example-$nf-bp
    revision: main
  downstream:
    repo: edge
    package: oai-ran-$nf
  annotations:
    approval.nephio.org/policy: initial
  injectors:
  - name: edge
EOF
done

for nf in du cuup cucp; do
    k8s_wait_ready "packagevariant" "oai-$nf"
done

for nf in du cuup; do
    kpt_wait_pkg "edge" "oai-ran-$nf" "nephio" "1800"
done
kpt_wait_pkg "regional" "oai-ran-cucp" "nephio" "1800"

_regional_kubeconfig="$(k8s_get_capi_kubeconfig "regional")"
_edge_kubeconfig="$(k8s_get_capi_kubeconfig "edge")"

k8s_wait_ready_replicas "deployment" "oai-gnb-cu-cp" "$_regional_kubeconfig" "oai-ran-cucp"
k8s_wait_ready_replicas "deployment" "oai-gnb-cu-up" "$_edge_kubeconfig" "oai-ran-cuup"
k8s_wait_ready_replicas "deployment" "oai-gnb-du" "$_edge_kubeconfig" "oai-ran-du"

# Check if the NGAPSetup Request Response is okay between AMF and CU-CP
_wait_for_n2_link "$_regional_kubeconfig"
# Check if the E1Setup Request Response is okay between AMF and CU-CP
_wait_for_e1_link "$_regional_kubeconfig"
# Check if the F1Setup Request Response is okay between AMF and CU-CP
_wait_for_f1_link "$_regional_kubeconfig"
