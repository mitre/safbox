#!/usr/bin/env bash
# 10-grow-disk.sh: first-boot hook of the base role. Gives a clone whose disk
# is larger than the template's the extra space: grows the volume group's
# partition to the end of the disk and its physical volume to the partition,
# then hands the volume group's free space to /home, /var, /var/log and
# /var/log/audit by the kickstart's shares (40/40/10/10), growing each XFS
# filesystem online. On a disk of the template's size there is nothing to
# grow and it changes nothing. A host without the kickstart's volume group
# is left alone.
#
# Idempotent: every step acts only on space not yet in use, so a second run
# is a no-op. Run by safbox-firstboot; after enlarging a deployed box's disk,
# run it again by hand as root. Logs each step to standard output (the
# journal, under safbox-firstboot, when run at first boot).
set -euo pipefail
export LC_ALL=C

# Keep in step with the kickstart's logvol --percent lines.
readonly VG=vg_safbox
# The last volume also takes the extents the rounding leaves over, so no
# free extent is left for a second run to hand out.
readonly SHARES=(home:40 var_log:10 var_log_audit:10 var:40)

log() { printf 'grow-disk: %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

if ! vgs "$VG" >/dev/null 2>&1; then
  log "no $VG; nothing to grow"
  exit 0
fi

pv=$(pvs --noheadings -o pv_name -S "vg_name=$VG" | tr -d ' ')
[[ -n "$pv" && "$pv" != *$'\n'* ]] || die "expected one physical volume in $VG, found: ${pv:-none}"
partition_file=/sys/class/block/$(basename "$pv")/partition
[[ -r "$partition_file" ]] || die "physical volume $pv is not a disk partition"
part=$(<"$partition_file")
disk=/dev/$(lsblk -dno PKNAME "$pv")

# growpart exits 1 and prints NOCHANGE when the partition already ends at
# the end of the disk.
if out=$(growpart "$disk" "$part" 2>&1); then
  log "grew partition $part of $disk: $out"
elif [[ $out == *NOCHANGE:* ]]; then
  log "partition $part of $disk already fills the disk"
else
  die "growpart $disk $part failed: $out"
fi

# growpart resizes the physical volume itself; pvresize covers a partition
# grown by other means and changes nothing when the volume already fills it.
pvresize "$pv" >/dev/null || die "pvresize $pv failed"
log "physical volume $pv fills its partition"

# If an extension fails, stop: the next run (first boot retries on the next
# boot) hands out whatever is still free by the same shares.
free=$(vgs --noheadings -o vg_free_count "$VG" | tr -d ' ')
log "$VG has $free free extent(s)"
given=0
for entry in "${SHARES[@]}"; do
  lv=${entry%%:*}
  extents=$(( free * ${entry#*:} / 100 ))
  if [[ $entry == "${SHARES[-1]}" ]]; then extents=$(( free - given )); fi
  given=$(( given + extents ))
  if (( extents > 0 )); then
    lvextend --resizefs -l "+$extents" "$VG/$lv" || die "lvextend of $VG/$lv by $extents extent(s) failed"
    log "extended $VG/$lv by $extents extent(s) and grew its filesystem"
  fi
done
log "done"
