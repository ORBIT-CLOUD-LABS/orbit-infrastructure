# k3s 클러스터 4개

구성: [#61](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/61) (재설계). 옛 단일 클러스터(polaris + 워커 3대, SQLite)의 구성과 재설치 기록은 [#3](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/3), [#28](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/28)과 이 문서의 Git 이력에 있다.
이 문서에는 이름과 절차만 기록한다. join 토큰, Cilium CA 키, kubeconfig 내용은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

## 구성

노트북마다 클러스터 하나, 클러스터마다 server VM 3대(내장 etcd). 워커(agent)는 두지 않는다.

| 클러스터 | 그룹 | 노트북 | server | 입구·API VIP | cluster.id | Pod 대역 | Service 대역 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ota-main` | `ota_main` | sol | `ota-main-1`~`3` (`10.10.41.1`~`.3`) | `10.10.41.100` | 1 | `10.41.0.0/16` | `10.141.0.0/16` |
| `ota-sub` | `ota_sub` | mercury | `ota-sub-1`~`3` (`10.10.42.1`~`.3`) | `10.10.42.100` | 2 | `10.42.0.0/16` | `10.142.0.0/16` |
| `cdn-main` | `cdn_main` | vesper | `cdn-main-1`~`3` (`10.10.51.1`~`.3`) | `10.10.51.100` | 3 | `10.51.0.0/16` | `10.151.0.0/16` |
| `cdn-sub` | `cdn_sub` | terra | `cdn-sub-1`~`3` (`10.10.52.1`~`.3`) | `10.10.52.100` | 4 | `10.52.0.0/16` | `10.152.0.0/16` |

| 항목 | 값 |
| --- | --- |
| 버전 | k3s `v1.35.9+k3s1`, Cilium `1.20.4` (`inventory/group_vars/k3s.yml`) |
| 클러스터별 값 | `inventory/group_vars/<클러스터 그룹>.yml` (이름, ID, 대역, VRRP ID) |
| 데이터 저장소 | 내장 etcd. `-1`이 `cluster-init`, `-2`·`-3`이 붙음. 한 대가 멈춰도 두 대로 정족수 유지 |
| taint | 없음. 3대 모두 일반 파드를 받음 |
| 입구·API VIP | keepalived. 3대가 VRRP(unicast)로 `10.10.<구역>.100`을 나눠 가짐. 평소 `-1`, 자기 API 서버(`/readyz`)가 두 번 연속 응답하지 않으면 내려놓음 |
| 클러스터 입구 | k3s 기본 Traefik을 NodePort로: HTTP `30080`, HTTPS `30443`. servicelb(klipper)는 끔. rp-ota·rp-cdn이 VIP의 이 포트로 보냄 |
| 네트워크 | flannel·k3s NetworkPolicy 끄고 Cilium. Cilium은 각 노드의 자기 API 서버(`127.0.0.1:6443`)로 붙음 |
| Cluster Mesh | 4개 클러스터를 Cilium Cluster Mesh로 묶음. clustermesh-apiserver NodePort `32379`, 다른 클러스터는 VIP의 이 포트로 붙음. 4개가 같은 Cilium CA를 씀 |
| Hubble | 클러스터마다 Hubble Relay. Hubble UI는 `ota-main`에만 두고 NodePort `31235` (`10.10.41.100:31235`). Cluster Mesh로 4개 클러스터 흐름을 함께 봄. rp-core의 `hubble` 도메인이 이 주소로 |
| kubeconfig | `cluster.yml`을 실행한 astra 계정의 `~/.kube/orbit-<클러스터 이름>.yaml` (`0600`). 서버 주소는 VIP, 클러스터·컨텍스트·사용자 이름은 클러스터 이름 |
| 비밀값 (Vault KV) | join 토큰 `secret/orbit/infra/k3s-<클러스터 이름>` (`token`), Cilium CA `secret/orbit/infra/cilium-ca` (`ca_crt`, `ca_key`). 없으면 처음 실행할 때 만들어 저장 |
| Vault Kubernetes 인증 | 클러스터마다 `auth/kubernetes-<클러스터 이름>`. Vault가 그 클러스터 VIP의 6443으로 TokenReview ([Vault 문서](vault.md)) |

방화벽(fw)에서 열어야 하는 것 (구역 사이): astra·vault → VIP 6443, rp-ota·rp-cdn → VIP 30080·30443, rp-core → `10.10.41.100:31235`, 클러스터 구역끼리 TCP 32379(clustermesh-apiserver), UDP 8472(VXLAN), TCP 4240(health), TCP 4244(Hubble peer).

## 플레이북

astra 개인 계정으로 `ansible/`에서 실행한다 ([개인 계정 문서의 Ansible 실행](personal-accounts.md#ansible-실행)).

```bash
../scripts/orbit-ssh-cert.sh                       # SSH 인증서와 Vault 토큰 (8시간)
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)    # join 토큰·Cilium CA (secret/orbit/infra)
ansible-playbook playbooks/cluster.yml -K --check --diff   # 미리보기
ansible-playbook playbooks/cluster.yml -K                  # 적용
unset VAULT_TOKEN
```

| 순서 | 대상 | 하는 일 |
| --- | --- | --- |
| 1 | 클러스터마다 `-1` (한 대씩) | Vault에서 join 토큰을 읽고, 없으면 만들어 저장. `ota-main-1`에서 Cilium CA를 읽고, 없으면 만들어 저장 |
| 2 | `-1` 4대 | 커널 확인 → `config.yaml`(`cluster-init`), Cilium·Traefik 설정 → k3s 설치 → keepalived → kubeconfig를 astra로 |
| 3 | `-2` 4대 | `-1`에 붙음 (`server:`) → keepalived |
| 4 | `-3` 4대 | 같은 방식 |
| 5 | `-1` 4대 | 확인: 내장 etcd, 3대 Ready, 3대 모두 control-plane·etcd 라벨, taint 없음, Cilium·Hubble·clustermesh-apiserver rollout, VIP가 한 대에만, astra에서 VIP로 `/readyz` 응답 |
| 6 | `-1` 4대 | Cluster Mesh 확인: `cilium-dbg status`의 `ClusterMesh: 3/3 remote clusters ready` |

- `-2`와 `-3`을 나눈 것은 etcd에 한 클러스터당 한 번에 한 대씩 붙이려는 것이다.
- 한 클러스터만 할 때는 `--limit ota_main`처럼 그룹을 준다. 이때 6단계는 나머지 클러스터가 아직 없으면 시간 초과로 실패한다.
- 처음 설치는 Cilium 이미지를 받느라 노드 Ready가 늦을 수 있다. `-e k3s_nodes_ready_retries=120`으로 대기를 20분으로 늘린다. 시간 초과로 실패하면 같은 명령을 다시 실행한다.
- 설정 파일이 바뀌면 그 노드의 k3s가 재시작된다. 한 클러스터의 3대가 같은 배치에 있지 않도록 위 순서로 돈다.

## 확인

```bash
export KUBECONFIG=~/.kube/orbit-ota-main.yaml
kubectl get nodes -o wide                                   # 3대, ROLES control-plane,etcd
kubectl -n kube-system get pods -o wide
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep ClusterMesh
```

VIP를 가진 노드는 그 클러스터의 server에서 확인한다.

```bash
ip -br addr show dev enp1s0      # 10.10.41.100이 붙어 있는 노드가 지금 주인
sudo journalctl -u keepalived -n 20
```

## 한 대가 멈췄을 때

- `-1`을 멈추면 keepalived가 VIP를 `-2`로 넘긴다. kubeconfig, Vault TokenReview, rp-ota·rp-cdn은 VIP로 접속하므로 그대로 동작한다.
- etcd는 두 대로 정족수를 유지한다. 두 대가 멈추면 그 클러스터의 API가 멈춘다.
- `-1`이 돌아오면 우선순위가 높아 VIP를 다시 가져간다.

## 옛 클러스터 제거

옛 클러스터(polaris + sol, terra, luna 워커)는 재설계에서 버렸다. 물리 호스트의 k3s 제거와 Cilium 잔여 정리는 물리 호스트 네트워크 변경 작업([#56](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/56))에서 했다. polaris는 전원을 끄고 이 구성에서 뺐다.
