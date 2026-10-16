# Variables for the install layer. Site-specific values (node, pool, VM IDs,
# storage, bridge, ISO) belong in a git-ignored *.auto.pkrvars.hcl; see
# example.pkrvars.hcl. Credentials come only from the environment.

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL including /api2/json. Read from PROXMOX_URL."
  default     = env("PROXMOX_URL")
}

variable "proxmox_username" {
  type        = string
  description = "API token id, user@realm!token. Read from PROXMOX_USERNAME."
  default     = env("PROXMOX_USERNAME")
}

variable "proxmox_token" {
  type        = string
  description = "API token secret. Read from PROXMOX_TOKEN."
  default     = env("PROXMOX_TOKEN")
  sensitive   = true
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification of the Proxmox API (self-signed lab certificates)."
  default     = false
}

variable "proxmox_node" {
  type        = string
  description = "Node the build VM is created on: its name as shown under Datacenter in the GUI (hostname on the node, or pvesh get /nodes), not its address."
  # An address makes Proxmox try to forward the request to a node of that
  # name and fail with "596 ... certificate verify failed".
  validation {
    condition     = !can(regex("^[0-9]+(\\.[0-9]+){3}$", var.proxmox_node)) && !strcontains(var.proxmox_node, ":")
    error_message = "The proxmox_node must be the node's name, not an IP address; the address belongs in PROXMOX_URL (docs/guides/proxmox/build.md, step 1)."
  }
}

variable "proxmox_pool" {
  type        = string
  description = "Resource pool the build VM and template belong to."
}

variable "vm_id" {
  type        = number
  description = "VM ID for the build VM; the template keeps it."
}

variable "vm_name" {
  type        = string
  description = "Name of the build VM and resulting template."
  default     = "safbox-el10-base"
}

variable "iso_file" {
  type        = string
  description = "Datastore path of the RHEL 10 family DVD or minimal ISO, e.g. local:iso/Rocky-10-x86_64-minimal.iso or an AlmaLinux 10 x86_64_v2 ISO."
  # A live image boots to a desktop and never runs the kickstart, so the build
  # would wait for SSH until install_timeout. Only the file name is checked,
  # by whole word, so a storage name like "olive" or a file name like
  # "...-automated-..." is not mistaken for one.
  validation {
    condition     = !can(regex("(?i)(^|[-_.])(live|workstation|kde|xfce|mate|cinnamon|lxqt)([-_.]|$)", regex("[^/:]*$", var.iso_file)))
    error_message = "The iso_file must be an installer ISO (minimal, dvd or boot), not a live image such as Workstation, Workstation-Lite or Live-GNOME (docs/guides/proxmox/build.md, step 2)."
  }
}

variable "iso_checksum" {
  type        = string
  description = "sha256:<hex> of the ISO from the distribution's CHECKSUM file. NOT verified by the plugin for an ISO already on the datastore (it only checks downloads); it is recorded in the template description for provenance, and the operator verifies the upload by hand. Required so that skipping is a deliberate act."
}

variable "disk_storage" {
  type        = string
  description = "Storage for the OS disk (thin pool or directory)."
}

variable "efi_storage" {
  type        = string
  description = "Storage for the EFI vars disk. Defaults to disk_storage."
  default     = null
}

variable "cloud_init_storage" {
  type        = string
  description = "Storage for the cloud-init drive attached to the template. Defaults to disk_storage."
  default     = null
}

variable "bridge" {
  type        = string
  description = "Bridge the VM's single NIC attaches to."
}

variable "vm_cores" {
  type        = number
  description = "vCPUs. Reference footprint is 4; the development build uses 2."
  default     = 4
}

variable "vm_memory" {
  type        = number
  description = "RAM in MiB. Reference footprint is 8192; the development build uses 4096."
  default     = 8192
}

variable "vm_disk_size" {
  type        = string
  description = "OS disk size. Reference footprint is 60G; the development build uses 40G. Must hold the fixed partition layout in the kickstart (about 32G) plus growth."
  default     = "60G"
}

variable "cpu_type" {
  type        = string
  description = "QEMU CPU model for the build VM, inherited by clones. A named model keeps clones migratable across a heterogeneous cluster; 'host' ties them to the build node. RHEL 10 and Rocky 10 require x86-64-v3."
  default     = "x86-64-v3"
}

variable "disk_format" {
  type        = string
  description = "Disk image format. raw is required on LVM-thin, ZFS, and Ceph RBD; qcow2 enables snapshots and linked clones on directory, NFS, and CIFS storages."
  default     = "raw"
}

variable "vlan_tag" {
  type        = number
  description = "802.1Q tag for the VM's NIC when the build network is a tagged VLAN. Null means untagged."
  default     = null
}

variable "datasource_list" {
  type        = string
  description = "cloud-init datasources the image consults, comma separated, platform specific. Proxmox presents a NoCloud volume."
  default     = "NoCloud"
}

variable "http_bind_address" {
  type        = string
  description = "Address Packer's kickstart HTTP server binds to. Null binds all interfaces; set the build-facing IP so the rendered answer file is not offered on every network the runner touches."
  default     = null
}

