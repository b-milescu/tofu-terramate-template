output "bucket_id" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "kms_key_arn" {
  description = "ARN of the state KMS key."
  value       = aws_kms_key.state.arn
}
