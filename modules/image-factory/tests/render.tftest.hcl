variables {
  elemental_image       = "registry.example.test/elemental3:1.0"
  build_id              = "abc123def456"
  extra_packages        = ["unzip"]
  hook_is_already_built = "HOOK_ALREADY_BUILT_MARK; return 1"
  hook_pre_build        = "HOOK_PRE_BUILD_MARK"
  hook_on_step          = "HOOK_ON_STEP_MARK"
  hook_deliver_raw      = "HOOK_DELIVER_MARK \"$1\""
  hook_on_exit          = "HOOK_ON_EXIT_MARK"
}

run "renders_with_hooks_in_order" {
  command = plan

  assert {
    condition     = startswith(output.script, "#!/usr/bin/env bash")
    error_message = "script must start with a shebang"
  }

  assert {
    condition     = strcontains(output.script, "registry.example.test/elemental3:1.0") && strcontains(output.script, "abc123def456")
    error_message = "image and build id must be rendered"
  }

  assert {
    condition     = strcontains(output.script, "zypper -n install podman curl unzip")
    error_message = "extra_packages must be installed with the base packages"
  }

  assert {
    condition     = strcontains(output.script, "ZYPP_PCK_PRELOAD=0")
    error_message = "zypper preload workaround missing"
  }

  # The call sites, not the definitions, must run in this order.
  assert {
    condition = (
      strcontains(output.script, "HOOK_ALREADY_BUILT_MARK") &&
      strcontains(output.script, "HOOK_PRE_BUILD_MARK") &&
      strcontains(output.script, "HOOK_ON_STEP_MARK") &&
      strcontains(output.script, "HOOK_DELIVER_MARK \"$1\"") &&
      strcontains(output.script, "HOOK_ON_EXIT_MARK")
    )
    error_message = "every hook body must be inlined verbatim"
  }

  assert {
    condition = (
      length(regexall("(?s)\nstep prereqs .*\npre_build\n.*\nif is_already_built; then.*\nstep customize .*\nstep locate .*\ndeliver_raw \"\\$RAW_IMAGE\"\n", output.script)) == 1
    )
    error_message = "steps must run prereqs, pre_build, is_already_built, customize, locate, deliver_raw in that order"
  }

  assert {
    condition     = !strcontains(lower(output.script), "python")
    error_message = "common script must not use Python"
  }

  assert {
    condition     = length(output.script_hash) == 64
    error_message = "script_hash must be a SHA-256 hex digest"
  }
}

run "defaults_render_without_hooks" {
  command = plan

  variables {
    extra_packages        = []
    hook_is_already_built = "return 1"
    hook_pre_build        = ":"
    hook_on_step          = ":"
    hook_deliver_raw      = "return 0"
    hook_on_exit          = ":"
  }

  assert {
    condition     = strcontains(output.script, "zypper -n install podman curl \\\n")
    error_message = "base packages only without extra_packages"
  }
}

run "hash_tracks_hook_body" {
  command = plan

  variables {
    hook_deliver_raw = "OTHER_DELIVER_MARK"
  }

  assert {
    condition     = !strcontains(output.script, "HOOK_DELIVER_MARK") && strcontains(output.script, "OTHER_DELIVER_MARK")
    error_message = "changing a hook body must change the script"
  }
}

run "rejects_zero_attempts" {
  command = plan

  variables {
    customize_attempts = 0
  }

  expect_failures = [var.customize_attempts]
}
