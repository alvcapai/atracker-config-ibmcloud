##############################################################################
# child/ — outputs
##############################################################################

output "logs_router_target_id" {
  description = "ID of the enterprise-managed Logs Routing V3 target."
  value       = ibm_logs_router_target.central.id
}

output "logs_router_route_id" {
  description = "ID of the enterprise-managed Logs Routing V3 route."
  value       = ibm_logs_router_route.central.id
}

output "atracker_target_id" {
  description = "ID of the enterprise-managed Activity Tracker target."
  value       = ibm_atracker_target.central.id
}

output "atracker_route_id" {
  description = "ID of the enterprise-managed Activity Tracker wildcard route."
  value       = ibm_atracker_route.central.id
}
