# This Terraform configuration sets up a serverless video transcoding pipeline on GCP.
# It includes:
# - An input Cloud Storage bucket for raw video uploads.
# - An output Cloud Storage bucket for transcoded videos.
# - A Cloud Pub/Sub topic to receive notifications from the input bucket.
# - A Cloud Storage notification configuration to send events to Pub/Sub.
# - A Cloud Run service to run your containerized transcoding application.
# - Necessary IAM permissions for service accounts to interact correctly.
# - A Pub/Sub subscription that triggers the Cloud Run service.

# --- Configuration Variables ---
variable "project_id" {
  description = "Your Google Cloud Project ID."
  type        = string
  default     = "YOUR_GCP_PROJECT_ID" # <<-- IMPORTANT: REPLACE THIS WITH YOUR PROJECT ID
}

variable "region" {
  description = "The GCP region to deploy resources."
  type        = string
  default     = "europe-west1" # Or choose another region, e.g., "us-central1"
}

variable "input_bucket_name_prefix" {
  description = "Prefix for the input Cloud Storage bucket name."
  type        = string
  default     = "raw-videos"
}

variable "output_bucket_name_prefix" {
  description = "Prefix for the output Cloud Storage bucket name."
  type        = string
  default     = "transcoded-videos"
}

variable "cloud_run_service_name" {
  description = "Name for the Cloud Run service."
  type        = string
  default     = "video-transcoder"
}

