# Mini Data Platform — Postgres + Airflow + Superset

Pipeline giả lập ingest dữ liệu mới theo chu kỳ, tự động clean + dedup, và
dashboard tự cập nhật sau mỗi lần chạy.

| Thành phần | Vai trò | URL |
|---|---|---|
| Postgres 16 | Lưu dữ liệu (3 DB: `airflow`, `superset`, `olist`) | `localhost:5433` |
| Airflow 2.10.5 | Orchestrate pipeline, tự schedule | http://localhost:8080 |
| Superset 4.1.1 | Dashboard phân tích | http://localhost:8088 |

Tài khoản mặc định của cả Airflow và Superset: `admin` / `admin` (đổi trong `.env`).

## Yêu cầu trước khi chạy

- Docker Desktop (đã bật WSL Integration nếu dùng Windows)
- RAM cấp cho Docker >= 6 GB
- **Windows/WSL:** repo phải nằm trong filesystem Linux (`~/projects/...`), **không** để ở `/mnt/c/...`

## Quickstart

```bash
cp .env.example .env
# Sửa AIRFLOW_UID trong .env cho khớp:
echo "AIRFLOW_UID=$(id -u)"
# Sinh 2 key rồi dán vào .env:
docker run --rm apache/airflow:2.10.5 python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"
openssl rand -base64 42

make init      # tạo thư mục + set quyền
make build     # build image Airflow
make up        # khởi động
make ps        # đợi tới khi tất cả là healthy
```

Lần đầu Superset mất khoảng 2–4 phút mới lên. Kiên nhẫn, xem `make logs s=superset`.

## macOS Apple Silicon (M1/M2/M3)

Kiểm tra Superset đã có bản arm64 chưa:

```bash
docker manifest inspect apache/superset:4.1.1 | grep -A2 platform
```

- Có `"architecture": "arm64"` → không cần làm gì thêm.
- Chỉ có `amd64` → bật Rosetta (Docker Desktop → Settings → General → *Use Rosetta for x86/amd64 emulation*) rồi:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

Compose tự merge file override, không cần thêm cờ `-f`. File này nằm trong
`.gitignore` nên không ảnh hưởng máy amd64.

## Bảng port — đọc kỹ chỗ này

| Kết nối từ đâu | Host | Port |
|---|---|---|
| Terminal / DBeaver trên máy bạn | `localhost` | `5433` |
| Trong container (Airflow, Superset) | `postgres` | `5432` |

Điền `localhost:5433` vào Superset sẽ **luôn fail**, vì với container Superset
thì `localhost` là chính nó.

## Kết nối Superset → Postgres

Settings → Database Connections → + Database → PostgreSQL:

```
postgresql://superset_ro:<mật khẩu trong .env>@postgres:5432/olist
```

Bật *Expose in SQL Lab*, tắt *Allow DDL/DML*.

## Vận hành DAG

```bash
make seed            # BƯỚC BẮT BUỘC ĐẦU TIÊN — nạp 3 bảng tĩnh, chạy 1 lần
make check-seed      # kiểm tra bảng tĩnh đã có dữ liệu
make dag-list        # kiểm tra DAG đã được nhận
make dag-test        # chạy thử toàn bộ, không cần scheduler
make dag-unpause     # bật schedule (*/15 phút)
make dag-trigger     # trigger 1 run thủ công (dùng khi demo)
make evidence        # thu thập số liệu sau mỗi run
```

Dataset Olist có 7 bảng, chia hai nhóm:

- **Tĩnh** (`products`, `customers`, `sellers`) — không có cột thời gian, seed
  một lần bằng DAG `olist_seed_static`
- **Động** (`orders`, `order_items`, `order_payments`, `order_reviews`) —
  incremental theo `order_purchase_timestamp`, chạy mỗi run

Quên `make seed` thì task `check_seed` sẽ chặn pipeline ngay từ đầu kèm thông báo rõ.

## Reset sạch

```bash
make reset && make up
```

Cần dùng khi sửa `docker/postgres/init/01-create-databases.sh` — init script
**chỉ chạy khi volume rỗng**.

