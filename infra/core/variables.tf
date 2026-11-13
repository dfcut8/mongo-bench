variable "subscription_id" {
  description = "Azure subscription containing the bootstrapped dev resource group."
  type        = string
  default     = "b8d7fc1c-6003-4425-baf0-15d8db0e1714"
}

variable "location" {
  description = "Azure region for AKS, ACR, and the MongoDB disk; independent of the state storage region."
  type        = string
  default     = "northcentralus"
}

variable "node_vm_size" {
  description = "Linux system pool VM size; check regional availability and subscription quota."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_count" {
  description = "Dev node count. Two nodes allow AKS maintenance; MongoDB still has only one member."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 2 && floor(var.node_count) == var.node_count
    error_message = "Use at least two nodes in the system pool."
  }
}

variable "developer_object_ids" {
  description = "Additional Entra object IDs allowed to push images and deploy in the two dev namespaces. The Terraform caller is included automatically."
  type        = set(string)
  default     = []
}

variable "aks_api_allowed_cidrs" {
  description = "Optional trusted public egress CIDRs for the AKS API. Empty leaves the public API reachable with Entra authentication. Include your machine's egress IP if restricting it."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.aks_api_allowed_cidrs : can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0" && cidr != "::/0"])
    error_message = "Use valid restricted CIDRs or leave the set empty."
  }
}

variable "mongodb_disk_size_gb" {
  description = "Initial persistent MongoDB disk size. Capacity changes require planned disk/PV/PVC maintenance; never shrink a disk."
  type        = number
  default     = 32

  validation {
    condition     = var.mongodb_disk_size_gb >= 32 && floor(var.mongodb_disk_size_gb) == var.mongodb_disk_size_gb
    error_message = "Use an integer disk size of at least 32 GiB."
  }
}
