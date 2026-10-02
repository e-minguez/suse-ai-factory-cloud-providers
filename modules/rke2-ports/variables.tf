variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2 ingress-controller setting. Controls which ingress ports appear in the matrix."

  validation {
    condition     = contains(["none", "traefik", "ingress-nginx"], var.ingress_controller)
    error_message = "ingress_controller must be one of: none, traefik, ingress-nginx."
  }
}
