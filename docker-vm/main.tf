# Configure the Google Cloud provider
# Ensure you've authenticated your gcloud CLI with: gcloud auth application-default login
# And set your project: gcloud config set project YOUR_PROJECT_ID
provider "google" {
  project = var.gcp_project_id
}

# --- Resources ---

resource "google_artifact_registry_repository" "docker_repository" {
  project       = var.gcp_project_id
  location      = var.artifact_registry_location
  repository_id = var.artifact_registry_repository_id
  format        = "DOCKER"
  description   = "Docker repository for built images"

  depends_on = [
    google_project_service.artifact_registry_api_enablement
  ]
}

resource "google_compute_instance" "docker_builder_vm" {
  project      = var.gcp_project_id
  zone         = var.vm_zone
  name         = "docker-builder-vm"
  machine_type = var.vm_machine_type

  scheduling {
    preemptible        = true
    provisioning_model = "SPOT"
    automatic_restart  = false
  }

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 50 # Increase disk size for Docker images if needed
    }
  }

  network_interface {
    network = "default"
    access_config {
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Explicitly define the user to add to the docker group.
    # This user is typically the one created by gcloud compute ssh.
    # Replace 'user' with the actual username you use for SSH.
    USER_TO_ADD="user"

    # --- Debugging lines (optional, for verification) ---
    echo "Startup script: Attempting to add user $${USER_TO_ADD} to docker group." | sudo tee /var/log/startup_script_docker_group_debug.log
    # ----------------------------------------------------

    # Install Docker
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker's official GPG key
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Set up the stable repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | sudo tee -a /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo apt-get install -y make

    # Add the determined user to the docker group
    # Check if docker group exists before adding (docker-ce install usually creates it)
    if ! getent group docker > /dev/null; then
        sudo groupadd docker
    fi
    # Check if the user exists before adding them to the group
    if id "$${USER_TO_ADD}" &>/dev/null; then
        sudo usermod -aG docker "$${USER_TO_ADD}"
        echo "Startup script: User $${USER_TO_ADD} added to docker group." | sudo tee -a /var/log/startup_script_docker_group_debug.log
    else
        echo "Startup script: Warning: User $${USER_TO_ADD} does not exist yet. Cannot add to docker group. It might be created later by gcloud SSH or via a cron job." | sudo tee -a /var/log/startup_script_docker_group_debug.log
        # As a fallback for cases where user might not exist yet,
        # schedule a cron job to add them to docker group on next reboot
        (crontab -l 2>/dev/null; echo "@reboot sleep 60 && /usr/bin/sudo /usr/sbin/usermod -aG docker $${USER_TO_ADD} >/dev/null 2>&1") | crontab -
    fi

    # Enable and start Docker service
    sudo systemctl enable docker
    sudo systemctl start docker

    # NEW: Install gcloud CLI for Artifact Registry authentication
    # This block assumes a Debian/Ubuntu-like OS. Adjust for other distributions.
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    sudo apt-get update
    sudo apt-get install -y google-cloud-cli

    echo "Startup script finished."
  EOF

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append",
      "https://www.googleapis.com/auth/cloud-platform", # Use this for broad access, covering Artifact Registry
      # Or, if you prefer a more specific scope for storage:
      # "https://www.googleapis.com/auth/devstorage.read_write",
    ]
  }

  tags = ["docker-builder-vm"]

  depends_on = [
    google_project_service.compute_api_enablement,
    google_project_service.artifact_registry_api_enablement
  ]
}

# 3. IAM Binding to grant IAP Tunnel User role to the specified user
resource "google_project_iam_member" "iap_tunnel_user_access" {
  project = var.gcp_project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:${var.iap_user_email}"
}

# 4. Ensure Compute Engine API is enabled
resource "google_project_service" "compute_api_enablement" {
  service                    = "compute.googleapis.com"
  project                    = var.gcp_project_id
  disable_on_destroy         = false
  disable_dependent_services = false
}

# 5. Ensure Artifact Registry API is enabled
resource "google_project_service" "artifact_registry_api_enablement" {
  service                    = "artifactregistry.googleapis.com"
  project                    = var.gcp_project_id
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Grant Artifact Registry Writer role to the VM's default service account for the specific repository
resource "google_artifact_registry_repository_iam_member" "repo_writer_role" {
  project    = var.gcp_project_id
  location   = google_artifact_registry_repository.docker_repository.location
  repository = google_artifact_registry_repository.docker_repository.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_compute_instance.docker_builder_vm.service_account[0].email}"
}


# --- Outputs ---
output "docker_builder_vm_name" {
  description = "The name of the Docker builder VM."
  value       = google_compute_instance.docker_builder_vm.name
}
output "docker_builder_vm_zone" {
  description = "The zone of the Docker builder VM."
  value       = google_compute_instance.docker_builder_vm.zone
}
output "artifact_registry_url" {
  description = "The full URL of the Docker Artifact Registry."
  value       = "${var.artifact_registry_location}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_registry_repository_id}"
}
