# 1. Root & Documentation
GET {{baseUrl}}/
HTTP 200

GET {{baseUrl}}/docs
HTTP 200

# 2. Health & Readiness Probes
GET {{baseUrl}}/healthz
HTTP 200

GET {{baseUrl}}/readyz
HTTP 200