variable "seal" {
  type        = bool
  description = "Run the full seal (scrub instance identity and installer residue, delete the build user, host keys and logs, assert the result) and produce a distributable template. false runs the development seal, which scrubs identity and residue but keeps the build user, its key, the host keys and the logs so the template can be inspected; such templates are tagged 'unsealed'."
  default     = true
}

variable "ansible_dir" {
  type        = string
  description = "Path to the appliance layer (playbooks, roles, group_vars, ansible.cfg). Defaults to the repository's ansible/ directory."
  default     = null
}

variable "galaxy_dir" {
  type        = string
  description = "Directory ansible-galaxy installs ansible/requirements.yml into for this build: roles under roles/, collections under collections/, both searched first by the playbooks. scripts/build.sh passes one inside the run's own directory so concurrent builds never install into the same place. Null installs into ansible/galaxy_roles/ and ansible/collections/, the paths ansible.cfg names."
  default     = null
}

variable "ansible_extra_vars" {
  type        = list(string)
  description = "Extra variables passed to every appliance playbook as key=value, e.g. [\"safbox_example_quadlet_enabled=true\"] for the acceptance build."
  default     = []
}

variable "git_revision" {
  type        = string
  description = "Short git revision of the repository that produced the template; recorded in the template description. scripts/build.sh supplies it."
  default     = "unknown"
}

variable "secure_boot" {
  type        = bool
  description = "Pre-enroll Microsoft and distribution keys in the EFI vars so Secure Boot is on."
  default     = true
}

variable "environment_group" {
  type        = string
  description = "Kickstart environment group. minimal-environment installs from the minimal ISO; graphical-server-environment needs the DVD ISO or a package mirror."
  default     = "minimal-environment"
}

variable "hostname" {
  type        = string
  description = "Hostname set by the kickstart; cloud-init overrides it on deploy."
  default     = "safbox"
}

variable "build_user" {
  type        = string
  description = "Key-authenticated user Packer connects as during the build. Removed or locked by the seal step."
  default     = "packer"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed for build_user by the kickstart. scripts/build.sh generates an ephemeral RSA key per build."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Private half of ssh_public_key, used by the Packer communicator."
}

variable "http_interface" {
  type        = string
  description = "Runner network interface Packer's HTTP server (kickstart delivery) should bind to, for hosts with several interfaces. Null lets Packer choose."
  default     = null
}

variable "boot_wait" {
  type        = string
  description = "Delay before typing the boot command. OVMF with Secure Boot on a slow host can take 20s+ to reach GRUB; keys typed earlier are lost or land as garbage. The only time-critical key is the first one: it must arrive before the ISO's 60s GRUB countdown ends (boot_wait plus about 2s); once the editor is open the countdown stops."
  default     = "30s"
}

variable "boot_key_interval" {
  type        = string
  description = "Pause between keystrokes. Each key is a separate Proxmox API call; the plugin default of 5ms is known to drop characters (packer-plugin-proxmox issue 124)."
  default     = "50ms"
}

variable "iso_label" {
  type        = string
  description = "Volume label of the ISO (AlmaLinux-10-2-x86_64_v2-dvd, Rocky-10-2-x86_64-dvd). Only needed by a custom boot_command that uses GRUB's command line with inst.stage2; the default editor-based boot_command does not use it."
  default     = null
}

variable "kickstart_url" {
  type        = string
  description = "Where the installer fetches the kickstart. Null uses Packer's temporary HTTP server on the runner, which the VM's network must be able to reach. In environments where the VM network cannot reach the runner, host the rendered kickstart on an internal web server and set this URL; see docs/rebuild.md."
  default     = null
}

variable "installer_ssh" {
  type        = bool
  description = "Boot the installer with inst.sshd so the runner can SSH into the Anaconda environment as root with the build key to read /tmp/*.log while an install is stuck. Development aid; off by default."
  default     = false
}

variable "boot_command" {
  type        = list(string)
  description = "Override the GRUB keystrokes. Null uses the default in build.pkr.hcl, the editor-based sequence documented there."
  default     = null
}

variable "install_timeout" {
  type        = string
  description = "How long to wait for the unattended install to finish and SSH to come up."
  default     = "45m"
}

variable "build_gate_site_inputs_file" {
  type        = string
  description = "A site's inputs file for the build-time gate, layered after verify/inputs/build.yml (its values win), for example expected_tools without a tool the site switches off. Keep it out of git; verify/local/ is git-ignored for this. Null passes none."
  default     = null
}

variable "build_gate_ssh_config_file" {
  type        = string
  description = "SSH client config CINC Auditor reads for the build-time gate instead of its defaults (~/.ssh/config, /etc/ssh/ssh_config), passed to scripts/validate.sh --ssh-config. \"/dev/null\" reads none, for a runner whose default config CINC Auditor's SSH library cannot open or use. Null keeps the defaults, so ProxyJump or bastion settings there still apply."
  default     = null
}
