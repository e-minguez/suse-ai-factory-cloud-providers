# A small, self-contained variables.tf-shaped fixture -- not the real
# module's file, which TestParsesRealModuleVariables covers directly -- for
# exercising two specific parser hazards in isolation:
#   1. A heredoc description, which spans multiple lines and contains a
#      blank line of its own.
#   2. A top-level `check` block, which ParseVariables must drop via
#      PartialContent's Remain without erroring or attempting to evaluate it.

variable "region" {
  type = string
  description = <<-EOT
    Multi-line description with a deliberately blank line below.

    Second paragraph, to make sure the heredoc terminator is still found
    correctly after it.
  EOT
}

variable "widgets" {
  type = map(object({
    count = optional(number, 1)
  }))
  default = {}
}

check "always_true" {
  assert {
    condition     = true
    error_message = "this should never be evaluated"
  }
}
