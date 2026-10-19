# Reaching a SAFBox console on Proxmox VE (SPICE)

**SPICE is the default, tested way to reach a SAFBox console on Proxmox:**
in the Proxmox GUI, **Console → SPICE**, which opens the console in
`remote-viewer` (part of virt-viewer) on your workstation. The image is
built with the QXL display adapter that SPICE needs, so every clone has it
without further setup. The procedure below was tested end to end on a
desktop SAFBox clone.

It matters most for a SAFBox built with the desktop
(`safbox_desktop_enabled`, see "A desktop build" in
[the appliance reference](../../reference/appliance.md#a-desktop-build)), which boots to the
GNOME login screen: compared with the browser's noVNC console, SPICE is
quicker on a full GNOME desktop, and with the guest's SPICE agent
(`spice-vdagent`, installed with the desktop) the desktop can follow the
client window's size. A headless SAFBox's text console works the same way.

## Build it with the desktop

A SAFBox is headless unless its template was built with the desktop. The
desktop is chosen at build time: switching it on in a clone of a headless
template does not install GNOME, so build a desktop template and clone
that.

1. In `ansible/local.yml` (git-ignored; see
   [Site configuration](../../reference/site-config.md)), set:

   ```
   ---
   safbox_desktop_enabled: true
   ```

2. Tell the validation profiles to expect a desktop, in a site inputs file
   such as `verify/local/inputs.yml` (git-ignored):

   ```
   ---
   gdm_required: true
   gui_required: true
   desktop: true
   ```

   Name it to the build gate in `packer/local.auto.pkrvars.hcl`
   (`build_gate_site_inputs_file = "verify/local/inputs.yml"`) and to the
   release gate with `SAFBOX_SITE_INPUTS` (see
   [Site inputs](../../reference/validation.md#site-inputs)). Without it
   the gates judge the box as headless and fail it for having gdm.

3. Leave the Packer variable `vga` at its default, `qxl`, which SPICE
   needs (section 1).
4. Build as in [the build guide](build.md), with `scripts/build.sh`.

The template then boots to the GNOME login screen, and every clone of it
does too. What the desktop adds, and what the switch changes in the
hardening, is in
[A desktop build](../../reference/appliance.md#a-desktop-build).

## 1. The VM's SPICE display

The Packer variable `vga` defaults to `qxl` (SPICE), so nothing needs
setting. It also takes `std`, the standard VGA adapter, which only the noVNC
console can use; anything else fails `packer validate`.

For a clone of a template built with `std`, change the clone, then power it
off and start it again (a reboot from inside the guest keeps the old
adapter):

```
qm set <vmid> --vga qxl
```

In the GUI this is the clone's **Hardware → Display → SPICE (qxl)**. The
build account's role already has `VM.Config.HWType`, which the change needs.

## 2. Install a SPICE client on your workstation

| Workstation | Client |
|---|---|
| Fedora, RHEL, Rocky, AlmaLinux | `sudo dnf install virt-viewer` |
| Debian, Ubuntu | `sudo apt install virt-viewer` |
| Windows | the virt-viewer MSI from [virt-manager.org/download](https://virt-manager.org/download) |
| macOS | the virt-viewer project publishes no macOS build; use the noVNC console (step 4) |

The client is `remote-viewer`. Proxmox hands it a `.vv` connection file;
associate `.vv` files with `remote-viewer` so the browser opens them
directly.

## 3. Connect

1. In the Proxmox GUI, select the VM.
2. Open the **Console** drop-down at the top right of the VM's page and
   choose **SPICE**. (It is offered only when the display is SPICE.)
3. The browser downloads a `.vv` file and, if `.vv` is associated, starts
   `remote-viewer` with it. Otherwise open it yourself:

   ```
   remote-viewer ~/Downloads/<file>.vv
   ```

   The file carries a one-time ticket that expires shortly after download:
   open it straight away, and download a new one from the Console menu for
   every connection.

4. The GNOME login screen appears, showing the SAF logo. Sign in as
   `safuser` with its password: the clone's cloud-init **Password**, or,
   when none was set, the one first boot generated (`sudo cat
   /etc/safbox/safuser.env` as `admin` over SSH). See
   [Accounts on a clone](build.md#accounts-on-a-clone).

The connection goes from your workstation to the node's SPICE proxy on TCP
port **3128**, not to the VM. If `remote-viewer` reports that it cannot
connect, allow that port from your workstation to the node. The Proxmox user
needs `VM.Console` on the VM, as for any console.

## 4. When SPICE is not available

The noVNC console (**Console → noVNC**) remains available and works with
both display adapters,
from any browser, with no client to install. Use it from macOS, or when port
3128 is closed. The desktop works there too, at a fixed resolution.

## Security notes

- The STIG's GNOME rules (session lock, no automatic login) apply to the
  desktop whichever console carries it: SPICE only carries the screen. The
  graphical login banner is not applied: the Lockdown task for it
  (RHEL-10-700020) fails, so the rule is switched off in
  `ansible/group_vars/all/main.yml`.
- SPICE's optional extras stay off. Proxmox does not add SPICE USB
  redirection ports (`usbN: spice`) or the folder-sharing and video-streaming
  enhancements (`spice_enhancements`) unless someone configures them; do not
  add them to a SAFBox, so no workstation devices or folders reach the box.
- The `.vv` file is a credential while its ticket is valid. Do not share it.
