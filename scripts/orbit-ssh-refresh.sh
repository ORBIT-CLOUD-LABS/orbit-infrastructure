#!/bin/sh
# Vault SSH 인증서를 필요할 때만 새로 받음 (docs/vault.md)
# orbit-ssh-setup.sh가 ~/.orbit/refresh-cert.sh로 복사하고, ~/.ssh/config의 Match exec가 ssh마다 실행함
# - 인증서가 10분 넘게 남았고 지금 공개키와 맞으면 아무것도 안 함
# - Vault 토큰(~/.orbit/vault-token)이 살아 있으면 그걸로, 아니면 키체인의 GitHub PAT로 로그인
# - 항상 0으로 끝남. 실패하면 경고만 하고 ssh는 기존 키로 접속을 계속 시도함
# 출력은 모두 stderr (ssh의 stdout은 scp, rsync, git이 데이터 통로로 씀)
# 비밀값(PAT, 토큰)은 명령 인자로 넘기지 않음 (ps에 보임). stdin과 0600 파일로만 다룸
set -u
exec 1>&2 </dev/null
umask 077

ORBIT_DIR=${ORBIT_DIR:-$HOME/.orbit}
V_ADDR=${ORBIT_VAULT_ADDR:-https://100.94.67.18:8200}
CA_CERT=${ORBIT_VAULT_CACERT:-$ORBIT_DIR/vault-ca.crt}
KEY=${ORBIT_SSH_KEY:-$HOME/.ssh/id_ed25519}
SIGN_PATH=ssh-client-signer/sign/orbit
PAT_SERVICE=orbit-github-pat
TOKEN_FILE=$ORBIT_DIR/vault-token
CERT=$KEY-cert.pub
LOCK=$ORBIT_DIR/.refresh.lock
DOWN=$ORBIT_DIR/.vault-unreachable   # 연결 실패 표시. 1분 동안은 다시 시도하지 않음
MARGIN=600   # 남은 시간이 이보다 짧으면 새로 받음 (초)

warn() { printf 'orbit-ssh: %s\n' "$*"; }

to_epoch() {
  date -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}

# 인증서가 있고, MARGIN보다 오래 남았고, 지금 공개키로 받은 것인지
cert_ok() {
  [ -f "$CERT" ] || return 1
  info=$(ssh-keygen -L -f "$CERT" 2>/dev/null) || return 1
  until=$(printf '%s\n' "$info" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
  [ -n "$until" ] || return 1
  end=$(to_epoch "$until") || return 1
  [ $((end - $(date +%s))) -gt "$MARGIN" ] || return 1
  want=$(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')
  have=$(printf '%s\n' "$info" | sed -n 's/^ *Public key: [^ ]* \(SHA256:[^ ]*\)$/\1/p')
  [ -n "$want" ] && [ "$want" = "$have" ]
}

cert_ok && exit 0

for c in curl jq ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { warn "$c 없음. 인증서를 받지 못해 기존 키로 접속"; exit 0; }
done
[ -f "$KEY.pub" ] || { warn "$KEY.pub 없음. scripts/orbit-ssh-setup.sh 실행"; exit 0; }
[ -f "$CA_CERT" ] || { warn "$CA_CERT 없음. scripts/orbit-ssh-setup.sh 실행"; exit 0; }
mkdir -p "$ORBIT_DIR"

# 와이파이처럼 8200이 막힌(DROP) 곳에서 ssh할 때마다 기다리지 않게
if [ -n "$(find "$DOWN" -mmin -1 2>/dev/null)" ]; then
  warn "Vault에 연결되지 않아 잠시 갱신을 건너뜀. 기존 키로 접속"
  exit 0
fi

# ssh를 여러 개 동시에 열어도 로그인은 한 번만 (먼저 잡은 쪽이 받고 나머지는 기다렸다가 그걸 씀)
i=0
while ! mkdir "$LOCK" 2>/dev/null; do
  if [ -n "$(find "$LOCK" -prune -mmin +1 2>/dev/null)" ]; then   # 1분 넘은 잠금은 죽은 것으로 봄
    rmdir "$LOCK" 2>/dev/null
    continue
  fi
  i=$((i + 1))
  [ "$i" -lt 20 ] || { warn "다른 갱신이 끝나지 않음. 지금 있는 인증서나 기존 키로 접속"; exit 0; }
  sleep 1
done
RESP=$(mktemp "$ORBIT_DIR/.resp.XXXXXX")
ERR=$(mktemp "$ORBIT_DIR/.err.XXXXXX")
trap 'rm -f "$RESP" "$ERR" "$CERT.tmp"; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 0' HUP INT TERM

cert_ok && exit 0   # 기다리는 동안 다른 ssh가 받았을 수 있음

# api 방식 경로 [curl 인자...]: 상태 코드를 출력. 본문은 $RESP. 연결 실패는 000
api() {
  m=$1 p=$2
  shift 2
  curl -sS --connect-timeout 2 --max-time 5 --cacert "$CA_CERT" -X "$m" -o "$RESP" -w '%{http_code}' "$@" "$V_ADDR/v1/$p" 2>"$ERR"
}

vault_errors() { jq -r '(.errors // []) | join(", ")' "$RESP" 2>/dev/null; }

net_fail() {
  warn "Vault($V_ADDR)에 연결하지 못함: $(head -n 1 "$ERR"). Tailscale 연결을 확인. 기존 키로 접속"
  touch "$DOWN"
  exit 0
}

get_pat() {
  if [ -n "${ORBIT_GITHUB_PAT:-}" ]; then
    printf '%s' "$ORBIT_GITHUB_PAT"
  elif command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$PAT_SERVICE" -w 2>/dev/null
  else
    return 1
  fi
}

tok=
fresh=0

login() {
  pat=$(get_pat) || pat=
  [ -n "$pat" ] || { warn "GitHub PAT를 찾지 못함 (키체인 $PAT_SERVICE). scripts/orbit-ssh-setup.sh 실행"; return 1; }
  code=$(printf '%s' "$pat" | jq -Rs '{token: .}' | api POST auth/github/login --data-binary @-)
  pat=
  case $code in
    200)
      tok=$(jq -r '.auth.client_token // empty' "$RESP")
      : >"$RESP"
      [ -n "$tok" ] || { warn "Vault 로그인 응답에 토큰이 없음"; return 1; }
      printf '%s\n' "$tok" >"$TOKEN_FILE"
      fresh=1
      ;;
    000) net_fail ;;
    *)
      warn "Vault GitHub 로그인 실패 (HTTP $code: $(vault_errors))"
      warn "PAT가 만료됐거나 read:org 권한이 없거나 GitHub orbit 팀이 아닐 수 있음. PAT 교체: scripts/orbit-ssh-setup.sh --reset-pat"
      return 1
      ;;
  esac
}

