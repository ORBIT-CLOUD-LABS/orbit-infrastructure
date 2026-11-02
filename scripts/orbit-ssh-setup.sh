#!/bin/sh
# Vault SSH 인증서 자동 갱신 설정. 팀원 Mac에서 한 번 실행 (docs/vault.md)
# 사용: scripts/orbit-ssh-setup.sh             처음 설정, 다시 실행해도 됨
#       scripts/orbit-ssh-setup.sh --reset-pat 키체인의 GitHub PAT만 새 값으로 바꿈
# 하는 일
#   1. Vault CA 인증서 ~/.orbit/vault-ca.crt (없으면 저장소의 scripts/vault-ca.crt, 그것도 없으면 astra에서 scp)
#   2. SSH 키 ~/.ssh/id_ed25519 (없으면 만듦)
#   3. GitHub PAT를 macOS 키체인에 저장 (orbit-github-pat)
#   4. Vault에 로그인해 내 개인 계정명을 확인하고 ~/.orbit/user에 저장 (정책 ssh-personal-<계정명>)
#      찾지 못하면 여기서 멈춤. 설치된 갱신 스크립트와 ~/.ssh/config는 바꾸지 않아서 기존 orbit 설정이 그대로 동작
#   5. ~/.orbit/refresh-cert.sh 설치 (이 저장소의 orbit-ssh-refresh.sh)
#   6. ~/.ssh/config에 Match 블록 추가. orbit 노드에 개인 계정으로 ssh할 때마다 인증서를 확인하고 필요하면 새로 받음
set -eu

here=$(cd "$(dirname "$0")" && pwd)
ORBIT_DIR=$HOME/.orbit
KEY=$HOME/.ssh/id_ed25519
ASTRA=100.94.67.18
# 자동 갱신을 켤 주소와 이름. 내부망(노드, VM), 와이파이, Tailscale 주소(tailscale status 기준), Tailscale 이름(MagicDNS)
# 노드가 바뀌거나 Tailscale 주소가 바뀌면 여기를 고치고 팀원이 이 스크립트를 다시 실행함
MATCH_HOSTS="10.0.0.20?,192.168.200.20?,$ASTRA,100.122.168.54,100.104.39.87,100.94.74.17,100.87.222.23,astra,polaris,sol,terra,luna,efk,lgtm,wazuh"
PAT_SERVICE=orbit-github-pat
SSH_CONFIG=$HOME/.ssh/config
BEGIN='# >>> orbit-vault-ssh (orbit-infrastructure/scripts/orbit-ssh-setup.sh가 관리) >>>'
END='# <<< orbit-vault-ssh <<<'

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'orbit-ssh-setup: %s\n' "$*" >&2; exit 1; }

reset_pat=0
case ${1:-} in
  --reset-pat) reset_pat=1 ;;
  '') ;;
  *) die "사용: $0 [--reset-pat]" ;;
esac

[ "$(uname)" = Darwin ] || die "macOS 전용 (PAT를 키체인에 보관함). 다른 OS는 docs/vault.md의 수동 절차를 따름"
command -v jq >/dev/null 2>&1 || die "jq 없음. brew install jq 후 다시 실행"
for c in curl ssh ssh-keygen scp security openssl; do
  command -v "$c" >/dev/null 2>&1 || die "$c 없음"
done

mkdir -p "$ORBIT_DIR"
chmod 700 "$ORBIT_DIR"

step "Vault CA 인증서 (~/.orbit/vault-ca.crt)"
if [ -f "$ORBIT_DIR/vault-ca.crt" ]; then
  echo "이미 있음"
else
  tmp=$ORBIT_DIR/vault-ca.crt.tmp
  # 공개 인증서라 저장소에 둘 수 있음. 없으면 공용 orbit 계정으로 scp (공용 접속 회수 전까지만 됨)
  if [ -f "$here/vault-ca.crt" ]; then
    cp "$here/vault-ca.crt" "$tmp"
  else
    scp -q "orbit@$ASTRA:/opt/vault/tls/vault-ca.crt" "$tmp" ||
      die "astra에서 받지 못함. 다른 팀원에게 vault-ca.crt를 받아 $ORBIT_DIR/vault-ca.crt에 둔 뒤 다시 실행"
  fi
  openssl x509 -in "$tmp" -noout 2>/dev/null || { rm -f "$tmp"; die "받은 파일이 인증서가 아님"; }
  chmod 644 "$tmp"
  mv "$tmp" "$ORBIT_DIR/vault-ca.crt"
  echo "받음"
fi

step "SSH 키 (~/.ssh/id_ed25519)"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -f "$KEY"
elif [ ! -f "$KEY.pub" ]; then
  ssh-keygen -y -f "$KEY" >"$KEY.pub"
  echo "공개키를 개인키에서 다시 만듦"
else
  echo "이미 있음"
fi

step "GitHub PAT (키체인 $PAT_SERVICE)"
if [ "$reset_pat" = 0 ] && security find-generic-password -s "$PAT_SERVICE" >/dev/null 2>&1; then
  echo "이미 있음 (바꾸려면 --reset-pat)"
else
  cat <<'EOF'
GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)에서 만든 PAT
scope는 read:org 하나만. 입력한 값은 화면에 보이지 않음 (두 번 입력)
EOF
  # -w를 마지막에 값 없이 주면 security가 직접 물어봄 (PAT가 명령 인자로 남지 않게)
  security add-generic-password -U -a "$USER" -s "$PAT_SERVICE" -l "ORBIT GitHub PAT (Vault 로그인)" -w
  rm -f "$ORBIT_DIR/vault-token"   # 예전 PAT로 받은 토큰은 버리고 새 PAT로 다시 로그인
  echo "저장함"
