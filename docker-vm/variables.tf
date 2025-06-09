# --- Variables ---
# These variables will be prompted for or can be passed via -var flags or a terraform.tfvars file.

variable "gcp_project_id" {
  description = "Your Google Cloud Project ID."
  type        = string
}

# Variables for Docker Builder VM
variable "vm_region" {
  description = "Region for the Docker builder VM."
  type        = string
  default     = "europe-west1" # Adjust to your preferred region
}
variable "vm_zone" {
  description = "Zone for the Docker builder VM."
  type        = string
  default     = "europe-west1-b" # Default to a zone within europe-west1
}
variable "vm_machine_type" {
  description = "Machine type for the Docker builder VM."
  type        = string
  default     = "e2-medium" # A good balance for general builds
}
variable "vm_image" {
  description = "Image for the Docker builder VM. Debian is good for Docker installations."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "iap_user_email" {
  description = "The email address of the user who will access the VM via IAP (e.g., your-email@example.com)."
  type        = string
}

variable "artifact_registry_location" {
  description = "The region for your Google Artifact Registry (e.g., europe-west1, us-central1)."
  type        = string
  default     = "europe-west1" # Should ideally match your VM region for lower latency
}

variable "artifact_registry_repository_id" {
  description = "The ID of the Docker repository in Artifact Registry (e.g., docker-images)."
  type        = string
  default     = "docker-images" # Default repository ID
}

