# Coolify Deployment Workflows

Bộ mẫu CI/CD cho:

- React Create React App (CRA)
- React + Vite
- NestJS
- Next.js Standalone

Luồng triển khai chung:

```text
GitHub push
→ GitHub Actions tạo file .env
→ Docker build
→ Push image lên private registry
→ Gọi Coolify webhook
→ Coolify pull image mới và restart container
```

## 1. Cấu hình GitHub Environments

Tạo hai environment trong repository:

```text
production
develop
```

Workflow tự chọn environment:

```text
master  → production
develop → develop
```

Trong mỗi environment, tạo:

### Variables

```text
REGISTRY=registry.example.com
```

Chỉ nhập hostname, không thêm `https://` và không thêm `/` cuối.

### Secrets

```text
ENV_FILE
REGISTRY_USERNAME
REGISTRY_PASSWORD
COOLIFY_WEBHOOK
COOLIFY_TOKEN
```

`ENV_FILE` chứa nội dung env tương ứng từng môi trường.

## 2. Quy tắc image tag

Production:

```text
registry.example.com/<org>/<repo>:latest
registry.example.com/<org>/<repo>:production-<short-sha>
```

Develop:

```text
registry.example.com/<org>/<repo>:develop
```

## 3. Cấu hình Coolify

Tạo application kiểu Docker Image.

Production dùng tag:

```text
registry.example.com/<org>/<repo>:latest
```

Develop dùng tag:

```text
registry.example.com/<org>/<repo>:develop
```

Đăng nhập private registry trên VPS Coolify:

```bash
docker login registry.example.com
```

Sau đó cấu hình domain, port và health check theo từng loại dự án ở phần bên dưới.

## 4. CRA

Thư mục mẫu: `cra/`

Output build:

```text
build/
```

Port container:

```text
80
```

Ví dụ `ENV_FILE`:

```env
REACT_APP_API_URL=https://api.example.com
REACT_APP_APP_NAME=My App
GENERATE_SOURCEMAP=false
```

Không đưa secret backend vào biến `REACT_APP_*` vì chúng xuất hiện trong bundle trình duyệt.

## 5. Vite React

Thư mục mẫu: `vite/`

Output build:

```text
dist/
```

Port container:

```text
80
```

Ví dụ `ENV_FILE`:

```env
VITE_API_URL=https://api.example.com
VITE_APP_NAME=My App
VITE_ENVIRONMENT=production
```

Không đưa secret backend vào biến `VITE_*`.

## 6. NestJS

Thư mục mẫu: `nestjs/`

Port container mặc định:

```text
3000
```

NestJS thường đọc env ở runtime. Nên đặt các biến sau trực tiếp trong Coolify:

```env
NODE_ENV=production
PORT=3000
DATABASE_URL=...
JWT_SECRET=...
REDIS_URL=...
```

Workflow vẫn hỗ trợ truyền `ENV_FILE` dưới dạng BuildKit secret nếu quá trình build cần env. Nếu build không cần env, có thể bỏ `secret-files`, `build-args` và `RUN --mount=type=secret` trong Dockerfile.

## 7. Next.js Standalone

Thư mục mẫu: `nextjs-standalone/`

Trong `next.config.js` hoặc `next.config.mjs`, bật:

```js
const nextConfig = {
  output: 'standalone',
};

export default nextConfig;
```

Nếu dùng CommonJS:

```js
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
};

module.exports = nextConfig;
```

Port container:

```text
3000
```

Ví dụ `ENV_FILE` dùng lúc build:

```env
NEXT_PUBLIC_API_URL=https://api.example.com
NEXT_PUBLIC_APP_NAME=My App
```

Các biến `NEXT_PUBLIC_*` xuất hiện trong bundle trình duyệt, không được chứa secret.

Các biến server-only như sau nên đặt trong Coolify runtime env:

```env
DATABASE_URL=...
JWT_SECRET=...
NEXTAUTH_SECRET=...
REDIS_URL=...
```

### Lưu ý runtime env Next.js

- `NEXT_PUBLIC_*`: được đóng vào bundle tại build time.
- Biến server-only: nên cấu hình trong Coolify và được đọc khi container chạy.
- Nếu code server đọc env trong quá trình build hoặc static generation, giá trị đó vẫn cần có trong `ENV_FILE` build.

## 8. Dùng workflow

Copy workflow tương ứng vào repository:

```text
.github/workflows/deploy.yml
```

Copy `Dockerfile` và các file đi kèm vào root repository.

Ví dụ với Vite:

```text
Dockerfile
nginx.conf
.github/workflows/deploy.yml
```

## 9. Registry tự host trên VPS

Registry cần bật xóa manifest nếu sau này muốn cleanup:

```yaml
environment:
  REGISTRY_STORAGE_DELETE_ENABLED: "true"
```

Image sẽ được lưu trong volume hoặc thư mục bind mount của registry trên VPS.

## 10. Kiểm tra trước khi deploy

Test đăng nhập registry:

```bash
docker login registry.example.com
```

Test pull image production:

```bash
docker pull registry.example.com/<org>/<repo>:latest
```

Test pull image develop:

```bash
docker pull registry.example.com/<org>/<repo>:develop
```