variable "cloud_run_image" {
  description = "Docker image for the Cloud Run service. REPLACE THIS WITH YOUR ACTUAL TRANSCoder IMAGE."
  type        = string
  # Using a placeholder image; in production, replace with your image like:
  # "gcr.io/your-project-id/your-transcoder-image:latest"
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

# --- GCP Provider Configuration ---
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Data Source: Project Number (needed for Pub/Sub service account email) ---
data "google_project" "project" {
  project_id = var.project_id
}

# --- 1. Cloud Storage Buckets ---

# Input Bucket: Where raw video files are uploaded
resource "google_storage_bucket" "input_bucket" {
  name          = "${var.input_bucket_name_prefix}-${var.project_id}"
  project       = var.project_id
  location      = "EU" # Bucket location can be multi-regional, regional, or dual-region
  force_destroy = false # Set to true to allow deletion of non-empty buckets for dev/test
  uniform_bucket_level_access = true # Recommended for consistent permissions

  labels = {
    env = "dev"
    use = "input-videos"
  }
}

# Output Bucket: Where transcoded video files are stored
resource "google_storage_bucket" "output_bucket" {
  name          = "${var.output_bucket_name_prefix}-${var.project_id}"
  project       = var.project_id
  location      = "EU" # Bucket location
  force_destroy = false # Set to true to allow deletion of non-empty buckets for dev/test
  uniform_bucket_level_access = true # Recommended

  labels = {
    env = "dev"
    use = "output-videos"
  }
}

# --- 2. Cloud Pub/Sub Topic ---

# Topic for Cloud Storage to send notifications to
resource "google_pubsub_topic" "transcode_topic" {
  name    = "${var.cloud_run_service_name}-transcode-topic"
  project = var.project_id
  labels = {
    env = "dev"
    use = "transcode-events"
  }
}

# --- 3. Cloud Storage Notification to Pub/Sub ---

# Grant the Cloud Storage service account permission to publish to the Pub/Sub topic
# This ensures Cloud Storage can send events.
resource "google_pubsub_topic_iam_member" "default_gcs_pubsub_publisher" {
  topic   = google_pubsub_topic.transcode_topic.id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# Configure the input bucket to send notifications for new object finalizations to the Pub/Sub topic
resource "google_storage_notification" "input_bucket_notification" {
  bucket         = google_storage_bucket.input_bucket.name
  payload_format = "JSON_API_V1" # Recommended format
  topic          = google_pubsub_topic.transcode_topic.id
  event_types    = ["OBJECT_FINALIZE"] # Trigger on new object creation/overwriting
  # object_name_prefix = "videos/" # Optional: only trigger for objects under a specific prefix
  depends_on = [google_pubsub_topic_iam_member.default_gcs_pubsub_publisher]
}

# --- 4. Service Account for Cloud Run ---

# A dedicated service account for the Cloud Run service for least privilege
resource "google_service_account" "cloud_run_sa" {
  account_id   = "${var.cloud_run_service_name}-sa"
  display_name = "Service Account for ${var.cloud_run_service_name} Cloud Run service"
  project      = var.project_id
}

# Grant Cloud Run Service Account permissions to access buckets
resource "google_project_iam_member" "cloud_run_sa_viewer_input_bucket" {
  project = var.project_id
  role    = "roles/storage.objectViewer" # To read from input bucket
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "cloud_run_sa_creator_output_bucket" {
  project = var.project_id
  role    = "roles/storage.objectCreator" # To write to output bucket
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Grant necessary permissions for Cloud Run to log and monitor
resource "google_project_iam_member" "cloud_run_sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "cloud_run_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# If your Cloud Run image is in Artifact Registry (recommended over GCR):
resource "google_project_iam_member" "cloud_run_sa_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
  # Note: This is a project-level role. For more granular control, you could bind it to a specific repository.
}


# --- 5. Cloud Run Service ---

resource "google_cloud_run_v2_service" "transcoder_service" {
  name     = var.cloud_run_service_name
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.cloud_run_sa.email
    containers {
      image = var.cloud_run_image
      # Define environment variables if your transcoder needs them (e.g., bucket names)
      # env {
      #   name  = "INPUT_BUCKET"
      #   value = google_storage_bucket.input_bucket.name
      # }
      # env {
      #   name  = "OUTPUT_BUCKET"
      #   value = google_storage_bucket.output_bucket.name
      # }
      resources {
        cpu    = "2"    # 2 vCPUs
        memory = "4Gi"  # 4 GB memory
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 5 # Adjust based on expected concurrency and costs
    }
    timeout = "900s" # 15 minutes. Adjust based on expected transcoding duration, up to 3600s by default (60 minutes)
                     # For longer than 60 minutes, you need to use a job-based approach or increase limit
                     # For jobs up to 24h, you'd use Cloud Run Jobs, not services.
  }

  # Allow unauthenticated invocations (useful for Pub/Sub push, but consider stricter auth for HTTP endpoints)
  # For production, consider using IAP or a custom authorizer if exposing directly.
  # For Pub/Sub push, the Pub/Sub service account provides the authentication.
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# Allow Pub/Sub to invoke the Cloud Run service
# The Pub/Sub service account needs the 'roles/run.invoker' role on the Cloud Run service.
resource "google_cloud_run_service_iam_member" "pubsub_invoker" {
  location = google_cloud_run_v2_service.transcoder_service.location
  service  = google_cloud_run_v2_service.transcoder_service.name
  role     = "roles/run.invoker"
  # The Pub/Sub service account is a Google-managed service account
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# --- 6. Cloud Pub/Sub Subscription for Cloud Run ---

# Subscription that pushes messages to the Cloud Run service
resource "google_pubsub_subscription" "transcode_subscription" {
  name    = "${var.cloud_run_service_name}-transcode-sub"
  project = var.project_id
  topic   = google_pubsub_topic.transcode_topic.name

  ack_deadline_seconds = 600 # 10 minutes. Time for Cloud Run to acknowledge message.

  # Configure push delivery to the Cloud Run service
  push_config {
    push_endpoint = google_cloud_run_v2_service.transcoder_service.uri # Use the service URI
    # Authenticate push requests using the Cloud Run service account
    oidc_token {
      service_account_email = google_service_account.cloud_run_sa.email
    }
  }

  labels = {
    env = "dev"
    use = "transcode-trigger"
  }

  depends_on = [
    google_cloud_run_service_iam_member.pubsub_invoker,
    google_cloud_run_v2_service.transcoder_service,
    google_service_account.cloud_run_sa
  ]
}

# --- Outputs (for easy access to deployed resources) ---
output "input_bucket_url" {
  description = "URL of the input Cloud Storage bucket."
  value       = google_storage_bucket.input_bucket.url
}

output "output_bucket_url" {
  description = "URL of the output Cloud Storage bucket."
  value       = google_storage_bucket.output_bucket.url
}

output "pubsub_topic_name" {
  description = "Name of the Pub/Sub topic for video transcoding events."
  value       = google_pubsub_topic.transcode_topic.name
}

output "cloud_run_service_url" {
  description = "URL of the deployed Cloud Run transcoding service."
  value       = google_cloud_run_v2_service.transcoder_service.uri
}

output "cloud_run_service_account_email" {
  description = "Email of the service account used by Cloud Run."
  value       = google_service_account.cloud_run_sa.email
}

