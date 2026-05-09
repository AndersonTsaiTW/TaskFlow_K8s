# Phase 2–5 執行計畫書：Helm CI / GitOps / EKS / RBAC 安全

基於 Phase 1（Helm 本地 Deploy）已完成，本文件涵蓋接下來四個階段的完整執行計畫。

---

## 總覽

| Phase | 目標 | 關鍵工具 |
|---|---|---|
| **Phase 2** | CI 全面改用 Helm（捨棄 sed 置換） | `helm upgrade --install`, `--set`, GitHub Actions |
| **Phase 3** | GitOps 自動同步 + 視覺化管理介面 | Argo CD |
| **Phase 4** | 上雲至 AWS EKS | EKS, ALB Controller, RDS, Route 53 |
| **Phase 5** | 進階安全：RBAC + Service Account（最小權限） | K8s RBAC, Argo CD AppProject | 

> 📄 Phase 5 詳細計畫：[05_advanced-gitops-rbac-plan.md](05_advanced-gitops-rbac-plan.md)

---

## Phase 2：Helm + CI（自動升版）

### 目標
把現有 GitHub Actions CI 從「`sed` 置換 placeholder → `kubectl apply`」改為「`helm upgrade --install --set image.tag=xxx`」，讓 Helm 成為唯一的部署工具。

### Phase 2.1：清理 CI 舊做法

**目前舊做法（要廢除的）：**
```yaml
# 舊：在 CI 裡用 sed 置換 placeholder
sed -i "s|__API_IMAGE__|$API_IMAGE|g" .rendered/k8s/api-deployment.yaml
kubectl apply -f .rendered/k8s/
```

**新做法（改成這樣）：**
```yaml
# 新：直接用 helm upgrade --install 帶入 image tag
helm upgrade --install taskflow ./charts/taskflow \
  --namespace taskflow \
  --create-namespace \
  --set api.image.tag=$API_TAG \
  --set web.image.tag=$WEB_TAG \
  --wait \
  --timeout 5m
```

**需要修改的 CI 檔案：**
- `.github/workflows/pr-kind-integration.yml`（現有的 PR CI）

---

### Phase 2.2：改寫 PR CI Workflow

新的 workflow 主要步驟：

```yaml
# .github/workflows/pr-kind-integration.yml
name: PR Integration Test (Helm)

on:
  pull_request:
    branches: [main]

jobs:
  integration-test:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # OIDC
      contents: read

    steps:
      - uses: actions/checkout@v4

      # 1. 讀取版本設定檔
      - name: Read image versions
        id: versions
        run: |
          API_TAG=$(yq -r '.images.api.tag' config/image-versions.yaml)
          WEB_TAG=$(yq -r '.images.web.tag' config/image-versions.yaml)
          echo "api_tag=${API_TAG}" >> "$GITHUB_OUTPUT"
          echo "web_tag=${WEB_TAG}" >> "$GITHUB_OUTPUT"

      # 2. 設定 AWS 憑證（OIDC）
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::485104726319:role/github-actions-ecr-pull
          aws-region: ca-central-1

      # 3. 登入雙方 ECR
      - name: Login to API ECR
        run: |
          aws ecr get-login-password --region ca-central-1 \
          | docker login --username AWS \
            --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com

      - name: Login to Partner Web ECR
        run: |
          aws ecr get-login-password --region us-east-1 \
          | docker login --username AWS \
            --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com

      # 4. Pull images
      - name: Pull images
        run: |
          docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:${{ steps.versions.outputs.api_tag }}
          docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:${{ steps.versions.outputs.web_tag }}

      # 5. 建立 Kind cluster
      - name: Create Kind cluster
        uses: helm/kind-action@v1
        with:
          cluster_name: taskflow-ci

      # 6. 載入 images 進 Kind
      - name: Load images into Kind
        run: |
          kind load docker-image \
            485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:${{ steps.versions.outputs.api_tag }} \
            --name taskflow-ci
          kind load docker-image \
            692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:${{ steps.versions.outputs.web_tag }} \
            --name taskflow-ci

      # 7. 用 Helm 部署（核心改變！）
      - name: Deploy with Helm
        run: |
          helm upgrade --install taskflow ./charts/taskflow \
            --namespace taskflow \
            --create-namespace \
            --set api.image.tag=${{ steps.versions.outputs.api_tag }} \
            --set web.image.tag=${{ steps.versions.outputs.web_tag }} \
            --wait \
            --timeout 5m

      # 8. 執行 smoke tests
      - name: Run smoke tests
        run: |
          kubectl port-forward svc/taskflow-api 8000:8000 -n taskflow &
          sleep 5
          hurl --test tests/smoke/crud.hurl

      # 9. 失敗時 dump logs
      - name: Dump logs on failure
        if: failure()
        run: |
          kubectl get all -n taskflow
          kubectl describe pods -n taskflow
          kubectl logs -l app=taskflow-api -n taskflow --tail=50
```

