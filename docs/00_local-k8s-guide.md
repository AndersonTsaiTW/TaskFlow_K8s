# 本地 Kubernetes (Kind) 測試與基本操作指南

這份指南涵蓋了如何在本地端透過 `kind` 啟動叢集、拉取 ECR 映像檔並載入到 Kind 中，以及常用的 `kubectl` 基本指令。

## 1. 啟動與清理本地測試叢集

每一次的本地測試都可以用乾淨的叢集來跑，避免舊的設定干擾。

### 啟動叢集
```bash
kind create cluster --name taskflow-ci
```

### 切換/確認目前連線的叢集 Context
```bash
# 確保 kubectl 是對你的 kind 下指令
kubectl config use-context kind-taskflow-ci
```

### 清理叢集 (測試完畢後釋放資源)
```bash
kind delete cluster --name taskflow-ci
```

---

## 2. 拉取 AWS ECR 映像檔並載入 Kind

因為 Kind 這個虛擬機平常無法讀到你的 AWS ECR 憑證，最穩定且不會出權限錯誤的方法，就是「先 `docker pull` 到本機，再載入給 Kind」。

### 登入 ECR 並拉取 Image
請替換成你的實際 Image Tag：
```bash
# 登入並拉取 API Image
aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com
docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.1

# 登入並拉取 Web Image (如果 frontend 是在不同 account)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com
docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6
```

### 把 Image 載入到 Kind 中
這步很重要，沒做的話會出現 `ImagePullBackOff`：
```bash
kind load docker-image 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.1 --name taskflow-ci
kind load docker-image 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6 --name taskflow-ci
```

---

## 3. 使用 Helm 部署應用程式

現在我們已經有 Helm Chart 了，部署只要一行指令：

```bash
# 安裝或升級 (如果沒有 taskflow namespace 就會自動建)
helm upgrade --install taskflow ./charts/taskflow \
  --namespace taskflow \
  --create-namespace
```

---

## 4. 日常除錯神器：kubectl 核心指令

### 查看所有狀態 (第一步)
部署完成後，第一件事就是看大家有沒有順利活著：
```bash
kubectl get pods -n taskflow
```
*如果看到 `Status: Error` 或 `CrashLoopBackOff`，就要進入下一步調查。*

### 看詳細事件 (為何起不來？)
如果 Image 拉不到、或資源不夠、或是 DNS 找不到，都在這裡看：
```bash
kubectl describe pod -l app=taskflow-api -n taskflow
```

### 看應用程式的 Log (為何程式閃退？)
這是最重要的指令，看後端噴了什麼 Python / Node Error：
```bash
kubectl logs -l app=taskflow-api -n taskflow
```
*💡 進階：如果 Pod 一直無限重啟，你可以加 `--previous` 看「剛剛那個死掉的容器」是為什麼死的：*
```bash
kubectl logs -l app=taskflow-api -n taskflow --previous
```

### Port-Forward (本地打開網頁檢視)
K8s 在虛擬網路裡面，你的本機瀏覽器打不開。需要靠 port-forward 把通道打開。

如果想看建立好的 API 服務：
```bash
# 本地 8000 : 叢集裡 service 的 8000
kubectl port-forward svc/taskflow-api 8000:8000 -n taskflow
```
如果想看建立好的 Web 網站：
```bash
# 本地 3000 : 叢集裡 service 的 3000
kubectl port-forward svc/taskflow-web 3000:3000 -n taskflow
```
*(注意：Port-forward 執行後視窗會卡著，按 `Ctrl+C` 結束)*

---

## 常見問題與處理

**Q: 為什麼部署剛開始時，API Pod 會呈現 `Error` 甚至重啟 1~3 次，但後來就變 `Running`？**

A: 這是 Kubernetes 常見現象。因為 API 啟動很快，但 Postgres 資料庫啟動比較慢（或是 K8s 的內部 DNS 還沒註冊好 `taskflow-postgres` 這個名字）。API 在第一秒嘗試連資料庫，連不到就會死掉 (`Temporary failure in name resolution`)。
K8s 發現它死掉後，會隔幾秒自動幫你重啟 (這就是 Retry)。等到第 2 或第 3 次重啟時，資料庫已經乖乖站好，API 就能順利連線並變為 `Running` 狀態了！(你剛才遇到的就是這個情況！)
