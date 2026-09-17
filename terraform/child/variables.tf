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

variable "central_logs_crn" {
  description = "Full CRN of the IBM Cloud Logs instance in the centralized Logging Account. Used as the destination for both Logs Routing and Activity Tracker."
  type        = string
  sensitive   = true
}

variable "logs_router_metadata_region" {
  description = "Primary metadata region for IBM Cloud Logs Routing V3 (e.g. us-south). Controls where Logs Routing route metadata is stored."
  type        = string
}

variable "atracker_target_region" {
  description = "IBM Cloud region where the Activity Tracker target resource is created. Typically matches the child account's primary region."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in Activity Tracker resource names to identify this child account (e.g. prod-us-south). Must be unique per child workspace."
  type        = string
}
