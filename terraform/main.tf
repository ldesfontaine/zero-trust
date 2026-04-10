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

# --- Clé SSH (créée au niveau du compte, référencée par ID) ---
# Accès root initial pour le bootstrap Ansible
resource "hostinger_vps_ssh_key" "deploy" {
  name = "deploy-key"
  key  = var.ssh_public_key
}

# --- VPS Sentinelle (DMZ) ---
# data_center_id et template_id : obtenir les valeurs disponibles via :
#   terraform plan -target=data.hostinger_vps_data_centers.all
#   terraform plan -target=data.hostinger_vps_templates.all
resource "hostinger_vps" "sentinel" {
  plan           = var.vps_plan
  data_center_id = var.vps_data_center_id
  template_id    = var.vps_template_id
  hostname       = var.vps_hostname

  ssh_key_ids = [hostinger_vps_ssh_key.deploy.id]
}

# --- Data sources (utiles pour découvrir les IDs disponibles) ---
data "hostinger_vps_data_centers" "all" {}
data "hostinger_vps_templates" "all" {}
data "hostinger_vps_plans" "all" {}
