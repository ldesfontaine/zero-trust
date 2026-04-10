# ============================================================================
# Variables Terraform — Paramètres du VPS
# Valeurs dans terraform.tfvars (gitignored si secrets)
# ============================================================================

variable "hostinger_api_token" {
  description = "Token API Hostinger pour gérer le VPS"
  type        = string
  sensitive   = true
}

variable "vps_plan" {
  description = "Plan VPS Hostinger (ex: hostingercom-vps-kvm2-usd-1m). Lister via data.hostinger_vps_plans.all"
  type        = string
}

variable "vps_data_center_id" {
  description = "ID du datacenter Hostinger (entier). Lister via data.hostinger_vps_data_centers.all"
  type        = number
}

variable "vps_template_id" {
  description = "ID du template OS (entier, ex: Ubuntu 22.04). Lister via data.hostinger_vps_templates.all"
  type        = number
}

variable "vps_hostname" {
  description = "Hostname du VPS (ex: sentinel.example.com)"
  type        = string
  default     = "sentinel"
}

variable "ssh_public_key" {
  description = "Clé SSH publique Ed25519 pour l'accès initial root"
  type        = string
}
