# k3s 클러스터

구성: [#3](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/3).
SQLite 재설치: [#28](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/28). 코드와 절차를 작성했고 **운영 클러스터 재설치와 검증은 아직 하지 않았다.**
이 문서에는 이름과 절차만 기록한다. join 토큰과 kubeconfig 내용은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

## 구성

| 항목 | 값 |
| --- | --- |
| 버전 | k3s `v1.35.9+k3s1`, Cilium `1.20.4` (`inventory/group_vars/k3s.yml`) |
| control plane | polaris `10.0.0.200` 1대. taint `node-role.kubernetes.io/control-plane=true:NoSchedule` (`k3s_cp_taint`) |
| 워커 | sol, terra, luna |
| 데이터 저장소 | SQLite (k3s 기본값). `/var/lib/rancher/k3s/server/db/state.db`, polaris NVMe(`/var/lib/rancher`) |
| 네트워크 | Pod `10.42.0.0/16`, Service `10.43.0.0/16`. flannel·k3s NetworkPolicy 끄고 Cilium 사용 |
| kubeconfig | astra `~/.kube/orbit-k3s.yaml` (`0600`). 서버 주소 `https://10.0.0.200:6443` |
| 클러스터 CA를 쓰는 곳 | astra kubeconfig, Vault Kubernetes 인증(`auth/kubernetes`의 `kubernetes_ca_cert`) |

## 플레이북

이 문서의 명령은 모두 astra의 `ansible/` 폴더에서 실행한다 (`kubectl` 포함).

| 플레이북 | 하는 일 |
| --- | --- |
| `playbooks/cluster.yml` | polaris 사전 확인(NVMe 마운트, 커널 eBPF, cpu cgroup) → k3s 서버 설치 → 워커 설치 → 확인 |

확인 단계(`roles/k3s/tasks/verify.yml`)는 다음을 검사하고 하나라도 어긋나면 멈춘다.

- 데이터 저장소: `state.db`가 있고 `server/db/etcd`가 없음
- 노드 4대 Ready
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
| 함께 갱신 | Vault Kubernetes 인증의 k3s CA (`playbooks/vault.yml` 재실행) |
| 그대로 | k3s·Cilium 버전, 노드 구성, IP, Pod·Service 대역, polaris taint |
| 클러스터 밖 | orbit-gitops `AGENTS.md`(k3s 클러스터 절), orbit-gitops#45·#46 작업자에게 CA·kubeconfig가 바뀐다고 공유 |
| 중단 | 제거부터 재설치 완료까지 클러스터 전체 사용 불가. 현재 기본 애드온과 Cilium만 있어 서비스 영향 없음 |

### 0. 사전 조건

- astra의 작업 트리가 #28 브랜치(또는 머지된 develop)여야 한다. `cluster-init: true`가 남은 코드로 `cluster.yml`을 실행하면 다시 etcd로 설치된다.

  ```bash
  grep -n cluster-init roles/k3s/templates/config-server.yaml.j2   # 주석 한 줄만 나와야 함
  ```

- Argo CD(#27)는 이 작업 뒤에 설치한다.
- `vault.yml`로 Vault 내부 설정을 바꾸려면 관리자 토큰이 필요하다 ([Vault 문서의 관리자 권한](vault.md#관리자-권한)).

### 1. 클러스터 상태 확인

기본 애드온(coredns, local-path-provisioner, metrics-server, traefik, svclb)과 Cilium 외에 리소스가 없어야 한다. 다른 것이 있으면 멈추고 소유자와 백업 여부를 확인한다.

```bash
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"
kubectl get ns
kubectl get all,helmchart,pvc -A
kubectl get pv
```

### 2. k3s 제거 (워커 → polaris)

워커를 먼저 지운다. polaris를 먼저 지우면 워커 에이전트가 서버를 계속 찾으며 재시도한다. **워커 3대의 제거를 확인(2-2)하기 전에는 polaris 제거(2-3)를 실행하지 않는다.** 단계마다 명령을 따로 실행하고 결과를 본 뒤 넘어간다.

제거 스크립트는 다른 k3s 유닛이 있으면 `Additional k3s services installed, skipping uninstall of k3s`를 출력하고 파일을 지우지 않은 채 성공 코드로 끝날 수 있다. 그래서 아래 명령은 이 메시지가 나오면 실패(rc=1)로 바꾸고, 2-2에서 파일·서비스가 실제로 사라졌는지 따로 확인한다.

먼저 같은 터미널에 두 셸 변수를 만든다. `K3S_UNINSTALL`은 제거 스크립트를 실행하고 생략 메시지를 실패로 바꾼다. `K3S_GONE`은 k3s 파일·systemd 유닛·프로세스가 남았는지 본다. 조회 실패는 rc=2, 잔여는 rc=1이다.

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
ansible workers -b -K -m shell -a "K3S_SCRIPT=/usr/local/bin/k3s-agent-uninstall.sh; $K3S_UNINSTALL"
```

- sol, terra, luna 모두 `CHANGED`(rc=0)여야 한다.
- 일부가 실패했으면 원인을 해결하고 **실패한 워커만** `--limit <호스트>`로 다시 실행한다. 이미 지운 워커에는 제거 스크립트가 없어서 전체를 다시 실행하면 그 워커에서 실패한다.
- `실패: 제거 생략됨`이 나오면 그 워커에 다른 k3s 유닛(`find /etc/systemd/system -name "k3s*"`)이 있는 것이다. 무엇인지 확인하고 정리한 뒤 다시 실행한다.

#### 2-2. 워커 제거 확인

```bash
ansible workers -b -K -m shell -a "$K3S_GONE"
```

sol, terra, luna 모두 `CHANGED`(rc=0)와 `제거 확인`이어야 한다. 하나라도 `남음`이나 `조회 실패`가 있으면 2-3으로 넘어가지 않는다.

#### 2-3. polaris 제거와 확인

```bash
ansible cp -b -K -m shell -a "K3S_SCRIPT=/usr/local/bin/k3s-uninstall.sh; $K3S_UNINSTALL"
ansible cp -b -K -m shell -a "$K3S_GONE"
```

두 명령 모두 rc=0이어야 하고, 두 번째는 `제거 확인`을 출력해야 한다.

- 제거 스크립트는 k3s 서비스, `/etc/rancher/k3s`, `/var/lib/rancher/k3s`(etcd 데이터 포함), `/var/lib/kubelet`, `/var/lib/cni`와 `KUBE-`·`CNI-`·flannel iptables 규칙을 지운다.
- 노드에 `tailscale` 명령이 있으면 제거 스크립트가 `tailscale set --advertise-routes=`로 광고 경로를 비운다. 지금은 Tailscale이 astra에만 있고 k3s 노드에는 없다. 노드에 설치했다면 먼저 확인한다.

### 3. Cilium 잔여 상태 정리 (재부팅)

k3s 제거 스크립트(`v1.35.9+k3s1` install.sh 기준)는 **Cilium을 정리하지 않는다.** `cilium_host`·`cilium_net`·`cilium_vxlan`·`lxc*` 인터페이스, `/sys/fs/bpf`의 BPF 맵, `CILIUM_*` iptables 체인이 남는다. 노드 4대를 재부팅해서 지운다. k3s 노드는 iptables를 저장하지 않으므로(`netfilter-persistent`는 astra에만 있음) 재부팅하면 남지 않는다.

아래 확인은 조회 성공과 잔여 여부를 나눠 판단한다. 조회 명령이 실패하면 `조회 실패`를 출력하고 rc=2, 무언가 남아 있으면 `남음: ...`을 출력하고 rc=1로 끝난다. 그래서 Ansible 결과에서 해당 노드가 FAILED로 보인다.

```bash
ansible k3s -b -K -m ansible.builtin.reboot
ansible k3s -b -K -m shell -a '
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
ansible cp -b -K -m command -a 'findmnt -n -o SOURCE /var/lib/rancher'   # polaris NVMe가 그대로 붙어 있는지
```

- 노드 4대 모두 `CHANGED`(rc=0)와 `깨끗함`이어야 한다.
- `남음`이 나오면 그 노드를 한 번 더 재부팅하고 다시 확인한다. 그래도 남으면 원인을 확인할 때까지 4단계로 넘어가지 않는다.
- `조회 실패`는 잔여가 없다는 뜻이 아니다. 명령이 실패한 원인부터 해결한다.
- polaris의 `findmnt`는 NVMe 장치를 출력해야 한다. 실패하면 4단계 사전 확인에서도 멈춘다.

### 4. 재설치

```bash
ansible-playbook playbooks/cluster.yml -K --ask-vault-pass --check --diff   # polaris config.yaml에 cluster-init이 없는지
ansible-playbook playbooks/cluster.yml -K --ask-vault-pass
```

- polaris를 설치한 뒤 새 토큰으로 워커를 붙이고, `~/.kube/orbit-k3s.yaml`을 새 CA로 덮어쓴다.
- 마지막 확인 단계가 통과해야 한다 (SQLite, Ready, 라벨·taint, Cilium).

### 5. 수동 확인

```bash
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"
kubectl get nodes -o wide
kubectl get nodes -L node-role.kubernetes.io/control-plane
kubectl describe node polaris | grep -A2 Taints
kubectl -n kube-system get pods
ansible cp -b -K -m shell -a 'ls -l /var/lib/rancher/k3s/server/db/'   # state.db 있고 etcd 폴더 없음
```

### 6. Vault Kubernetes 인증의 k3s CA 갱신

`vault.yml`이 polaris의 `/var/lib/rancher/k3s/server/tls/server-ca.crt`를 다시 읽어 `auth/kubernetes`에 넣는다. 코드 변경은 필요 없다. [Vault 문서의 KV·Kubernetes 인증 운영 적용과 검증](vault.md#kvkubernetes-인증-운영-적용과-검증) 순서대로 실행한다.

- 미리보기에서 바뀌는 설정이 `kubernetes_ca_cert`뿐인지 확인한다.
- [실제 k3s 로그인·권한 검증](vault.md#실제-k3s-로그인권한-검증)을 다시 해서 임시 SA 로그인 성공과 거부를 확인하고 시험 리소스를 정리한다.

### 7. 후속

- orbit-gitops `AGENTS.md`의 k3s 클러스터 절에 데이터 저장소(SQLite)와 재설치 사실 반영을 요청한다.
- 아래 적용 기록을 채운다.

### 적용 기록

아직 적용하지 않았다.
