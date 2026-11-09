# k3s 클러스터

구성: [#3](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/3).
SQLite 재설치: [#28](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/28). 2026-11-09 운영 클러스터를 SQLite 기준으로 재설치하고 노드·Cilium·Vault Kubernetes 로그인을 검증했다 ([적용 기록](#적용-기록)).
이 문서에는 이름과 절차만 기록한다. join 토큰과 kubeconfig 내용은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

## 구성

| 항목 | 값 |
| --- | --- |
| 버전 | k3s `v1.35.9+k3s1`, Cilium `1.20.4` (`inventory/group_vars/k3s.yml`) |
| control plane | polaris `10.0.0.200` 1대. taint `node-role.kubernetes.io/control-plane=true:NoSchedule` (`k3s_cp_taint`) |
| 워커 | sol, terra, luna |
| 데이터 저장소 | SQLite (k3s 기본값). `/var/lib/rancher/k3s/server/db/state.db`, polaris NVMe(`/var/lib/rancher`) |
| 네트워크 | Pod `10.42.0.0/16`, Service `10.43.0.0/16`. flannel·k3s NetworkPolicy 끄고 Cilium 사용 |
| kubeconfig | `cluster.yml`을 실행한 astra 계정의 `~/.kube/orbit-k3s.yaml` (`0600`). 지금은 `orbit` 계정. 서버 주소 `https://10.0.0.200:6443` |
| 클러스터 CA | `k3s-server-ca@1794207293` (2026-11-09 재설치). astra kubeconfig와 Vault Kubernetes 인증(`auth/kubernetes`의 `kubernetes_ca_cert`)이 사용 |

## 플레이북

이 문서의 명령은 모두 astra의 **`orbit` 계정**으로 `~/orbit-infrastructure/ansible`에서 실행한다 (`kubectl` 포함). Ansible 접속 키(`~/.ssh/orbit_ansible`)와 ansible-vault 파일(`inventory/group_vars/all/vault.yml`)이 이 계정에만 있다. 노드에는 어느 계정에서 실행하든 `orbit`으로 접속한다(`ansible.cfg`). `group_vars/all/vault.yml`을 항상 읽으므로 ad-hoc 명령에도 `--ask-vault-pass`가 필요하다.

astra에는 polaris 등을 거치지 않고 바로 접속한다 (`ssh orbit@astra.orbit-labs.space`). 재부팅할 노드를 거친 세션에서 실행하면 그 노드가 재부팅될 때 `ansible`도 같이 끊긴다.

| 플레이북 | 하는 일 |
| --- | --- |
| `playbooks/cluster.yml` | polaris 사전 확인(NVMe 마운트, 커널 eBPF, cpu cgroup) → k3s 서버 설치 → 워커 설치 → 확인 |

확인 단계(`roles/k3s/tasks/verify.yml`)는 다음을 검사하고 하나라도 어긋나면 멈춘다.

- 데이터 저장소: `state.db`가 있고 `server/db/etcd`가 없음
- 노드 4대 Ready (`k3s_nodes_ready_retries` × 10초 대기. 기본 30회)
- control-plane 라벨(`true`)과 `k3s_cp_taint`는 polaris에만 있음. 워커에는 같은 라벨 키·taint 키가 없음
- Cilium DaemonSet, operator rollout 완료

## 데이터 저장소를 SQLite로 둔 이유와 제약

control plane이 polaris 1대라서 etcd의 다중 서버 기능이 필요 없다. 설계대로 SQLite를 쓴다. k3s 공식 문서 기준 (2026-11-09 확인):

- SQLite는 다른 저장소 설정이 없고 **디스크에 내장 etcd 파일도 없을 때** 쓰인다. etcd 파일이 남아 있으면 `cluster-init` 등 저장소 옵션과 상관없이 etcd로 시작한다. ([datastore](https://docs.k3s.io/datastore), [ha-embedded](https://docs.k3s.io/datastore/ha-embedded))
- 문서에는 SQLite → etcd 전환(`--cluster-init`으로 재시작)만 있고, etcd → SQLite 전환 방법은 없다. 그래서 제자리 전환 대신 k3s를 지우고 다시 설치한다.
- SQLite는 서버를 여러 대 둘 수 없다. control plane을 늘리려면 `--cluster-init`으로 etcd로 전환해야 한다.
- 백업은 `/var/lib/rancher/k3s/server/db/`와 서버 토큰을 함께 복사한다. ([backup-restore](https://docs.k3s.io/datastore/backup-restore))

## 재설치 절차 (#28, 내장 etcd → SQLite)

### 영향 범위

| 구분 | 내용 |
| --- | --- |
| 새로 만들어짐 | 클러스터 CA, join 토큰, astra kubeconfig, 클러스터 안의 모든 리소스 |
| 함께 갱신 | Vault Kubernetes 인증의 k3s CA (6단계) |
| 그대로 | k3s·Cilium 버전, 노드 구성, IP, Pod·Service 대역, polaris taint |
| 클러스터 밖 | orbit-gitops `AGENTS.md`(k3s 클러스터 절), orbit-gitops#45·#46 작업자에게 CA·kubeconfig가 바뀐다고 공유 |
| 중단 | 제거부터 재설치 완료까지 클러스터 전체 사용 불가. 재설치 당시 기본 애드온과 Cilium만 있어 서비스 영향 없었음 |

### 0. 사전 조건

- astra `orbit` 계정의 작업 트리가 #28 브랜치(또는 머지된 develop)여야 한다. `cluster-init: true`가 남은 코드로 `cluster.yml`을 실행하면 다시 etcd로 설치된다.

  ```bash
  grep -n cluster-init roles/k3s/templates/config-server.yaml.j2   # 주석 한 줄만 나와야 함
  ```

- Argo CD(#27)는 이 작업 뒤에 설치한다.
- 6단계에 Vault 관리자 토큰이 필요하다 ([Vault 문서의 관리자 권한](vault.md#관리자-권한)).

### 1. 클러스터 상태 확인

기본 애드온(coredns, local-path-provisioner, metrics-server, traefik, svclb)과 Cilium 외에 리소스가 없어야 한다. 다른 것이 있으면 멈추고 소유자와 백업 여부를 확인한다.

```bash
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"
kubectl get ns
kubectl get all,helmchart,helmchartconfig,pvc -A
kubectl get pv
kubectl get crd --no-headers | awk '{print $1}'
```

통과 기준:

- namespace: `default`, `kube-system`, `kube-public`, `kube-node-lease`, `cilium-secrets`(Cilium 차트가 만듦)
- 리소스: Cilium(agent, envoy, operator, `hubble-peer`), 기본 애드온, `helm-install-*` Job
- PV·PVC 없음
- CRD: `*.cilium.io`, `*.traefik.io`, `*.hub.traefik.io`, `*.gateway.networking.k8s.io`(traefik-crd 차트), `*.k3s.cattle.io`, `*.helm.cattle.io`

kubeconfig가 없는 계정이면 polaris에서 `sudo k3s kubectl ...`로 같은 내용을 본다 (`k3s` 명령은 k3s 노드에만 있다).

### 2. k3s 제거 (워커 → polaris)

워커를 먼저 지운다. polaris를 먼저 지우면 워커 에이전트가 서버를 계속 찾으며 재시도한다. **워커 3대의 제거를 확인(2-2)하기 전에는 polaris 제거(2-3)를 실행하지 않는다.** 단계마다 명령을 따로 실행하고 결과를 본 뒤 넘어간다.

제거 스크립트는 다른 k3s 유닛이 있으면 `Additional k3s services installed, skipping uninstall of k3s`를 출력하고 파일을 지우지 않은 채 성공 코드로 끝날 수 있다. 그래서 아래 명령은 이 메시지가 나오면 실패(rc=1)로 바꾸고, 2-2에서 파일·서비스가 실제로 사라졌는지 따로 확인한다.

먼저 같은 터미널에 두 셸 변수를 만든다. `K3S_UNINSTALL`은 제거 스크립트를 실행하고 생략 메시지를 실패로 바꾼다. `K3S_GONE`은 k3s 파일·systemd 유닛·프로세스가 남았는지 본다. 조회 실패는 rc=2, 잔여는 rc=1이다. 변수는 그 터미널에만 남는다.

```bash
K3S_UNINSTALL='
  out=$("$K3S_SCRIPT" 2>&1); rc=$?
  printf "%s\n" "$out"
  [ "$rc" = 0 ] || exit "$rc"
  printf "%s\n" "$out" | grep -q "skipping uninstall" && { echo "실패: 제거 생략됨"; exit 1; }
  exit 0'
K3S_GONE='
  bad=0
  units=$(find /etc/systemd/system -name "k3s*") || { echo "조회 실패: systemd 유닛"; exit 2; }
  [ -n "$units" ] && { echo "$units"; echo "남음: k3s systemd 유닛"; bad=1; }
  pgrep -l "^k3s" ; prc=$?
  [ "$prc" = 0 ] && { echo "남음: k3s 프로세스"; bad=1; }
  [ "$prc" -gt 1 ] && { echo "조회 실패: pgrep"; exit 2; }
  for f in /usr/local/bin/k3s /usr/local/bin/k3s-killall.sh /usr/local/bin/k3s-uninstall.sh \
           /usr/local/bin/k3s-agent-uninstall.sh /etc/init.d/k3s /etc/init.d/k3s-agent \
           /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet; do
    [ -e "$f" ] && { echo "남음: $f"; bad=1; }
  done
  [ "$bad" = 0 ] && echo "제거 확인"
  exit "$bad"'
```

#### 2-1. 워커 제거

```bash
ansible workers -b -K --ask-vault-pass -m shell -a "K3S_SCRIPT=/usr/local/bin/k3s-agent-uninstall.sh; $K3S_UNINSTALL"
```

- sol, terra, luna 모두 `CHANGED`(rc=0)여야 한다.
- 일부가 실패했으면 원인을 해결하고 **실패한 워커만** `--limit <호스트>`로 다시 실행한다. 이미 지운 워커에는 제거 스크립트가 없어서 전체를 다시 실행하면 그 워커에서 실패한다.
- `실패: 제거 생략됨`이 나오면 그 워커에 다른 k3s 유닛(`find /etc/systemd/system -name "k3s*"`)이 있는 것이다. 무엇인지 확인하고 정리한 뒤 다시 실행한다.
- 출력의 `Cannot find device "cni0"`, `flannel.1` 등은 flannel을 쓰지 않아 원래 없는 장치라서 정상이다.

#### 2-2. 워커 제거 확인

```bash
ansible workers -b -K --ask-vault-pass -m shell -a "$K3S_GONE"
ansible workers -b -K --ask-vault-pass -m shell -a 'tailscale debug prefs | grep -A3 AdvertiseRoutes'
```

sol, terra, luna 모두 `CHANGED`(rc=0)와 `제거 확인`이어야 한다. 하나라도 `남음`이나 `조회 실패`가 있으면 2-3으로 넘어가지 않는다. 두 번째 명령은 아래 Tailscale 항목을 확인한다.

#### 2-3. polaris 제거와 확인

```bash
ansible cp -b -K --ask-vault-pass -m shell -a "K3S_SCRIPT=/usr/local/bin/k3s-uninstall.sh; $K3S_UNINSTALL"
ansible cp -b -K --ask-vault-pass -m shell -a "$K3S_GONE"
```

두 명령 모두 rc=0이어야 하고, 두 번째는 `제거 확인`을 출력해야 한다.

- 제거 스크립트는 k3s 서비스, `/etc/rancher/k3s`, `/var/lib/rancher/k3s`(etcd 데이터 포함), `/var/lib/kubelet`, `/var/lib/cni`와 `KUBE-`·`CNI-`·flannel iptables 규칙을 지운다. `/var/lib/rancher`(NVMe 마운트)는 남는다.
- **k3s 노드 4대에도 Tailscale이 있어서** 제거 스크립트가 `tailscale set --advertise-routes=`로 각 노드의 광고 경로를 비운다. 내부망 경로(`10.0.0.0/24`)는 astra만 광고하므로 접속에는 영향이 없다. 노드가 따로 경로를 광고하고 있었다면 제거 전에 기록해 두고 재설치 후 다시 설정한다.

### 3. Cilium 잔여 상태 정리 (재부팅)

k3s 제거 스크립트(`v1.35.9+k3s1` install.sh 기준)는 **Cilium을 정리하지 않는다.** `cilium_host`·`cilium_net`·`cilium_vxlan`·`lxc*` 인터페이스, `/sys/fs/bpf`의 BPF 맵, `CILIUM_*` iptables 체인이 남는다. 노드 4대를 재부팅해서 지운다. k3s 노드는 iptables를 저장하지 않으므로(`netfilter-persistent`는 astra에만 있음) 재부팅하면 남지 않는다.

아래 확인은 조회 성공과 잔여 여부를 나눠 판단한다. 조회 명령이 실패하면 `조회 실패`를 출력하고 rc=2, 무언가 남아 있으면 `남음: ...`을 출력하고 rc=1로 끝난다. 그래서 Ansible 결과에서 해당 노드가 FAILED로 보인다.

```bash
ansible k3s -b -K --ask-vault-pass -m ansible.builtin.reboot
ansible k3s -b -K --ask-vault-pass -m command -a 'uptime -s'   # 4대 모두 방금 재부팅됐는지
ansible k3s -b -K --ask-vault-pass -m shell -a '
  bad=0
  links=$(ip -br link)  || { echo "조회 실패: ip link"; exit 2; }
  v4=$(iptables-save)   || { echo "조회 실패: iptables-save"; exit 2; }
  v6=$(ip6tables-save)  || { echo "조회 실패: ip6tables-save"; exit 2; }
  if mountpoint -q /sys/fs/bpf; then
    bpf=$(find /sys/fs/bpf -iname "*cilium*") || { echo "조회 실패: find /sys/fs/bpf"; exit 2; }
  else
    bpf=""; echo "bpffs 미마운트: 고정된 BPF 맵 없음"
  fi
  echo "$links" | grep -E "cilium|lxc" && { echo "남음: 인터페이스"; bad=1; }
  [ -n "$bpf" ] && { echo "$bpf"; echo "남음: BPF"; bad=1; }
  echo "$v4" | grep -i cilium && { echo "남음: iptables (IPv4)"; bad=1; }
  echo "$v6" | grep -i cilium && { echo "남음: ip6tables (IPv6)"; bad=1; }
  for d in /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /var/lib/cni; do
    [ -e "$d" ] && { echo "남음: $d"; bad=1; }
  done
  [ "$bad" = 0 ] && echo "깨끗함"
  exit "$bad"'
ansible cp -b -K --ask-vault-pass -m command -a 'findmnt -n -o SOURCE /var/lib/rancher'   # polaris NVMe가 그대로 붙어 있는지
```

- 노드 4대 모두 `CHANGED`(rc=0)와 `깨끗함`이어야 한다.
- `남음`이 나오면 그 노드를 한 번 더 재부팅하고 다시 확인한다. 그래도 남으면 원인을 확인할 때까지 4단계로 넘어가지 않는다.
- `조회 실패`는 잔여가 없다는 뜻이 아니다. 명령이 실패한 원인부터 해결한다.
- polaris의 `findmnt`는 NVMe 장치(`/dev/nvme0n1p1`)를 출력해야 한다. 실패하면 4단계 사전 확인에서도 멈춘다.
- **sol은 재부팅 중 멈출 수 있다.** 2026-11-09에는 OS 종료(`journalctl -b -1` 마지막 줄 `Journal stopped`)까지 정상으로 끝난 뒤 다시 켜지지 않았고, 덮개를 열고 전원을 넣자 부팅됐다. 몇 분 지나도 `UNREACHABLE`이면 sol(맨 위 노트북) 상태를 직접 확인한다. 덮개를 닫아도 잠들지 않도록 logind 설정과 `sleep`·`suspend` 마스킹은 되어 있다.

### 4. 재설치

```bash
ansible-playbook playbooks/cluster.yml -K --ask-vault-pass --check --diff   # polaris config.yaml에 cluster-init이 없는지
ansible-playbook playbooks/cluster.yml -K --ask-vault-pass -e k3s_nodes_ready_retries=120
```

- polaris를 설치한 뒤 새 토큰으로 워커를 붙이고, 실행한 계정의 `~/.kube/orbit-k3s.yaml`을 새 CA로 덮어쓴다.
- 처음 설치는 Cilium 이미지를 받느라 노드 Ready가 늦을 수 있어 대기를 20분(120회)으로 늘린다. 이전 설치에서는 `helm-install-cilium`이 31분 걸렸다. 시간 초과로 실패하면 같은 명령을 다시 실행한다. 설치된 부분은 건너뛰고 확인만 다시 한다.
- 마지막 확인 단계가 통과해야 한다 (SQLite, Ready, 라벨·taint, Cilium).

### 5. 수동 확인

```bash
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"
kubectl get nodes -o wide                                   # polaris ROLES는 control-plane (etcd 없음)
kubectl get nodes -L node-role.kubernetes.io/control-plane
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl -n kube-system get pods -o wide
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d | openssl x509 -noout -subject
```

coredns, local-path-provisioner, metrics-server는 control-plane taint를 허용(toleration)해서 polaris에 올라갈 수 있다. 일반 앱 파드는 워커에만 올라간다.

### 6. Vault Kubernetes 인증의 k3s CA 갱신

Vault `auth/kubernetes/config`의 `kubernetes_ca_cert`를 새 CA로 바꾼다. 바꾸기 전에는 ESO 등 앱의 Vault 로그인이 TokenReview 단계에서 실패한다.

원래는 `playbooks/vault.yml`을 관리자 토큰으로 다시 실행하면 된다. 이 플레이북이 polaris의 `/var/lib/rancher/k3s/server/tls/server-ca.crt`를 읽어 넣는다. 다만 지금은 `vault.yml`이 #11 스냅샷 백업 단계(`roles/vault/tasks/snapshot.yml`)에서 멈춘다. Ubuntu 24.04 apt에 `awscli` 패키지가 없다 (`No package matching 'awscli' is available`). 또 관리자 토큰으로 실행하면 아직 운영에 적용하지 않은 #11 설정(스냅샷 정책, AppRole, 백업 타이머)도 함께 들어간다. 그래서 #11 문제가 해결될 때까지는 아래처럼 CA만 직접 갱신한다.

직접 갱신은 플레이북이 쓰는 세 필드를 같은 값으로 쓴다. `disable_local_ca_jwt=true`를 빠뜨리면 기본값 `false`로 돌아가니 그대로 쓴다. kubeconfig의 CA는 polaris `server-ca.crt`와 같은 인증서다.

```bash
set +x
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/opt/vault/tls/vault-ca.crt
read -rs VAULT_TOKEN && export VAULT_TOKEN        # 관리자 토큰 (화면에 안 보임)
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"

vault read -field=kubernetes_ca_cert auth/kubernetes/config | openssl x509 -noout -subject   # 갱신 전 (예전 CA)
CA=$(mktemp)
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CA"
openssl x509 -in "$CA" -noout -subject           # 새 CA인지 확인. 아니면 멈춤
vault write auth/kubernetes/config \
  kubernetes_host=https://10.0.0.200:6443 \
  kubernetes_ca_cert=@"$CA" \
  disable_local_ca_jwt=true
rm -f "$CA"
vault read -field=kubernetes_ca_cert auth/kubernetes/config | openssl x509 -noout -subject   # 새 CA
vault read -field=disable_local_ca_jwt auth/kubernetes/config; echo                          # true
```

그다음 [실제 k3s 로그인·권한 검증](vault.md#실제-k3s-로그인권한-검증)으로 임시 SA 로그인을 확인하고 시험 리소스를 정리한다. 시험 경로는 ESO 읽기 범위 안인 `orbit/k3s/vault-auth-check-...`여야 한다(#21 이후 `vault.md` 기준). `orbit/vault-auth-check-...`처럼 범위 밖 경로를 쓰면 로그인은 성공해도 읽기가 403으로 거부된다.

### 7. 후속

- orbit-gitops `AGENTS.md`의 k3s 클러스터 절에 데이터 저장소(SQLite)와 재설치 사실 반영을 요청한다.
- #11: `snapshot.yml`의 awscli 설치를 Ubuntu 24.04에서 되는 방식(snap `aws-cli` 또는 AWS 공식 설치 파일)으로 바꾼다. 고친 뒤 `vault.yml`을 실행하면 k3s CA는 이미 같아서 바뀌지 않는다.
- sol 재부팅 멈춤의 원인(펌웨어·ACPI 리셋 등)을 확인한다.

### 적용 기록

| 날짜 | 단계 | 대상 | 결과 | 실행 |
| --- | --- | --- | --- | --- |
| 2026-11-09 | 1. 상태 확인 | 클러스터 | 노드 4대 Ready, polaris ROLES `control-plane,etcd`(내장 etcd 확인). namespace 5개(`cilium-secrets` 포함), 기본 애드온·Cilium만, PV·PVC 없음. #13 시험 리소스도 없음 | `jyvnee`(polaris `sudo k3s kubectl`) |
| 2026-11-09 | 2. 제거 | sol, terra, luna → polaris | 워커 3대 `CHANGED rc=0`, 생략 없음 → `제거 확인`. Tailscale `AdvertiseRoutes: null`(astra만 `10.0.0.0/24` 광고). polaris `CHANGED rc=0` → `제거 확인` | `orbit`@astra |
| 2026-11-09 | 3. 재부팅·잔여 | 노드 4대 | polaris 06:26:57, terra·luna 06:26:36, sol 06:48:50(재부팅 멈춤, 직접 전원). 4대 모두 `깨끗함`, polaris `/dev/nvme0n1p1` | `orbit`@astra |
| 2026-11-09 | 4. 재설치 | `cluster.yml` | 미리보기에서 `cluster-init` 없음 확인. 설치 후 확인 단계의 라벨·taint 검사가 Jinja 문법 오류로 실패 → `618e15a`로 수정 후 재실행. 4대 `failed=0`, 재실행 `changed=0` | `orbit`@astra |
| 2026-11-09 | 5. 수동 확인 | 클러스터 | polaris ROLES `control-plane`(etcd 없음), 라벨·taint polaris에만, Cilium agent·envoy 4개와 operator, 기본 애드온 Running. 새 CA `k3s-server-ca@1794207293`, kubeconfig `/home/orbit/.kube/orbit-k3s.yaml` 갱신 | `orbit`@astra |
| 2026-11-09 | 6. Vault CA | `auth/kubernetes/config` | `vault.yml`은 #11 awscli 문제로 중단(변경 없음). CA만 직접 갱신: `k3s-server-ca@1793246016` → `@1794207293`, `kubernetes_host`·`disable_local_ca_jwt=true` 유지 | `orbit`@astra, 관리자 토큰 |
| 2026-11-09 | 6. 로그인 검증 | ESO 역할 `eso` | `external-secrets/external-secrets` 로그인 성공(새 CA로 TokenReview). `orbit/k3s/...` 읽기 성공, 쓰기 403, `orbit/...` 구역 밖 읽기 403. 다른 SA 이름 403(`service account name not authorized`), 다른 namespace 403(`namespace not authorized`) | `orbit`@astra |
| 2026-11-09 | 6. 정리 | Vault, 클러스터 | ESO 토큰 폐기, 시험 경로 2개 `metadata delete`, ClusterRoleBinding·namespace 2개 삭제. 클러스터 namespace 5개로 복귀 | `orbit`@astra |
