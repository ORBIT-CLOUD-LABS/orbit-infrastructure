#!/bin/sh
# Vault SSH 인증서를 필요할 때만 새로 받음 (docs/vault.md)
# orbit-ssh-setup.sh가 ~/.orbit/refresh-cert.sh로 복사하고, ~/.ssh/config의 Match exec가 ssh마다 실행함
# 사용: refresh-cert.sh            인증서 확인·갱신 (ssh가 실행)
#       refresh-cert.sh --whoami   Vault 로그인 후 내 개인 계정명을 stdout에 출력 (setup이 실행)
# - 개인 계정명은 ~/.orbit/user (setup이 Vault 정책 ssh-personal-<계정명>에서 알아내 저장)
# - 인증서가 10분 넘게 남았고, 지금 공개키로 받았고, principal이 내 계정명뿐이면 아무것도 안 함
# - Vault 토큰(~/.orbit/vault-token)이 살아 있으면 그걸로, 아니면 키체인의 GitHub PAT로 로그인
# - 갱신 모드는 항상 0으로 끝남. 실패하면 경고만 하고 ssh는 남은 인증서로 접속을 시도함
#   개인 계정은 인증서로만 로그인되므로, 유효한 인증서가 없으면 거부됨. 급하면 ssh orbit@<호스트>
#   --whoami는 실패하면 1 (setup이 갱신 스크립트 설치와 ~/.ssh/config 변경 전에 멈춤)
# 출력은 모두 stderr (ssh의 stdout은 scp, rsync, git이 데이터 통로로 씀). --whoami 결과만 stdout
# 비밀값(PAT, 토큰)은 명령 인자로 넘기지 않음 (ps에 보임). stdin과 0600 파일로만 다룸
set -u
mode=${1:-}
case $mode in
  '' | --whoami) ;;
  *) printf 'orbit-ssh: 사용: %s [--whoami]\n' "$0" >&2; exit 2 ;;
esac
exec 3>&1 1>&2 </dev/null
umask 077

ORBIT_DIR=${ORBIT_DIR:-$HOME/.orbit}
V_ADDR=${ORBIT_VAULT_ADDR:-https://100.94.67.18:8200}
CA_CERT=${ORBIT_VAULT_CACERT:-$ORBIT_DIR/vault-ca.crt}
KEY=${ORBIT_SSH_KEY:-$HOME/.ssh/id_ed25519}
SIGN_PREFIX=ssh-client-signer/sign/personal-   # Vault 역할 personal-<계정명> (hvault_ssh_personal_role_prefix)
POLICY_PREFIX=ssh-personal-                    # Vault 정책 ssh-personal-<계정명> (hvault_ssh_personal_policy_prefix)
USER_FILE=$ORBIT_DIR/user
PAT_SERVICE=orbit-github-pat
TOKEN_FILE=$ORBIT_DIR/vault-token
CERT=$KEY-cert.pub
LOCK=$ORBIT_DIR/.refresh.lock
DOWN=$ORBIT_DIR/.vault-unreachable   # 연결 실패 표시. 1분 동안은 다시 시도하지 않음
MARGIN=600   # 남은 시간이 이보다 짧으면 새로 받음 (초)
NOCERT='남은 인증서로 접속을 시도함 (유효한 인증서가 없으면 개인 계정은 거부됨. 급하면 ssh orbit@<호스트>)'
[ -z "$mode" ] || NOCERT=   # setup(--whoami)에서는 접속 안내가 필요 없음

warn() { printf 'orbit-ssh: %s\n' "$*"; }

# 갱신 모드는 ssh를 막지 않게 0, --whoami는 setup이 멈추게 1
bail() {
  [ "$mode" = --whoami ] && exit 1
  exit 0
}

# Linux 계정명 규칙 (ansible personal_accounts와 같음)
user_ok() {
  case $1 in
    '' | *[!a-z0-9_]*) return 1 ;;
    [a-z]*) [ "${#1}" -le 32 ] ;;
    *) return 1 ;;
  esac
}

to_epoch() {
  date -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null
}

