# Install layer: Proxmox + RHEL 10 family (Rocky 10 for release, AlmaLinux 10
# x86-64-v2 for development hosts without AVX2). The only input that differs
# between the two is iso_file. See ADR-0001 §Decision (install layer).

source "proxmox-iso" "el10" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  node    = var.proxmox_node
  pool    = var.proxmox_pool
  vm_id   = var.vm_id
  vm_name = var.vm_name
  # A template built with seal = false (the development seal) still carries
  # the build user, its key, and shared SSH host keys; it is tagged
  # 'unsealed' and says so.
  # (tags need the datacenter's user-tag-access to permit them.)
  tags = var.seal ? "safbox;base" : "safbox;base;unsealed"

  template_name        = var.vm_name
  template_description = "${var.seal ? "SAFBox base image, sealed." : "SAFBox base image, UNSEALED (build user and shared host identity present; not distributable)."} ISO ${var.iso_file} ${var.iso_checksum}. FIPS enabled at install. git ${var.git_revision}. Built ${timestamp()}."

  boot_iso {
    type         = "scsi"
    iso_file     = var.iso_file
    iso_checksum = var.iso_checksum
    unmount      = true
  }

  # UEFI with Secure Boot. RHEL 10 deprecates legacy BIOS installation.
  bios    = "ovmf"
  machine = "q35"
  efi_config {
    efi_storage_pool  = coalesce(var.efi_storage, var.disk_storage)
    efi_type          = "4m"
    pre_enrolled_keys = var.secure_boot
  }

  os       = "l26"
  cpu_type = var.cpu_type
  cores    = var.vm_cores
  memory   = var.vm_memory

  # qxl (default) for SPICE; std for standard VGA. noVNC works with both.
  vga {
    type = var.vga
  }

  scsi_controller = "virtio-scsi-single"
  disks {
    type         = "scsi"
    storage_pool = var.disk_storage
    disk_size    = var.vm_disk_size
    format       = var.disk_format
    discard      = true
    io_thread    = true
    ssd          = true
  }

  network_adapters {
    bridge   = var.bridge
    model    = "virtio"
    firewall = false
    vlan_tag = var.vlan_tag
  }

  # Entropy. A named CPU model (unlike 'host') exposes no RDRAND, and a FIPS
  # system blocks host-key generation and the random seed until the kernel
  # generator is seeded; without this device an idle VM can take tens of
  # minutes to boot. /dev/urandom as the source needs no root on Proxmox.
  rng0 {
    source    = "/dev/urandom"
    max_bytes = 1024
    period    = 1000
  }

  # The guest agent is how the plugin learns the VM's IP for SSH.
  qemu_agent = true

  # Attach a cloud-init drive to the template so clones take user-data.
  cloud_init              = true
  cloud_init_storage_pool = coalesce(var.cloud_init_storage, var.disk_storage)

  # The answer file is rendered in memory. How the installer fetches it is a
  # variable (kickstart_url in build.pkr.hcl): Packer's temporary HTTP server
  # by default, or an operator-hosted URL. Nothing is written to disk.
  http_content = {
    "/ks.cfg" = templatefile("${abspath(path.root)}/answerfiles/el10/ks.cfg.pkrtpl.hcl", {
      build_user        = var.build_user
      ssh_public_key    = var.ssh_public_key
      hostname          = var.hostname
      environment_group = var.environment_group
      installer_ssh     = var.installer_ssh
      datasource_list   = var.datasource_list
    })
  }
  http_interface    = var.http_interface
  http_bind_address = var.http_bind_address

  boot_wait         = var.boot_wait
  boot_key_interval = var.boot_key_interval
  boot_command      = local.boot_command

  ssh_username         = var.build_user
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = var.install_timeout
}
