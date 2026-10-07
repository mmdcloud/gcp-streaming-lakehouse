variable "name" {}
variable "network" {}
variable "subnetwork" {}
variable "template_gcs_path" {
  type    = string
  default = ""
}
variable "temp_gcs_location" {}
variable "service_account_email" {}
variable "parameters" {
  type    = map(string)
  default = {}
}
variable "additional_experiments" {
  type = list(string)
}

variable "is_flex" {
  type    = bool
  default = false
}

variable "enable_streaming_engine" {
  type    = bool
  default = false
}
variable "deletion_policy" {
  type    = string
  default = ""
}
variable "transform_name_mapping" {
  type    = map(string)
  default = {}
}
variable "ip_configuration" {
  type    = string
  default = "WORKER_IP_PUBLIC"
}
variable "on_delete" {
  type    = string
  default = "cancel"
}
variable "machine_type" {
  type    = string
  default = null
}
variable "max_workers" {
  type    = number
  default = 0
}
variable "kms_key_name" {
  type    = string
  default = null
}
variable "skip_wait_on_job_termination" {
  type    = bool
  default = false
}
variable "labels" {
  type    = map(string)
  default = {}
}

variable "num_workers" {
  type    = number
  default = 0
}
variable "launcher_machine_type" {
  type    = string
  default = null
}
variable "sdk_container_image" {
  type    = string
  default = null
}
variable "staging_location" {
  type    = string
  default = null
}
variable "autoscaling_algorithm" {
  type    = string
  default = null
}
variable "container_spec_gcs_path" {
  type    = string
  default = null
}
variable "additional_pipeline_options" {
  type    = set(string)
  default = []
}
variable "create_ignore_already_exists" {
  type    = bool
  default = false
}