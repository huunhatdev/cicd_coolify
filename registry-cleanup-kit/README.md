# Docker Registry Cleanup Kit

Bộ script dùng để dọn Docker Registry self-hosted trên VPS/Coolify.

## Quy tắc cleanup

- Luôn bảo vệ tag `latest`.
- Luôn bảo vệ tag `develop`.
- Chỉ quản lý các tag dạng `production-*`.
- Giữ tối đa `KEEP_PRODUCTION`, mặc định là 3.
- Sau khi xoá manifest, script dừng Registry và chạy garbage collection.
- Hỗ trợ Docker Registry 2 và Registry 3.
- Hỗ trợ Registry container có custom entrypoint.

## 1. Yêu cầu

VPS cần có:

```bash
sudo apt-get update
sudo apt-get install -y curl jq
```

Docker phải đang chạy và user thực thi cần có quyền dùng Docker.

## 2. Bật quyền xoá manifest

Trong config Registry:

```yaml
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
```

Hoặc trong Docker Compose:

```yaml
environment:
  REGISTRY_STORAGE_DELETE_ENABLED: "true"
```

Sau đó restart hoặc redeploy Registry.

## 3. Cài script

```bash
sudo mkdir -p /opt/registry-cleanup
sudo cp cleanup.sh /opt/registry-cleanup/cleanup.sh
sudo chmod +x /opt/registry-cleanup/cleanup.sh
```

## 4. Tạo file cấu hình

```bash
sudo cp registry-cleanup.env.example /etc/registry-cleanup.env
sudo nano /etc/registry-cleanup.env
sudo chmod 600 /etc/registry-cleanup.env
```

Ví dụ Coolify:

```bash
REGISTRY_URL='http://10.0.6.2:5000'
REGISTRY_CONTAINER='registry-skao425ijnocslq45npzhuhw'
REGISTRY_CONFIG='/etc/docker/registry/config.yml'
KEEP_PRODUCTION=3
REGISTRY_USERNAME='username'
REGISTRY_PASSWORD='password'
```

Có thể bỏ `REGISTRY_URL`; script sẽ tự lấy IP nội bộ đầu tiên của container.

## 5. Tìm container và config path

```bash
docker ps --format '{{.Names}}\t{{.Image}}' | grep registry
```

Kiểm tra mount:

```bash
docker inspect <container-name> \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Thông thường config là:

```text
/etc/docker/registry/config.yml
```

## 6. Test kết nối

```bash
sudo bash -c '
  set -a
  source /etc/registry-cleanup.env
  set +a

  curl -i \
    ${REGISTRY_USERNAME:+-u "$REGISTRY_USERNAME:$REGISTRY_PASSWORD"} \
    "$REGISTRY_URL/v2/"
'
```

Kết quả đúng là HTTP `200 OK` và body `{}`.

## 7. Chạy dry-run

Dry-run không xoá manifest, không dừng Registry và không chạy garbage collection.

```bash
sudo DRY_RUN=true /opt/registry-cleanup/cleanup.sh
```

## 8. Chạy thật

```bash
sudo DRY_RUN=false /opt/registry-cleanup/cleanup.sh
```

## 9. Cài cron

```bash
sudo crontab -e
```

Thêm:

```cron
0 3 * * * /opt/registry-cleanup/cleanup.sh >> /var/log/registry-cleanup.log 2>&1
```

Xem log:

```bash
sudo tail -f /var/log/registry-cleanup.log
```

## 10. Kiểm tra garbage collection

Script tự lấy image hiện tại của Registry và tìm binary bằng:

```bash
docker exec <container-name> \
  sh -c 'command -v registry || command -v docker-registry'
```

Với Registry 3 thường là:

```text
/bin/registry
```

## 11. Tag GitHub Actions đề xuất

Production:

```text
latest
production-<short-sha>
```

Develop:

```text
develop
```

Ví dụ:

```yaml
tags: |
  registry.example.com/owner/app:latest
  registry.example.com/owner/app:production-${{ steps.vars.outputs.sha }}
```

Branch develop chỉ push:

```text
registry.example.com/owner/app:develop
```

## 12. Lỗi thường gặp

### HTTP 401

Credential chưa đúng hoặc Registry dùng authentication.

```bash
curl -i -u 'username:password' http://registry-ip:5000/v2/
```

### HTTP 405 khi DELETE

Registry chưa bật:

```yaml
storage:
  delete:
    enabled: true
```

### Garbage collection yêu cầu USERNAME/PASSWORD

Container Registry có custom entrypoint. Script đã xử lý bằng cách ghi đè entrypoint và gọi trực tiếp binary Registry.

### Repository vẫn xuất hiện trong catalog

Sau khi xoá hết manifest, catalog có thể vẫn hiển thị tên repository rỗng. Kiểm tra:

```bash
curl "$REGISTRY_URL/v2/<repository>/tags/list"
```

Nếu `tags` là `null`, repository đã không còn tag.

## 13. Lưu ý an toàn

- Luôn chạy `DRY_RUN=true` trước.
- Không push image trong thời gian garbage collection.
- Nên chạy cron ngoài giờ deploy.
- File `/etc/registry-cleanup.env` phải có quyền `600`.
