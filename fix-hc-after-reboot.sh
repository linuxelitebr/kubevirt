#!/bin/bash

# Restarting a HOSTING(1) cluster may affect the INGRESS functionality of HOSTED(2) clusters.
# This script restarts the associated pods in the HOSTING(1) cluster to restore normal operation of the HOSTED(2) cluster.
# Andre Rocha

for ns in $(oc get ns -l hypershift.openshift.io/hosted-control-plane=true -o jsonpath='{.items[*].metadata.name}'); do
  echo "Removing pods with errors in the hosted namespace $ns"
  oc get pods -n $ns --no-headers \
    | awk '$3 != "Running" && $3 != "Completed" {print $1}' \
    | xargs -r oc delete pod -n $ns
done
