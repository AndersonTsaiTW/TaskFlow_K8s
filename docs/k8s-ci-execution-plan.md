# K8s 部署 Repo 執行計畫書

這份計畫書把你的目標拆成可逐步完成的任務：

- 這個 repo 就是純 K8s/部署 repo（可以，方向正確）
- 版本來源改成單一檔案管理（API/Web tag 不再散落在多個檔）
- PR 必須通過：Kind 啟動 + 部署 + 簡單 CRUD 測試
- 測試通過才合併

## 0) 先回答你的兩個問題

### Q1. 「就是這個 repo，可以嗎？」

可以。這個 repo 建議只放：

- Kubernetes manifests 或 Helm/Kustomize
- GitHub Actions CI workflow
- 測試腳本（smoke / CRUD）
- 版本設定檔

不要放：

- 應用程式原始碼
- 機密金鑰（`security/` 已在 `.gitignore`）

### Q2. 「版本來源單一檔案」是什麼？

意思是所有人都只改一個檔案決定部署版本，不要在多個 YAML 手動改 tag。

本 repo 已建立版本檔：

- `config/image-versions.yaml`

內容範例：

```yaml
images:
  api:
    repository: taskflow/api
    tag: v1.0.6
  web:
    repository: taskflow/web
    tag: v1.0.6
```

之後要升版時，只改這個檔案的 tag，PR 進來後 CI 自動用新版本部署測試。

## 1) 目標架構

1. 來源 image 都在你的 ECR：
   - `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:<tag>`
   - `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/web:<tag>`
2. PR workflow 做整合驗證：
   - 讀 `config/image-versions.yaml`
   - 從 ECR pull api/web
   - 建 Kind 叢集
   - 套用 K8s manifests
   - 做 CRUD smoke tests
3. branch protection 要求 CI 必綠燈才可 merge

## 2) 分階段執行（照順序做）

### Phase A: Repo 基礎整理

1. 建立目錄（若不存在）：
   - `.github/workflows/`
   - `k8s/`（manifests）
   - `tests/smoke/`
   - `config/`（版本檔）
2. 保留現有 image sync workflow：
   - `.github/workflows/sync-partner-web-image.yml`
3. 把 Deployment image 改成來自你 ECR。

   實作方式（我們剛剛討論版）：

   - API image：`485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:<tag>`
   - Web image：`485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/web:<tag>`

   目前 repo 範例檔（已可直接用）：

   - `k8s/namespace.yaml`
   - `k8s/postgres.yaml`
   - `k8s/api-deployment.yaml`
   - `k8s/web-deployment.yaml`

   具體要改的欄位是 Deployment 的 `spec.template.spec.containers[].image`。

   套用指令：

   建新叢集
   ```bash
   kind create cluster --name taskflow-ci
   ```

   切 context
   ```bash
   kubectl config use-context kind-taskflow-ci
   ```

   套用資源
   ```bash
   kubectl apply -f k8s/namespace.yaml
   kubectl apply -f k8s/postgres.yaml
   kubectl apply -f k8s/api-deployment.yaml
   kubectl apply -f k8s/web-deployment.yaml
   ```

   驗證指令：

   ```bash
   kubectl -n taskflow get pods
   kubectl -n taskflow describe pod <pod-name>
   ```

   實際測試（本機手動驗證）：

   1. 開 Web（終端 A 持續開著）
   ```bash
   kubectl -n taskflow port-forward svc/taskflow-web 3000:3000
   ```
   然後瀏覽器開 `http://localhost:3000`

   2. 開 API（終端 B 持續開著）
   ```bash
   kubectl -n taskflow port-forward svc/taskflow-api 8000:8000
   ```
   先測 `http://localhost:8000/docs`（應回 200）

   3. 若前端顯示 `Failed to fetch`，優先檢查：
   - API 的 port-forward 是否同時在跑
   - 前端呼叫 URL 是否為 `http://localhost:8000`
   - 兩個 port-forward 是否被中斷（中斷要重開）

   測完刪除
   ```bash
   kind delete cluster --name taskflow-ci
   ```

   若看到 `ImagePullBackOff`，優先檢查：

   - image URI 與 tag 是否存在於 ECR
   - EKS 執行身分（Node Role/Fargate Execution Role）是否有 ECR Read 權限
   - region/account 是否與 ECR 實際位置一致

   Kind 本地測試建議做法（避免私有 ECR 認證問題）：

   由於你的基礎設施現在是直接從你的 ECR 抓 API，從 Partner 的 ECR 抓 Web，所以在本地測試時，必須登入雙方的 ECR 拉取，再手動塞進 Kind 裡面：

   ```bash
   # 1. 登入你自己的 ECR 並拉取 API Image
   aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com
   docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:<tag>
   kind load docker-image 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:<tag> --name taskflow-ci

   # 2. 登入 Partner 的 ECR 並拉取 Web Image
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com
   docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:<tag>
   kind load docker-image 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:<tag> --name taskflow-ci
   ```

   若 API 出現 `CrashLoopBackOff` 且 log 顯示連到 `localhost:5432` 失敗：

   - 代表資料庫未就緒或 API 還指向 localhost
   - 本 repo 本地測試使用 `k8s/postgres.yaml`
   - API 需設定 `DATABASE_URL` 指向 `taskflow-postgres:5432`

    若 `kubectl port-forward svc/taskflow-web 3000:3000` 出現
    `failed to connect to localhost:3000 inside namespace`：

    - 代表 web 容器沒有監聽在 `0.0.0.0`
    - 確認 `k8s/web-deployment.yaml` 有設定：
       - `HOSTNAME=0.0.0.0`
       - `PORT=3000`

