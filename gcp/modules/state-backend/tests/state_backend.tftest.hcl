mock_provider "google" {
  # The IAM resource's validator rejects the mock's random string for the member.
  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
      member        = "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

# Real-looking ids make the wiring assertions meaningful (mock ids are random strings).
override_resource {
  target = google_kms_key_ring.state
  values = {
    id = "projects/example-dev/locations/europe-west3/keyRings/example-tfstate"
  }
}

override_resource {
  target = google_kms_crypto_key.state
  values = {
    id = "projects/example-dev/locations/europe-west3/keyRings/example-tfstate/cryptoKeys/tfstate"
  }
}

variables {
  location          = "europe-west3"
  bucket_name       = "example-tfstate-example-dev-europe-west3"
  kms_key_ring_name = "example-tfstate"
  kms_key_name      = "tfstate"
}

run "hardening_wiring_and_lifecycle" {
  command = plan

  assert {
    condition     = google_storage_bucket.state.name == "example-tfstate-example-dev-europe-west3" && google_kms_key_ring.state.name == "example-tfstate" && google_kms_crypto_key.state.name == "tfstate"
    error_message = "The bucket, key ring and key must carry the names passed in."
  }

  assert {
    condition     = google_storage_bucket.state.force_destroy == false && google_storage_bucket.state.uniform_bucket_level_access == true && google_storage_bucket.state.public_access_prevention == "enforced"
    error_message = "force_destroy must stay false, uniform bucket-level access on and public access prevention enforced."
  }

  assert {
    condition     = one(google_storage_bucket.state.versioning).enabled == true
    error_message = "Object versioning must be enabled."
  }

  assert {
    condition     = one(google_storage_bucket.state.encryption).default_kms_key_name == "projects/example-dev/locations/europe-west3/keyRings/example-tfstate/cryptoKeys/tfstate"
    error_message = "The bucket must default to the state key."
  }

  assert {
    condition     = google_kms_crypto_key.state.key_ring == "projects/example-dev/locations/europe-west3/keyRings/example-tfstate"
    error_message = "The key must live in the state key ring."
  }

  assert {
    condition     = google_kms_key_ring.state.location == "europe-west3" && lower(google_storage_bucket.state.location) == google_kms_key_ring.state.location
    error_message = "The key ring and the bucket must share one region (Cloud Storage rejects a default key from another location)."
  }

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "7776000s"
    error_message = "The state key must rotate every 90 days (7776000s)."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gcs.crypto_key_id == google_kms_crypto_key.state.id && google_kms_crypto_key_iam_member.gcs.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter" && google_kms_crypto_key_iam_member.gcs.member == "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    error_message = "Only the Cloud Storage service agent gets encrypt and decrypt on the state key."
  }

  assert {
    condition     = length(google_storage_bucket.state.lifecycle_rule) == 1 && one(google_storage_bucket.state.lifecycle_rule[0].action).type == "Delete" && one(google_storage_bucket.state.lifecycle_rule[0].condition).days_since_noncurrent_time == 90
    error_message = "Noncurrent versions must be deleted after 90 days, and nothing else expires."
  }
}

# A second set of values, so that a name or a location fixed in the module cannot pass: the longest bucket name, other key names, another region.
run "names_and_locations_follow_the_variables" {
  command = plan

  variables {
    location          = "us-central1"
    bucket_name       = format("%063d", 0) # 63 characters, the limit
    kms_key_ring_name = "Other_ring-1"
    kms_key_name      = "other-key_2"
  }

  assert {
    condition     = google_storage_bucket.state.name == format("%063d", 0) && length(google_storage_bucket.state.name) == 63 && google_kms_key_ring.state.name == "Other_ring-1" && google_kms_crypto_key.state.name == "other-key_2"
    error_message = "The bucket (63 characters), the key ring and the key must carry the names passed in."
  }

  assert {
    condition     = lower(google_storage_bucket.state.location) == "us-central1" && google_kms_key_ring.state.location == "us-central1"
    error_message = "The bucket and the key ring must live in the location passed in."
  }
}

run "bucket_name_rejects_goog_prefix" {
  command = plan

  variables {
    bucket_name = "goog-state-bucket"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_rejects_google" {
  command = plan

  variables {
    bucket_name = "my-google-state"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_rejects_google_lookalike" {
  command = plan

  variables {
    bucket_name = "my-g00gle-state"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_rejects_uppercase" {
  command = plan

  variables {
    bucket_name = "TFState"
  }

  expect_failures = [var.bucket_name]
}

run "bucket_name_rejects_64_characters" {
  command = plan

  variables {
    bucket_name = format("%064d", 0) # 64 characters, one over the limit
  }

  expect_failures = [var.bucket_name]
}

run "location_rejects_multi_region" {
  command = plan

  variables {
    location = "EU"
  }

  expect_failures = [var.location]
}

run "location_rejects_zone" {
  command = plan

  variables {
    location = "europe-west3-a"
  }

  expect_failures = [var.location]
}

run "kms_key_ring_name_rejects_dot" {
  command = plan

  variables {
    kms_key_ring_name = "tfstate.ring"
  }

  expect_failures = [var.kms_key_ring_name]
}

run "kms_key_name_rejects_empty" {
  command = plan

  variables {
    kms_key_name = ""
  }

  expect_failures = [var.kms_key_name]
}
