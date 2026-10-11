# Copy to packer/local.auto.pkrvars.hcl (git-ignored) and fill in your site.
# Credentials are NOT set here; export PROXMOX_URL, PROXMOX_USERNAME,
# PROXMOX_TOKEN in the environment (scripts/build.sh sources a 0600 env file).

proxmox_node = "your-node"
proxmox_pool = "your-pool"
vm_id        = 123456 # any free ID the build account may allocate; keep your real IDs out of git

# Rocky 10 for release; AlmaLinux 10 x86_64_v2 for hosts without AVX2.
iso_file     = "local:iso/Rocky-10-latest-x86_64-minimal.iso"
iso_checksum = "sha256:<from the distribution CHECKSUM file; recorded for provenance, verify the upload yourself>"
# Only used by a custom GRUB command-line boot_command. Minimal and DVD ISOs
# of the same release share the "-dvd" volume label.
# iso_label  = "Rocky-10-2-x86_64-dvd"

disk_storage = "local-lvm"
disk_format  = "raw" # qcow2 on directory/NFS/CIFS storages
bridge       = "vmbr0"
# vlan_tag   = 100           # if the build network is a tagged VLAN
cpu_type = "x86-64-v3" # Rocky 10 needs v3; x86-64-v2-AES for the AlmaLinux v2 lane

# Reference footprint (4 / 8192 / 60G). Reduce for a small development host.
vm_cores     = 4
vm_memory    = 8192
vm_disk_size = "60G"

# Self-signed lab API certificate? Set true. Keep false against a real CA.
proxmox_insecure_skip_tls_verify = false

# Runner interface Packer's kickstart HTTP server should bind to, if the
# runner has several (VPNs, container bridges). Leave null to autodetect.
# http_interface = "en0"

# ssh_public_key and ssh_private_key_file are not set here: scripts/build.sh
# mints an ephemeral RSA pair per build and tests/packer/validate.sh uses a
# throwaway pair. Set them only if you must drive packer by hand.
