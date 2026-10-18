mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
}

override_resource {
  target = aws_kms_key.state
  values = {
    arn    = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    key_id = "00000000-0000-0000-0000-000000000000"
  }
}

override_resource {
  target = aws_s3_bucket.state
  values = {
    arn = "arn:aws:s3:::acme-tfstate-nonprod-eu-west-1"
    id  = "acme-tfstate-nonprod-eu-west-1"
  }
}

variables {
  bucket_name    = "acme-tfstate-nonprod-eu-west-1"
  kms_alias_name = "tfstate"
}

run "hardening_wiring_and_policy" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "force_destroy must stay false."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).bucket_key_enabled == true
    error_message = "Bucket keys must be enabled."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "Default encryption must be aws:kms."
  }

  assert {
    condition     = aws_kms_key.state.deletion_window_in_days == 30
    error_message = "The key deletion window must be 30 days."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].kms_master_key_id == aws_kms_key.state.arn
    error_message = "Default encryption must use the state CMK."
  }

  assert {
    condition = jsondecode(aws_s3_bucket_policy.state.policy).Statement == [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = ["arn:aws:s3:::acme-tfstate-nonprod-eu-west-1", "arn:aws:s3:::acme-tfstate-nonprod-eu-west-1/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = ["arn:aws:s3:::acme-tfstate-nonprod-eu-west-1", "arn:aws:s3:::acme-tfstate-nonprod-eu-west-1/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
    error_message = "The bucket policy must be exactly: deny non-TLS requests and deny TLS older than 1.2, on the bucket and its objects."
  }

  assert {
    condition     = aws_kms_alias.state.name == "alias/tfstate" && aws_kms_alias.state.target_key_id == aws_kms_key.state.key_id
    error_message = "The alias must be alias/<kms_alias_name> and point at the state key."
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.state.rule) == 1 && aws_s3_bucket_lifecycle_configuration.state.rule[0].status == "Enabled" && aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90 && aws_s3_bucket_lifecycle_configuration.state.rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Noncurrent versions must expire after 90 days and incomplete multipart uploads after 7."
  }

  assert {
    condition     = length(jsondecode(aws_kms_key.state.policy).Statement) == 1 && jsondecode(aws_kms_key.state.policy).Statement[0].Sid == "AccountAdmin" && jsondecode(aws_kms_key.state.policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:root"
    error_message = "The key policy must be the single AccountAdmin statement for the account root."
  }
}

run "bucket_name_rejects_uppercase" {
  command = plan

  variables {
    bucket_name = "TFState"
  }

  expect_failures = [var.bucket_name]
}

run "kms_alias_name_rejects_alias_prefix" {
  command = plan

  variables {
    kms_alias_name = "alias/tfstate"
  }

  expect_failures = [var.kms_alias_name]
}
