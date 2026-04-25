# Helm 部署與演進計畫書 (Helm Execution Plan)

基於先前的純 K8s YAML 配置，我們的下一步是將部署方式升級為 Helm。
這份計畫書將原定的進度結合了目前 repository 內實務上的配置 (例如 Web 使用 Port 3000、預設有 PostgreSQL 服務等) 進行了調整，作為我們接下來的執行依據。

## 總體階段性目標

- **Phase 1: Helm（本地 Deploy）：** 將現有 `k8s/` 目錄下的 YAML 資源轉換為 Helm Chart，並確認能於本地成功執行。
- **Phase 2: Helm + CI（自動升版）：** 調整 PR CI 流程，捨棄 `sed` 置換字串的做法，改以 `helm upgrade --install` 與 `--set` 動態注入 Image 版本。
- **Phase 3: GitOps（Argo CD）：** 導入 GitOps 概念，由 Argo CD 監測倉庫狀態來觸發部署。
- **Phase 4: EKS（上雲）：** 正式部署到 AWS EKS，使用 AWS Load Balancer Controller、RDS 取代本地 Postgres 等。

---

## Phase 1：先把 Helm chart 做出來

Helm chart 最基本會有：
- `Chart.yaml`
- `values.yaml`
- `templates/`

### 💡 相較於原定計畫的調整要點：
1. **加入 Postgres 到 Chart 中：** 根據目前的 `k8s/postgres.yaml`，API 極度依賴 K8s 內的資料庫。第一版 Helm Chart 將連同 `taskflow-postgres` 一起包裝進來 (透過 values 切換開關)，讓開發與測試環境能一鍵完全啟動。
2. **Web 服務的 Port：** 原計畫為 80，但目前實作為 3000，在新計畫中將修正為對齊現況的 3000。
3. **API 依賴的環境變數：** `DATABASE_URL` 需要完整定義在 `values.yaml` 的 ConfigMap/Secret 區塊中，或透過模板動態組裝。

### Phase 1.1：定義 chart 目錄結構

你的 `taskflow-deploy` K8s repo 先整理成這樣：

```
charts/
  taskflow/
    Chart.yaml
    values.yaml
    templates/
      deployment-api.yaml
      service-api.yaml
      deployment-web.yaml
      service-web.yaml
      deployment-postgres.yaml
      service-postgres.yaml
      pvc-postgres.yaml
      ingress.yaml
      configmap.yaml
      secret.yaml
```

> **注意**：先把每個資源分開寫清楚，減少過度複雜的 helper template，初版好 debug 最重要。

---

### Phase 1.2：定義 `values.yaml`

控制整個 chart 的核心，依據目前系統現況草擬如下：

```yaml
namespace: taskflow

imagePullSecrets: []

api:
  replicaCount: 1
  image:
    repository: <YOUR_ECR_URI>/taskflow/api
    tag: v1
    pullPolicy: IfNotPresent
  containerPort: 8000
  service:
    port: 8000

web:
  replicaCount: 1
  image:
    repository: <YOUR_ECR_URI>/taskflow/web
    tag: v1
    pullPolicy: IfNotPresent
  containerPort: 3000
  service:
    port: 3000

postgres:
  enabled: true
  image: postgres:16-alpine
  port: 5432
  storage: 1Gi

config:
  dbHost: taskflow-postgres
  dbPort: "5432"
  dbName: taskflow
  dbUser: postgres

secret:
  dbPassword: "postgres"
  jwtSecret: "change-me"

ingress:
  enabled: false
  className: ""
  host: taskflow.local
  path: /
  pathType: Prefix
```

### 🔒 最佳實踐：處理公開 Repo 與真實密碼 (`values-local.yaml`)

如果你的專案將開源或是儲存在公開 Repo 中，請遵守以下黃金法則：

