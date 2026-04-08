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
  description = "Plan VPS Hostinger (ex: KVM-1, KVM-2)"
  type        = string
  default     = "KVM-1"
}

variable "vps_location" {
  description = "Localisation du VPS (ex: fr, nl, de)"
  type        = string
  default     = "fr"
}

variable "ssh_public_key" {
  description = "Clé SSH publique Ed25519 pour l'accès initial root"
  type        = string
}
