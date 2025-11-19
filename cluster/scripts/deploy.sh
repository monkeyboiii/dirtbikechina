#!/bin/bash
# Kubernetes Deployment Script for Dirtbikechina
# Usage: ./deploy.sh [environment] [component]
#   environment: prod | stage | dev | test | all
#   component: infra | apps | ingress | backups | all (default)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 [environment] [component]"
    echo ""
    echo "Environments:"
    echo "  prod    - Production environment"
    echo "  stage   - Staging environment"
    echo "  dev     - Development environment"
    echo "  test    - Testing environment"
    echo "  all     - All environments"
    echo ""
    echo "Components:"
    echo "  infra    - Infrastructure (databases)"
    echo "  apps     - Applications (WordPress, Discourse, etc.)"
    echo "  ingress  - Ingress routes"
    echo "  backups  - Backup CronJobs"
    echo "  all      - All components (default)"
    echo ""
    echo "Examples:"
    echo "  $0 prod all          # Deploy everything to production"
    echo "  $0 stage apps        # Deploy only apps to staging"
    echo "  $0 dev infra         # Deploy only databases to dev"
    exit 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    # Check namespaces exist
    if ! kubectl get namespace prod &> /dev/null; then
        log_warn "Namespaces not found. Creating..."
        kubectl apply -f "$CLUSTER_DIR/base/namespaces.yaml"
    fi

    log_info "Prerequisites OK"
}

deploy_infra() {
    local env=$1
    log_info "Deploying infrastructure to $env..."

    # Deploy databases (always in 'infra' namespace, shared across environments)
    kubectl apply -f "$CLUSTER_DIR/base/databases/postgres-statefulset.yaml"
    kubectl apply -f "$CLUSTER_DIR/base/databases/mysql-statefulset.yaml"

    # Wait for databases to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgres -n infra --timeout=300s || true

    log_info "Waiting for MySQL to be ready..."
    kubectl wait --for=condition=ready pod -l app=mysql -n infra --timeout=300s || true

    # Run discourse init job
    log_info "Running Discourse initialization job..."
    kubectl delete job discourse-init -n infra --ignore-not-found=true
    kubectl apply -f "$CLUSTER_DIR/base/databases/discourse-init-job.yaml"

    # Wait for init job to complete
    kubectl wait --for=condition=complete job/discourse-init -n infra --timeout=300s || {
        log_error "Discourse init job failed. Check logs:"
        echo "  kubectl logs -n infra job/discourse-init"
        exit 1
    }

    log_info "Infrastructure deployment complete"
}

deploy_apps() {
    local env=$1
    log_info "Deploying applications to $env..."

    if [ -f "$CLUSTER_DIR/environments/$env/kustomization.yaml" ]; then
        # Use Kustomize if available
        log_info "Deploying with Kustomize..."
        kubectl apply -k "$CLUSTER_DIR/environments/$env/"
    else
        # Fallback to direct apply
        log_info "Deploying base manifests..."
        kubectl apply -f "$CLUSTER_DIR/base/apps/" -n "$env"
    fi

    log_info "Application deployment complete"
}

deploy_ingress() {
    log_info "Deploying ingress routes..."

    # Check if cert-manager is installed
    if ! kubectl get namespace cert-manager &> /dev/null; then
        log_warn "cert-manager not found. Installing..."
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
        log_info "Waiting for cert-manager to be ready..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
    fi

    # Apply ingress routes
    kubectl apply -f "$CLUSTER_DIR/base/ingress/traefik-ingress-routes.yaml"

    log_info "Ingress deployment complete"
}

deploy_backups() {
    log_info "Deploying backup CronJobs..."

    kubectl apply -f "$CLUSTER_DIR/backup/postgres-backup-cronjob.yaml"

    log_info "Backup deployment complete"
}

deploy_environment() {
    local env=$1
    local component=${2:-all}

    log_info "Starting deployment to $env (component: $component)"

    case $component in
        infra)
            deploy_infra "$env"
            ;;
        apps)
            deploy_apps "$env"
            ;;
        ingress)
            deploy_ingress
            ;;
        backups)
            deploy_backups
            ;;
        all)
            deploy_infra "$env"
            deploy_apps "$env"
            deploy_ingress
            deploy_backups
            ;;
        *)
            log_error "Unknown component: $component"
            usage
            ;;
    esac

    log_info "Deployment to $env complete!"
}

# Main script
ENVIRONMENT=${1:-}
COMPONENT=${2:-all}

if [ -z "$ENVIRONMENT" ]; then
    usage
fi

check_prerequisites

case $ENVIRONMENT in
    prod|stage|dev|test)
        deploy_environment "$ENVIRONMENT" "$COMPONENT"
        ;;
    all)
        for env in dev test stage prod; do
            log_info "===== Deploying to $env ====="
            deploy_environment "$env" "$COMPONENT"
            echo ""
        done
        ;;
    *)
        log_error "Unknown environment: $ENVIRONMENT"
        usage
        ;;
esac

log_info "All deployments complete!"
log_info ""
log_info "Verify deployment with:"
echo "  kubectl get pods -A"
echo "  kubectl get svc -A"
echo "  kubectl get ingressroute -A"
