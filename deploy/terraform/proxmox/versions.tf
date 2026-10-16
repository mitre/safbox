# Deploys a SAFBox from its template on Proxmox VE (ADR-0001 §Decision:
# deployment is Terraform, one module per target, mirroring the install
# layer). The community provider bpg/proxmox, pinned to one release like
# the Packer plugins in packer/build.pkr.hcl; .terraform.lock.hcl records
# its checksums (terraform providers lock, see docs/deploy.md).
terraform {
  required_version = ">= 1.16.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.116.0"
    }
  }
}
