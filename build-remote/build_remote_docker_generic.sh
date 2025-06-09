#!/bin/bash

# --- Configuration ---
# IMPORTANT: These are default values. GCP_PROJECT_ID can be overridden by --project switch.
# You can get VM_NAME and VM_ZONE from `terraform output`
DEFAULT_GCP_PROJECT_ID="your-gcp-project-id" # e.g., "my-file-transfer-project-12345"
VM_NAME="docker-builder-vm"
VM_ZONE="europe-west1-b" # e.g., "europe-west1-b"

ARTIFACT_REGISTRY_LOCATION="europe-west1" # Should match var.artifact_registry_location
ARTIFACT_REGISTRY_REPO_ID="docker-images" # Should match var.artifact_registry_repository_id
# The full registry host will be like: europe-west1-docker.pkg.dev
ARTIFACT_REGISTRY_HOST="${ARTIFACT_REGISTRY_LOCATION}-docker.pkg.dev"

# Remote directory on the VM where files will be uploaded.
REMOTE_PARENT_BUILD_DIR="/tmp/remote_docker_build_context"

# Timeout for VM start/stop operations (in seconds)
VM_OPERATION_TIMEOUT=300 # 5 minutes
SSH_READY_TIMEOUT=120    # 2 minutes for SSH to become ready

# --- Script Parameters (will be parsed from arguments) ---
LOCAL_BUILD_CONTEXT_DIR=""
DOCKER_IMAGE_NAME=""
DOCKER_IMAGE_TAG=""
NO_CLEANUP=false
PROJECT_ID_OVERRIDE=""

# --- Helper Functions ---

get_resolved_project_id() {
    if [ -n "${PROJECT_ID_OVERRIDE}" ]; then
        echo "${PROJECT_ID_OVERRIDE}"
    else
        echo "${DEFAULT_GCP_PROJECT_ID}"
    fi
}

get_vm_status() {
    local resolved_project_id=$(get_resolved_project_id)
    gcloud compute instances describe "${VM_NAME}" --zone="${VM_ZONE}" --project="${resolved_project_id}" --format="value(status)" 2>/dev/null
}

get_vm_external_ip() {
    local resolved_project_id=$(get_resolved_project_id)
    gcloud compute instances describe "${VM_NAME}" --zone="${VM_ZONE}" --project="${resolved_project_id}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null
}

wait_for_vm_status() {
    local target_status="$1"
    local timeout="$2"
    local elapsed=0

    echo "Waiting for VM '${VM_NAME}' to be '${target_status}' (timeout: ${timeout}s)..."
    while [ "${elapsed}" -lt "${timeout}" ]; do
        current_status=$(get_vm_status)
        if [ "${current_status}" = "${target_status}" ]; then
            echo "VM '${VM_NAME}' is now '${target_status}'."
            return 0
        fi
        printf "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Error: VM '${VM_NAME}' did not reach '${target_status}' within ${timeout} seconds. Current status: ${current_status}"
    return 1
}

wait_for_ssh_port() {
    local vm_ip="$1"
    local timeout="$2"
    local elapsed=0

    echo "Waiting for SSH port 22 on ${vm_ip} to be ready (timeout: ${timeout}s)..."
    while [ "${elapsed}" -lt "${timeout}" ]; do
        if nc -zvw1 "${vm_ip}" 22 &> /dev/null; then
            echo "SSH port 22 on ${vm_ip} is ready."
            return 0
        fi
        printf "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Error: SSH port 22 on ${vm_ip} did not become ready within ${timeout} seconds."
    return 1
}

execute_remote_command() {
    local command="$1"
    local resolved_project_id=$(get_resolved_project_id)
    echo "Executing remote command: ${command}"
    if ! gcloud compute ssh "${VM_NAME}" --zone="${VM_ZONE}" --project="${resolved_project_id}" -- "${command}"; then
        echo "Error: Remote command failed."
        return 1
    fi
    return 0
}

scp_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local resolved_project_id=$(get_resolved_project_id)
    echo "Uploading '${local_path}' to VM:'${remote_path}'..."
    if ! gcloud compute scp --recurse "${local_path}" "${VM_NAME}:${remote_path}" --zone="${VM_ZONE}" --project="${resolved_project_id}"; then
        echo "Error: Failed to upload files."
        return 1
    fi
    return 0
}