## Troubleshooting

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Cannot connect to the Docker daemon` | Chưa bật WSL Integration | Docker Desktop → Settings → Resources → WSL Integration |
| `exec ...: no such file or directory` với file `.sh` | Line ending CRLF | Đã có `.gitattributes`; nếu vẫn dính: `dos2unix docker/postgres/init/*.sh` |
| Log Airflow trống trong UI | `logs/` thuộc quyền root | `sudo chown -R $(id -u):0 logs` và đặt lại `AIRFLOW_UID` |
| Sửa init script mà DB không đổi | Volume đã có dữ liệu | `make reset` |
| Superset "could not connect to server" | Dùng `localhost:5433` | Đổi thành `postgres:5432` |
| Dashboard không đổi số dù Airflow đã chạy | Ai đó bật lại cache Superset | Kiểm tra `superset/superset_config.py` vẫn là `NullCache`. View là view thường (tính lại real-time), KHÔNG có task refresh — cache là lớp phòng hộ duy nhất |
| DAG vừa bật đã có hàng trăm run | `catchup=True` | Đã đặt `catchup=False`; nếu lỡ: pause DAG rồi xoá run cũ |
| `no unique constraint matching ON CONFLICT` | Bảng mart thiếu UNIQUE `(order_id, order_item_id)` | Việc của Noel: thêm UNIQUE vào `mart.fct_order_items` để `mart_upsert` ON CONFLICT chạy được |
| Máy đơ, Vmmem ăn hết RAM | WSL không giới hạn | Đặt `memory=8GB` trong `C:\Users\<user>\.wslconfig`, rồi `wsl --shutdown` |
| `no space left on device` | Image/volume tích tụ | `docker system prune -af` (cẩn thận, mất dữ liệu volume nếu thêm `--volumes`) |


## Làm việc chung — máy Khải là server

Cả nhóm dùng **một stack duy nhất** chạy trên máy Khải. Noel truy cập qua Tailscale.
Lý do: hai stack riêng sẽ ra hai bộ số liệu khác nhau, lúc ghép evidence rất rối.

### Setup (làm ngay buổi 1)

Trên máy Khải, trong WSL:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # gửi IP này cho Noel
```

PowerShell với quyền Administrator:

```powershell
New-NetFirewallRule -DisplayName "DataPlatform" -Direction Inbound `
  -LocalPort 8080,8088,5433 -Protocol TCP -Action Allow
```

Rồi Settings → System → Power → Screen and sleep → **Never**.

```bash
make tailscale-info      # in ra bảng endpoint để gửi Noel
```

### Endpoint cho Noel

| Việc | Địa chỉ |
|---|---|
| Dựng chart, dashboard, SQL Lab | `http://<tailscale-ip>:8088` |
| Xem DAG run và log | `http://<tailscale-ip>:8080` |
| Query bằng DBeaver | `<tailscale-ip>:5433`, db `olist`, user `olist_user` |

Vì port mở ra ngoài máy, **đổi hết mật khẩu trong `.env`** trước khi bật Tailscale.

### Luật quan trọng nhất

**`make reset` xoá cả ba database** — mất dashboard của Noel và mất lịch sử DagRun
(chính là evidence). Từ buổi 3 trở đi gần như không dùng lệnh này nữa. Muốn làm sạch
dữ liệu nghiệp vụ:

```bash
make truncate-data       # xoá raw/staging/mart, GIỮ dashboard + load_audit
```

`make reset` chỉ cần khi sửa `docker/postgres/init/*.sh`, và phải báo Noel trước.
Lệnh này có bước xác nhận, gõ đúng chuỗi mới chạy.

### Backup dashboard

Noel chạy mỗi cuối buổi rồi commit file zip:

```bash
make dashboard-export
git add superset/dashboard_export.zip && git commit -m "backup: dashboard"
```

Khôi phục:

```bash
make dashboard-import
```

File export không chứa mật khẩu database, lúc import Superset sẽ hỏi lại — đây là
hành vi cố ý.

### Phân chia file trong Git

Chia theo ranh giới này thì gần như không bao giờ merge conflict:

- **Khải:** `docker-compose.yml`, `docker/`, `superset/superset_config.py`, `dags/`, `Makefile`, `scripts/capture_evidence.sh`, `README.md`
- **Noel:** `sql/`, `scripts/generate_batch.py`, `docs/dataset.md`, `superset/dashboard_export.zip`

Noel viết SQL trong SQL Lab, chạy đúng rồi mới lưu thành file `.sql` và push. DAG đọc
file `.sql` từ đĩa mỗi lần chạy nên Khải chỉ cần `git pull`, **không phải restart Airflow**.

### Sự cố kết nối

| Triệu chứng | Cách xử lý |
|---|---|
| Noel không mở được port dù ping được | Chạy lại lệnh `New-NetFirewallRule` với quyền Administrator |
| Ping được nhưng port vẫn không vào | Kiểm tra `.wslconfig` có `networkingMode=mirrored` không — xoá dòng đó rồi `wsl --shutdown` |
| Kết nối chập chờn | Máy Khải vào sleep — đặt Power = Never |
| Superset chậm khi Noel dùng | Máy Khải thiếu RAM — tăng `memory` trong `.wslconfig`, kiểm tra bằng `docker stats` |

## Phân công

Repo này chứa **phần hạ tầng và orchestration (Khải)**.

- **Khải** — `docker-compose.yml`, `docker/`, `superset/superset_config.py`, `dags/`, `Makefile`, `scripts/capture_evidence.sh`, README
- **Noel** — `sql/` (DDL + transform + views), `scripts/generate_batch.py`, `docs/dataset.md`, chart/dashboard trên Superset

Thư mục `sql/` và file `scripts/generate_batch.py` đang trống — Noel tự viết và
tuỳ biến. Những gì DAG trông đợi từ phía Noel được liệt kê đầy đủ trong
[INTERFACE_CHO_NOEL.md](INTERFACE_CHO_NOEL.md): tên file SQL, tên bảng, tên cột,
tham số script, XCom key.

Noel đổi bất kỳ mục nào trong đó thì báo để sửa DAG tương ứng.
