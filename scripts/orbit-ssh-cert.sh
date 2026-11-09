#!/usr/bin/env bash
# astra 개인 계정에서 쓰는 Vault SSH 인증서 받기 (Linux. macOS는 orbit-ssh-setup.sh)
# astra에서 개인 계정으로 Ansible을 실행하면 다른 호스트에 개인 인증서로 접속해야 함
#   ~/orbit-infrastructure/scripts/orbit-ssh-cert.sh
# - GitHub PAT를 숨김 입력으로 받아 Vault에 로그인. 토큰은 ~/.orbit/vault-token(0600)에 두고 살아 있는 동안 다시 씀
# - ~/.ssh/id_ed25519가 없으면 만들고, 공개키를 Vault 역할 personal-<계정명>으로 서명받아 ~/.ssh/id_ed25519-cert.pub에 저장
# - 인증서는 8시간. 작업을 시작할 때 실행. 자동 갱신은 하지 않음 (키체인 같은 PAT 보관소가 없음)
# 같은 토큰으로 Vault 비밀값(efk 등)도 읽을 수 있음: export VAULT_TOKEN=$(cat ~/.orbit/vault-token)
set -euo pipefail
umask 077

die() { printf 'orbit-ssh-cert: %s\n' "$*" >&2; exit 1; }

ME=$(id -un)
ORBIT_DIR=$HOME/.orbit
TOKEN_FILE=$ORBIT_DIR/vault-token
KEY=$HOME/.ssh/id_ed25519
CERT=$KEY-cert.pub
SIGN_PATH=ssh-client-signer/sign/personal-$ME   # Vault 역할 personal-<계정명> (hvault_ssh_personal_role_prefix)
POLICY=ssh-personal-$ME                          # Vault 정책 ssh-personal-<계정명> (hvault_ssh_personal_policy_prefix)
MIN_TTL=600                                      # 토큰이 10분 넘게 남았을 때만 다시 씀

export VAULT_ADDR=${VAULT_ADDR:-https://10.0.0.201:8200}
export VAULT_CACERT=${VAULT_CACERT:-/opt/vault/tls/vault-ca.crt}

for c in vault jq ssh-keygen; do
  command -v "$c" >/dev/null || die "$c 명령이 없음"
done
[ -r "$VAULT_CACERT" ] || die "Vault CA 인증서를 읽을 수 없음: $VAULT_CACERT"
mkdir -p "$ORBIT_DIR" "$HOME/.ssh"
chmod 700 "$ORBIT_DIR" "$HOME/.ssh"

# 저장된 토큰이 살아 있고 내 개인 정책이 있으면 그대로 씀
token_ok() {
  [ -s "$TOKEN_FILE" ] || return 1
  info=$(VAULT_TOKEN=$(cat "$TOKEN_FILE") vault token lookup -format=json 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg p "$POLICY" --argjson min "$MIN_TTL" \
    '(.data.ttl > $min) and ((.data.policies // []) + (.data.identity_policies // []) | index($p))' >/dev/null
}

if ! token_ok; then
  echo "Vault GitHub 로그인 (PAT는 화면에 나오지 않음)"
  tok=$(vault login -method=github -token-only) || die "Vault 로그인 실패"
  printf '%s\n' "$tok" >"$TOKEN_FILE"
  unset tok
  token_ok || die "토큰에 개인 SSH 정책($POLICY)이 없음. 관리자에게 personal_accounts 명단 추가와 Vault 적용을 요청"
fi

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "$ME@$(hostname -s)" -f "$KEY"
fi

VAULT_TOKEN=$(cat "$TOKEN_FILE") vault write -field=signed_key "$SIGN_PATH" public_key=@"$KEY.pub" >"$CERT.tmp" \
  || { rm -f "$CERT.tmp"; die "인증서 서명 실패 (역할 personal-$ME)"; }
ssh-keygen -L -f "$CERT.tmp" >/dev/null 2>&1 || { rm -f "$CERT.tmp"; die "Vault가 돌려준 인증서를 읽을 수 없음"; }
chmod 644 "$CERT.tmp"
mv -f "$CERT.tmp" "$CERT"

until=$(ssh-keygen -L -f "$CERT" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
echo "SSH 인증서를 받음 ($ME, ${until#*T}까지)"
