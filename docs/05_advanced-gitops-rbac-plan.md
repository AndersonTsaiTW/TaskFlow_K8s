# Phase 5：進階 GitOps 安全架構（Argo CD RBAC + Service Account）

這個 Phase 是在 Argo CD 基本運作（Phase 3）之後，
把整套 GitOps 流程做到「production 等級安全」的進階章節。

> 🎯 目標：不只是「能跑」，而是「跑得安全、跑得可控」

---

## 為什麼需要這個 Phase？

Phase 3 裝好 Argo CD 之後，預設狀態其實有點危險：

```
Argo CD（預設）
  ↓
cluster-admin 等級權限  ← 🚨 等於 root，什麼都能改
```

在 production 環境，這是不被允許的。你需要的是：

```
Argo CD
  ↓
只能 deploy taskflow namespace 裡的東西  ← ✅ 最小權限
  ↓
不能動 kube-system、不能刪 namespace
```

---

## 完整 GitOps 安全架構圖

```
[Developer]
    ↓ push feature branch
[GitHub]
    ↓ PR → CI 跑 smoke test
[GitHub Actions]
    ↓ merge to main 後觸發
[Argo CD] 👀 監控 Git repo
    ↓ 偵測 charts/taskflow 有變更
[K8s API Server]
    ↓ 用 Service Account 身份送請求
[RBAC 驗證層] 🔐
    ↓ 只允許在 taskflow namespace 操作
[K8s 資源]
    Deployment、Service、ConfigMap...
```

---

## 關鍵概念說明

### Service Account（K8s 裡的「身份證」）

人類用 `kubectl` 連 K8s → 用 **User Account**（IAM / OIDC）
程式連 K8s → 用 **Service Account**

Argo CD 在 K8s 裡跑，所以它的身份是 Service Account：

```yaml
# Argo CD 安裝後自動建立的 SA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-application-controller
  namespace: argocd
```

### RBAC（誰能做什麼）

RBAC = Role-Based Access Control，三個元件：

```
Role / ClusterRole      ← 定義「能做什麼」
RoleBinding             ← 把「誰」綁到「能做什麼」
ServiceAccount          ← 「誰」
```

---

## Phase 5.1：理解 Argo CD 預設權限（先診斷）

安裝 Argo CD 後，查看它目前用什麼身份、有什麼權限：

```bash
# 確認 Argo CD 的 Service Account
kubectl get serviceaccount -n argocd

# 確認目前 ClusterRoleBinding（預設通常是 cluster-admin！）
kubectl get clusterrolebinding | grep argocd
```

輸出如果看到 `cluster-admin`，代表 Argo CD 現在有完整叢集權限，要改掉。

---

## Phase 5.2：建立 Argo CD AppProject（部署範圍控制）

AppProject 是 Argo CD 內建的沙箱機制，限制「這個 Project 能部署什麼、到哪裡」。

建立 `argocd/taskflow-project.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: taskflow
  namespace: argocd
spec:
  description: TaskFlow application project

  # 允許從哪些 Git repo 取得設定
  sourceRepos:
    - https://github.com/<你的帳號>/TaskFlow_K8s

  # 只允許部署到 taskflow namespace
  destinations:
    - namespace: taskflow
      server: https://kubernetes.default.svc

  # 只允許操作這些 K8s 資源類型
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace   # 允許建立 namespace（因為 --create-namespace）

  namespaceResourceWhitelist:
    - group: "apps"
      kind: Deployment
    - group: ""
      kind: Service
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: PersistentVolumeClaim

  # 不允許做的事（黑名單）
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota  # 不允許修改 quota
```

套用：
```bash
kubectl apply -f argocd/taskflow-project.yaml
```

---

## Phase 5.3：為 Argo CD 建立最小權限 RBAC

建立 `argocd/taskflow-rbac.yaml`：

