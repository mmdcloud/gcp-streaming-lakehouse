# One CMEK per service so a key can be disabled/rotated independently.
locals {
  cmek_services = toset(["bigquery", "pubsub", "gcs", "composer", "dataflow", "artifact"])
}

resource "google_kms_key_ring" "this" {
  name     = "${local.prefix}-keyring"
  location = var.region

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "keys" {
  for_each = local.cmek_services

  name            = "${local.prefix}-${each.key}"
  key_ring        = google_kms_key_ring.this.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # key => list of principals that must be able to use it
  cmek_grants = {
    bigquery = [local.agents.bigquery]
    pubsub   = [local.agents.pubsub]
    gcs      = [local.agents.gcs]
    composer = [local.agents.composer]
    artifact = [local.agents.artifact]
    dataflow = [
      local.agents.dataflow,
      local.agents.compute,
      "serviceAccount:${google_service_account.dataflow.email}",
    ]
  }

  cmek_grant_pairs = merge([
    for key, members in local.cmek_grants : {
      for m in members : "${key}|${m}" => { key = key, member = m }
    }
  ]...)
}

resource "google_kms_crypto_key_iam_member" "grants" {
  for_each = local.cmek_grant_pairs

  crypto_key_id = google_kms_crypto_key.keys[each.value.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value.member

  depends_on = [google_project_service_identity.agents]
}
