# MDF infrastructure -- one fleet pod, one Tunnel, one DNS record.
#
# We provision:
#   - 1 RunPod pod (NVIDIA RTX A6000 SECURE by default)
#   - 1 Cloudflare Tunnel sized for that pod
#   - 1 Cloudflare DNS record (CNAME) -> Tunnel
#   - 1 Cloudflare Access application for *.mdf.mayaos.dev
#   - R2 bucket "android" (idempotent; created if missing)
#
# This intentionally maps 1 pod -> 1 module instance so adding a 2nd
# pod for HA (Phase 10) is a `count` bump.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    runpod     = { source = "runpod/runpod",         version = "~> 1.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.40" }
  }
  backend "s3" {
    # filled in via -backend-config in CI; for local dev a local backend works
  }
}

provider "runpod"     { api_key = var.runpod_api_key }
provider "cloudflare" { api_token = var.cloudflare_api_token }

# ---------------------------------------------------------------------------
# RunPod pod -- the fleet host
# ---------------------------------------------------------------------------
resource "runpod_pod" "this" {
  name              = var.mdf_hostname
  image             = "nvidia/cuda:12.4.1-devel-ubuntu22.04"
  gpu_type_id       = var.pod_type
  gpu_count         = 1
  cloud_type        = "SECURE"
  data_center_id    = var.region
  container_disk_in_gb = 100
  volume_in_gb         = 500
  volume_mount_path    = "/srv/mayaos-images"
  start_ssh         = true
  start_jupyter     = false
  ports             = "22/tcp,7100/tcp,8080/tcp,28015/tcp,29015/tcp"
  env = {
    MDF_HOSTNAME = var.mdf_hostname
    MDF_REGION   = var.region
  }
}

# ---------------------------------------------------------------------------
# Cloudflare Tunnel -- inbound HTTPS without opening ports
# ---------------------------------------------------------------------------
resource "random_id" "tunnel_secret" { byte_length = 32 }

resource "cloudflare_tunnel" "this" {
  account_id = var.cloudflare_account_id
  name       = var.mdf_hostname
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_tunnel_config" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_tunnel.this.id
  config {
    ingress_rule {
      hostname = "${var.mdf_hostname}.mdf.${var.cloudflare_zone_name}"
      service  = "http://localhost:8080"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_record" "this" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.mdf_hostname}.mdf"
  value   = "${cloudflare_tunnel.this.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "MDF fleet pod ${var.mdf_hostname}"
}

# ---------------------------------------------------------------------------
# Cloudflare Access application + policies
# ---------------------------------------------------------------------------
resource "cloudflare_access_application" "mdf" {
  zone_id                  = var.cloudflare_zone_id
  name                     = "MayaOS Device Farm"
  domain                   = "*.mdf.${var.cloudflare_zone_name}"
  type                     = "self_hosted"
  session_duration         = "24h"
  auto_redirect_to_identity = true
  allowed_idps             = var.cloudflare_idp_ids
}

resource "cloudflare_access_policy" "operator" {
  application_id = cloudflare_access_application.mdf.id
  zone_id        = var.cloudflare_zone_id
  name           = "mdf-operator"
  precedence     = 1
  decision       = "allow"
  include {
    email = ["sumit@mayaos.dev"]
  }
  include {
    group = var.access_operator_group_ids
  }
}

resource "cloudflare_access_policy" "viewer" {
  application_id = cloudflare_access_application.mdf.id
  zone_id        = var.cloudflare_zone_id
  name           = "mdf-viewer"
  precedence     = 2
  decision       = "allow"
  include {
    group = var.access_viewer_group_ids
  }
}

resource "cloudflare_access_policy" "deny_all" {
  application_id = cloudflare_access_application.mdf.id
  zone_id        = var.cloudflare_zone_id
  name           = "deny-all-fallback"
  precedence     = 99
  decision       = "deny"
  include { everyone = true }
}

# ---------------------------------------------------------------------------
# R2 bucket (idempotent)
# ---------------------------------------------------------------------------
resource "cloudflare_r2_bucket" "android" {
  account_id = var.cloudflare_account_id
  name       = "android"
  location   = var.r2_location
  lifecycle  { prevent_destroy = true }
}
