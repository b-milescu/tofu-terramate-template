# state-backend

Creates the Cloud Storage bucket, Cloud KMS key ring and key that hold one Google Cloud project and region's OpenTofu state. The bucket has object versioning, the state key as its default customer-managed encryption key, uniform bucket-level access, enforced public access prevention, expiry of noncurrent versions after 90 days, `force_destroy = false` and `prevent_destroy`. The key rotates every 90 days, has `prevent_destroy`, and the module grants it to the project's Cloud Storage service agent only; roles that the project or an ancestor grants on keys are not restricted. Cloud KMS cannot delete key rings or keys: destroying the key ring only forgets it, destroying the key forgets it and schedules its versions for destruction, after which data encrypted with it is unreadable. Applied once per project and region through the generated call in `stacks/<environment>/<region>/state-backend`; the project and the region come from that stack's provider block.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 8.0, < 9.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | >= 8.0, < 9.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_kms_crypto_key.state](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key) | resource |
| [google_kms_crypto_key_iam_member.gcs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key_iam_member) | resource |
| [google_kms_key_ring.state](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_key_ring) | resource |
| [google_storage_bucket.state](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_project_service_account.gcs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/storage_project_service_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Globally unique name of the OpenTofu state bucket. | `string` | n/a | yes |
| <a name="input_kms_key_name"></a> [kms\_key\_name](#input\_kms\_key\_name) | Name of the KMS crypto key that encrypts the state bucket. | `string` | n/a | yes |
| <a name="input_kms_key_ring_name"></a> [kms\_key\_ring\_name](#input\_kms\_key\_ring\_name) | Name of the KMS key ring (key rings cannot be deleted or renamed). | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Region of the state bucket and the KMS key ring, e.g. europe-west3. Both must live in the same location. | `string` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