完成條件：

- 本機可 `docker pull` 到 api/web 兩個 image。

### Phase B: 版本單一來源接入

1. 以 `config/image-versions.yaml` 當唯一版本來源（這個檔案是唯一可以改 tag 的地方）。

2. 先把 manifests 的 image 改成 placeholder（只做一次）：

    - `k8s/api-deployment.yaml` 的 image 改成 `__API_IMAGE__`
    - `k8s/web-deployment.yaml` 的 image 改成 `__WEB_IMAGE__`

    這樣之後部署時由 CI 注入實際 image URI，不再手動改 manifest。

3. 在 CI 讀取 `config/image-versions.yaml` 並組出完整 image URI。

    參考流程：

    - 安裝 `yq`（YAML 讀值工具）
    - 讀出 `images.api` 的帳號、區域、倉庫與標籤
    - 讀出 `images.web` 的帳號、區域、倉庫與標籤
    - 組成：
       - `API_IMAGE`
       - `WEB_IMAGE`

    GitHub Actions 範例 step：

    ```yaml
    - name: Install yq
       run: |
          sudo curl -sSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 \
            -o /usr/local/bin/yq
          sudo chmod +x /usr/local/bin/yq
          yq --version

    - name: Build image URIs from config file
       id: images
       run: |
          API_ACCT=$(yq -r '.images.api.account' config/image-versions.yaml)
          API_REG=$(yq -r '.images.api.region' config/image-versions.yaml)
          API_REPO=$(yq -r '.images.api.repository' config/image-versions.yaml)
          API_TAG=$(yq -r '.images.api.tag' config/image-versions.yaml)
          
          WEB_ACCT=$(yq -r '.images.web.account' config/image-versions.yaml)
          WEB_REG=$(yq -r '.images.web.region' config/image-versions.yaml)
          WEB_REPO=$(yq -r '.images.web.repository' config/image-versions.yaml)
          WEB_TAG=$(yq -r '.images.web.tag' config/image-versions.yaml)

          API_IMAGE="${API_ACCT}.dkr.ecr.${API_REG}.amazonaws.com/${API_REPO}:${API_TAG}"
          WEB_IMAGE="${WEB_ACCT}.dkr.ecr.${WEB_REG}.amazonaws.com/${WEB_REPO}:${WEB_TAG}"

          echo "api_image=${API_IMAGE}" >> "$GITHUB_OUTPUT"
          echo "web_image=${WEB_IMAGE}" >> "$GITHUB_OUTPUT"
    ```

