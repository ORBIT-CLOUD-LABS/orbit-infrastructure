"""Read-only check of the desired HelmChart and its latest Helm v3 release.

The caller passes the rendered HelmChart as JSON on stdin, with valuesContent
also parsed as JSON in expectedValues. Only status messages are printed; Helm
release contents can contain credentials and must not appear in command output.
"""

import base64
import gzip
import json
import subprocess
import sys


def kubectl(namespace, *args):
    result = subprocess.run(
        ["/usr/local/bin/k3s", "kubectl", "-n", namespace, *args, "-o", "json"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    return json.loads(result.stdout)


def check(desired):
    namespace = desired["metadata"]["namespace"]
    name = desired["metadata"]["name"]
    expected = desired["spec"]
    chart = kubectl(namespace, "get", "helmchart", name)
    if any(chart["spec"].get(key) != value for key, value in expected.items()):
        return "HelmChart가 아직 원하는 설정으로 반영되지 않음"

    secrets = kubectl(
        expected["targetNamespace"], "get", "secrets", "-l", "owner=helm,name=" + name
    )["items"]
    if not secrets:
        return "Helm release가 아직 없음"

    # 이전 deployed revision만 조회하면 pending/failed upgrade를 놓칠 수 있음.
    latest = max(secrets, key=lambda item: int(item["metadata"]["labels"]["version"]))
    if latest["metadata"]["labels"].get("status") != "deployed":
        return "최신 Helm release가 아직 deployed 상태가 아님"

    # Kubernetes Secret base64 -> Helm base64 -> gzip JSON (Helm v3 storage).
    payload = base64.b64decode(base64.b64decode(latest["data"]["release"]))
    release = json.loads(gzip.decompress(payload))
    if release["info"]["status"] != "deployed":
        return "최신 Helm release의 배포가 아직 완료되지 않음"
    if release["chart"]["metadata"]["version"] != expected["version"]:
        return "최신 Helm release의 chart 버전이 아직 다름"
    if release.get("config", {}) != desired["expectedValues"]:
        return "최신 Helm release의 values가 아직 다름"
    return None


def main():
    try:
        message = check(json.load(sys.stdin))
    except (KeyError, ValueError, OSError, EOFError, subprocess.SubprocessError):
        # 상세 예외나 kubectl 출력에는 release 데이터가 포함될 수 있음.
        message = "Helm 설치 상태를 아직 확인할 수 없음"
    print(message or "원하는 chart 버전과 values로 Helm 배포 완료")
    return 1 if message else 0


if __name__ == "__main__":
    sys.exit(main())
