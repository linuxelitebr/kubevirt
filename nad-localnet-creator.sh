#!/bin/bash

# Script to create Localnet NADs for VLANs in a specified range
# Supports parallel creation and deletion of NADs
# Requires: kubectl or oc, seq, xargs, bash, awk
# v1.0 - Initial version
# Andres Rocha

set -e

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Detect available Kubernetes command (prefer oc over kubectl)
if command -v oc >/dev/null 2>&1; then
    K8S_CMD="oc"
elif command -v kubectl >/dev/null 2>&1; then
    K8S_CMD="kubectl"
else
    error_exit "Neither 'oc' nor 'kubectl' found. Install one of them before continuing."
fi

# Check other essential commands
for cmd in seq xargs bash awk; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "Command '$cmd' not found. Install it before continuing."
done

usage() {
    echo "Usage: $0 -p PREFIX -r START-END -l LABELS [-n NAMESPACE] [-d DESCRIPTION] [-m MTU] [-j JOBS] [-D]"
    echo ""
    echo "Options:"
    echo "  -p PREFIX       : Prefix for NAD (ex: nad-vlan)"
    echo "  -r START-END    : VLAN range (ex: 1-4094)"
    echo "  -l LABELS       : Labels in format key1=value1,key2=value2"
    echo "  -n NAMESPACE    : Namespace (default: default)"
    echo "  -d DESCRIPTION  : Description template (default: 'NAD VLAN <VLAN_ID> VMs')"
    echo "  -m MTU          : Network MTU (optional - uses CNI default if not specified)"
    echo "  -j JOBS         : Number of parallel jobs (default: 10)"
    echo "  -D              : Delete mode - remove NADs instead of creating"
    echo ""
    echo "Examples:"
    echo "  # Create NADs with default MTU"
    echo "  $0 -p vlan -r 1-100 -l environment=production,team=network"
    echo ""
    echo "  # Create NADs with custom MTU"
    echo "  $0 -p vlan -r 1-100 -l environment=production -m 9000"
    echo ""
    echo "  # Delete NADs"
    echo "  $0 -p vlan -r 1-100 -D"
    exit 1
}

# Default values
NAMESPACE="default"
MTU=""  # No default MTU
JOBS=10
DELETE_MODE=false

while getopts "p:r:l:n:d:m:j:D" opt; do
    case $opt in
        p) PREFIX="$OPTARG" ;;
        r) RANGE="$OPTARG" ;;
        l) LABELS="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        d) DESCRIPTION="$OPTARG" ;;
        m) MTU="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        D) DELETE_MODE=true ;;
        *) usage ;;
    esac
done

# Check required arguments
if [ -z "$PREFIX" ] || [ -z "$RANGE" ]; then
    usage
fi

# Labels are only required for create mode
if [ "$DELETE_MODE" = false ] && [ -z "$LABELS" ]; then
    usage
fi