---

### Phase 2.3：升版 SOP（Phase 2 版本）

每次升版只需：

1. 開 PR，只改 `config/image-versions.yaml` 的 tag
2. CI 自動讀取 tag → 拉 image → Helm deploy → smoke test
3. CI 全綠 → Merge to main
4. Main branch 觸發另一個 workflow（或手動）重新 Helm deploy

**完成條件：**
- [ ] PR CI 不再出現 `sed` 指令
- [ ] `helm upgrade --install` 成功且 `--wait` 通過
- [ ] smoke test 全部通過

---

## Phase 3：GitOps（Argo CD）

### 目標
導入 Argo CD，讓它「監測 Git repo 的 Helm chart 狀態 → 自動同步到叢集」，並提供視覺化 Web UI 管理介面。

### Phase 3.1：在本地（Kind）安裝 Argo CD

```bash
# 建立 argocd namespace
kubectl create namespace argocd

# 安裝 Argo CD
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待所有 pod 就緒
kubectl wait --for=condition=available \
  --timeout=300s deployment -l "app.kubernetes.io/name=argocd-server" -n argocd

# 取得初始密碼
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 開啟 Web UI（另開一個 terminal 持續執行）
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

瀏覽器開 `https://localhost:8080`，帳號 `admin`，密碼用上面指令取得的字串登入。

---

### Phase 3.2：建立 Argo CD Application

有兩種方式定義 Argo CD 要監測什麼：

**方式 A：在 Web UI 手動建立（適合先玩一玩）**

在 Argo CD UI 點「New App」，填入：
- Application Name: `taskflow`
- Project: `default`
- Repository URL: `https://github.com/<你的帳號>/TaskFlow_K8s`
- Revision: `main`
- Path: `charts/taskflow`
- Cluster: `https://kubernetes.default.svc`（in-cluster）
- Namespace: `taskflow`
- Helm Values Files: `values.yaml`

**方式 B：用 YAML 宣告式定義（建議！符合 GitOps 精神）**

建立檔案 `argocd/taskflow-app.yaml`：

```yaml
# argocd/taskflow-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: taskflow
  namespace: argocd
spec:
  project: default
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
      prune: true       # 自動刪除 Git 裡不存在的資源
      selfHeal: true    # 有人手動改叢集，自動修正回 Git 狀態
    syncOptions:
      - CreateNamespace=true
```

套用：
```bash
kubectl apply -f argocd/taskflow-app.yaml
```

---

### Phase 3.3：GitOps 升版 SOP（Phase 3 版本）

```
開 PR → 改 charts/taskflow/values.yaml 的 image tag
        ↓
CI 驗證（helm lint + smoke test）
        ↓
Merge to main
        ↓
Argo CD 偵測 Git 變更（每 3 分鐘 poll 一次，或透過 webhook 秒觸發）
        ↓
Argo CD 自動 sync → helm upgrade 到叢集
        ↓
Web UI 顯示 "Synced / Healthy" ✅
```

**設定 GitHub Webhook 讓 Argo CD 即時觸發（選做）：**

在 GitHub repo Settings → Webhooks，Payload URL 填入：
```
https://<你的 argocd server>/api/webhook
```

---

### Phase 3.4：Argo CD Notifications（選做）