1. **`values.yaml` 還是必須上傳**：但裡面的機密值必須改回假資料（例如 `dbPassword: "change-me"` 或 `<YOUR_AWS_ACCOUNT>`），當作給其他開發者的設定格式範本。
2. **建立本機私房檔案 `values-local.yaml`**：在裡面只寫入你要覆蓋的「真實」變數（如真實 DB 密碼、私有的 ECR 網址）。
3. **把私房檔加入 `.gitignore`**：在 `.gitignore` 加入 `*local.yaml` 防止不小心 commit 洩漏密碼。
4. **疊加部署**：在本機測試時使用指令疊加兩個檔案：
   ```bash
   helm upgrade --install taskflow ./charts/taskflow \
     -f ./charts/taskflow/values.yaml \
     -f ./charts/taskflow/values-local.yaml
   ```
   這樣就能完美做到「向世界公開乾淨設定檔、在本地無縫套用真實機密」的最強防護！

---

### Phase 1.3：實作 Postgres 相關資源

在原本的寫法中，PostgreSQL 是直接固定寫死在 `k8s/postgres.yaml` 裡，只要部署就一定會啟動。
但考量到**未來的彈性**（例如上雲到 EKS 時，會改用 AWS RDS 而不是在 K8s 裡裝 DB），我們在 Helm 中會加上**「模板開關」**。

具體作法是將原有 DB 的資源拆分為三個檔案，並用 `{{- if .Values.postgres.enabled }}` 包圍起來：
- `pvc-postgres.yaml`: 利用 Helm 變數帶入 Storage 大小 (預設 1Gi)。
- `deployment-postgres.yaml`: 利用 Helm 變數帶入 DB 帳號密碼等環境變數。
- `service-postgres.yaml`: 暴露出 5432 port 給後端連線。

**這樣做的最大好處**：
只要在 `values.yaml` 中設定 `postgres.enabled: false`，Helm 就會自動略過這些檔案，不會在叢集內啟動資料庫！而在本地測試或 CI 階段設為 `true`，就能享受快速的一鍵啟動。

---

### Phase 1.4：實作 API Deployment 與 Service

- **Deployment (`deployment-api.yaml`)**：指定 image, port (8000)，並從 ConfigMap/Secret 中注入 `DATABASE_URL` 或透過獨立 env 變數(`DB_HOST`, `DB_PORT`, `DB_PASSWORD` 等)組合連線字串。
- **Service (`service-api.yaml`)**：使用 ClusterIP，Port 8000，名稱統一固定為 `taskflow-api` 以利後續前端或其他連線。

---

### Phase 1.5：實作 Web Deployment 與 Service

- **Deployment (`deployment-web.yaml`)**：指定 container port 為 `3000` (對齊現行 `web-deployment.yaml`)。並注入 `HOSTNAME=0.0.0.0` 與 `PORT=3000`。
- **Service (`service-web.yaml`)**：使用 ClusterIP，Port 3000。

---

### Phase 1.6：加入 ConfigMap 與 Secret 統一管理參數

- **`configmap.yaml`**：放置 `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` 等非機敏變數。
- **`secret.yaml`**：放置 DB 密碼以及未來可能的 JWT 密鑰等，後續 Deployment 可用 `envFrom` 來綁定。

---

### Phase 1.7：可開關的 Ingress 設計

- 將 `ingress.yaml` 預設 `enabled: false`，等未來準備要公開服務或本機上有 nginx ingress controller 再打開。本機現階段繼續使用 `kubectl port-forward`。

---

### Phase 1.8：本地 render 與靜態檢查

撰寫完畢後執行三步測試：
1. **Render chart:** `helm template taskflow ./charts/taskflow -f ./charts/taskflow/values.yaml -f ./charts/taskflow/values-local.yaml`
2. **Lint chart:** `helm lint ./charts/taskflow -f ./charts/taskflow/values.yaml -f ./charts/taskflow/values-local.yaml`
3. **肉眼驗證:** 確認 label、selector、port、DB 連線字串的結果是否與原本寫死的 YAMl 一致。

---

### Phase 1.9：部署安裝與驗證

1. **安裝 Chart:**
   ```bash
   helm install taskflow ./charts/taskflow --create-namespace -n taskflow
   ```
2. **驗證資源狀態:**
   ```bash
   kubectl get all -n taskflow
   ```
