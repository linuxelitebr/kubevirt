#!/bin/bash

# Script to create Bridge NADs for VLANs in a specified range
# Supports parallel creation and deletion of NADs
# Requires: kubectl or oc, seq, xargs, bash, awk
# v1.0 - Initial version
# Andres Rocha

set -e

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Debug logging function
debug_log() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
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
    echo "Usage: $0 -p PREFIX -r START-END -b BRIDGE -l LABELS [-n NAMESPACE] [-d DESCRIPTION] [-j JOBS] [-M] [-D] [-t] [-v]"
    echo ""
    echo "Options:"
    echo "  -p PREFIX       : Prefix for NAD (ex: nic1-vlan)"
    echo "  -r START-END    : VLAN range (ex: 1-4094)"
    echo "  -b BRIDGE       : Bridge name (ex: br-vmdata, br0)"
    echo "  -l LABELS       : Labels in format key1=value1,key2=value2"
    echo "  -n NAMESPACE    : Namespace (default: default)"
    echo "  -d DESCRIPTION  : Description template (default: 'VLAN <VLAN_ID> <BRIDGE>')"
    echo "  -j JOBS         : Number of parallel jobs (default: 10)"
    echo "  -M              : Disable MAC spoof checking (default: enabled)"
    echo "  -D              : Delete mode - remove NADs instead of creating"
    echo "  -t              : Dry run - show templates without creating"
    echo "  -v              : Debug mode - verbose output"
    echo ""
    echo "Examples:"
    echo "  # Create bridge NADs with MAC spoof check enabled"
    echo "  $0 -p nic1-vlan -r 1-100 -b br-vmdata -l environment=production,team=network"
    echo ""
    echo "  # Dry run to see templates"
    echo "  $0 -p nic1-vlan -r 1-5 -b br-vmdata -l env=test -t"
    echo ""
    echo "  # Debug mode to troubleshoot errors"
    echo "  $0 -p nic1-vlan -r 1-5 -b br-vmdata -l env=test -v"
    echo ""
    echo "  # Delete bridge NADs"
    echo "  $0 -p nic1-vlan -r 1-100 -D"
    exit 1
}

# Default values
NAMESPACE="default"
JOBS=10
MACSPOOFCHK=true
DELETE_MODE=false
DRY_RUN=false
DEBUG=false

while getopts "p:r:b:l:n:d:j:MDtv" opt; do
    case $opt in
        p) PREFIX="$OPTARG" ;;
        r) RANGE="$OPTARG" ;;
        b) BRIDGE="$OPTARG" ;;
        l) LABELS="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        d) DESCRIPTION="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        M) MACSPOOFCHK=false ;;
        D) DELETE_MODE=true ;;
        t) DRY_RUN=true ;;
        v) DEBUG=true ;;
        *) usage ;;
    esac
done

# Check required arguments
if [ -z "$PREFIX" ] || [ -z "$RANGE" ]; then
    usage
fi

# For create mode, bridge and labels are required
if [ "$DELETE_MODE" = false ]; then
    if [ -z "$BRIDGE" ] || [ -z "$LABELS" ]; then
        usage
    fi
fi

debug_log "Parsed arguments: PREFIX=$PREFIX, RANGE=$RANGE, BRIDGE=$BRIDGE, LABELS=$LABELS, NAMESPACE=$NAMESPACE"
debug_log "JOBS=$JOBS, MACSPOOFCHK=$MACSPOOFCHK, DELETE_MODE=$DELETE_MODE, DRY_RUN=$DRY_RUN, DEBUG=$DEBUG"

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

# Validate JOBS
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
    error_exit "Invalid JOBS: $JOBS (must be a positive number)"
fi

# Process labels only in create mode
if [ "$DELETE_MODE" = false ]; then
    # Set default description template
    if [ -z "$DESCRIPTION" ]; then
        DESCRIPTION_TEMPLATE="VLAN <VLAN_ID> $BRIDGE"
    else
        DESCRIPTION_TEMPLATE="$DESCRIPTION"
    fi

    debug_log "Processing labels: $LABELS"
    debug_log "Description template: $DESCRIPTION_TEMPLATE"

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

    debug_log "Generated YAML labels:"
    debug_log "$(printf "$LABELS_YAML")"
fi

