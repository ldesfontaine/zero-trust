# ============================================================================
# Terraform — Lifecycle VPS Hostinger
#
# Ce fichier gère la création/destruction du VPS via l'API Hostinger.
# Si demain on change de provider (OVH, AWS...), on change ce fichier,
# pas le reste de l'infra (Ansible gère la configuration).
#
# Usage :
#   terraform init
#   terraform plan
#   terraform apply
#
# Output : IP publique du VPS → utilisée par Ansible (inventory)
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    # Provider Hostinger — à adapter si changement de fournisseur cloud
    # Pour OVH : ovh/ovh, pour AWS : hashicorp/aws, etc.
    hostinger = {
      source  = "hostinger/hostinger"
      version = "~> 0.1"
    }
  }
}

provider "hostinger" {
  # Token API Hostinger — passé via variable ou TF_VAR_hostinger_api_token
  api_token = var.hostinger_api_token
}

# --- VPS Sentinelle (DMZ) ---
resource "hostinger_vps" "sentinel" {
  plan     = var.vps_plan
  location = var.vps_location

  # Clé SSH injectée au provisioning — accès root initial pour bootstrap Ansible
  ssh_key = var.ssh_public_key
}