# --- Argument Parsing ---
temp_args=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-cleanup)
            NO_CLEANUP=true
            echo "Cleanup phase will be skipped for debugging."
            shift
            ;;
        --project)
            if [ -z "$2" ]; then
                echo "Error: --project requires an argument."
                exit 1
            fi
            PROJECT_ID_OVERRIDE="$2"
            echo "Using overridden project ID: ${PROJECT_ID_OVERRIDE}"
            shift 2
            ;;
        *) # Positional arguments
            temp_args+=("$1")
            shift
            ;;
    esac
done

LOCAL_BUILD_CONTEXT_DIR="${temp_args[0]}"
DOCKER_IMAGE_NAME="${temp_args[1]}"
DOCKER_IMAGE_TAG_ARG="${temp_args[2]}" # Store the provided tag, if any

if [ -z "${LOCAL_BUILD_CONTEXT_DIR}" ] || [ -z "${DOCKER_IMAGE_NAME}" ]; then
    echo "Error: Missing required arguments."
    echo "Usage: $0 [--no-cleanup] [--project <GCP_PROJECT_ID>] <local_build_context_path> <docker_image_name> [docker_image_tag]"
    echo ""
    echo "  <local_build_context_path> : Path to the local directory containing Dockerfile, Go code, etc."
    echo "  <docker_image_name>        : The base name for the Docker image (e.g., 'gcs-downloader')"
    echo "  [docker_image_tag]         : Optional. The tag for the Docker image (e.g., 'v1.0.0')."
    echo "                               If not provided, the script will try to read it from a './VERSION' file."
    echo "                               If './VERSION' is also not found, it defaults to 'latest'."
    echo ""
    echo "Example: $0 ./gcs_downloader_project gcs-downloader v1.0.0"
    echo "Example using VERSION file: $0 ./gcs_downloader_project gcs-downloader"
    echo "Example with project override: $0 --project my-other-project ./gcs_downloader_project gcs-downloader v1.0.0"
    echo "Example for debugging: $0 --no-cleanup ./gcs_downloader_project gcs-downloader v1.0.0"
    exit 1
fi

if [ -n "${DOCKER_IMAGE_TAG_ARG}" ]; then
    DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG_ARG}"
    echo "Using provided Docker image tag: ${DOCKER_IMAGE_TAG}"
else
    VERSION_FILE="${LOCAL_BUILD_CONTEXT_DIR}/VERSION"
    if [ -f "${VERSION_FILE}" ]; then
        DOCKER_IMAGE_TAG=$(cat "${VERSION_FILE}" | tr -d '\n' | tr -d '\r') # Remove newlines/carriage returns
        if [ -z "${DOCKER_IMAGE_TAG}" ]; then
            echo "Warning: VERSION file is empty. Defaulting Docker image tag to 'latest'."
            DOCKER_IMAGE_TAG="latest"
        else
            echo "Using Docker image tag from ${VERSION_FILE}: ${DOCKER_IMAGE_TAG}"
        fi
    else
        echo "Warning: No VERSION file found at ${VERSION_FILE}. Defaulting Docker image tag to 'latest'."
        DOCKER_IMAGE_TAG="latest"
    fi
fi

VM_PROJECT_ID=$(get_resolved_project_id)

REMOTE_CONTEXT_SUBDIR=$(basename "${LOCAL_BUILD_CONTEXT_DIR}")
REMOTE_ACTUAL_BUILD_DIR="${REMOTE_PARENT_BUILD_DIR}/${REMOTE_CONTEXT_SUBDIR}"

FULL_IMAGE_NAME_VERSION="${ARTIFACT_REGISTRY_HOST}/${VM_PROJECT_ID}/${ARTIFACT_REGISTRY_REPO_ID}/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"

FULL_IMAGE_NAME_LATEST="${ARTIFACT_REGISTRY_HOST}/${VM_PROJECT_ID}/${ARTIFACT_REGISTRY_REPO_ID}/${DOCKER_IMAGE_NAME}:latest"


echo "--- Starting On-Demand Remote Docker Build Workflow ---"
echo "Project: ${VM_PROJECT_ID}"
echo "VM: ${VM_NAME} (${VM_ZONE})"
echo "Local Build Context: ${LOCAL_BUILD_CONTEXT_DIR}"
echo "Image (versioned): ${FULL_IMAGE_NAME_VERSION}"
echo "Image (latest): ${FULL_IMAGE_NAME_LATEST}"


