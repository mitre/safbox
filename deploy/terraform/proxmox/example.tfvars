# Copy to terraform.tfvars (git-ignored) and fill in your site. Credentials
# are NOT set here: export PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN in
# the environment (docs/deploy.md shows how to derive them from the build's
# env file).

node_name      = "your-node"
pool_id        = "your-pool"
datastore_id   = "local-lvm"
template_vm_id = 123456 # the sealed SAFBox template; keep your real IDs out of git
# vm_id        = 123457 # or leave unset for the next free ID

name    = "safbox"
ci_user = "safbox"
ssh_public_keys = [
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC0example0key0replace0with0yours operator@example.invalid",
]

# DHCP by default; for a static address:
# ipv4_address = "192.0.2.10/24"
# ipv4_gateway = "192.0.2.1"
# dns_servers  = ["192.0.2.53"]

# Keep the template's network, CPU and memory unless set:
# network_bridge = "vmbr0"
# vlan_id        = 100
# cpu            = { cores = 4, type = "x86-64-v3" }
# memory_mib     = 8192

# Self-signed lab API certificate? Set true. Keep false against a real CA.
proxmox_insecure = false
