locals {
  script = templatefile("${path.module}/templates/factory-common.sh.tftpl", {
    elemental_image       = var.elemental_image
    build_id              = var.build_id
    config_dir            = var.config_dir
    log_file              = var.log_file
    state_dir             = var.state_dir
    packages              = join(" ", concat(["podman", "curl"], var.extra_packages))
    customize_attempts    = var.customize_attempts
    customize_retry_delay = var.customize_retry_delay
    hook_is_already_built = var.hook_is_already_built
    hook_pre_build        = var.hook_pre_build
    hook_on_step          = var.hook_on_step
    hook_deliver_raw      = var.hook_deliver_raw
    hook_on_exit          = var.hook_on_exit
  })

  # Comments are dropped ("#!" lines stay) and blank runs collapsed, so the
  # stripped script is what ships in size-limited user_data and what is hashed.
  # Wrapped in forward slashes, so replace() treats them as regexes.
  strip_comment_lines = "/(?m)^[ \\t]*#(?:[^!].*)?\\n/"
  collapse_blank_runs = "/\\n{3,}/"

  script_stripped = replace(
    replace(local.script, local.strip_comment_lines, ""),
    local.collapse_blank_runs, "\n\n"
  )
}