fi

# 설치된 갱신 스크립트는 아직 바꾸지 않음. 예전 버전(orbit 서명)을 쓰던 사람이 여기서 멈춰도 그대로 동작하게
step "개인 계정 확인 (Vault GitHub 로그인)"
ssh_user=$(sh "$here/orbit-ssh-refresh.sh" --whoami) ||
  die "Vault에서 개인 SSH 권한을 찾지 못함 (위 orbit-ssh: 메시지 확인). 갱신 스크립트와 ~/.ssh/config는 바꾸지 않았음"
printf '%s\n' "$ssh_user" >"$ORBIT_DIR/user.tmp"
chmod 644 "$ORBIT_DIR/user.tmp"
mv "$ORBIT_DIR/user.tmp" "$ORBIT_DIR/user"
echo "$ssh_user (~/.orbit/user)"

step "갱신 스크립트 설치 (~/.orbit/refresh-cert.sh)"
install -m 755 "$here/orbit-ssh-refresh.sh" "$ORBIT_DIR/refresh-cert.sh"

step "~/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
cp -p "$SSH_CONFIG" "$SSH_CONFIG.orbit-bak"
# 예전 블록을 빼고 맨 뒤에 다시 붙임 (사용자가 앞에 둔 Host 설정이 먼저 적용됨)
# 빈 줄은 뒤에 내용이 올 때만 출력해서, 다시 실행해도 파일 끝에 빈 줄이 쌓이지 않게 함
awk -v b="$BEGIN" -v e="$END" '
  $0 == b {skip = 1}
  !skip { if ($0 == "") blank++; else { while (blank > 0) {print ""; blank--} print } }
  $0 == e {skip = 0}
' "$SSH_CONFIG.orbit-bak" >"$SSH_CONFIG.orbit-tmp"
cat >>"$SSH_CONFIG.orbit-tmp" <<EOF

$BEGIN
# orbit 노드(내부망, 와이파이, Tailscale)에 ssh하기 직전에 Vault SSH 인증서를 확인하고 필요하면 새로 받음
# 개인 계정($ssh_user)으로 접속. 인증서는 이 계정에만 유효함
# 개인 계정이 아직 없는 호스트나 비상시에는 ssh orbit@<호스트> (authorized_keys의 기존 키)
Match host $MATCH_HOSTS exec "sh ~/.orbit/refresh-cert.sh"
  User $ssh_user
  IdentityFile ~/.ssh/id_ed25519
  CertificateFile ~/.ssh/id_ed25519-cert.pub
$END
EOF
mv "$SSH_CONFIG.orbit-tmp" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
echo "Match 블록 추가 (이전 파일: ~/.ssh/config.orbit-bak)"

step "인증서 받기"
sh "$ORBIT_DIR/refresh-cert.sh"
# 읽을 수 있는지만 보면, 갱신에 실패하고 예전(만료된) 인증서가 남은 경우도 완료로 보임
# 유효기간이 남았고 지금 공개키로 받은 인증서인지까지 확인
cert_info=$(ssh-keygen -L -f "$KEY-cert.pub" 2>/dev/null) || cert_info=
cert_until=$(printf '%s\n' "$cert_info" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
cert_end=0
[ -z "$cert_until" ] || cert_end=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$cert_until" +%s 2>/dev/null) || cert_end=0
cert_fp=$(printf '%s\n' "$cert_info" | sed -n 's/^ *Public key: [^ ]* \(SHA256:[^ ]*\)$/\1/p')
key_fp=$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')
cert_principals=$(printf '%s\n' "$cert_info" | awk '/^ *Principals:/ {p = 1; next} /^ *Critical Options:/ {p = 0} p {gsub(/^ +| +$/, ""); print}')
if [ "$cert_end" -gt "$(date +%s)" ] && [ -n "$cert_fp" ] && [ "$cert_fp" = "$key_fp" ] && [ "$cert_principals" = "$ssh_user" ]; then
  printf '%s\n' "$cert_info" | grep -E '^ +(Key ID|Valid):'
  cat <<EOF

완료. 이제 ssh 10.0.0.202 처럼 접속하면 개인 계정($ssh_user)으로 들어감 (만료 10분 전부터 접속할 때 자동으로 새로 받음)
인증서로 들어갔는지 확인: ssh -v 10.0.0.202 true 2>&1 | grep 'Server accepts key'  → ED25519-CERT 이면 정상
개인 계정이 아직 만들어지지 않은 호스트는 거부됨. 그때는 ssh orbit@<호스트> (기존 키)
EOF
else
  if [ -n "$cert_info" ]; then
    echo "남아 있는 인증서는 쓸 수 없음 (만료: ${cert_until:-알 수 없음}, 다른 키나 다른 계정(orbit)으로 받은 것일 수도 있음)"
  fi
  cat <<EOF

설정은 끝났지만 유효한 인증서를 받지 못함. 위 orbit-ssh: 메시지를 확인
Vault가 sealed이거나 Tailscale이 꺼져 있으면 다음 접속 때 다시 시도함
개인 계정은 인증서로만 로그인되므로 그동안은 거부됨. 급하면 ssh orbit@<호스트> (기존 키)
EOF
  exit 1
fi
