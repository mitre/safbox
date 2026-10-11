# Shared build: one provisioner chain for every source. Phase 1 only asserts
# the installed state; the Ansible appliance layer, self-test, and seal arrive
# in Phase 2 (ADR-0001 §Implementation Plan).

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
}

build {
  name    = "safbox"
  sources = ["source.proxmox-iso.el10"]

  # Assert, do not configure: FIPS is on in kernel and userland, Secure Boot
  # is enforced, the guest agent and cloud-init are present and enabled, no
  # distribution default user was created, and we are on the expected OS.
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

  # Remove the account the None datasource created on the build VM's own
  # boot, then reset cloud-init and the machine identity so a clone of the
  # template runs as a new instance. The Phase 2 seal role completes the
  # scrub (build user, host keys, installer logs and kickstart copies,
  # NetworkManager profile).
  provisioner "shell" {
    execute_command = "sudo -n sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -eu",
      "for u in almalinux rocky cloud-user; do if id \"$u\" >/dev/null 2>&1; then echo \"removing default user $u\"; userdel -r \"$u\"; fi; done",
      "cloud-init clean --logs --machine-id",
    ]
  }

  # Assert the template carries no distribution default user.
  provisioner "shell" {
    inline = [
      "set -eu",
      "for u in almalinux rocky cloud-user; do ! id \"$u\" >/dev/null 2>&1 || { echo \"unexpected default user $u\"; exit 1; }; done",
      "echo 'no default user present'",
    ]
  }
}
