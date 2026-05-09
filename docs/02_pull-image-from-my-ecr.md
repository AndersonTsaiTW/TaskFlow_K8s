# Pull images from ECR

這份文件是「從 ECR 拉 image」的獨立操作手冊。現在 API 直接從你的 ECR 拉，Web 直接從朋友的 ECR 拉，不再把朋友的 image 複製到你的 ECR。

## 基本資訊

- API ECR: `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.1`
- Web ECR: `692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6`

## 1) 本機先驗證可不可以 pull

### PowerShell

```powershell
aws sts get-caller-identity

aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com

docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.1

docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6
```

### Bash

```bash
aws sts get-caller-identity

aws ecr get-login-password --region ca-central-1 \
| docker login --username AWS --password-stdin 485104726319.dkr.ecr.ca-central-1.amazonaws.com

aws ecr get-login-password --region us-east-1 \
| docker login --username AWS --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com

docker pull 485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:v1.0.1
docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6
```

## 2) 需要的最小 IAM 權限

如果 pull 遇到 `AccessDenied`，給目前使用的 IAM user/role 這些權限：

- `ecr:GetAuthorizationToken` on `*`
- `ecr:BatchCheckLayerAvailability` on target repo ARN
- `ecr:GetDownloadUrlForLayer` on target repo ARN
- `ecr:BatchGetImage` on target repo ARN

可參考的最小 policy：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "PullFromPartnerRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:us-east-1:692735150780:repository/taskflow/web"
    }
  ]
}
```

## 3) Kubernetes（EKS）怎麼拉

EKS 通常由 Node Role 或 Fargate Pod Execution Role 去拉 ECR：

1. 對執行身分附加 `AmazonEC2ContainerRegistryReadOnly`（或等效自訂 read-only policy）。
2. 在 Deployment 使用實際來源 ECR image URI。
3. rollout 後檢查 pod event。

Deployment 範例：

```yaml
spec:
  containers:
    - name: web
      image: 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6
      imagePullPolicy: IfNotPresent
```

檢查指令：

```bash
kubectl rollout restart deployment/<your-deployment> -n <your-namespace>
kubectl rollout status deployment/<your-deployment> -n <your-namespace>
kubectl get pods -n <your-namespace>
kubectl describe pod <pod-name> -n <your-namespace>
```

## 4) 非 EKS 叢集（需要 imagePullSecret）

如果你的叢集無法用 AWS runtime IAM，需建立 docker-registry secret：

### PowerShell

```powershell
$token = aws ecr get-login-password --region us-east-1

kubectl create secret docker-registry ecr-pull-secret `
  --docker-server=692735150780.dkr.ecr.us-east-1.amazonaws.com `
  --docker-username=AWS `
  --docker-password=$token `
  -n <your-namespace> `
  --dry-run=client -o yaml | kubectl apply -f -
```

### Bash

```bash
TOKEN=$(aws ecr get-login-password --region us-east-1)

kubectl create secret docker-registry ecr-pull-secret \
  --docker-server=692735150780.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$TOKEN" \
  -n <your-namespace> \
  --dry-run=client -o yaml | kubectl apply -f -
```

再把 `ecr-pull-secret` 掛到 ServiceAccount 或 Pod 的 `imagePullSecrets`。

## 5) 常見錯誤快速對照

- `no basic auth credentials`:
  - 通常是沒先 `docker login` 或 token 過期。
- `requested access to the resource is denied`:
  - IAM 權限不足，或 repo ARN/region 寫錯。
- `manifest unknown`:
  - 該 tag 不存在。
- `ImagePullBackOff`:
  - Kubernetes 執行身分沒 pull 權限，或 image URI/tag 錯誤。

## 6) 建議操作順序

1. 先在本機完成一次 `docker pull`。
2. 再把 Deployment 指向實際來源 ECR image。
3. 觀察 rollout 與 pod event。
4. 最後再做版本滾動（例如 `v1.0.7`, `v1.0.8`）。

## 7) 補充：在本機 (kind) 開發測試直接載入 Image

由於本機的 `kind` 叢集預設沒有連線雲端 ECR 的 IAM 權限，最簡單的做法是在本機 Docker 拉取後，直接手動塞進 kind 裡面。如果你改拉 Partner 的 ECR，只需替換下方帳號與 Region：

```bash
# 1. 用本機 AWS 憑證登入 ECR (以 Partner ECR 為例)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 692735150780.dkr.ecr.us-east-1.amazonaws.com

# 2. 拉取 Image 到你的本機 Docker
docker pull 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6

# 3. 載入到目前的 kind 叢集中 (假設你的 cluster 名稱為 taskflow)
kind load docker-image 692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6 --name taskflow

# 4. 重新套用部署檔 (確認裡面有設定 imagePullPolicy: IfNotPresent)
kubectl apply -f k8s/web-deployment_l.yaml
```
