#!/usr/bin/env bash
# Ansible 롤 검증용 테스트 VM(기본 3대, libvirt 기본망 192.168.122.x)
# 사용법: ./scripts/test-vms.sh          생성
#        ./scripts/test-vms.sh delete   삭제 (VM, 디스크, DHCP 예약, known_hosts 항목)
# sudo 없이 libvirt 그룹 권한만으로 동작한다 (디스크는 libvirt 스토리지 풀 볼륨으로 만든다).
# 접속 키는 기본으로 ~/.ssh/id_ed25519.pub를 넣고, SSH_PUBKEY="<공개키 내용>"로 바꿀 수 있다 (여러 줄 가능).
set -e
V="virsh -c qemu:///system"

MARKER="created-by=orbit-test-vms"

# 이 스크립트가 만든 VM인지 확인
# 옵션 없이 desc를 읽으면 실행 중인 VM은 live 설정을 읽으므로, 저장된(config) 설정을 읽는다.
is_ours() {
  [ "$($V desc "$1" --config 2>/dev/null)" = "$MARKER" ]
}

vm_exists() {
  $V dominfo "$1" >/dev/null 2>&1
}

# 기본망 DHCP 예약 (VM이 인벤토리와 같은 IP를 받도록)
# 같은 예약이 이미 있으면 건너뛰고, MAC·이름·IP 중 하나라도 다른 예약과 겹치면 중단한다.
reserve_dhcp() {
  local name=$1 mac=$2 ip=$3 entry xml conflict
  entry="<host mac='$mac' name='$name' ip='$ip'/>"
  xml=$($V net-dumpxml default --inactive)
  if grep -qF "$entry" <<<"$xml"; then
    return 0
  fi
  conflict=$(grep -E "<host .*(mac='$mac'|name='$name'|ip='${ip//./\\.}')" <<<"$xml" || true)
  if [ -n "$conflict" ]; then
    echo "[ERROR] $name: DHCP 예약이 기존 예약과 겹쳐 중단합니다."
    echo "  요청: $entry"
    echo "  기존: $(echo "$conflict" | sed 's/^ *//')"
    exit 1
  fi
  $V net-update default add ip-dhcp-host "$entry" --live --config >/dev/null
}

# 이 스크립트가 만든 것과 똑같은 DHCP 예약만 지운다
release_dhcp() {
  local entry="<host mac='$2' name='$1' ip='$3'/>"
  if $V net-dumpxml default --inactive | grep -qF "$entry"; then
    $V net-update default delete ip-dhcp-host "$entry" --live --config >/dev/null
  fi
}

# known_hosts에서 테스트 VM IP 항목 삭제
# ssh-keygen -R은 known_hosts.old를 덮어쓰므로 임시 사본에서 지운 뒤 내용만 되돌려 쓴다.
forget_host() {
  local kh=~/.ssh/known_hosts tmp
  [ -f "$kh" ] && ssh-keygen -F "$1" -f "$kh" >/dev/null || return 0
  tmp=$(mktemp)
  cp "$kh" "$tmp"
  ssh-keygen -R "$1" -f "$tmp" >/dev/null 2>&1
  cat "$tmp" > "$kh"
  rm -f "$tmp" "$tmp.old"
}

# Lab VM(Terraform)과 같은 Ubuntu 24.04 베이스 이미지 (images 풀의 볼륨)
POOL=images
BASE_VOL=noble-server-cloudimg-amd64.img
NODES="${NODES:-test-cp:10 test-w1:11 test-w2:12}"   # 예: NODES="test-db:13 test-mon:14" ./scripts/test-vms.sh

if [ "${1:-}" = "delete" ]; then
  for n in $NODES; do
    NAME=${n%%:*}; NUM=${n##*:}
    if vm_exists "$NAME"; then
      if ! is_ours "$NAME"; then
        echo "[SKIP] $NAME: 이 스크립트가 만든 VM이 아니라 삭제하지 않습니다."
        continue
      fi
      $V destroy "$NAME" 2>/dev/null || true
      $V undefine "$NAME" --remove-all-storage >/dev/null
      echo "🗑  $NAME 삭제"
    else
      echo "[SKIP] $NAME: VM 없음"
    fi
    release_dhcp "$NAME" "52:54:00:aa:00:$NUM" "192.168.122.$NUM"
    forget_host "192.168.122.$NUM"
  done
  exit 0
fi

if ! $V vol-info --pool "$POOL" "$BASE_VOL" >/dev/null 2>&1; then
  echo "[ERROR] 베이스 이미지 볼륨 없음: $POOL/$BASE_VOL"
  echo "  Ubuntu 24.04 cloud image를 받은 뒤(SRC) libvirt 풀에 올리세요 (sudo 불필요):"
  echo "  SRC=noble-server-cloudimg-amd64.img"
  echo "  curl -fL -o \$SRC https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  echo "  virsh -c qemu:///system vol-create-as $POOL $BASE_VOL \$(stat -c %s \$SRC) --format raw"
  echo "  virsh -c qemu:///system vol-upload --pool $POOL $BASE_VOL \$SRC"
  exit 1
fi

KEYS="${SSH_PUBKEY:-$(cat ~/.ssh/id_ed25519.pub)}"
$V net-start default 2>/dev/null || true
$V net-autostart default >/dev/null

for n in $NODES; do
  NAME=${n%%:*}; NUM=${n##*:}
  MAC=52:54:00:aa:00:$NUM
  IP=192.168.122.$NUM

  reserve_dhcp "$NAME" "$MAC" "$IP"

  if vm_exists "$NAME"; then
    if is_ours "$NAME"; then
      echo "[SKIP] $NAME: 이미 있음 (다시 만들려면 먼저 delete)"
      continue
    fi
    echo "[ERROR] $NAME: 같은 이름의 다른 VM이 있어 중단합니다."
    exit 1
  fi

  # 베이스 이미지 기반 디스크 (풀 볼륨이라 VM 삭제 시 --remove-all-storage로 같이 지워진다)
  $V vol-create-as "$POOL" "$NAME.qcow2" 30G --format qcow2 \
    --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null

  # cloud-init: 실제 Lab VM과 같은 orbit 계정 + SSH 키 (VM 생성에만 쓰고 바로 지운다)
  USER_DATA=$(mktemp)
  {
    echo "#cloud-config"
    echo "hostname: $NAME"
    echo "users:"
    echo "  - name: orbit"
    echo "    sudo: ALL=(ALL) NOPASSWD:ALL"
    echo "    shell: /bin/bash"
    echo "    ssh_authorized_keys:"
    # 빈 줄은 건너뛴다 (&&로 쓰면 마지막 줄이 빈 줄일 때 set -e로 스크립트가 멈춘다)
    while IFS= read -r k; do if [ -n "$k" ]; then echo "      - $k"; fi; done <<<"$KEYS"
  } > "$USER_DATA"

  virt-install --connect qemu:///system --name "$NAME" \
    --memory 4096 --vcpus 2 \
    --disk vol="$POOL/$NAME.qcow2" --import --osinfo ubuntu24.04 \
    --network network=default,mac=$MAC \
    --cloud-init user-data="$USER_DATA" \
    --graphics none --noautoconsole >/dev/null
  rm -f "$USER_DATA"
  echo "✅ $NAME → $IP"

  $V desc "$NAME" --live --config --new-desc "$MARKER" >/dev/null

done
echo "부팅까지 1~2분 기다린 뒤: cd ansible && ansible -i inventory/test.ini k8s -m ping"
