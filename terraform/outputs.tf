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
