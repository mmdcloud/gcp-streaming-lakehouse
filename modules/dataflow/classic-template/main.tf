resource "google_dataflow_job" "job" {
  name                         = var.name
  template_gcs_path            = var.template_gcs_path
  temp_gcs_location            = var.temp_gcs_location
  network                      = var.network
  subnetwork                   = var.subnetwork
  enable_streaming_engine      = var.enable_streaming_engine
  transform_name_mapping       = var.transform_name_mapping
  ip_configuration             = var.ip_configuration
  on_delete                    = var.on_delete
  machine_type                 = var.machine_type
  max_workers                  = var.max_workers
  kms_key_name                 = var.kms_key_name
  skip_wait_on_job_termination = var.skip_wait_on_job_termination
  labels                       = var.labels
  service_account_email        = var.service_account_email
  additional_experiments       = var.additional_experiments
  parameters                   = var.parameters
}