設定部署事件通知到 Slack 或 Email：

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-notifications/stable/manifests/install.yaml
```

**完成條件：**
- [ ] 本地 Argo CD Web UI 可登入
- [ ] `taskflow` Application 顯示 `Synced` 且 `Healthy`
- [ ] 改 `values.yaml` merge 到 main 後，Argo CD 自動觸發 sync

---

## Phase 4：EKS（上雲）

### 目標
將 TaskFlow 從本地 Kind 正式部署到 AWS EKS，使用雲端標準服務取代本地替代方案。

### Phase 4.1：關鍵架構差異

| 元件 | Phase 1–3（本地 Kind） | Phase 4（EKS） |
|---|---|---|
| 資料庫 | K8s 內的 Postgres Pod + PVC | AWS RDS PostgreSQL |
| 流量入口 | `kubectl port-forward` | AWS ALB (Load Balancer) |
| TLS/HTTPS | 無 | ACM Certificate |
| DNS | 手動改 `/etc/hosts` | Route 53 |
| Image 拉取 | Kind 手動 load | EKS Node Role（IAM 直接授權） |
| Argo CD | 本地 in-cluster | 安裝在 EKS 上 |

### Phase 4.2：建立 EKS Cluster

```bash
# 使用 eksctl 建立叢集（最簡單）
eksctl create cluster \
  --name taskflow-prod \
  --region ca-central-1 \
  --nodegroup-name standard \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

### Phase 4.3：安裝 AWS Load Balancer Controller

```bash
# 安裝 cert-manager（ALB Controller 依賴）
kubectl apply --validate=false \
  -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# 安裝 ALB Controller（透過 Helm）
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=taskflow-prod \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<ALB_CONTROLLER_ROLE_ARN>
```

### Phase 4.4：調整 Helm values for EKS

建立 `charts/taskflow/values-eks.yaml`（不 commit 機密值）：

```yaml
# values-eks.yaml（EKS 環境覆蓋）

postgres:
  enabled: false   # 改用 AWS RDS，關掉 K8s 內的 Postgres

config:
  dbHost: <RDS_ENDPOINT>   # 例：taskflow.xxxxx.ca-central-1.rds.amazonaws.com
  dbPort: "5432"
  dbName: taskflow
  dbUser: postgres

ingress:
  enabled: true
  className: alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: <ACM_CERT_ARN>
  host: taskflow.yourdomain.com
```

### Phase 4.5：部署到 EKS

```bash
# 切到 EKS context
kubectl config use-context <EKS_CONTEXT>

# Helm 部署
helm upgrade --install taskflow ./charts/taskflow \
  --namespace taskflow \
  --create-namespace \
  -f ./charts/taskflow/values.yaml \
  -f ./charts/taskflow/values-eks.yaml \
  -f ./charts/taskflow/values-local.yaml
```

### Phase 4.6：Argo CD on EKS

在 EKS 上重新安裝 Argo CD，並透過 ALB 暴露 Web UI（HTTPS）：

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 建立 Ingress 給 Argo CD UI（使用 ALB）
# 詳細設定參考 Argo CD 官方 EKS 文件
```

**完成條件：**
- [ ] EKS cluster 建立，節點 Ready
- [ ] AWS ALB Controller 安裝完成
- [ ] RDS 連線正常，API 可寫入資料
- [ ] `https://taskflow.yourdomain.com` 可公開訪問
- [ ] Argo CD 在 EKS 上運行，Web UI 可透過 HTTPS 訪問

---

## 整體里程碑快速對照

```
[✅] Phase 1：Helm 本地 Deploy 完成
[✅] Phase 2：PR CI 改用 helm upgrade --install（sed 已移除）
[ ] Phase 3a：本地安裝 Argo CD + 設定 Application
[ ] Phase 3b：Argo CD 自動 sync 驗證
[ ] Phase 5a：Argo CD AppProject 建立（部署範圍控制）
[ ] Phase 5b：RBAC Role + RoleBinding（最小權限）
[ ] Phase 5c：kubectl auth can-i 驗證
[ ] Phase 4a：EKS cluster 建立
[ ] Phase 4b：RDS + ALB 串接
[ ] Phase 4c：Argo CD on EKS（沿用 Phase 5 RBAC 設定）
```

---

## 下一步行動（立即可做）

1. **建立 branch** `feat/migrate-ci-to-helm`，commit 已完成的 CI 修改
2. 開 PR，讓 CI 跑新的 `helm upgrade --install` 流程驗證
3. CI 通過後 merge → 進入 Phase 3（本地安裝 Argo CD）
4. Phase 3 完成後，**立刻接 Phase 5**（安全設定），再進 Phase 4 上雲