# 저장된 토큰이 1분 넘게 남았으면 그대로 씀
if [ -s "$TOKEN_FILE" ]; then
  tok=$(head -n 1 "$TOKEN_FILE")
  code=$(printf 'X-Vault-Token: %s\n' "$tok" | api GET auth/token/lookup-self -H @-)
  case $code in
    200) [ "$(jq -r '.data.ttl // 0' "$RESP")" -gt 60 ] 2>/dev/null || tok= ;;
    000) net_fail ;;
    *) tok= ;;
  esac
fi
[ -n "$tok" ] || login || exit 0
rm -f "$DOWN"

sign() {
  body=$(jq -Rs '{public_key: rtrimstr("\n")}' <"$KEY.pub")
  code=$(printf 'X-Vault-Token: %s\n' "$tok" | api POST "$SIGN_PATH" -H @- --data-binary "$body")
}

sign
# 저장된 토큰이 그사이 폐기됐으면 한 번만 다시 로그인
if [ "$code" = 403 ] && [ "$fresh" = 0 ]; then
  login || exit 0
  sign
fi
case $code in
  200) ;;
  000) net_fail ;;
  *) warn "인증서 서명 실패 (HTTP $code: $(vault_errors)). 기존 키로 접속"; exit 0 ;;
esac

jq -r '.data.signed_key // empty | rtrimstr("\n")' "$RESP" >"$CERT.tmp"   # Vault 값 끝의 줄바꿈 + jq 줄바꿈으로 빈 줄이 생기지 않게
if ! ssh-keygen -L -f "$CERT.tmp" >/dev/null 2>&1; then
  warn "Vault가 돌려준 인증서를 읽을 수 없음. 기존 키로 접속"
  exit 0
fi
chmod 644 "$CERT.tmp"
mv -f "$CERT.tmp" "$CERT"
until=$(ssh-keygen -L -f "$CERT" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
warn "SSH 인증서를 새로 받음 (${until#*T}까지)"
exit 0
