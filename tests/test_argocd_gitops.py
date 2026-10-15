"""Issue #34: bootstrap 권한 및 인증정보 노출 회귀 검증.

실행: python -m unittest discover -s tests -v (ansible-core, PyYAML 필요)
"""

from pathlib import Path
from copy import deepcopy
import unittest

from ansible.parsing.dataloader import DataLoader
from ansible.template import Templar
import yaml

try:
    from ansible.template import trust_as_template
except ImportError:
    # ansible-core 2.21 이전에는 문자열을 별도로 신뢰 표시할 필요가 없다.
    def trust_as_template(value):
        return value


ROOT = Path(__file__).resolve().parents[1]
ROLE = ROOT / "ansible/roles/argocd_gitops"


def render(name, overrides=None):
    variables = yaml.safe_load((ROOT / "ansible/roles/argocd/defaults/main.yml").read_text())
    variables.update(yaml.safe_load((ROLE / "defaults/main.yml").read_text()))
    variables.update(overrides or {})
    loader = DataLoader()
    templar = Templar(loader=loader, variables=variables)
    template = trust_as_template((ROLE / "templates" / name).read_text())
    return list(yaml.safe_load_all(templar.template(template)))


class Issue34GitOpsPolicyTest(unittest.TestCase):
    def test_manifest_read_wait_rejects_errors_missing_children_and_stale_revision(self):
        defaults = yaml.safe_load((ROLE / "defaults/main.yml").read_text())
        tasks = yaml.safe_load((ROLE / "tasks/main.yml").read_text())
        expression = tasks[-1]["until"]
        root = render("root-application.yml.j2")[0]
        status = {
            "sync": {"status": "OutOfSync", "comparedTo": {"source": root["spec"]["source"]}},
            "resources": [{"kind": "Application", "name": "orbit-astra-smoke-test"}],
        }

        def ready(resources):
            variables = {**defaults, "argocd_gitops_root": {"resources": resources}}
            template = trust_as_template("{{ (" + expression + ") }}")
            return Templar(loader=DataLoader(), variables=variables).template(template)

        self.assertTrue(ready([{"status": status}]))
        self.assertFalse(ready([]))
        self.assertFalse(ready([{}]))
        bad = deepcopy(status)
        bad["resources"] = []
        self.assertFalse(ready([{"status": bad}]))
        bad = deepcopy(status)
        bad["conditions"] = [{"type": "ComparisonError", "message": "authentication failed"}]
        self.assertFalse(ready([{"status": bad}]))
        bad = deepcopy(status)
        bad["sync"]["comparedTo"]["source"]["targetRevision"] = "old-branch"
        self.assertFalse(ready([{"status": bad}]))

    def test_root_can_only_manage_child_applications(self):
        projects = {p["metadata"]["name"]: p["spec"] for p in render("projects.yml.j2")}
        root = render("root-application.yml.j2")[0]
        project = projects[root["spec"]["project"]]
        self.assertIn(root["spec"]["destination"], project["destinations"])
        self.assertIn(root["spec"]["source"]["repoURL"], project["sourceRepos"])
        self.assertEqual(project["clusterResourceWhitelist"], [])
        self.assertEqual(project["namespaceResourceWhitelist"], [{"group": "argoproj.io", "kind": "Application"}])
        # Directory의 기본값(false)을 명시하면 Argo CD 정규화 후 drift가 생긴다.
        self.assertNotIn("directory", root["spec"]["source"])
        self.assertFalse(any(root["spec"]["syncPolicy"]["automated"].values()))
        self.assertNotIn("finalizers", root["metadata"])

    def test_business_and_platform_cannot_deploy_into_argocd_or_create_apps(self):
        # 확장된 업무 리소스 허용 목록에서도 관리 CRD 금지는 유지되어야 한다.
        projects = render("projects.yml.j2", {
            "argocd_gitops_workload_namespaces": ["orbit-gitops-test", "orbit"],
            "argocd_gitops_workload_namespace_resources": [{"group": "*", "kind": "*"}],
        })
        for p in projects[1:]:
            with self.subTest(project=p["metadata"]["name"]):
                spec = p["spec"]
                self.assertNotIn("argocd", [d["namespace"] for d in spec["destinations"]])
                self.assertNotIn("*", spec["sourceRepos"])
                self.assertTrue(all(
                    resource["group"] != "*" and resource["kind"] != "*"
                    for resource in spec["clusterResourceWhitelist"]
                ))
                if p["metadata"]["name"] == "workloads":
                    self.assertEqual(spec["clusterResourceWhitelist"], [])
                for kind in ("Application", "ApplicationSet", "AppProject"):
                    self.assertIn({"group": "argoproj.io", "kind": kind}, spec["namespaceResourceBlacklist"])

    def test_issue39_workload_destination_and_resource_scope(self):
        projects = {p["metadata"]["name"]: p["spec"] for p in render("projects.yml.j2")}
        workloads = projects["workloads"]

        self.assertEqual(workloads["sourceRepos"], ["git@github.com:ORBIT-CLOUD-LABS/orbit-gitops.git"])
        self.assertEqual(workloads["destinations"], [
            {"server": "https://kubernetes.default.svc", "namespace": "orbit-gitops-test"},
            {"server": "https://kubernetes.default.svc", "namespace": "orbit"},
        ])
        self.assertEqual(workloads["clusterResourceWhitelist"], [])
        self.assertEqual(workloads["namespaceResourceWhitelist"], [
            {"group": "", "kind": "ConfigMap"},
            {"group": "apps", "kind": "Deployment"},
            {"group": "", "kind": "Service"},
            {"group": "autoscaling", "kind": "HorizontalPodAutoscaler"},
            {"group": "policy", "kind": "PodDisruptionBudget"},
        ])
        self.assertEqual(workloads["namespaceResourceBlacklist"], [
            {"group": "argoproj.io", "kind": "Application"},
            {"group": "argoproj.io", "kind": "ApplicationSet"},
            {"group": "argoproj.io", "kind": "AppProject"},
        ])

    def test_issue40_platform_metrics_server_scope(self):
        # 전체 범위는 이후 애드온(#57)이 확장하므로 metrics-server 전용 항목만 부분 검증한다.
        projects = {p["metadata"]["name"]: p["spec"] for p in render("projects.yml.j2")}
        platform = projects["platform"]

        self.assertIn("https://kubernetes-sigs.github.io/metrics-server/", platform["sourceRepos"])
        self.assertIn(
            {"server": "https://kubernetes.default.svc", "namespace": "kube-system"},
            platform["destinations"],
        )
        self.assertEqual(platform["clusterResourceWhitelist"], [
            {"group": "rbac.authorization.k8s.io", "kind": "ClusterRole"},
            {"group": "rbac.authorization.k8s.io", "kind": "ClusterRoleBinding"},
            {"group": "apiregistration.k8s.io", "kind": "APIService"},
        ])
        for kind in (
            {"group": "", "kind": "ServiceAccount"},
            {"group": "", "kind": "Service"},
            {"group": "apps", "kind": "Deployment"},
            {"group": "rbac.authorization.k8s.io", "kind": "RoleBinding"},
        ):
            self.assertIn(kind, platform["namespaceResourceWhitelist"])
        self.assertEqual(platform["namespaceResourceBlacklist"], [
            {"group": "argoproj.io", "kind": "Application"},
            {"group": "argoproj.io", "kind": "ApplicationSet"},
            {"group": "argoproj.io", "kind": "AppProject"},
        ])
        for name in ("bootstrap", "workloads"):
            self.assertEqual(projects[name]["sourceRepos"], [
                "git@github.com:ORBIT-CLOUD-LABS/orbit-gitops.git",
            ])

    def test_issue57_platform_observability_scope(self):
        # kube-state-metrics·Alloy(orbit-gitops#10)를 위해 platform 범위를 확장한다.
        projects = {p["metadata"]["name"]: p["spec"] for p in render("projects.yml.j2")}
        platform = projects["platform"]

        self.assertEqual(platform["sourceRepos"], [
            "git@github.com:ORBIT-CLOUD-LABS/orbit-gitops.git",
            "https://kubernetes-sigs.github.io/metrics-server/",
            "https://prometheus-community.github.io/helm-charts",
            "https://grafana.github.io/helm-charts",
        ])
        self.assertEqual(platform["destinations"], [
            {"server": "https://kubernetes.default.svc", "namespace": "orbit-platform"},
            {"server": "https://kubernetes.default.svc", "namespace": "kube-system"},
            {"server": "https://kubernetes.default.svc", "namespace": "observability"},
        ])
        # Alloy·kube-state-metrics는 기존 ClusterRole/ClusterRoleBinding 종류를 재사용하므로 변하지 않는다.
        self.assertEqual(platform["clusterResourceWhitelist"], [
            {"group": "rbac.authorization.k8s.io", "kind": "ClusterRole"},
            {"group": "rbac.authorization.k8s.io", "kind": "ClusterRoleBinding"},
            {"group": "apiregistration.k8s.io", "kind": "APIService"},
        ])
        self.assertEqual(platform["namespaceResourceWhitelist"], [
            {"group": "", "kind": "ConfigMap"},
            {"group": "", "kind": "ServiceAccount"},
            {"group": "", "kind": "Service"},
            {"group": "apps", "kind": "Deployment"},
            {"group": "apps", "kind": "DaemonSet"},
            {"group": "rbac.authorization.k8s.io", "kind": "RoleBinding"},
        ])
        tasks = yaml.safe_load((ROLE / "tasks/main.yml").read_text())
        self.assertIn(
            "argocd_gitops_platform_helm_repo_urls == "
            "['https://kubernetes-sigs.github.io/metrics-server/', "
            "'https://prometheus-community.github.io/helm-charts', "
            "'https://grafana.github.io/helm-charts']",
            tasks[0]["ansible.builtin.assert"]["that"],
        )

    def test_secret_is_redacted_and_not_stored_in_apply_annotation(self):
        tasks = yaml.safe_load((ROLE / "tasks/main.yml").read_text())
        secret = next(t for t in tasks if t.get("kubernetes.core.k8s", {}).get("definition", {}).get("kind") == "Secret")
        self.assertTrue(secret["no_log"])
        self.assertFalse(secret["diff"])
        module = secret["kubernetes.core.k8s"]
        self.assertFalse(module.get("apply", False))
        self.assertNotIn("stringData", module["definition"])
        self.assertIn("sshPrivateKey", module["definition"]["data"])
        # Vault 로드도 출력이 숨겨져야 한다.
        play = yaml.safe_load((ROOT / "ansible/argocd.yml").read_text())[0]
        self.assertTrue(play["pre_tasks"][0]["no_log"])


if __name__ == "__main__":
    unittest.main()
