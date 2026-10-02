# Quota check is a hard failure at plan when the cluster's footprint exceeds
# the organization LIMIT; usage by other workloads is not consulted. Flavors are
# 4 vCPU / 16 GB, three zones, three control planes: pass 1 holds 3 hosts
# (12 vCPU), pass 2 holds 4 (16 vCPU); peak 16 vCPU, 64 GB, 2 public IPs.
# Plan only, evroc mocked.

mock_provider "evroc" {
  override_during = plan
}
mock_provider "http" {}

override_data {
  target = module.config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("../elemental-config/tests/fixtures/release_manifest.yaml")
  }
}

override_data {
  target = data.evroc_compute_profiles.this
  values = {
    profiles = ["c1a.m", "a1a.m", "a1a.xl", "gn-l40s.s"]
    details = [
      { name = "c1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = "", gpu_quantity = 0 },
      { name = "a1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = "", gpu_quantity = 0 },
      { name = "a1a.xl", vcpus = 16, memory_amount = 64, memory_unit = "GB", gpu_model = "", gpu_quantity = 0 },
      { name = "gn-l40s.s", vcpus = 16, memory_amount = 64, memory_unit = "GB", gpu_model = "AD102GL_L40S", gpu_quantity = 1 },
    ]
  }
}

variables {
  admin_cidrs                = ["198.51.100.0/24"]
  ssh_authorized_keys        = ["ssh-ed25519 AAAADUMMY test"]
  root_password_hash         = "$6$SALT$ROOT"
  node_user_password_hash    = "$6$SALT$NODE"
  appco_username             = "appco-user"
  appco_password             = "appco-pass"
  suse_registry_username     = "REGCODE"
  suse_registry_password     = "registry-pass"
  nvidia_api_key             = "nvidia-key"
  rancher_bootstrap_password = "bootstrap-pass"
  rancher_hostname           = null
  region                     = "se-sto"
}

run "fits_pass1" {
  command = plan

  variables {
    image_ready = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 16
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }
}

run "fits_pass2" {
  command = plan

  variables {
    image_ready = true
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 16
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }
}

run "vcpu_short" {
  command = plan

  variables {
    image_ready = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 15
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "vcpu_short_pass2" {
  command = plan

  variables {
    image_ready = true
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 15
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "memory_short" {
  command = plan

  variables {
    image_ready = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 100
      compute_memory        = "63GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "ip_short" {
  command = plan

  variables {
    image_ready = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 100
      compute_memory        = "4000GB"
      networking_public_ips = 1
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "ip_short_with_control_plane_ips" {
  command = plan

  variables {
    image_ready             = false
    control_plane_public_ip = true
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 100
      compute_memory        = "4000GB"
      networking_public_ips = 4
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "high_usage_but_footprint_fits" {
  command = plan

  variables {
    image_ready = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 16
      compute_memory        = "64GB"
      networking_public_ips = 2
      usage_vcpus           = 16
      usage_memory          = "64GB"
      usage_public_ips      = 2
    }
  }
}

# Pass 3 (build disks reclaimed) holds the same footprint as pass 2.
run "fits_pass3" {
  command = plan

  variables {
    image_ready          = true
    keep_build_artifacts = false
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 16
      compute_memory        = "64GB"
      networking_public_ips = 2
      usage_vcpus           = 16
      usage_memory          = "64GB"
      usage_public_ips      = 2
    }
  }
}

# A 16 vCPU jumphost makes pass 1 the peak (3 x 16 = 48 > 16 + 12); the check
# still fails on pass 2, where the builders no longer exist.
run "vcpu_short_pass1_peak_seen_on_pass2" {
  command = plan

  variables {
    image_ready            = true
    jumphost_instance_type = "a1a.xl"
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 40
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

# Pass 2 peak is 4 (jumphost) + 3 x 4 (control planes) = 16 vCPU; one worker
# (4 vCPU) makes it 20.
run "worker_nodes_count_toward_footprint" {
  command = plan

  variables {
    image_ready  = true
    worker_pools = { general = { instance_type = "c1a.m", count = 1 } }
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 16
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "worker_nodes_fit" {
  command = plan

  variables {
    image_ready  = true
    worker_pools = { general = { instance_type = "c1a.m", count = 1 } }
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 20
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }
}

run "worker_public_ips_count" {
  command = plan

  variables {
    image_ready  = true
    worker_pools = { general = { instance_type = "c1a.m", count = 1, public_ip = true } }
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 100
      compute_memory        = "4000GB"
      networking_public_ips = 2
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "worker_gpu_flavor_rejected" {
  command = plan

  variables {
    worker_pools = { general = { instance_type = "gn-l40s.s", count = 1 } }
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 1000
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [data.evroc_compute_profiles.this]
}

run "worker_flavor_null_gpu_quantity_accepted" {
  command = plan

  variables {
    image_ready  = true
    worker_pools = { general = { instance_type = "c1a.m", count = 1 } }
  }

  override_data {
    target = data.evroc_compute_profiles.this
    values = {
      profiles = ["c1a.m", "a1a.m"]
      details = [
        { name = "c1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = null, gpu_quantity = null },
        { name = "a1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = null, gpu_quantity = null },
      ]
    }
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 100
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }
}
