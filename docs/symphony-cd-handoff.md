# Handoff: CD Symphony

Ngày: 2026-10-16.

## Đã thực hiện

- Thêm `.github/workflows/deploy.yml`: mỗi lần `main` cập nhật, chỉ deploy
  khi `make-all` và `burrito-nightly` của cùng SHA đều thành công.
- Dùng artifact `linux_x86_64` từ đúng build run, kiểm tra checksum, bỏ qua
  commit cũ và không restart lặp khi hai sự kiện cùng báo thành công.
- Thêm `scripts/deploy_symphony.py`: stage release riêng, restart ngay BE,
  FE, Landing, QA; kiểm tra process, JSON state và heartbeat. Nếu lỗi sau khi
  bắt đầu đổi service, tự rollback và báo workflow thất bại.
- Script tự quản lý drop-in `90-cd.conf`; không cần sửa tay các unit trước
  lần deploy đầu tiên. Giữ cấu hình môi trường, origin dashboard và dữ liệu
  runtime hiện có. Không Pause/Resume hoặc thay đổi checkout nghiệp vụ.
- Chạy deploy trong transient systemd service để thao tác còn tiếp tục nếu
  kết nối SSH từ runner bị đứt.
- Đã tạo SSH key riêng cho CD, thêm public key có tùy chọn `restrict` vào
  `authorized_keys` của `dgminhtam`, và thử đăng nhập thành công.
- Đã lưu `DEPLOY_SSH_KEY` và `DEPLOY_KNOWN_HOSTS` vào GitHub repository secrets.
  Host key lấy qua kết nối SSH đã xác minh. Private key tạm trên máy local
  đã xóa; không dùng lại key cá nhân.
- Đã cập nhật tài liệu và quy định deployment trong repo.

Fingerprint public key CD để nhận diện khi cần thu hồi:
`SHA256:APkVxAWSEgPwRIl/ZfLsPyQEnhVaB5fAfL8IsBTfvHw`.

CD được kích hoạt khi workflow được đưa lên `main`. Release `850924f` là
mốc khảo sát trước lần triển khai đầu tiên; xem GitHub Actions và executable
của các service theo bước 2 để xác nhận release đang chạy thực tế.

## Bạn cần làm

### 1. Dùng lại cách cấu hình Tailscale của repo BE