3. **功能驗證:**
   - DB 是否啟動且沒有 CrashLoopBackOff。
   - `kubectl port-forward svc/taskflow-api 8000:8000 -n taskflow` (測試看 API 是否回傳 200)。
   - `kubectl port-forward svc/taskflow-web 3000:3000 -n taskflow` (開瀏覽器確認前端能顯示，如果前端需要吃 Backend_URL，再追加對應的 ConfigMap)。

PS. 本地更新
```bash
helm upgrade --install taskflow ./charts/taskflow `
  --create-namespace `
  -n taskflow `
  -f ./charts/taskflow/values.yaml `
  -f ./charts/taskflow/values-local.yaml
```
---

### Phase 1.10：測試 Helm upgrade 流程

這點極為重要！也是未來 CI 的核心。
嘗試使用命令列改變 Web 或 API 的 tag（假裝是 CI 在跑部署腳本），確認資源是否有確實替換。

> 注意：在 Kind 本機環境測試時，新的 image tag 必須已存在於 Kind node 裡，否則 Pod 可能會因為拉不到私有 ECR image 而進入 `ImagePullBackOff`。

以 API 從 `v1.0.1` 升級到 `v1.0.2` 為例：

1. 先確認本機 Docker 能拉到新 image：
```powershell
aws ecr get-login-password --region ca-central-1 |
  docker login --username AWS --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com

docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.2
```

2. 將新 image 載入 Kind cluster：
```powershell
kind load docker-image 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.2 --name taskflow
```

可用這個指令確認 Kind node 裡已經有該 image：
```powershell
docker exec taskflow-control-plane crictl images | Select-String taskflow/api
```

3. 執行 Helm upgrade，只覆蓋 API tag：
```powershell
helm upgrade taskflow ./charts/taskflow `
  -n taskflow `
  -f ./charts/taskflow/values.yaml `
  -f ./charts/taskflow/values-local.yaml `
  --set api.image.tag=v1.0.2
```

Helm 顯示 `STATUS: deployed` 與 `REVISION: 2` 只代表新的資源規格已送進 Kubernetes；接著仍要檢查 rollout。

4. 檢查 rollout 與 Pod 狀態：
```powershell
kubectl rollout status deployment/taskflow-api -n taskflow
kubectl get pods -n taskflow
kubectl get all -n taskflow
```

成功時會看到新的 API Pod 變成 `1/1 Running`，例如：
```text
taskflow-api-779b7984d8-xzvrs       1/1     Running
taskflow-postgres-cd9c4c86c-lxdq8   1/1     Running
taskflow-web-7b6d854959-px5nx       1/1     Running
```

ReplicaSet 會呈現「新版本 1 個 ready、舊版本縮到 0」：
```text
replicaset.apps/taskflow-api-779b7984d8   1   1   1
replicaset.apps/taskflow-api-7fbcd8cbcc   0   0   0
```

這代表 Deployment 已經把舊 API Pod 替換成新 API Pod；Service 不需要改，仍會指向目前健康的 API Pod。

5. 確認 Deployment 目前使用的新 image：
```powershell
kubectl get deployment taskflow-api -n taskflow -o jsonpath="{.spec.template.spec.containers[0].image}"
```

預期輸出：
```text
485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.2
```

6. 查看 Helm revision 歷史：
```powershell
helm history taskflow -n taskflow
```

若升級後要回復，有兩種方式：

方式 A：用 Helm rollback 回到前一個 revision。
```powershell
helm rollback taskflow 1 -n taskflow
kubectl rollout status deployment/taskflow-api -n taskflow
```

方式 B：明確用 Helm upgrade 把 tag 切回舊版。
```powershell
helm upgrade taskflow ./charts/taskflow `
  -n taskflow `
  -f ./charts/taskflow/values.yaml `
  -f ./charts/taskflow/values-local.yaml `
  --set api.image.tag=v1.0.1
```

若確認 K8s 有觸發新的 rollout，則代表 Phase 1 順利完工！之後就可以進入 Phase 2 (將 `sed` 腳本從 CI 移除，全面改用 Helm 啟動與自動測試)。