# Validate range format
if ! [[ "$RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
    error_exit "Invalid range. Use format START-END, ex: 1-4094"
fi

START=$(echo "$RANGE" | cut -d- -f1)
END=$(echo "$RANGE" | cut -d- -f2)

if [ "$START" -gt "$END" ]; then
    error_exit "START ($START) cannot be greater than END ($END)"
fi

# Validate VLAN IDs (standard range 1-4094)
if [ "$START" -lt 1 ] || [ "$END" -gt 4094 ]; then
    error_exit "VLAN IDs must be between 1 and 4094"
fi

# Validate MTU (only if specified)
if [ -n "$MTU" ] && { ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 68 ] || [ "$MTU" -gt 9000 ]; }; then
    error_exit "Invalid MTU: $MTU (must be between 68 and 9000)"
fi

# Validate JOBS
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    error_exit "Invalid JOBS: $JOBS (must be a positive number)"
fi

# Process labels only in create mode
if [ "$DELETE_MODE" = false ]; then
    # Set default description template
    if [ -z "$DESCRIPTION" ]; then
        DESCRIPTION_TEMPLATE="NAD VLAN <VLAN_ID> VMs"
    else
        DESCRIPTION_TEMPLATE="$DESCRIPTION"
    fi

    # Convert CSV labels to YAML format
    LABELS_YAML=""
    OLD_IFS="$IFS"
    IFS=','
    for label in $LABELS; do
        label=$(echo "$label" | xargs)  # trim whitespace
        if [[ "$label" == *"="* ]]; then
            key=$(echo "$label" | cut -d'=' -f1 | xargs)
            value=$(echo "$label" | cut -d'=' -f2- | xargs)
            LABELS_YAML="${LABELS_YAML}    ${key}: \"${value}\"\n"
        fi
    done
    IFS="$OLD_IFS"

    if [ -z "$LABELS_YAML" ]; then
        error_exit "Invalid labels. Use format key1=value1,key2=value2"
    fi
fi

# Function to create a single NAD
create_nad() {
    local VLAN_ID=$1
    local NAD_NAME="${PREFIX}${VLAN_ID}"
    local DESCRIPTION="${DESCRIPTION_TEMPLATE//<VLAN_ID>/$VLAN_ID}"
    
    # Generate CNI configuration with conditional MTU
    local CNI_CONFIG
    if [ -n "$MTU" ]; then
        CNI_CONFIG='{"cniVersion":"0.4.0","name":"'$NAD_NAME'","type":"ovn-k8s-cni-overlay","mtu":'$MTU',"netAttachDefName":"'$NAMESPACE'/'$NAD_NAME'","topology":"localnet","vlanID":'$VLAN_ID'}'
    else
        CNI_CONFIG='{"cniVersion":"0.4.0","name":"'$NAD_NAME'","type":"ovn-k8s-cni-overlay","netAttachDefName":"'$NAMESPACE'/'$NAD_NAME'","topology":"localnet","vlanID":'$VLAN_ID'}'
    fi

    # Generate complete NAD manifest
    local MANIFEST=$(cat <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: $NAD_NAME
  namespace: $NAMESPACE
  labels:
$(printf "$LABELS_YAML")
  annotations:
    description: "$DESCRIPTION"
    k8s.ovn.org/network-id: '$VLAN_ID'
    k8s.ovn.org/network-name: '$NAD_NAME'
spec:
  config: '$CNI_CONFIG'
EOF
)

    if echo "$MANIFEST" | $K8S_CMD apply -f - >/dev/null 2>&1; then
        if [ -n "$MTU" ]; then
            echo "SUCCESS: NAD '$NAD_NAME' created in namespace '$NAMESPACE' with VLAN $VLAN_ID and MTU $MTU"
        else
            echo "SUCCESS: NAD '$NAD_NAME' created in namespace '$NAMESPACE' with VLAN $VLAN_ID (default MTU)"
        fi
    else
        echo "✗ Error creating NAD '$NAD_NAME' with VLAN $VLAN_ID" >&2
        return 1
    fi
}

# Function to delete a single NAD
delete_nad() {
    local VLAN_ID=$1
    local NAD_NAME="${PREFIX}${VLAN_ID}"
    
    # Check if NAD exists first
    if $K8S_CMD get network-attachment-definitions.k8s.cni.cncf.io "$NAD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        # NAD exists, try to delete it
        if $K8S_CMD delete network-attachment-definitions.k8s.cni.cncf.io "$NAD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
            echo "SUCCESS: NAD '$NAD_NAME' deleted from namespace '$NAMESPACE'"
        else
            echo "✗ Error deleting NAD '$NAD_NAME'" >&2
            return 1
        fi
    else
        # NAD doesn't exist
        echo "- NAD '$NAD_NAME' not found in namespace '$NAMESPACE' (already deleted or never existed)"
    fi
}

# Export functions for parallel execution
export -f create_nad delete_nad
export K8S_CMD PREFIX NAMESPACE MTU LABELS_YAML DESCRIPTION_TEMPLATE

echo "Using command: $K8S_CMD"

if [ "$DELETE_MODE" = true ]; then
    echo "Deleting NADs from $PREFIX$START to $PREFIX$END in namespace '$NAMESPACE'..."
    echo "Parallel jobs: $JOBS"
    echo "---"
    
    if seq "$START" "$END" | xargs -n1 -P "$JOBS" -I{} bash -c 'delete_nad "$@"' _ {}; then
        echo "---"
        echo "Delete process completed successfully!"
    else
        echo "---"
        echo "Delete process completed with some errors." >&2
        exit 1
    fi
else
    echo "Creating NADs from $PREFIX$START to $PREFIX$END in namespace '$NAMESPACE'..."
    if [ -n "$MTU" ]; then
        echo "MTU: $MTU, Parallel jobs: $JOBS"
    else
        echo "MTU: default, Parallel jobs: $JOBS"
    fi
    echo "---"
    
    if seq "$START" "$END" | xargs -n1 -P "$JOBS" -I{} bash -c 'create_nad "$@"' _ {}; then
        echo "---"
        echo "Process completed successfully!"
    else
        echo "---"
        echo "Process completed with some errors." >&2
        exit 1
    fi
fi
