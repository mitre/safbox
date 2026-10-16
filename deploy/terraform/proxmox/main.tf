# One SAFBox: a full clone of the sealed template, handed a cloud-init user,
# key and network, then started. First boot runs on the clone (fresh host
# keys and machine identity, the per-install secrets and certificate) and
# starts the services; the guest agent reports the address.

provider "proxmox" {
  insecure = var.proxmox_insecure
}

resource "proxmox_virtual_environment_vm" "safbox" {
  name        = var.name
  description = "SAFBox deployed by Terraform from template ${var.template_vm_id} (deploy/terraform/proxmox)."
  node_name   = var.node_name
  pool_id     = var.pool_id
  vm_id       = var.vm_id
  # Proxmox stores tags sorted; sorting here keeps plans clean.
  tags = sort(var.tags)

  clone {
    vm_id        = var.template_vm_id
    full         = true
    datastore_id = var.datastore_id
  }

  # The template's firmware and machine (packer/source-proxmox-el10.pkr.hcl:
  # UEFI with Secure Boot keys enrolled on q35), stated because the provider
  # otherwise applies its own defaults (SeaBIOS) to the clone, which would
  # not boot. The EFI disk with its enrolled keys comes with the clone.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  operating_system {
    type = "l26"
  }
  # Start with the node, like any appliance.
  on_boot = true

  # The template runs the guest agent; the address output comes from it.
  agent {
    enabled = true
    wait_for_ip {
      ipv4 = true
    }
  }

  dynamic "cpu" {
    for_each = var.cpu == null ? [] : [var.cpu]
    content {
      cores = cpu.value.cores
      type  = cpu.value.type
    }
  }

  dynamic "memory" {
    for_each = var.memory_mib == null ? [] : [var.memory_mib]
    content {
      dedicated = memory.value
    }
  }

  dynamic "network_device" {
    for_each = var.network_bridge == null ? [] : [var.network_bridge]
    content {
      bridge  = network_device.value
      vlan_id = var.vlan_id
      model   = "virtio"
    }
  }

  initialization {
    datastore_id = var.datastore_id
    # No package upgrade on first boot: an appliance is patched
    # deliberately, and on a disconnected network the upgrade hangs first
    # boot (docs/rebuild.md, "First boot of a clone takes a while").
    upgrade = false

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_address == "dhcp" ? null : var.ipv4_gateway
      }
    }

    dynamic "dns" {
      for_each = length(var.dns_servers) == 0 ? [] : [var.dns_servers]
      content {
        servers = dns.value
      }
    }

    user_account {
      username = var.ci_user
      keys     = var.ssh_public_keys
    }
  }

  started = true
  # Destroying the SAFBox deletes it, so there is nothing to shut down
  # gracefully for.
  stop_on_destroy = true
}

locals {
  vm = proxmox_virtual_environment_vm.safbox
  # The guest agent reports every interface, including loopback and the
  # bridges podman creates for the service pods; the SAFBox's address is
  # the first IPv4 address on any other interface.
  host_interfaces = [
    for i, name in local.vm.network_interface_names : i
    if name != "lo" && !startswith(name, "podman") && !startswith(name, "veth")
  ]
  address = try([
    for a in flatten([for i in local.host_interfaces : local.vm.ipv4_addresses[i]]) : a
    if !startswith(a, "127.") && !startswith(a, "169.254.")
  ][0], null)
}