# Function to create a single NAD
create_nad() {
    local VLAN_ID=$1
    local NAD_NAME="${PREFIX}${VLAN_ID}"
    local DESCRIPTION="${DESCRIPTION_TEMPLATE//<VLAN_ID>/$VLAN_ID}"
    
    debug_log "Processing VLAN $VLAN_ID -> NAD name: $NAD_NAME"
    debug_log "Bridge: $BRIDGE, MAC spoof check: $MACSPOOFCHK"
    
    # Generate CNI configuration for linux bridge (properly indented)
    local CNI_CONFIG=$(cat <<EOF
    {
      "cniVersion": "0.3.1",
      "name": "$NAD_NAME",
      "type": "bridge",
      "bridge": "$BRIDGE",
      "ipam": {},
      "macspoofchk": $MACSPOOFCHK,
      "preserveDefaultVlan": false,
      "vlan": $VLAN_ID
    }
EOF
)

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
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/$BRIDGE
spec:
  config: |-
$CNI_CONFIG
EOF
)

    if [ "$DRY_RUN" = true ]; then
        echo "=== Bridge NAD Template for VLAN $VLAN_ID ==="
        echo "$MANIFEST"
        echo "=== End of Template ==="
        echo ""
        return 0
    fi

    debug_log "Applying NAD $NAD_NAME using command: $K8S_CMD"
    
    # Capture both stdout and stderr to show errors
    local APPLY_OUTPUT
    APPLY_OUTPUT=$(echo "$MANIFEST" | $K8S_CMD apply -f - 2>&1)
    local APPLY_STATUS=$?
    
    if [ $APPLY_STATUS -eq 0 ]; then
        echo "SUCCESS: NAD '$NAD_NAME' created in namespace '$NAMESPACE' with VLAN $VLAN_ID on bridge '$BRIDGE' (macspoofchk: $MACSPOOFCHK)"
        debug_log "Apply output: $APPLY_OUTPUT"
    else
        echo "ERROR: Error creating NAD '$NAD_NAME' with VLAN $VLAN_ID" >&2
        echo "   Error details: $APPLY_OUTPUT" >&2
        if [ "$DEBUG" = true ]; then
            echo "[DEBUG] Failed manifest for $NAD_NAME (with line numbers):" >&2
            echo "$MANIFEST" | nl -ba >&2
        else
            echo "   Run with -v flag to see the full manifest and debug info" >&2
        fi
        return 1
    fi
}

# Function to delete a single NAD
delete_nad() {
    local VLAN_ID=$1
    local NAD_NAME="${PREFIX}${VLAN_ID}"
    
    debug_log "DELETE MODE: Processing delete for VLAN $VLAN_ID -> NAD name: $NAD_NAME"
    
    if [ "$DRY_RUN" = true ]; then
        echo "Would delete: NAD '$NAD_NAME' in namespace '$NAMESPACE'"
        return 0
    fi
    
    # Check if NAD exists first
    if $K8S_CMD get network-attachment-definitions.k8s.cni.cncf.io "$NAD_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        debug_log "DELETE MODE: Deleting NAD $NAD_NAME using command: $K8S_CMD"
        # NAD exists, try to delete it
        local DELETE_OUTPUT
        DELETE_OUTPUT=$($K8S_CMD delete network-attachment-definitions.k8s.cni.cncf.io "$NAD_NAME" -n "$NAMESPACE" 2>&1)
        local DELETE_STATUS=$?
        
        if [ $DELETE_STATUS -eq 0 ]; then
            echo "SUCCESS: NAD '$NAD_NAME' deleted from namespace '$NAMESPACE'"
            debug_log "Delete output: $DELETE_OUTPUT"
        else
            echo "ERROR: Error deleting NAD '$NAD_NAME'" >&2
            echo "   Error details: $DELETE_OUTPUT" >&2
            return 1
        fi
    else
        # NAD doesn't exist
        echo "- NAD '$NAD_NAME' not found in namespace '$NAMESPACE' (already deleted or never existed)"
    fi
}

# Export functions for parallel execution
export -f create_nad delete_nad debug_log
export K8S_CMD PREFIX NAMESPACE BRIDGE LABELS_YAML DESCRIPTION_TEMPLATE MACSPOOFCHK DRY_RUN DEBUG

echo "Using command: $K8S_CMD"

if [ "$DELETE_MODE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN DELETE MODE - Would delete bridge NADs from $PREFIX$START to $PREFIX$END"
        echo "Namespace: '$NAMESPACE'"
        seq "$START" "$END" | while read -r vlan_id; do
            delete_nad "$vlan_id"
        done
    else
        echo "Deleting bridge NADs from $PREFIX$START to $PREFIX$END in namespace '$NAMESPACE'..."
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
    fi
elif [ "$DRY_RUN" = true ]; then
    echo "DRY RUN MODE - Showing bridge NAD templates from $PREFIX$START to $PREFIX$END"
    echo "Namespace: '$NAMESPACE', Bridge: $BRIDGE, MAC spoof check: $MACSPOOFCHK"
    # In dry run, limit to first few examples to avoid overwhelming output
    if [ $((END - START + 1)) -gt 5 ]; then
        echo "Showing first 5 templates (total range: $START-$END):"
        seq "$START" $((START + 4)) | while read -r vlan_id; do
            create_nad "$vlan_id"
        done
        echo "... (remaining $((END - START + 1 - 5)) templates would be similar)"
    else
        seq "$START" "$END" | while read -r vlan_id; do
            create_nad "$vlan_id"
        done
    fi
else
    echo "Creating bridge NADs from $PREFIX$START to $PREFIX$END in namespace '$NAMESPACE'..."
    echo "Bridge: $BRIDGE, MAC spoof check: $MACSPOOFCHK, Parallel jobs: $JOBS"
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
