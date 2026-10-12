# Shared build: one provisioner chain for every source. Assert the installed
# state, run the appliance layer, check it from outside, then seal
# (ADR-0001 §Decision: two-layer pipeline).

packer {
  required_version = ">= 1.12.0"
  required_plugins {
    proxmox = {
      version = "= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = "= 1.1.6"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  # GRUB editor boot, the pattern every working EL-on-Proxmox template uses:
  # <up> selects "Install" (the ISO default is "Test this media"), e opens the
  # editor on the setparams line, the entry body begins with an EMPTY line, so
  # two <down> reach the linuxefi line; <end> appends; F10 boots (same as
  # Ctrl-X, without holding a modifier across API calls). Each key is one
  # Proxmox API call, so the typed text is kept short and groups are
  # separated by waits. fips=1 is appended explicitly so a dropped arrow key
  # still yields a FIPS install rather than a silent non-FIPS one.
  kickstart_url = coalesce(var.kickstart_url, "http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg")
  default_boot_command = [
    "<up><wait>e<wait>",
    "<down><wait><down><wait><end><wait>",
    " inst.text inst.ks=${local.kickstart_url} fips=1${var.installer_ssh ? " inst.sshd" : ""}<wait>",
    "<f10>"
  ]
  boot_command = var.boot_command != null ? var.boot_command : local.default_boot_command

  ansible_dir = coalesce(var.ansible_dir, "${abspath(path.root)}/../ansible")
  ansible_env = [
    "ANSIBLE_CONFIG=${local.ansible_dir}/ansible.cfg",
    "ANSIBLE_ROLES_PATH=${local.ansible_dir}/roles",
    "ANSIBLE_FORCE_COLOR=0",
  ]
  ansible_extra = flatten([for v in var.ansible_extra_vars : ["-e", v]])
}

build {
  name    = "safbox"
  sources = ["source.proxmox-iso.el10"]

  # Assert, do not configure: FIPS is on in kernel and userland, Secure Boot
  # is enforced, the guest agent and cloud-init are present and enabled, and
  # we are on the expected OS. Fails fast, before the appliance layer runs.
  provisioner "shell" {
    inline = [
      "set -eu",
      "echo \"fips_enabled=$(cat /proc/sys/crypto/fips_enabled)\"",
      "test \"$(cat /proc/sys/crypto/fips_enabled)\" = 1",
      "grep -q 'fips=1' /proc/cmdline",
      "policy=$(update-crypto-policies --show); echo \"crypto-policy=$policy\"; test \"$policy\" = FIPS",
      "openssl list -providers | grep -qi fips",
      "sb=$(sudo -n mokutil --sb-state 2>&1 | head -1); echo \"secureboot: $sb\"; echo \"$sb\" | grep -q 'SecureBoot enabled'",
      ". /etc/os-release && echo \"os=$ID $VERSION_ID\" && test \"$PLATFORM_ID\" = platform:el10",
      "level=$(/lib64/ld-linux-x86-64.so.2 --help | grep -E 'x86-64-v[234] \\(supported' | head -1); echo \"microarch:$level\"; test -n \"$level\"",
      "systemctl is-enabled qemu-guest-agent cloud-init sshd",
      "systemctl is-active qemu-guest-agent sshd",
    ]
  }

  # Appliance layer (ADR-0001 two-layer pipeline): the same playbooks any
  # operator can run against an existing host. Packer connects as the build
  # user with the ephemeral key; group_vars load from the playbooks.
  provisioner "ansible" {
    playbook_file    = "${local.ansible_dir}/playbooks/safbox.yml"
    galaxy_file      = "${local.ansible_dir}/requirements.yml"
    user             = var.build_user
    use_proxy        = false
    ansible_env_vars = local.ansible_env
    extra_arguments  = local.ansible_extra
  }

  # Outside-in check of the build VM before the seal: the inspec-safbox
  # profile runs from this machine over SSH as the build user, and the SAF
  # CLI gates the build on verify/threshold.yml. Nothing is installed or
  # left on the image for it.
  provisioner "shell-local" {
    inline = [
      "${abspath(path.root)}/../scripts/validate.sh '${build.User}@${build.Host}:${build.Port}' '${var.ssh_private_key_file}' build build_info_expected=false",
    ]
  }

  # Seal: record the build, scrub identity and residue, delete the build
  # user, and verify its own post-conditions. Nothing may run over SSH
  # afterwards; Packer stops the VM through the Proxmox API. With seal =
  # false the development seal runs instead: identity and residue are
  # scrubbed so clones boot as new instances, and the build user, host keys
  # and logs stay for inspection.
  provisioner "ansible" {
    playbook_file    = "${local.ansible_dir}/playbooks/seal.yml"
    user             = var.build_user
    use_proxy        = false
    ansible_env_vars = local.ansible_env
    extra_arguments = concat([
      "-e", "seal_git_commit=${var.git_revision}",
      "-e", "seal_mode=${var.seal ? "full" : "development"}",
    ], local.ansible_extra)
  }
}
