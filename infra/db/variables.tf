variable "mongodb_image" {
  description = "Official MongoDB image; pin a patch version or digest and review upgrades for disk compatibility."
  type        = string
  default     = "mongo:8.0.38"
}
