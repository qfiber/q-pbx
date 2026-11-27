#!/usr/bin/env bash
# Creates the local Debian 12 lab VM (libvirt, qemu:///system) used until real lab hardware
# exists. Idempotent: reuses the downloaded image, the SSH key and an existing VM.
#   lab/create-vm.sh            create (or start) the VM and print its IP
#   lab/create-vm.sh destroy    remove the VM and its disk
set -euo pipefail
NAME=${QPBX_LAB_NAME:-qpbx-lab}
LAB_DIR=${QPBX_LAB_DIR:-$HOME/.local/share/qpbx-lab}
POOL=${QPBX_LAB_POOL:-default}
# Default: bridge to the host LAN (br0) for direct internet; or e.g. "network=default" for libvirt NAT.
NET=${QPBX_LAB_NET:-bridge=br0}
IMG_URL=https://cloud.debian.org/images/cloud/bookworm/latest
IMG=debian-12-genericcloud-amd64.qcow2
export LIBVIRT_DEFAULT_URI=qemu:///system

if [[ ${1:-} == destroy ]]; then
  virsh destroy "$NAME" 2>/dev/null || true
  virsh undefine "$NAME" --nvram 2>/dev/null || virsh undefine "$NAME" 2>/dev/null || true
  virsh vol-delete --pool "$POOL" "$NAME.qcow2" 2>/dev/null || true
  virsh vol-delete --pool "$POOL" "$NAME-seed.iso" 2>/dev/null || true
  rm -f "$LAB_DIR/known_hosts"
  exit 0
fi

mkdir -p "$LAB_DIR" && cd "$LAB_DIR"
[[ -f id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C qpbx-lab -f id_ed25519

if [[ ! -f $IMG ]]; then
  curl -fsSLO "$IMG_URL/$IMG" && curl -fsSL "$IMG_URL/SHA512SUMS" -o SHA512SUMS
  grep " $IMG\$" SHA512SUMS | sha512sum -c - || { rm -f "$IMG"; echo "checksum mismatch" >&2; exit 1; }
fi

if ! virsh dominfo "$NAME" >/dev/null 2>&1; then
  qemu-img convert -O qcow2 "$IMG" disk.qcow2 && qemu-img resize -q disk.qcow2 20G
  virsh vol-create-as "$POOL" "$NAME.qcow2" 20G --format qcow2 >/dev/null
  virsh vol-upload --pool "$POOL" "$NAME.qcow2" disk.qcow2 && rm -f disk.qcow2
  cat > user-data <<UD
#cloud-config
hostname: $NAME
users: [default]
ssh_authorized_keys: ["$(cat id_ed25519.pub)"]
package_update: true
packages: [python3, python3-apt, acl, qemu-guest-agent]
runcmd: [[systemctl, start, qemu-guest-agent]]
UD
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > meta-data
  # NoCloud seed (label "cidata") as a virtio disk: the Debian cloud kernel has no SATA CD-ROM driver.
  genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
  virsh vol-create-as "$POOL" "$NAME-seed.iso" 1M --format raw >/dev/null
  virsh vol-upload --pool "$POOL" "$NAME-seed.iso" seed.iso && rm -f seed.iso
  virt-install --name "$NAME" --memory 4096 --vcpus 4 --osinfo debian12 --import \
    --disk "vol=$POOL/$NAME.qcow2,bus=virtio" --disk "vol=$POOL/$NAME-seed.iso,device=disk,bus=virtio,readonly=on" \
    --network "$NET,model=virtio" --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 --graphics none --noautoconsole >/dev/null
fi
virsh domstate "$NAME" | grep -q running || virsh start "$NAME" >/dev/null

for _ in $(seq 1 60); do
  # Guest agent works on any network; the lease table only on libvirt NAT networks.
  ip=$( { virsh domifaddr "$NAME" --source agent 2>/dev/null; virsh domifaddr "$NAME" 2>/dev/null; } \
    | awk '/ipv4/ && $4 !~ /^127\./ {sub("/.*","",$4); print $4; exit}')
  [[ -n ${ip:-} ]] && ssh -q -o IdentitiesOnly=yes -i id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
    -o UserKnownHostsFile="$LAB_DIR/known_hosts" "debian@$ip" 'cloud-init status --wait >/dev/null; true' && break
  sleep 3
done
[[ -n ${ip:-} ]] || { echo "VM did not get an IP" >&2; exit 1; }
ssh -q -o IdentitiesOnly=yes -i id_ed25519 -o UserKnownHostsFile="$LAB_DIR/known_hosts" "debian@$ip" true \
  || { echo "VM at $ip does not accept the lab SSH key" >&2; exit 1; }
echo "$ip"
