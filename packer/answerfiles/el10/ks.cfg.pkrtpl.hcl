# SAFBox base install, RHEL 10 family. Answer file for the unattended
# install; delivery to the installer is a Packer variable, not a property of
# this file. Rendered by Packer's templatefile();
# ${build_user}, ${ssh_public_key}, ${hostname}, ${environment_group} are
# substituted at build time. Validate with tests/kickstart/ks-lint.sh.
text
# No installation source command on purpose. Anaconda then uses the install
# tree Dracut mounted from the boot media (/run/install/repo), validated by
# its repository metadata. The explicit `cdrom` command instead validates
# .discinfo, whose architecture line reads x86_64_v2 on the AlmaLinux v2 ISOs
# while the installer reports x86_64, so `cdrom` fails with "Found no CD-ROM"
# on exactly the media the development build uses. Rocky's x86_64 ISO would
# pass either way; omitting the command works for both.
eula --agreed
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone Etc/UTC --utc
network --bootproto=dhcp --device=link --activate --hostname=${hostname}
selinux --enforcing
firewall --enabled --service=ssh
skipx
firstboot --disable

# Separate filesystems for the paths the RHEL STIG requires (/home, /tmp,
# /var, /var/tmp, /var/log, /var/log/audit). /boot, /boot/efi, /, /tmp,
# /var/tmp and swap have small fixed sizes. The volume group's remaining
# space is shared 40/40/10/10 between /home (automation content, rootless
# container storage), /var (container images), /var/log and /var/log/audit:
# --percent is a share of the space left after the fixed volumes (blivet
# grow_lvm), and --size cannot be given with it. The first-boot hook
# 10-grow-disk.sh (base role) hands a clone's enlarged disk out by the same
# shares; keep the two in step.
zerombr
clearpart --all --initlabel --disklabel=gpt
part /boot/efi --fstype=efi --size=600
part /boot --fstype=xfs --size=1024
part pv.01 --size=1 --grow
volgroup vg_safbox pv.01
logvol /              --vgname=vg_safbox --name=root          --fstype=xfs  --size=12288
logvol /tmp           --vgname=vg_safbox --name=tmp           --fstype=xfs  --size=2048
logvol /var/tmp       --vgname=vg_safbox --name=var_tmp       --fstype=xfs  --size=2048
logvol swap           --vgname=vg_safbox --name=swap          --fstype=swap --size=2048
logvol /home          --vgname=vg_safbox --name=home          --fstype=xfs  --percent=40 --grow
logvol /var           --vgname=vg_safbox --name=var           --fstype=xfs  --percent=40 --grow
logvol /var/log       --vgname=vg_safbox --name=var_log       --fstype=xfs  --percent=10 --grow
logvol /var/log/audit --vgname=vg_safbox --name=var_log_audit --fstype=xfs  --percent=10 --grow

# fips=1 on the installer command line puts the installer in FIPS mode;
# --append carries it onto the installed system. Both are required. Other
# kernel arguments (audit=1 and friends) are STIG work for the hardening
# role, which can change them after install; FIPS cannot be.
bootloader --append="fips=1" --timeout=1

rootpw --lock
user --name=${build_user} --groups=wheel --lock --gecos="Packer build user"
sshkey --username=${build_user} "${ssh_public_key}"

%{ if installer_ssh ~}
# Installer-environment only (variable installer_ssh): lets the runner SSH
# into Anaconda for log inspection when booted with inst.sshd. Never reaches
# the installed system.
sshpw --username=root --sshkey "${ssh_public_key}"
%{ endif ~}

# Only units that exist at this point. qemu-guest-agent and cloud-init are not
# on the minimal ISO; %post installs and enables them. Naming them here makes
# Anaconda's service step fail before %post runs.
services --enabled=sshd
reboot

%packages
@^${environment_group}
openssh-server
sudo
mokutil
%end

%post --erroronfail --log=/root/ks-post.log
# Not on the minimal ISO; installed from the distribution's own repositories,
# which works unchanged for Rocky and AlmaLinux. --erroronfail turns a missing
# network route into an immediate, visible install failure instead of a
# silent template with no guest agent.
dnf -y install qemu-guest-agent cloud-init
systemctl enable qemu-guest-agent cloud-init

# Passwordless sudo for the build user during the build only. The seal step
# removes the build user.
echo "${build_user} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-${build_user}
chmod 0440 /etc/sudoers.d/90-${build_user}
visudo -cf /etc/sudoers.d/90-${build_user}

# Which cloud-init datasources the image will consult; the Packer source for
# each platform passes its own list (Proxmox: NoCloud). The 'None' fallback
# is required: without it, a boot with no datasource (the build VM's own
# first boot) never completes cloud-init, and sshd, which is ordered after
# it, never starts (observed on two builds). The price is that the None
# datasource applies defaults, which would create the distribution's default
# user; the next file stops that.
cat > /etc/cloud/cloud.cfg.d/90-safbox-datasource.cfg <<'EOC'
datasource_list: [ ${datasource_list}, None ]
EOC

# No distribution default user, even when the None datasource applies
# defaults on the build VM's own boot. Users come only from the deploy-time
# datasource. A deployment that asks for the default user (Proxmox always
# does, with users: [default]; its User field, when set, renames it) gets
# admin: key login only, a locked password, passwordless sudo. The
# set_passwords module is left out of the init stage (the package's
# cloud_init_modules otherwise, in its order): the top-level password a
# deployment supplies (Proxmox's Password field) is safuser's, which first
# boot gives it, and cloud-init must not also set it on admin. Without
# set_passwords cloud-init also ignores chpasswd and ssh_pwauth; a users
# list still sets passwords through its own entries.
cat > /etc/cloud/cloud.cfg.d/80-safbox-users.cfg <<'EOC'
users: []
system_info:
  default_user:
    name: admin
    gecos: SAFBox administrator
    lock_passwd: true
cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh
EOC

# SSH takes keys only. The STIG does not require it; the distribution's
# cloud.cfg (ssh_pwauth: false) had set_passwords write it, which no longer
# runs, so SAFBox says it itself, ahead of any later drop-in.
install -m 0600 /dev/null /etc/ssh/sshd_config.d/40-safbox.conf
cat > /etc/ssh/sshd_config.d/40-safbox.conf <<'EOC'
PasswordAuthentication no
EOC
%end
