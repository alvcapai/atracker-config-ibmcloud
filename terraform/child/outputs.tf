##############################################################################
# child/ — outputs
##############################################################################

output "logs_instance_id" {
  description = "GUID of the IBM Cloud Logs instance created in this child account."
  value       = ibm_resource_instance.logs.guid
}

output "logs_instance_crn" {
  description = "CRN of the IBM Cloud Logs instance created in this child account."
  value       = ibm_resource_instance.logs.crn
}

output "logs_router_target_id" {
  description = "ID of the enterprise-managed Logs Routing V3 target (pointing to the local Logs instance)."
  value       = ibm_logs_router_target.local.id
}

output "logs_router_route_id" {
  description = "ID of the enterprise-managed Logs Routing V3 route."
  value       = ibm_logs_router_route.local.id
}

output "atracker_target_id" {
  description = "ID of the enterprise-managed Activity Tracker target (pointing to the local Logs instance)."
  value       = ibm_atracker_target.local.id
}

output "atracker_route_id" {
  description = "ID of the enterprise-managed Activity Tracker wildcard route."
  value       = ibm_atracker_route.local.id
}
