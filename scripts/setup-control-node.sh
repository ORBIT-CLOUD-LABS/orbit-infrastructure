#!/usr/bin/env bash
# 제어 노드(astra) 준비 상태 점검 + 필요한 것만 설치
# 사용법: ./scripts/setup-control-node.sh
# - /etc/ansible 등 시스템 전역 설정은 건드리지 않는다 (공용 계정이라서)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; FAILED=1; }
FAILED=0

echo "== 1. Ansible / Python"
if ! command -v ansible-playbook >/dev/null; then
  warn "ansible 없음 → 설치합니다"
  sudo apt-get update -qq && sudo apt-get install -y -qq ansible >/dev/null
fi
command -v ansible-playbook >/dev/null && ok "$(ansible --version | head -1)" || fail "ansible 설치 실패"
command -v python3 >/dev/null && ok "$(python3 --version)" || fail "python3 없음"

echo "== 2. SSH 키 (관리 노드 접속용)"
if [ -f ~/.ssh/id_ed25519 ]; then
  ok "~/.ssh/id_ed25519 있음 — 이 공개키가 VM에 등록돼 있어야 함"
  echo "     $(cut -c1-60 ~/.ssh/id_ed25519.pub)..."
else
  fail "~/.ssh/id_ed25519 없음 → ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/id_ed25519 후 Terraform 담당에게 공개키 전달"
fi

echo "== 3. libvirt 접근 (VM 상태 확인용)"
if virsh -c qemu:///system list >/dev/null 2>&1; then
  ok "virsh 접근 가능"
else
  fail "virsh 접근 불가 → libvirt 그룹 추가 후 재접속 (sudo usermod -aG libvirt \$USER)"
fi

echo "== 4. 프로젝트 ansible.cfg 적용"
cd "$ROOT/ansible"
CFG=$(ansible --version 2>/dev/null | awk -F'= ' '/config file/ {print $2}')
if [ "$CFG" = "$ROOT/ansible/ansible.cfg" ]; then
  ok "config file = $CFG"
else
  fail "프로젝트 ansible.cfg가 적용 안 됨 (현재: ${CFG:-없음}) → ansible/ 폴더에서 실행하세요"
fi

echo "== 5. 인벤토리"
INV="$ROOT/ansible/inventory/lab/hosts.ini"
if [ -f "$INV" ]; then
  ok "inventory/lab/hosts.ini 있음"
  ansible-inventory --graph 2>/dev/null | sed 's/^/     /'
  echo "== 6. 관리 노드 접속 (ping)"
  ansible all -m ping -o 2>/dev/null | sed 's/^/     /' || true
else
  warn "inventory/lab/hosts.ini 없음 → Terraform apply로 생성되는지 Terraform 담당에게 확인"
fi

echo
[ "$FAILED" = 0 ] && echo "제어 노드 준비 완료 ✅" || { echo "위 ❌ 항목을 먼저 해결하세요"; exit 1; }
