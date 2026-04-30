variable "runpod_api_key" {
  type        = string
  sensitive   = true
  description = "RunPod API key (env: TF_VAR_runpod_api_key)."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:Edit + Tunnel:Edit + Access:Edit + R2:Edit."
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID (CLOUDFLARE_ACCOUNT_ID)."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for mayaos.dev."
}

variable "cloudflare_zone_name" {
  type        = string
  default     = "mayaos.dev"
  description = "DNS zone name; combined with mdf_hostname becomes ${mdf_hostname}.mdf.${name}."
}

variable "cloudflare_idp_ids" {
  type        = list(string)
  default     = []
  description = "Identity provider IDs for Access (e.g. Google Workspace)."
}

variable "access_operator_group_ids" {
  type        = list(string)
  default     = []
  description = "Cloudflare Access groups granted operator access."
}

variable "access_viewer_group_ids" {
  type        = list(string)
  default     = []
  description = "Cloudflare Access groups granted viewer access."
}

variable "r2_location" {
  type        = string
  default     = "EU"
  description = "R2 bucket region (EU or AUTO or NA)."
}

variable "region" {
  type        = string
  default     = "us-or"
  description = "RunPod data center ID (e.g. eu-de, us-or, eu-amsterdam)."
}

variable "pod_type" {
  type        = string
  default     = "NVIDIA_RTX_A6000_SECURE"
  description = "RunPod GPU type ID."
}

variable "mdf_hostname" {
  type        = string
  default     = "mdf-pod-0"
  description = "Hostname prefix for the pod; becomes ${name}.mdf.${zone}."
}