if ! gcloud auth print-access-token &> /dev/null; then
    echo "Error: gcloud not authenticated. Please run 'gcloud auth application-default login'."
    exit 1
fi
if ! gcloud config set project "${VM_PROJECT_ID}" --quiet; then
    echo "Error: Failed to set gcloud project to ${VM_PROJECT_ID}. Ensure it's valid and you have permissions."
    exit 1
fi


if [ ! -d "${LOCAL_BUILD_CONTEXT_DIR}" ]; then
    echo "Error: Local build context directory not found: ${LOCAL_BUILD_CONTEXT_DIR}"
    exit 1
fi

# Determine which Dockerfile to use (local check to inform remote command)
DOCKERFILE_TO_USE="Dockerfile"
if [ -f "${LOCAL_BUILD_CONTEXT_DIR}/Dockerfile.downloader" ]; then
    DOCKERFILE_TO_USE="Dockerfile.downloader"
    echo "Using Dockerfile: Dockerfile.downloader (locally detected)"
elif [ ! -f "${LOCAL_BUILD_CONTEXT_DIR}/Dockerfile" ]; then
    echo "Error: No 'Dockerfile' or 'Dockerfile.downloader' found in ${LOCAL_BUILD_CONTEXT_DIR}."
    echo "A Dockerfile is required in the root of the build context directory."
    exit 1
else
    echo "Using Dockerfile: Dockerfile (locally detected)"
fi


# --- VM Management: Start VM ---
CURRENT_VM_STATUS=$(get_vm_status)
if [ "${CURRENT_VM_STATUS}" = "RUNNING" ]; then
    echo "VM '${VM_NAME}' is already running. Proceeding with build."
elif [ "${CURRENT_VM_STATUS}" = "TERMINATED" ] || [ -z "${CURRENT_VM_STATUS}" ]; then
    echo "VM '${VM_NAME}' is not running (Current status: ${CURRENT_VM_STATUS}). Starting it now..."
    if ! gcloud compute instances start "${VM_NAME}" --zone="${VM_ZONE}" --project="${VM_PROJECT_ID}" --quiet; then
        echo "Error: Failed to start VM '${VM_NAME}'. Exiting."
        exit 1
    fi
    if ! wait_for_vm_status "RUNNING" "${VM_OPERATION_TIMEOUT}"; then
        exit 1
    fi
    VM_EXTERNAL_IP=$(get_vm_external_ip)
    if [ -z "${VM_EXTERNAL_IP}" ]; then
        echo "Warning: Could not get VM external IP. SSH readiness check may be skipped or fail."
    else
        if ! wait_for_ssh_port "${VM_EXTERNAL_IP}" "${SSH_READY_TIMEOUT}"; then
            echo "Error: SSH not ready. Exiting."
            exit 1 # Exit handled by trap
        fi
    fi
else
    echo "Error: VM '${VM_NAME}' is in an unexpected state: ${CURRENT_VM_STATUS}. Cannot proceed."
    exit 1
fi

cleanup_and_exit() {
    local exit_code="$?"
    local resolved_project_id=$(get_resolved_project_id)
    local vm_is_running_now=$(get_vm_status)

    # --- Step 1: Remote cleanup (MUST happen before VM shutdown) ---
    if [ "${NO_CLEANUP}" = false ]; then # Only clean up if --no-cleanup is NOT specified
        echo "Cleaning up remote build directory on VM (if reachable)..."
        if [ "${vm_is_running_now}" = "RUNNING" ]; then
            if ! execute_remote_command "rm -rf ${REMOTE_PARENT_BUILD_DIR}"; then
                echo "Warning: Failed to clean up remote directory. Manual cleanup might be required on VM: ${REMOTE_PARENT_BUILD_DIR}"
            fi
        else
            echo "VM is not running (${vm_is_running_now}). Skipping remote directory cleanup."
        fi
    else
        echo "Skipping remote build directory cleanup as --no-cleanup was specified."
    fi

    if [ "${CURRENT_VM_STATUS}" = "TERMINATED" ] || [ -z "${CURRENT_VM_STATUS}" ]; then
        echo "Attempting to stop VM '${VM_NAME}' (was started by this script)..."
        if [ "$(get_vm_status)" = "RUNNING" ]; then
            gcloud compute instances stop "${VM_NAME}" --zone="${VM_ZONE}" --project="${resolved_project_id}" --quiet || echo "Warning: Failed to gracefully stop VM, attempting again."
            wait_for_vm_status "TERMINATED" "${VM_OPERATION_TIMEOUT}" || echo "Warning: VM did not reach TERMINATED state."
        else
            echo "VM is already stopped or in an unexpected state. Not attempting to stop."
        fi
    else
        echo "VM was already running upon script start. Not stopping it after script execution."
    fi

    exit "${exit_code}"
}
trap cleanup_and_exit ERR EXIT