```yaml
# Role：定義在 taskflow namespace 裡能做什麼
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-deploy-role
  namespace: taskflow
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets", "persistentvolumeclaims", "pods"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]

---
# RoleBinding：把 Argo CD 的 SA 綁到這個 Role
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-deploy-binding
  namespace: taskflow
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: argocd
roleRef:
  kind: Role
  apiRef: argocd-deploy-role
  apiGroup: rbac.authorization.k8s.io
```

套用：
```bash
kubectl apply -f argocd/taskflow-rbac.yaml
```

---

## Phase 5.4：更新 Argo CD Application，指定 AppProject

把 `argocd/taskflow-app.yaml` 的 project 改為剛才建的 `taskflow`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: taskflow
  namespace: argocd
spec:
  project: taskflow   # ← 從 default 改成 taskflow project
  source:
    repoURL: https://github.com/<你的帳號>/TaskFlow_K8s
    targetRevision: main
    path: charts/taskflow
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: taskflow
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Phase 5.5：驗證最小權限是否生效

```bash
# 模擬 Argo CD 的 SA，確認能操作 taskflow namespace
kubectl auth can-i create deployment \
  --as=system:serviceaccount:argocd:argocd-application-controller \
  -n taskflow
# 預期：yes ✅

# 確認它不能動 kube-system
kubectl auth can-i create deployment \
  --as=system:serviceaccount:argocd:argocd-application-controller \
  -n kube-system
# 預期：no ✅

# 確認它不能刪 namespace
kubectl auth can-i delete namespace \
  --as=system:serviceaccount:argocd:argocd-application-controller
# 預期：no ✅
```

---

## Phase 5.6：多環境隔離（選做，EKS 階段再考慮）

當你有多個環境（staging / prod）時，可以為每個環境建立獨立 AppProject：

```
ArgoCD Projects:
  taskflow-staging  → 只能部署到 staging namespace
  taskflow-prod     → 只能部署到 production namespace
```

這樣一個環境的部署問題，不會影響另一個環境。

---

## Phase 5.7：Argo CD Image Updater（選做，自動追蹤新 tag）

這個工具可以讓 Argo CD 自動偵測 ECR 上有新 image tag，自動更新 `values.yaml` 並 commit 回 Git：

```
CI push image v1.0.5 到 ECR
        ↓
Argo CD Image Updater 偵測到新 tag
        ↓
自動改 values.yaml: tag: v1.0.5
        ↓
commit 回 Git repo
        ↓
Argo CD 偵測到 Git 變更
        ↓
自動 deploy v1.0.5 ✅
```

安裝：
```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

> ⚠️ 注意：Image Updater 需要 ECR 的 read 權限，要另外設定 IRSA 或 secret。

---

## 里程碑

```
[✅] Phase 3：Argo CD 基本安裝與 Application 設定
[ ] Phase 5.1：診斷現有 Argo CD 預設權限
[ ] Phase 5.2：建立 AppProject，限制部署範圍
[ ] Phase 5.3：建立 RBAC Role + RoleBinding（最小權限）
[ ] Phase 5.4：更新 Application，指定 AppProject
[ ] Phase 5.5：用 kubectl auth can-i 驗證權限邊界
[ ] Phase 5.6：（EKS 後）多環境 AppProject 隔離
[ ] Phase 5.7：（選做）Image Updater 自動追蹤 tag
```

---

## Resume 寫法參考

完成這個 Phase 後，你可以這樣寫：

> "Implemented GitOps deployment pipeline using Argo CD with Kubernetes RBAC-secured Service Accounts. Applied the Principle of Least Privilege by scoping Argo CD's permissions to the application namespace via AppProject and custom ClusterRoles, preventing unauthorized cluster-wide access."

---

## 與其他 Phase 的關係

```
Phase 3：安裝 Argo CD，讓它能 sync（能動）
    ↓
Phase 5：設定 RBAC，讓它只能動該動的（安全）
    ↓
Phase 4：上 EKS 時，同樣的安全設定沿用到雲端
```
