# Site values come from a git-ignored tfvars file (copy example.tfvars to
# terraform.tfvars). Credentials never do: the provider reads the API
# endpoint and token from PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN in the
# environment (docs/deploy.md).

variable "proxmox_insecure" {
  description = "Skip verifying the API's TLS certificate. Only for a throwaway lab whose API serves a self-signed certificate: with verification off the token goes to whoever answers. Prefer trusting the cluster CA (SSL_CERT_FILE)."
  type        = bool
  default     = false
}

variable "node_name" {
  description = "Proxmox node that holds the template and runs the SAFBox."
  type        = string
}

variable "pool_id" {
  description = "Resource pool the SAFBox joins. Creating a VM into a pool is authorized by VM.Allocate on the pool, the grant the build account already has (docs/guides/proxmox/build.md)."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the sealed SAFBox template to clone."
  type        = number
}

variable "vm_id" {
  description = "VM ID of the new SAFBox. Null lets Proxmox pick the next free ID."
  type        = number
  default     = null
}

variable "name" {
  description = "VM name; cloud-init makes it the SAFBox's host name, which its first-boot certificate names."
  type        = string
  default     = "safbox"
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must be a DNS label: lower-case letters, digits and hyphens, at most 63 characters."
  }
}

variable "datastore_id" {
  description = "Storage for the clone's disks and its cloud-init drive."
  type        = string
}

variable "ci_user" {
  description = "Login the SAFBox creates on first boot through cloud-init. It is the only account that can log in, by SSH key, with sudo."
  type        = string
  default     = "safbox"
}

variable "ssh_public_keys" {
  description = "Public SSH keys for ci_user. SAFBox runs in FIPS mode, which accepts RSA (3072 bits or more recommended) and ECDSA keys; Ed25519 keys may be refused."
  type        = list(string)
  validation {
    condition     = length(var.ssh_public_keys) > 0 && alltrue([for key in var.ssh_public_keys : can(regex("^(ssh-rsa|ecdsa-sha2-nistp(256|384|521)) ", key))])
    error_message = "ssh_public_keys needs at least one key, each an RSA (ssh-rsa) or ECDSA (ecdsa-sha2-nistp*) public key, which FIPS mode accepts."
  }
}

variable "ipv4_address" {
  description = "IPv4 address of the SAFBox in CIDR notation, or dhcp."
  type        = string
  default     = "dhcp"
}

variable "ipv4_gateway" {
  description = "IPv4 gateway for a static ipv4_address; null with dhcp."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "DNS servers cloud-init configures; empty keeps what DHCP or the template provides."
  type        = list(string)
  default     = []
}

variable "network_bridge" {
  description = "Bridge for the SAFBox's network interface. Null keeps the template's."
  type        = string
  default     = null
}

variable "vlan_id" {
  description = "VLAN tag on network_bridge; null for none."
  type        = number
  default     = null
}

variable "cpu" {
  description = "CPU cores and model. Null keeps the template's. Rocky Linux 10 needs an x86-64-v3 model; the AlmaLinux x86_64_v2 development build runs on x86-64-v2-AES."
  type = object({
    cores = number
    type  = string
  })
  default = null
}

variable "memory_mib" {
  description = "Memory in MiB. Null keeps the template's. The reference footprint is 8192; Heimdall and Vulcan together need 4096 at the least (docs/rebuild.md, Footprint)."
  type        = number
  default     = null
}

variable "tags" {
  description = "Proxmox tags for the SAFBox."
  type        = list(string)
  default     = ["safbox"]
}