4. 在 CI 產生暫時部署檔，將 placeholder 置換成實際 URI，再 apply：

    ```yaml
    - name: Render manifests with resolved images
       run: |
          mkdir -p .rendered/k8s
          cp k8s/*.yaml .rendered/k8s/
          sed -i "s|__API_IMAGE__|${{ steps.images.outputs.api_image }}|g" .rendered/k8s/api-deployment.yaml
          sed -i "s|__WEB_IMAGE__|${{ steps.images.outputs.web_image }}|g" .rendered/k8s/web-deployment.yaml

    - name: Apply manifests
       run: |
          kubectl apply -f .rendered/k8s/namespace.yaml
          kubectl apply -f .rendered/k8s/postgres.yaml
          kubectl apply -f .rendered/k8s/api-deployment.yaml
          kubectl apply -f .rendered/k8s/web-deployment.yaml
    ```

5. 之後升版流程只改 `config/image-versions.yaml`：

    - 例：把 `images.api.tag` 從 `v1.0.1` 改 `v1.0.2`
    - 開 PR 後，CI 會自動用新版本 URI 部署測試

完成條件：

- 改 `config/image-versions.yaml` 的 tag，CI 會使用新 tag。

### Phase C: PR CI（Kind + Deploy + CRUD）

新增 workflow（建議檔名）：

- `.github/workflows/pr-kind-integration.yml`

觸發：

- `pull_request`（針對 main）

主要步驟：

1. Checkout
2. OIDC 取得 AWS 暫時憑證（唯讀 ECR 權限角色）
3. Login 你的 ECR
4. Pull `api` 與 `web` image
5. 建立 Kind 叢集
6. 將 image 載入 Kind
7. 套用 manifests
8. 等待 rollout 成功
9. 執行 CRUD smoke tests
10. 失敗時輸出 `kubectl describe` 與 logs

完成條件：

- PR 內任一部署錯誤或 CRUD 失敗都會讓 check 失敗。

### Phase D: 分支保護

1. 在 GitHub 開啟 branch protection（main）。
2. Required status checks 加入：
   - `pr-kind-integration`
3. 關閉直接 push 到 main（視團隊規則）。

完成條件：

- 未通過 CI 的 PR 無法 merge。

## 3) IAM 與權限配置

### CI Role（PR workflow 用，建議唯讀）

最小建議：

- `ecr:GetAuthorizationToken`（`*`）
- `ecr:BatchCheckLayerAvailability`（api/web repo ARN）
- `ecr:GetDownloadUrlForLayer`（api/web repo ARN）
- `ecr:BatchGetImage`（api/web repo ARN）

注意：

- 這個 PR CI role 不需要 ECR push 權限。
- 跟你現有 sync role 分開更安全。

## 4) CRUD 測試最小範圍

先做最小可用測試（smoke level）：

1. GET `/docs` 應回 200（確認 API 可達）
2. POST `/items` 建立資料
3. GET `/items/{id}` 讀取資料
4. PUT `/items/{id}` 更新資料
5. DELETE `/items/{id}` 刪除資料

建議輸出：

- 每一步回應 status code
- 失敗時輸出 body，方便除錯

## 5) 每次升版 SOP

1. 建立 PR
2. 只改 `config/image-versions.yaml` 的 tag（api/web 其中一個或兩個）
3. 等待 `pr-kind-integration` 通過
4. Merge 到 main
5. 由部署流程（或手動）套到目標環境

## 6) 風險與對策

1. ECR 權限不足
   - 對策：先本機 pull 驗證，再跑 CI。
2. tag 不存在
   - 對策：CI 在 pull 階段就 fail fast。
3. Kind 部署成功但服務不可用
   - 對策：加入 CRUD test，而不只看 rollout。
4. 測試不穩定
   - 對策：健康檢查 + retry（有上限）+ 失敗時輸出完整 logs。

## 7) 你接下來直接做的 7 步

1. 確認 `taskflow/api` 與 `taskflow/web` 兩個 repo 都有可用 tag。
2. 確認 PR CI 專用 IAM role（ECR read-only）已建好。
3. 在 manifests 使用變數化 image（或由 CI 置換）。
4. 建 `.github/workflows/pr-kind-integration.yml`。
5. 建 `tests/smoke/` CRUD 測試腳本。
6. 提一個測試 PR（只改 `config/image-versions.yaml`）。
7. 設 main branch protection，將 `pr-kind-integration` 設為必須。

---

如果你要，我下一步會直接幫你把 `pr-kind-integration.yml` 和最小 CRUD 測試腳本一起建好，讓你可以立即開第一個 PR 驗證整條鏈路。
