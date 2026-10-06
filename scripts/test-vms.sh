#!/usr/bin/env bash
# Ansible 롤 검증용 테스트 VM 3대 (libvirt 기본망 192.168.122.x)
# 사용법: ./scripts/test-vms.sh          생성
#        ./scripts/test-vms.sh delete   삭제
set -e
V="virsh -c qemu:///system"

MARKER="created-by=orbit-test-vms"

# 이 스크립트가 만든 VM인지 확인
is_ours() {
  [ "$($V desc "$1" 2>/dev/null)" = "$MARKER" ]
}

vm_exists() {
  $V dominfo "$1" >/dev/null 2>&1
}
IMG=/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img
NODES="${test-cp:10 test-w1:11 test-w2:12}"   # 예: NODES="test-db:13 test-mon:14" ./scripts/test-vms.sh

if [ "${1:-}" = "delete" ]; then
  for n in $NODES; do
    NAME=${n%%:*}; NUM=${n##*:}
    if ! vm_exists "$NAME"; then
      echo "[SKIP] $NAME: 없음"
      continue
    fi
    if ! is_ours "$NAME"; then
      echo "[SKIP] $NAME: 이 스크립트가 만든 VM이 아니라 삭제하지 않습니다."
      continue
    fi
    $V destroy "$NAME" 2>/dev/null || true
    $V undefine "$NAME" --remove-all-storage
    ssh-keygen -R "192.168.122.$NUM" >/dev/null 2>&1 || true
    echo "🗑  $NAME 삭제"
  done
  exit 0
fi

KEY=$(cat ~/.ssh/id_ed25519.pub)
$V net-start default 2>/dev/null || true
$V net-autostart default >/dev/null

for n in $NODES; do
  NAME=${n%%:*}; NUM=${n##*:}
  MAC=52:54:00:aa:00:$NUM
  IP=192.168.122.$NUM

  # 항상 같은 IP 받도록 DHCP 예약
  $V net-update default add ip-dhcp-host \
    "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config 2>/dev/null || true

  if vm_exists "$NAME"; then
    if is_ours "$NAME"; then
      echo "[SKIP] $NAME: 이미 있음 (다시 만들려면 먼저 delete)"
      continue
    fi
    echo "[ERROR] $NAME: 같은 이름의 다른 VM이 있어 중단합니다."
    exit 1
  fi

  # 베이스 이미지 기반 디스크
  sudo qemu-img create -q -f qcow2 -F qcow2 -b "$IMG" \
    "/var/lib/libvirt/images/$NAME.qcow2" 30G

  # cloud-init: 실제 Lab VM과 같은 orbit 계정 + SSH 키
  cat > "/tmp/$NAME-user-data" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: orbit
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $KEY
EOF

  virt-install --connect qemu:///system --name "$NAME" \
    --memory 4096 --vcpus 2 \
    --disk "/var/lib/libvirt/images/$NAME.qcow2" --import --osinfo ubuntu22.04 \
    --network network=default,mac=$MAC \
    --cloud-init user-data="/tmp/$NAME-user-data" \
    --graphics none --noautoconsole >/dev/null
  echo "✅ $NAME → $IP"

  $V desc "$NAME" --config --new-desc "$MARKER"

done
echo "부팅까지 1~2분 기다린 뒤: cd ansible && ansible -i inventory/test.ini k8s -m ping"