**Đã hoàn tất:** người dùng đã thêm `TS_OAUTH_CLIENT_ID` và `TS_OAUTH_SECRET`.
Run [38860122117](https://github.com/signapse-group/signapse-symphony/actions/runs/38860122117)
ngày 2026-10-16 đã dùng chính secrets của Symphony để kết nối Tailscale,
SSH với host verification và đọc health cả bốn service thành công. Không
còn thao tác Tailscale bắt buộc trước khi đưa CD lên `main`. Hướng dẫn bên
dưới giữ lại để dùng khi cần cấu hình lại.

Đã khảo sát workflow live của `signapse-group/signapse`: BE dùng OAuth client
với `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `tag:ci`, kết nối tới cùng server
`100.113.56.38`, user `dgminhtam`. Run
[38752593517](https://github.com/signapse-group/signapse/actions/runs/38752593517)
ngày 2026-10-15 có bước kết nối Tailscale và deploy thành công.

Workflow Symphony đã đổi sang đúng cách này. Không cần OIDC, `TS_AUDIENCE`
hoặc tag mới. SSH vẫn dùng key riêng đã thiết lập cho Symphony và xác minh
host key; không sao chép phần bỏ qua host verification của BE.

Nếu còn lưu giá trị OAuth client của BE, thêm hai giá trị đó tại
[GitHub Actions secrets của Symphony](https://github.com/signapse-group/signapse-symphony/settings/secrets/actions)
→ **New repository secret**:

| Secret cần thêm | Giá trị |
| --- | --- |
| `TS_OAUTH_CLIENT_ID` | Client ID của OAuth client BE đang dùng |
| `TS_OAUTH_SECRET` | Client secret của cùng OAuth client |

Không cần sửa policy Tailscale nếu tiếp tục dùng client/tag/quyền truy cập
hiện tại của BE. Client phải còn hiệu lực và cho phép dùng `tag:ci`.

GitHub chỉ trả metadata của secret, không trả giá trị đã lưu; không thể
copy trực tiếp repository secret từ BE bằng API/CLI. Nhập từ nơi lưu
credential gốc, không đưa secret vào chat hoặc file repo.

Nếu không còn giữ client secret BE, tạo **OAuth client mới** trong Tailscale
Admin → **Trust credentials** → **Credential** → **OAuth**: cấp quyền
Auth Keys / `auth_keys` write cho `tag:ci`, rồi lưu Client ID/secret mới vào
hai secret Symphony ở trên. Giữ credential BE hiện tại để không ảnh hưởng
pipeline BE. Xem [Tailscale GitHub Action — OAuth client](https://tailscale.com/docs/integrations/github/github-action#using-an-oauth-client).

Đã kiểm tra metadata: cả BE và Symphony hiện không được chia sẻ organization
secret nào. Nếu muốn dùng chung về sau, org owner có thể tạo hai organization
secrets từ giá trị gốc và cấp quyền qua **Selected repositories**. Danh sách
toàn bộ organization secrets yêu cầu quyền quản trị mà CLI hiện chưa có.
Xem [GitHub organization secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#creating-secrets-for-an-organization).

Hai secret SSH đã có; không cần copy `DEV_SSH_PRIVATE_KEY`, DockerHub secrets
hay cấu hình Docker deployment từ BE.

### 2. Đưa thay đổi lên main và kiểm tra lần đầu

Review, commit/push và merge thay đổi theo quy trình repo sau khi xong bước 1.
Lần push `main` chứa workflow mới sẽ chạy CI/build rồi tự deploy. Không cần
duyệt thêm hoặc đăng nhập server để cài script/unit bằng tay.

Trong [GitHub Actions](https://github.com/signapse-group/signapse-symphony/actions),
kiểm tra `make-all`, `burrito-nightly`, rồi lượt `deploy` có bước deploy thực
sự chạy. Một lượt `deploy` kết thúc mà bỏ qua bước deploy là bình thường
khi workflow còn lại chưa xong hoặc commit đã bị thay thế.

Để kiểm tra trên server, kết nối `ssh dgminhtam-server`, rồi chạy:

```bash
systemctl --user show symphony.service symphony-fe.service symphony-landing.service symphony-qa.service -p ActiveState -p ExecStart
journalctl --user -u 'symphony-cd-*' --no-pager -n 80
```

Cả bốn service phải active và dùng cùng đường dẫn
`/opt/apps/symphony/runtime/releases/<full-sha>/symphony` của commit vừa deploy.
Dashboard tiếp tục ở các port 4000–4003 qua Tailscale Serve.

Nếu lỗi do thiếu quyền Tailscale/SSH, sửa quyền rồi re-run workflow `deploy`
của commit `main` hiện tại. Nếu lỗi runtime, đọc log rollback trước khi thử lại.

## Kiểm chứng đã chạy

- Deployment tests bằng Python standard library, được thêm vào CI `make-all`.
  Có các ca checksum sai, CI/build hoàn tất theo hai thứ tự, CI lỗi, commit
  bị thay thế, deploy thành công, lỗi start/health, khôi phục drop-in cũ hoặc
  chưa tồn tại, phát hiện rollback thất bại và tránh restart lặp.
- `actionlint 1.7.12` kiểm tra hai workflow đã thêm/sửa: đạt.
- `make -C elixir all` trong bản source cô lập trên server: đạt; 365 tests,
  0 failures, 6 skipped; coverage và Dialyzer đạt. Lần thử archive CRLF từ
  Windows lỗi format; tạo lại archive LF rồi chạy gate thành công.
- Thử deploy bằng bốn service systemd thật dành riêng cho kiểm thử: deploy
  đạt, sự kiện lặp không đổi PID, bản lỗi HTTP 200 kèm snapshot error bị
  rollback về bản trước. PID production giữ nguyên; unit kiểm thử đã dọn.
- Smoke binary Burrito hiện tại với `sys.config` của server, memory tracker
  và database/workspace riêng: khởi động đạt, runtime-control Paused/online.
- SSH key CD đã đăng nhập thành công; health của cả bốn service production đạt.

Đã kiểm chứng kết nối từ GitHub runner của Symphony qua Tailscale và SSH
bằng run `38860122117`: cả bốn secrets tồn tại, OAuth/tag hoạt động, SSH key
và host key hợp lệ, cả bốn service active và JSON state/heartbeat khỏe.
Nhánh kiểm tra tạm được dọn sau khi chạy; không deploy hoặc restart production.
Kiểm chứng thay binary trên production được thực hiện sau khi push `main`,
theo bước 2; run chỉ kiểm tra kết nối ở trên không thay binary.
Dependencies hiện có phát cảnh báo security advisories khi `mix deps.get`;
không nâng cấp dependency trong thay đổi CD này.

## Khi vận hành

- Mỗi deploy có downtime ngắn và có thể ngắt lượt agent đang chạy, theo lựa
  chọn đã chốt. Không tự Resume nếu runtime đang Paused.
- Chờ health tối đa 120 giây mỗi lần; yêu cầu ba lần liên tiếp với PID ổn định.
- Backup cấu hình trước deploy nằm trong
  `runtime/deployments/<github-run-id>-<attempt>/backup/`; log trong journal
  của `symphony-cd-<github-run-id>-<attempt>.service`.
- Nếu log báo `Rollback failed; manual recovery required`, dùng SSH hiện có
  để kiểm tra service. `before.json` ghi executable cũ; file `<service>.conf`
  trong backup là nội dung `90-cd.conf` trước deploy. Khôi phục chúng; service
  không có file backup thì trước đó chưa có drop-in CD. Sau đó daemon-reload,
  restart và kiểm tra health cả bốn. Không phục hồi SQLite cũ tự động.
- Chưa tự dọn release/install cũ. Giữ lại các release/env/config đang được
  unit hoặc backup tham chiếu; bổ sung cleanup khi dung lượng yêu cầu.
- Rollback binary không đảo ngược thay đổi schema. Release có migration dữ
  liệu không tương thích cần kế hoạch riêng trước khi merge.
