output "pod_ssh_host" {
  value       = runpod_pod.this.public_ip
  description = "Public IP of the fleet pod."
}

output "pod_ssh_port" {
  value       = runpod_pod.this.ssh_port
  description = "SSH port (RunPod typically forwards a high port)."
}

output "cloudflare_tunnel_token" {
  value       = cloudflare_tunnel.this.tunnel_token
  sensitive   = true
  description = "Token used by cloudflared on the pod to authenticate the Tunnel."
}

output "mdf_public_url" {
  value       = "https://${var.mdf_hostname}.mdf.${var.cloudflare_zone_name}"
  description = "Public URL of the operator UI."
}

output "pods" {
  value = [
    {
      name       = var.mdf_hostname
      ssh_host   = runpod_pod.this.public_ip
      ssh_port   = runpod_pod.this.ssh_port
      public_url = "https://${var.mdf_hostname}.mdf.${var.cloudflare_zone_name}"
    }
  ]
  description = "Single-element list for symmetry with the multi-pod HA setup (Phase 10)."
}
