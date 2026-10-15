#!/usr/bin/env python3
"""#52: rendered manifests against AppProject scope (offline, no cluster writes)."""
import argparse
from fnmatch import fnmatchcase
from pathlib import Path

import yaml

# Only the Kubernetes kinds used by this repository are supported. Unknown scope fails closed.
CLUSTER = {
    ("", "Namespace"), ("", "PersistentVolume"),
    ("rbac.authorization.k8s.io", "ClusterRole"),
    ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    ("apiregistration.k8s.io", "APIService"),
}
NAMESPACED = {
    ("", k) for k in ("ConfigMap", "Secret", "Service", "ServiceAccount", "Pod", "PersistentVolumeClaim")
} | {
    ("apps", "Deployment"), ("apps", "DaemonSet"), ("apps", "StatefulSet"),
    ("autoscaling", "HorizontalPodAutoscaler"), ("policy", "PodDisruptionBudget"),
    ("rbac.authorization.k8s.io", "Role"), ("rbac.authorization.k8s.io", "RoleBinding"),
    ("argoproj.io", "Application"), ("argoproj.io", "ApplicationSet"), ("argoproj.io", "AppProject"),
}


def matches(rules, group, kind):
    return any(fnmatchcase(group, r["group"]) and fnmatchcase(kind, r["kind"]) for r in rules)


def verify(application, resources, projects):
    """Return scope errors; this does not evaluate Kubernetes RBAC, health or storage access."""
    errors = []
    if application.get("kind") != "Application" or application.get("apiVersion") != "argoproj.io/v1alpha1":
        return ["expected argoproj.io/v1alpha1 Application"]
    app = application["spec"]
    project = next((p["spec"] for p in projects if p.get("kind") == "AppProject"
                    and p["metadata"]["name"] == app.get("project")), None)
    if project is None:
        return ["AppProject missing"]
    # This checker covers the explicit policies used here, not every Argo CD policy dialect.
    rules = [r for field in ("clusterResourceWhitelist", "clusterResourceBlacklist",
             "namespaceResourceWhitelist", "namespaceResourceBlacklist") for r in project.get(field, [])]
    if any("name" in r for r in rules) or any(p.startswith("!") for p in project.get("sourceRepos", [])):
        return ["unsupported named resource or negative repository policy"]
    if project.get("permitOnlyProjectScopedClusters") or any(
        d.get("server", "").startswith("!") or d.get("namespace", "").startswith("!")
        for d in project.get("destinations", [])
    ):
        return ["unsupported scoped cluster or negative destination policy"]
    dest = app["destination"]
    server, namespace = dest.get("server", ""), dest.get("namespace", "")
    # ASTRA uses explicit server and namespace; do not silently interpret named clusters.
    if not server or not namespace:
        return ["explicit destination.server and namespace required"]

    def destination_allowed(ns):
        return any(fnmatchcase(server, d.get("server", "")) and fnmatchcase(ns, d.get("namespace", ""))
                   for d in project.get("destinations", []))

    if not destination_allowed(namespace):
        errors.append("Application destination denied")
    sources = app.get("sources") or [app.get("source", {})]
    for source in sources:
        repo = source.get("repoURL", "")
        if not repo or not any(fnmatchcase(repo, pattern) for pattern in project.get("sourceRepos", [])):
            errors.append("source repository denied: " + repo)
    if not resources:
        errors.append("no rendered resources")
    for resource in resources:
        group = resource["apiVersion"].split("/")[0] if "/" in resource["apiVersion"] else ""
        kind = resource["kind"]
        key = (group, kind)
        label = group + "/" + kind + "/" + resource["metadata"].get("name", "?")
        if key not in CLUSTER | NAMESPACED:
            errors.append("unknown resource scope: " + label)
            continue
        scope = "cluster" if key in CLUSTER else "namespace"
        if scope == "namespace":
            ns = resource["metadata"].get("namespace") or namespace
            if not destination_allowed(ns):
                errors.append("resource destination denied: " + label)
        elif resource["metadata"].get("namespace"):
            errors.append("cluster resource has namespace: " + label)
        whitelist = project.get(scope + "ResourceWhitelist")
        # Cluster resources require explicit allow; namespace resources default to allow.
        if (scope == "cluster" or whitelist is not None) and not matches(whitelist or [], group, kind):
            errors.append("resource kind not allowed: " + label)
        if matches(project.get(scope + "ResourceBlacklist", []), group, kind):
            errors.append("resource kind denied: " + label)
    return errors


def documents(path):
    result = []
    for doc in yaml.safe_load_all(Path(path).read_text()):
        if doc:
            result.extend(doc["items"] if doc.get("kind") == "List" else [doc])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--projects", required=True)
    args = parser.parse_args()
    try:
        apps = documents(args.application)
        if len(apps) != 1:
            raise ValueError("exactly one Application required")
        resources = documents(args.resources)
        errors = verify(apps[0], resources, documents(args.projects))
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as exc:
        parser.exit(2, "invalid verification input: " + str(exc) + "\n")
    for error in errors:
        print("FAIL " + error)
    if errors:
        return 1
    print("PASS " + apps[0]["metadata"]["name"] + ": " + str(len(resources)) + " rendered resources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
