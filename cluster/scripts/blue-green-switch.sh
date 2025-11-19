#!/bin/bash
# Blue-Green Deployment Switcher
# Usage: ./blue-green-switch.sh <app-name> [namespace] [--rollback]

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
APP_NAME=$1
NAMESPACE=${2:-prod}
ROLLBACK=${3:-}

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app-name> [namespace] [--rollback]"
    echo ""
    echo "Examples:"
    echo "  $0 wordpress prod              # Switch WordPress in prod"
    echo "  $0 discourse stage             # Switch Discourse in stage"
    echo "  $0 wordpress prod --rollback   # Rollback to previous version"
    exit 1
fi

# Get current version from service selector
CURRENT_VERSION=$(kubectl get service "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector.version}' 2>/dev/null)

if [ -z "$CURRENT_VERSION" ]; then
    log_error "Service $APP_NAME not found in namespace $NAMESPACE"
    exit 1
fi

# Determine target version
if [ "$ROLLBACK" == "--rollback" ]; then
    # Rollback to previous version (stored in annotation)
    PREVIOUS_VERSION=$(kubectl get service "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.previous-version}' 2>/dev/null)
    if [ -z "$PREVIOUS_VERSION" ]; then
        log_error "No previous version found for rollback. Annotation 'previous-version' not set."
        exit 1
    fi
    NEW_VERSION=$PREVIOUS_VERSION
    log_warn "Rolling back $APP_NAME from $CURRENT_VERSION to $NEW_VERSION"
else
    # Switch to the other version
    if [ "$CURRENT_VERSION" == "blue" ]; then
        NEW_VERSION="green"
    elif [ "$CURRENT_VERSION" == "green" ]; then
        NEW_VERSION="blue"
    else
        log_error "Unknown current version: $CURRENT_VERSION (expected 'blue' or 'green')"
        exit 1
    fi
    log_info "Switching $APP_NAME from $CURRENT_VERSION to $NEW_VERSION in $NAMESPACE"
fi

# Check if target deployment exists
TARGET_DEPLOYMENT="${APP_NAME}-${NEW_VERSION}"
if ! kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    log_error "Target deployment $TARGET_DEPLOYMENT not found in namespace $NAMESPACE"
    log_info "Available deployments:"
    kubectl get deployments -n "$NAMESPACE" -l app="$APP_NAME"
    exit 1
fi

# Check if target deployment is ready
READY_REPLICAS=$(kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED_REPLICAS=$(kubectl get deployment "$TARGET_DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

if [ "$READY_REPLICAS" != "$DESIRED_REPLICAS" ]; then
    log_warn "Target deployment $TARGET_DEPLOYMENT is not fully ready ($READY_REPLICAS/$DESIRED_REPLICAS)"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        exit 0
    fi
fi

# Perform the switch
log_info "Updating service selector..."

# Save current version as previous (for rollback)
kubectl annotate service "$APP_NAME" -n "$NAMESPACE" previous-version="$CURRENT_VERSION" --overwrite

# Patch service selector
kubectl patch service "$APP_NAME" -n "$NAMESPACE" -p "{\"spec\":{\"selector\":{\"version\":\"$NEW_VERSION\"}}}"

log_info "✅ Traffic switched to $NEW_VERSION"
echo ""

# Monitor the switch
log_info "Monitoring new version for 30 seconds..."
echo "  (Press Ctrl+C to skip monitoring)"
echo ""

for i in {1..30}; do
    # Get current pod status
    PODS=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME",version="$NEW_VERSION" --no-headers 2>/dev/null | wc -l)
    RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME",version="$NEW_VERSION" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

    echo -ne "\r  Pods running: $RUNNING/$PODS (${i}s)"
    sleep 1
done

echo ""
echo ""

# Final status check
log_info "Current status:"
kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME",version="$NEW_VERSION"
echo ""

# Provide next steps
log_info "Next steps:"
echo "  1. Monitor logs:"
echo "     kubectl logs -f -l app=$APP_NAME,version=$NEW_VERSION -n $NAMESPACE"
echo ""
echo "  2. Check metrics/errors in your monitoring dashboard"
echo ""
echo "  3. If issues arise, rollback immediately:"
echo "     $0 $APP_NAME $NAMESPACE --rollback"
echo ""
echo "  4. If stable, cleanup old deployment:"
echo "     kubectl delete deployment ${APP_NAME}-${CURRENT_VERSION} -n $NAMESPACE"
echo ""

log_info "Blue-green switch complete!"