# --- Build Process ---

echo "Creating remote parent build directory ${REMOTE_PARENT_BUILD_DIR} on VM..."
if ! execute_remote_command "mkdir -p ${REMOTE_PARENT_BUILD_DIR}"; then
    exit 1 # Exit handled by trap
fi

echo "Uploading build context from '${LOCAL_BUILD_CONTEXT_DIR}' to VM..."
if ! scp_to_remote "${LOCAL_BUILD_CONTEXT_DIR}" "${REMOTE_PARENT_BUILD_DIR}/"; then
    echo "Error: Failed to upload build context. Exiting."
    exit 1 # Exit handled by trap
fi
echo "Build context uploaded successfully. It is now located at: ${REMOTE_ACTUAL_BUILD_DIR}"

echo "Authenticating Docker to Google Artifact Registry: ${ARTIFACT_REGISTRY_HOST}..."
# Use 'sg docker' to ensure gcloud auth configure-docker runs with docker group privileges
if ! execute_remote_command "sg docker -c \"gcloud auth configure-docker ${ARTIFACT_REGISTRY_HOST} --project=${VM_PROJECT_ID} --quiet\""; then
    echo "Error: Failed to configure Docker for Artifact Registry authentication. Ensure gcloud CLI is installed and configured on VM, and VM service account has Artifact Registry Writer permissions."
    exit 1 # Exit handled by trap
fi
echo "Docker successfully configured for Artifact Registry."

echo "Initiating Docker build on VM. This might take a while..."
REMOTE_DOCKER_BUILD_COMMAND="\
    cd ${REMOTE_ACTUAL_BUILD_DIR} && \
    echo '--- Remote directory contents (inside actual build context) before Docker build ---' && \
    ls -l . && \
    echo '--- Starting Docker build ---' && \
    sg docker -c \"docker build -f ${DOCKERFILE_TO_USE} -t ${FULL_IMAGE_NAME_VERSION} .\" \
    "
if ! execute_remote_command "${REMOTE_DOCKER_BUILD_COMMAND}"; then
    echo "Error: Docker build failed on the VM. Check VM logs for details."
    exit 1 # Exit handled by trap
fi
echo "Docker image built successfully on the VM and tagged as: ${FULL_IMAGE_NAME_VERSION}"

echo "Adding 'latest' tag to the image: ${FULL_IMAGE_NAME_VERSION} -> ${FULL_IMAGE_NAME_LATEST}"
if ! execute_remote_command "sg docker -c \"docker tag ${FULL_IMAGE_NAME_VERSION} ${FULL_IMAGE_NAME_LATEST}\""; then
    echo "Error: Failed to add 'latest' tag to the Docker image."
    exit 1 # Exit handled by trap
fi
echo "'latest' tag added successfully."

echo "Pushing Docker image (versioned): ${FULL_IMAGE_NAME_VERSION}..."
if ! execute_remote_command "sg docker -c \"docker push ${FULL_IMAGE_NAME_VERSION}\""; then
    echo "Error: Failed to push versioned Docker image to Artifact Registry."
    exit 1 # Exit handled by trap
fi

echo "Pushing Docker image (latest): ${FULL_IMAGE_NAME_LATEST}..."
if ! execute_remote_command "sg docker -c \"docker push ${FULL_IMAGE_NAME_LATEST}\""; then
    echo "Error: Failed to push 'latest' Docker image to Artifact Registry."
    exit 1 # Exit handled by trap
fi
echo "Docker images pushed successfully to Artifact Registry."

# --- VM Management: Stop VM ---
# The trap will handle stopping the VM and remote cleanup when the script exits.
# Unset trap to avoid double execution on successful path
trap - ERR EXIT
cleanup_and_exit 0
