locals {
  bucket_settings = {
    lake      = { versioning = true, expire_prefixes = [] }
    dataflow  = { versioning = false, expire_prefixes = ["tmp/", "staging/"] }
    artifacts = { versioning = true, expire_prefixes = ["dq-docs/"] }
  }
}

resource "google_storage_bucket" "buckets" {
  for_each = local.bucket_settings

  name                        = local.buckets[each.key]
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = !var.deletion_protection
  labels                      = local.labels

  encryption {
    default_kms_key_name = google_kms_crypto_key.keys["gcs"].id
  }

  versioning {
    enabled = each.value.versioning
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  dynamic "lifecycle_rule" {
    for_each = each.value.versioning ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        days_since_noncurrent_time = 14
        with_state                 = "ARCHIVED"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = each.value.expire_prefixes
    content {
      action {
        type = "Delete"
      }
      condition {
        age            = 14
        matches_prefix = [lifecycle_rule.value]
      }
    }
  }

  # Clean up abandoned multipart uploads.
  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = 3
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.grants]
}

############################
# Container registry for the Flex Template image and the dbt/GE runner image
############################
resource "google_artifact_registry_repository" "images" {
  repository_id = "${local.prefix}-images"
  location      = var.region
  format        = "DOCKER"
  description   = "Dataflow flex-template + dbt/GE runner images"
  kms_key_name  = google_kms_crypto_key.keys["artifact"].id
  labels        = local.labels

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.grants]
}
