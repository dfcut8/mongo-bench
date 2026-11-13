variable "application" {
  description = "Optional future service deployment. With build_context, Terraform builds/pushes locally before updating AKS; use a new immutable image_tag/source_revision per source change."
  type = object({
    image_tag       = string
    build_context   = optional(string)
    source_revision = optional(string)
    port            = optional(number, 8080)
    replicas        = optional(number, 1)
  })
  default = null

  validation {
    condition = var.application == null ? true : (
      can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.application.image_tag)) &&
      var.application.image_tag != "latest" &&
      var.application.port >= 1 && var.application.port <= 65535 &&
      floor(var.application.port) == var.application.port &&
      var.application.replicas >= 1 && floor(var.application.replicas) == var.application.replicas &&
      (var.application.build_context == null || var.application.source_revision != null)
    )
    error_message = "Use a versioned image tag, integer port/replicas, and source_revision when building locally."
  }
}
