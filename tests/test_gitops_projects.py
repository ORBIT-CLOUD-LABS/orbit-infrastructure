"""Issue #52: reject actual deployment scope changes independently of template assertions."""
from copy import deepcopy
import unittest

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

_spec = spec_from_file_location("gitops_projects", Path(__file__).resolve().parents[1] / "scripts/verify_gitops_projects.py")
_module = module_from_spec(_spec)
_spec.loader.exec_module(_module)
verify = _module.verify
from test_argocd_gitops import render


class Issue52RenderedPermissionTest(unittest.TestCase):
    def setUp(self):
        self.projects = render("projects.yml.j2")
        self.app = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "spec": {
            "project": "workloads", "source": {"repoURL": "git@github.com:ORBIT-CLOUD-LABS/orbit-gitops.git"},
            "destination": {"server": "https://kubernetes.default.svc", "namespace": "orbit"}}}
        self.pv = {"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": "origin"}}
        self.pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "origin"}}

    def test_static_volume_and_default_namespace_are_allowed(self):
        self.assertEqual(verify(self.app, [self.pv, self.pvc], self.projects), [])

    def test_explicit_other_namespace_and_secret_are_denied(self):
        bad = deepcopy(self.pvc)
        bad["metadata"]["namespace"] = "argocd"
        self.assertTrue(verify(self.app, [bad], self.projects))
        bad["kind"] = "Secret"
        self.assertTrue(any("not allowed" in e for e in verify(self.app, [bad], self.projects)))

    def test_all_multi_source_repositories_must_be_allowed(self):
        self.app["spec"]["project"] = "platform"
        self.app["spec"]["destination"]["namespace"] = "observability"
        self.app["spec"]["sources"] = [
            {"repoURL": "https://grafana.github.io/helm-charts"}, self.app["spec"].pop("source")]
        ds = {"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "alloy"}}
        self.assertEqual(verify(self.app, [ds], self.projects), [])
        self.app["spec"]["sources"][1]["repoURL"] = "https://example.invalid/other"
        self.assertTrue(any("repository denied" in e for e in verify(self.app, [ds], self.projects)))

    def test_namespace_blacklist_wins_even_if_whitelisted(self):
        for p in self.projects:
            if p["metadata"]["name"] == "workloads":
                p["spec"]["namespaceResourceWhitelist"] = [{"group": "*", "kind": "*"}]
        bad = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "escape"}}
        self.assertTrue(any("kind denied" in e for e in verify(self.app, [bad], self.projects)))

    def test_unknown_scope_and_empty_render_are_not_success(self):
        bad = {"apiVersion": "custom.io/v1", "kind": "Widget", "metadata": {"name": "x"}}
        self.assertTrue(any("unknown resource scope" in e for e in verify(self.app, [bad], self.projects)))
        self.assertTrue(verify(self.app, [], self.projects))

    def test_omitted_namespace_whitelist_differs_from_explicit_empty_list(self):
        for project in self.projects:
            if project["metadata"]["name"] == "workloads":
                project["spec"].pop("namespaceResourceWhitelist")
        self.assertEqual(verify(self.app, [self.pvc], self.projects), [])
        bad = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "escape"}}
        self.assertTrue(verify(self.app, [bad], self.projects))
        for project in self.projects:
            if project["metadata"]["name"] == "workloads":
                project["spec"]["namespaceResourceWhitelist"] = []
        self.assertTrue(verify(self.app, [self.pvc], self.projects))

    def test_project_and_cluster_scope_are_not_inferred_from_namespace(self):
        bad = deepcopy(self.pv)
        bad["metadata"]["namespace"] = "orbit"
        self.assertTrue(verify(self.app, [bad], self.projects))
        self.app["spec"]["project"] = "missing"
        self.assertTrue(verify(self.app, [self.pv], self.projects))


if __name__ == "__main__":
    unittest.main()
