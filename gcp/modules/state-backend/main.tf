# The Cloud Storage service agent of the stack's project; the API creates it on first call, so always look it up.
data "google_storage_project_service_account" "gcs" {}

# Cloud KMS cannot delete key rings: destroying one only forgets it (drops it from state).
resource "google_kms_key_ring" "state" {
  name     = var.kms_key_ring_name
  location = var.location

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud KMS cannot delete keys either: destroying one forgets it and schedules its versions for destruction, after which data encrypted with it is unreadable.
resource "google_kms_crypto_key" "state" {
  name            = var.kms_key_name
  key_ring        = google_kms_key_ring.state.id
  rotation_period = "7776000s" # 90 days; earlier key versions stay enabled, so older state versions stay readable

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gcs" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = data.google_storage_project_service_account.gcs.member
}

# Access logging needs a separate log bucket; add one per organisation.
#trivy:ignore:GCP-0077
resource "google_storage_bucket" "state" {
  #checkov:skip=CKV_GCP_62:Access logging needs a separate log bucket; add one per organisation.
  name          = var.bucket_name
  location      = var.location
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.state.id
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = 90
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  # Cloud Storage rejects a default key its service agent cannot use yet.
  depends_on = [google_kms_crypto_key_iam_member.gcs]
}
