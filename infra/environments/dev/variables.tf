variable "atlas_org_id" {
  description = "ID of the existing Atlas organization that will own the dev project."
  type        = string
}

variable "atlas_region" {
  description = "Atlas Azure region name supporting M0, chosen to match future Azure hosting."
  type        = string
}

variable "allowed_cidrs" {
  description = "Map of explicitly allowed client CIDR blocks to their descriptions. Empty blocks all client IPs."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for cidr in keys(var.allowed_cidrs) : can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0" && cidr != "::/0"])
    error_message = "Use valid, restricted CIDR blocks; unrestricted IPv4 and IPv6 ranges are not allowed."
  }
}
