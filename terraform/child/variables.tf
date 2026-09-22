##############################################################################
# child/ — input variables
#
# Schematics renders these as workspace input fields.
# - sensitive = true  → value is masked in Schematics logs and UI.
# - All descriptions are plain strings (no nested blocks).
# - Do NOT add an ibmcloud_api_key variable; credentials come from the
#   Schematics execution identity.
##############################################################################

variable "ibmcloud_region" {
  description = "IBM Cloud region for the provider (e.g. us-south). Should match the child account's primary region."
  type        = string
  default     = "us-south"
}

##############################################################################
# Central COS archive — supplied from the central/ workspace outputs
##############################################################################

variable "central_cos_bucket_crn" {
  description = "CRN of the central COS bucket where this child account's IBM Cloud Logs instance will archive data after the hot-retention window. Copy this from the central/ workspace's cos_bucket_crn output."
  type        = string
  sensitive   = true
}

variable "central_cos_bucket_endpoint" {
  description = "S3 endpoint of the central COS bucket (public or private depending on logs_service_endpoints). Copy this from the central/ workspace's cos_bucket_s3_endpoint_public or cos_bucket_s3_endpoint_private output."
  type        = string
}

##############################################################################
# Local IBM Cloud Logs instance
##############################################################################

variable "logs_plan" {
  description = "Plan for the IBM Cloud Logs instance created in this child account."
  type        = string
  default     = "standard"
}

variable "logs_resource_group_id" {
  description = "Resource group ID for the IBM Cloud Logs instance. Leave empty to use the account's Default resource group."
  type        = string
  default     = ""
}

variable "logs_service_endpoints" {
  description = "Service endpoints for the IBM Cloud Logs instance: public, private, or public-and-private. Must match the type of endpoint used in central_cos_bucket_endpoint."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private", "public-and-private"], var.logs_service_endpoints)
    error_message = "logs_service_endpoints must be one of: public, private, public-and-private."
  }
}

variable "logs_retention_days" {
  description = "Days this child account's IBM Cloud Logs instance keeps ingested data searchable ('hot') before archiving it to the central COS bucket. Must be one of the values IBM Cloud Logs accepts: 7, 14, 30, 60, 90."
  type        = number
  default     = 30

  validation {
    condition     = contains([7, 14, 30, 60, 90], var.logs_retention_days)
    error_message = "logs_retention_days must be one of: 7, 14, 30, 60, 90."
  }
}

##############################################################################
# Routing configuration
##############################################################################

variable "logs_router_metadata_region" {
  description = "Primary metadata region for IBM Cloud Logs Routing V3 (e.g. us-south). Controls where Logs Routing route metadata is stored."
  type        = string
}

variable "atracker_target_region" {
  description = "IBM Cloud region where the Activity Tracker target resource is created. Typically matches the child account's primary region."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in resource names to identify this child account (e.g. prod-us-south). Must be unique per child workspace."
  type        = string
}
