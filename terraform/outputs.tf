# ============================================================================
# Outputs Terraform — Données exposées après apply
# L'IP publique est utilisée par Ansible dans l'inventaire
# ============================================================================

output "vps_public_ip" {
  description = "IP publique du VPS sentinelle"
  value       = hostinger_vps.sentinel.ipv4_address
}

output "vps_id" {
  description = "ID du VPS chez Hostinger"
  value       = hostinger_vps.sentinel.id
}

output "available_data_centers" {
  description = "Datacenters disponibles (pour choisir vps_data_center_id)"
  value       = data.hostinger_vps_data_centers.all.data_centers
}

output "available_templates" {
  description = "Templates OS disponibles (pour choisir vps_template_id)"
  value       = data.hostinger_vps_templates.all.templates
}

output "available_plans" {
  description = "Plans disponibles (pour choisir vps_plan)"
  value       = data.hostinger_vps_plans.all.plans
}
