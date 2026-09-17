##############################################################################
# central/ — input variables
#
# Schematics renders these as workspace input fields.
# - sensitive = true  → value is masked in Schematics logs and UI.
# - All descriptions are plain strings (no nested blocks).
# - Do NOT add an ibmcloud_api_key variable; credentials come from the
#   Schematics execution identity.
##############################################################################

variable "ibmcloud_region" {
  description = "IBM Cloud region for the provider (e.g. us-south). Must be the region where the central IBM Cloud Logs instance is located."
  type        = string
  default     = "us-south"
}

variable "enterprise_name" {
  description = "Display name of the IBM Cloud Enterprise as shown in the Enterprise dashboard (ibmcloud enterprise show). Used to auto-discover all child account IDs."
  type        = string
}

variable "central_logs_instance_id" {
  description = "GUID of the IBM Cloud Logs instance in the centralized Logging Account. Used as the target resource for all S2S Sender authorizations."
  type        = string
  sensitive   = true
}

variable "excluded_account_ids" {
  description = "List of account IDs to exclude from auto-discovery. Always include the management account ID and the central Logging Account ID to avoid self-authorization."
  type        = list(string)
  default     = []
}