# 인증서가 있고, MARGIN보다 오래 남았고, 지금 공개키로 받았고, principal이 내 계정명 하나뿐인지
# 공용 orbit 인증서가 남아 있으면 여기서 걸러져 개인 인증서를 새로 받음
cert_ok() {
  [ -f "$CERT" ] || return 1
  info=$(ssh-keygen -L -f "$CERT" 2>/dev/null) || return 1
  until=$(printf '%s\n' "$info" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
  [ -n "$until" ] || return 1
  end=$(to_epoch "$until") || return 1
  [ $((end - $(date +%s))) -gt "$MARGIN" ] || return 1
  want=$(ssh-keygen -lf "$KEY.pub" 2>/dev/null | awk '{print $2}')
  have=$(printf '%s\n' "$info" | sed -n 's/^ *Public key: [^ ]* \(SHA256:[^ ]*\)$/\1/p')
  [ -n "$want" ] && [ "$want" = "$have" ] || return 1
  principals=$(printf '%s\n' "$info" | awk '/^ *Principals:/ {p = 1; next} /^ *Critical Options:/ {p = 0} p {gsub(/^ +| +$/, ""); print}')
  [ "$principals" = "$SSH_USER" ]
}

SSH_USER=
if [ -z "$mode" ]; then
  SSH_USER=${ORBIT_SSH_USER:-}
  [ -n "$SSH_USER" ] || [ ! -f "$USER_FILE" ] || SSH_USER=$(head -n 1 "$USER_FILE")
  user_ok "$SSH_USER" || { warn "개인 계정 설정이 없거나 잘못됨 ($USER_FILE). scripts/orbit-ssh-setup.sh를 다시 실행. $NOCERT"; exit 0; }
  cert_ok && exit 0
fi

for c in curl jq ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { warn "$c 없음. 인증서를 받지 못함. $NOCERT"; bail; }
done
[ -f "$KEY.pub" ] || { warn "$KEY.pub 없음. scripts/orbit-ssh-setup.sh 실행"; bail; }
[ -f "$CA_CERT" ] || { warn "$CA_CERT 없음. scripts/orbit-ssh-setup.sh 실행"; bail; }
mkdir -p "$ORBIT_DIR"

# 와이파이처럼 8200이 막힌(DROP) 곳에서 ssh할 때마다 기다리지 않게. setup(--whoami)은 매번 시도
if [ -z "$mode" ] && [ -n "$(find "$DOWN" -mmin -1 2>/dev/null)" ]; then
  warn "Vault에 연결되지 않아 잠시 갱신을 건너뜀. $NOCERT"
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
  [ "$i" -lt 20 ] || { warn "다른 갱신이 끝나지 않음. $NOCERT"; bail; }
  sleep 1
done
RESP=$(mktemp "$ORBIT_DIR/.resp.XXXXXX")
ERR=$(mktemp "$ORBIT_DIR/.err.XXXXXX")
trap 'rm -f "$RESP" "$ERR" "$CERT.tmp"; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'bail' HUP INT TERM

[ -n "$mode" ] || ! cert_ok || exit 0   # 기다리는 동안 다른 ssh가 받았을 수 있음

# api 방식 경로 [curl 인자...]: 상태 코드를 출력. 본문은 $RESP. 연결 실패는 000
api() {
  m=$1 p=$2
  shift 2
  curl -sS --connect-timeout 2 --max-time 5 --cacert "$CA_CERT" -X "$m" -o "$RESP" -w '%{http_code}' "$@" "$V_ADDR/v1/$p" 2>"$ERR"
}

vault_errors() { jq -r '(.errors // []) | join(", ")' "$RESP" 2>/dev/null; }

net_fail() {
  warn "Vault($V_ADDR)에 연결하지 못함: $(head -n 1 "$ERR"). Tailscale 연결을 확인. $NOCERT"
  touch "$DOWN"
  bail
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
      warn "PAT가 만료됐거나 read:org 권한이 없거나 ORBIT-CLOUD-LABS 조직 멤버가 아닐 수 있음. PAT 교체: scripts/orbit-ssh-setup.sh --reset-pat"
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
[ -n "$tok" ] || login || bail
rm -f "$DOWN"

# 토큰 정책 중 ssh-personal-<계정명>이 정확히 하나여야 함. 결과는 $me
find_user() {
  me=
  code=$(printf 'X-Vault-Token: %s\n' "$tok" | api GET auth/token/lookup-self -H @-)
  case $code in
    200) ;;
    000) net_fail ;;
    *) warn "Vault 토큰 조회 실패 (HTTP $code: $(vault_errors))"; return 1 ;;
  esac
  found=$(jq -r --arg p "$POLICY_PREFIX" '.data.policies // [] | .[] | select(startswith($p)) | ltrimstr($p)' "$RESP")
  [ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" = 1 ] && user_ok "$found" || return 1
  me=$found
}

if [ "$mode" = --whoami ]; then
  # 매핑이 생기기 전에 받은 토큰에는 개인 정책이 없음. 한 번만 새로 로그인
  if ! find_user && [ "$fresh" = 0 ]; then
    login || exit 1
    find_user || true
  fi
  if [ -z "$me" ]; then
    warn "Vault 토큰에 개인 SSH 정책(${POLICY_PREFIX}<계정명>)이 하나만 있어야 함. 관리자에게 personal_accounts 명단 추가와 Vault 적용을 요청"
    exit 1
  fi
  printf '%s\n' "$me" >&3
  exit 0
fi

sign() {
  body=$(jq -Rs '{public_key: rtrimstr("\n")}' <"$KEY.pub")
  code=$(printf 'X-Vault-Token: %s\n' "$tok" | api POST "$SIGN_PREFIX$SSH_USER" -H @- --data-binary "$body")
}

sign
# 저장된 토큰이 그사이 폐기됐거나 개인 매핑 전에 받은 토큰이면 한 번만 다시 로그인
if [ "$code" = 403 ] && [ "$fresh" = 0 ]; then
  login || exit 0
  sign
fi
case $code in
  200) ;;
  000) net_fail ;;
  403) warn "개인 인증서 서명 거부 (역할 personal-$SSH_USER). 명단에서 빠졌거나 계정명이 바뀌었을 수 있음. 관리자에게 확인. $NOCERT"; exit 0 ;;
  *) warn "인증서 서명 실패 (HTTP $code: $(vault_errors)). $NOCERT"; exit 0 ;;
esac

jq -r '.data.signed_key // empty | rtrimstr("\n")' "$RESP" >"$CERT.tmp"   # Vault 값 끝의 줄바꿈 + jq 줄바꿈으로 빈 줄이 생기지 않게
if ! ssh-keygen -L -f "$CERT.tmp" >/dev/null 2>&1; then
  warn "Vault가 돌려준 인증서를 읽을 수 없음. $NOCERT"
  exit 0
fi
chmod 644 "$CERT.tmp"
mv -f "$CERT.tmp" "$CERT"
until=$(ssh-keygen -L -f "$CERT" | sed -n 's/^ *Valid: from [^ ]* to \([0-9T:-]*\)$/\1/p')
warn "SSH 인증서를 새로 받음 ($SSH_USER, ${until#*T}까지)"
exit 0
