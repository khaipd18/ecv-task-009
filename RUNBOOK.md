# RUNBOOK — Vận hành & Demo (Infra/Orchestration)

> Runbook tự đủ cho phần Infra/Orchestration: cách dựng stack từ đầu, định nghĩa
> từng lệnh `make`, và kịch bản demo "dashboard tự cập nhật". Tách khỏi README
> (README = giới thiệu dự án; file này = vận hành thực tế).

---

## 1. Stack gồm gì

| Service | Container | Vai trò | URL / cổng |
|---|---|---|---|
| Postgres | `dp-postgres` | 3 database: `airflow` (metadata), `superset` (metadata), `olist` (data) | host `localhost:5433` |
| Airflow | `dp-airflow-web` + `dp-airflow-sched` | Orchestrate pipeline theo lịch | http://localhost:8080 |
| Superset | `dp-superset` | Dashboard BI (đọc view real-time) | http://localhost:8088 |

Luồng: `CSV batch → raw → staging (clean/dedup) → mart (dim+fct) → view → dashboard`.
Airflow điều phối; Postgres + SQL của Noel làm việc thật.

**Kết nối (thuộc lòng):**
- Trong container: host `postgres` cổng `5432`.
- Từ máy host: `localhost` cổng `5433`.
- User: `olist_user` (ghi, Airflow dùng) · `superset_ro` (chỉ đọc mart+ops, Superset dùng).

---

## 2. Chạy lần đầu (từ số 0)

Chạy đúng thứ tự này một lần:
```bash
make init          # tạo thư mục logs/data/plugins + set quyền (1 lần)
make build         # build image Airflow/Superset (1 lần, hoặc khi sửa Dockerfile)
make up            # bật 4 container
make ps            # đợi tới khi cả 4 "healthy" (Superset lần đầu 2-4 phút)

make ddl           # tạo bảng từ sql/ddl/ (bằng olist_user)   [SQL của Noel]
make views         # tạo view Superset từ sql/marts/           [SQL của Noel]
make set-vars      # nạp credential Postgres vào Airflow Variable (cho load_raw.sh)
make dag-list      # kiểm tra 2 DAG load được, không import error

make seed          # nạp bảng tĩnh + đơn lịch sử (DAG olist_seed_static, chạy 1 lần)
make check-seed    # xác nhận dim_product/customer/seller đã có dữ liệu
make batches       # xem batch nào đã nạp / còn lại
```
Sau bước này: seed xong, sẵn sàng nạp batch hằng ngày.

> Đồng bộ SQL mới của Noel: `git fetch` → cập nhật `sql/` → `make views` (và `make ddl`
> nếu Noel đổi cấu trúc bảng — **cẩn thận, ddl xoá data**).

---

## 3. Định nghĩa TỪNG lệnh `make` (thực chất chạy gì)

### Vòng đời stack
| Lệnh | Thực chất | Khi nào |
|---|---|---|
| `make init` | `mkdir` logs/plugins/data + `chown $(id -u):0` | 1 lần trước `up` đầu tiên |
| `make build` | `docker compose build` | Khi sửa Dockerfile |
| `make up` | `docker compose up -d` — bật 4 container | Đầu buổi |
| `make down` | `docker compose down` — tắt container, **GIỮ data (volume)** | Cuối buổi |
| `make restart` | `docker compose restart` — restart tất cả | Khi cần khởi động lại |
| `make ps` | `docker compose ps` — trạng thái container | Kiểm tra healthy |
| `make logs s=<svc>` | `docker compose logs -f <svc>` | Debug (vd `s=airflow-scheduler`) |
| `make psql` | vào `psql` DB `olist` bằng `olist_user` | Query tay |

### Chuẩn bị dữ liệu / schema
| Lệnh | Thực chất | Ghi chú |
|---|---|---|
| `make ddl` | chạy `sql/ddl/{01_raw,02_staging,03_mart,04_ops}.sql` bằng `olist_user` | ⚠️ **DROP+CREATE bảng → MẤT data nghiệp vụ**. Chỉ khi rebuild schema |
| `make views` | chạy `sql/marts/*.sql` (`CREATE OR REPLACE VIEW`) | An toàn, chạy lại được. Dùng khi Noel push view mới |
| `make set-vars` | set Airflow Variable `olist_db/user/password` | Cho `load_raw.sh` + psql. Chạy 1 lần sau `up` |
| `make seed` | trigger DAG `olist_seed_static` (nạp bảng tĩnh + đơn lịch sử) | Chạy 1 lần trước khi bật daily |
| `make check-seed` | đếm `dim_product/customer/seller` | Xác nhận seed OK |
| `make batches` | liệt kê batch trên đĩa vs đã nạp (theo `ops.load_audit`) | Kiểm tra trước demo |

### Điều khiển DAG daily (`olist_daily_pipeline`)
| Lệnh | Thực chất | Ghi chú |
|---|---|---|
| `make dag-list` | `airflow dags list` + xem import error | Kiểm tra DAG load OK |
| `make dag-trigger` | `airflow dags trigger` — bắn 1 run (KHÔNG chờ, KHÔNG so sánh) | Nếu DAG paused → run đứng `queued` |
| `make dag-unpause` | bật schedule `*/15` (cứ 15 phút tự nạp 1 batch) | Cho demo "tự chạy". ⚠️ xem cảnh báo dưới |
| `make dag-test` | `airflow dags test` — chạy thử, **không tạo DagRun** trên lịch | Test nhanh |

### Evidence & backup
| Lệnh | Thực chất | Khi nào |
|---|---|---|
| `make evidence` | chạy `scripts/capture_evidence.sh` → lưu `docs/evidence/<time>/` | **Sau mỗi run demo** |
| `make dashboard-export` | export dashboard Superset ra `superset/dashboard_export.zip` | Backup chart Noel (phòng reset) |
| `make dashboard-import` | khôi phục dashboard từ zip | Sau khi reset |

### Dọn data — CẨN THẬN
| Lệnh | Thực chất | An toàn? |
|---|---|---|
| `make truncate-data` | TRUNCATE bảng động + `fct_order_items` + `rejected_rows`, **GIỮ** bảng tĩnh + `load_audit` + dashboard | ✅ tương đối |
| `make reset` | `docker compose down -v` — **XOÁ CẢ 3 DATABASE** | ❌ **CẤM** (mất dashboard Noel + evidence + seed). Có hỏi xác nhận "xoa het" |

---

## 4. Script hỗ trợ (không phải `make`)

| Script | Tác dụng |
|---|---|
| `./scripts/demo_batch.sh --snap` | Chỉ **chụp số** hiện tại (batch đã nạp, fct, revenue, reject). Read-only, không nạp |
| `./scripts/demo_batch.sh` | Chụp TRƯỚC → chạy **đúng 1 run** (`airflow dags test`) nạp batch kế → in **bảng so sánh có delta** |
| `./scripts/capture_evidence.sh` | = `make evidence`. Chụp `load_audit` + row counts + check dup/orphan |

> `demo_batch.sh` dùng `airflow dags test` (chạy 1 DagRun đồng bộ, giữ DAG paused) nên
> **mỗi lần gọi = đúng 1 batch**. KHÔNG dùng `dag-unpause` trong demo tay (xem cảnh báo).

---

## 5. Kịch bản DEMO "dashboard tự cập nhật" (chính)

**Mục tiêu:** mỗi lần chạy 1 batch → dashboard Superset tự đổi số (không sửa tay),
chụp bằng chứng theo từng run. Nền tảng: view real-time + cache Superset đã tắt (NullCache).

**Chuẩn bị:** seed + một số batch đã nạp, để dành vài batch cuối cho demo. DAG **paused**.
```bash
make up && make ps                 # 4 container healthy
make batches                       # xác nhận còn batch để dành
./scripts/demo_batch.sh --snap     # số khởi điểm
```

**Chạy (giữ tay — khuyến nghị, mỗi batch 1 lệnh):**
```bash
#   -> mở Superset, chụp dashboard SỐ CŨ
./scripts/demo_batch.sh            # nạp batch kế → bảng so sánh delta (+1 batch)
make evidence                      # lưu bằng chứng đợt này
#   -> refresh Superset, chụp dashboard SỐ MỚI (số phải nhảy đúng cột SAU)
./scripts/demo_batch.sh            # nạp batch kế tiếp → nhảy tiếp
make evidence
#   -> refresh Superset lần cuối, chụp
make down                          # xong, tắt (giữ data)
```

**Cách khác — để tự chạy theo lịch (hands-off):**
```bash
make dag-unpause     # bật */15; 15 phút sau tự nạp 1 batch, 15 phút nữa batch kế...
```
Nhược điểm: phải đợi tới mốc 15 phút, không có bảng so sánh tự động.

> ⚠️ **CẢNH BÁO — vì sao demo tay KHÔNG `dag-unpause`:** unpause bật lịch `*/15`,
> scheduler sẽ tự đẻ thêm run `scheduled__...` **cộng vào** run tay → một lần bấm ăn
> NHIỀU batch. `demo_batch.sh` tránh điều này bằng `dags test` (giữ paused). Nếu lỡ
> unpause: `docker compose exec airflow-scheduler airflow dags pause olist_daily_pipeline`.

---

## 6. Vận hành hằng ngày

| Tình huống | Làm gì |
|---|---|
| Bắt đầu buổi | `make up` → `make ps` (đợi healthy) |
| Kết thúc buổi | `make down` (data vẫn còn trong volume `pgdata`) |
| Sau khi **máy sleep/lock** | Scheduler hay `unhealthy` giả → `docker compose restart airflow-scheduler` |
| Sau khi **restart máy / tắt Docker** | `make up`; nếu Superset `exited`/container lộn xộn → `make up` lại + `docker compose restart airflow-scheduler airflow-webserver` |
| Superset lâu lên | Bình thường 2–4 phút (init lại) |
| Noel push SQL mới | `git fetch` → cập nhật `sql/` → `make views` (+`make ddl` nếu đổi bảng) |

---

## 7. TUYỆT ĐỐI tránh khi demo

| Lệnh / hành động | Hậu quả |
|---|---|
| `make reset` / `docker compose down -v` | Xoá cả 3 DB: mất dashboard Noel + evidence + seed |
| `make ddl` | DROP+CREATE bảng → mất data nghiệp vụ |
| `make truncate-data` | Xoá data động + fct |
| `make dag-unpause` (trong demo tay) | Scheduler đẻ run thừa → nhảy nhiều batch |
| Bật lại cache Superset | Dashboard đứng số → hỏng đúng điểm demo |

---

## 8. Xử lý sự cố nhanh

| Triệu chứng | Nguyên nhân | Cách sửa |
|---|---|---|
| Trigger nhưng run đứng `queued` | DAG paused | `demo_batch.sh` tự lo; hoặc `airflow dags unpause ...` |
| Scheduler `unhealthy` sau sleep máy | Tiến trình wedged, kết nối DB cũ chết | `docker compose restart airflow-scheduler` |
| Superset `exited (127)` / TimeoutError sau boot cứng | Nghẽn connection Postgres lúc mọi container khởi động cùng lúc | `make up` lại (Postgres đã rảnh sẽ dựng lại được) |
| Log Airflow trống trong UI | `logs/` thuộc root | `chown -R $(id -u):0 logs` + đúng `AIRFLOW_UID` |
| `.sh` báo `no such file or directory` | CRLF | `dos2unix` (đã có `.gitattributes` ép LF) |
| Dashboard không đổi số dù run xanh | cache bật lại, hoặc view tạo bằng `postgres` thay vì `olist_user` | kiểm tra NullCache; chạy lại `make views` |
| `check_seed` đỏ | chưa seed | `make seed` trước |

---

## 9. Evidence (bằng chứng nộp)

`make evidence` lưu tự động vào `docs/evidence/<timestamp>/`:
- `01_docker_ps.txt` — container healthy
- `02_load_audit.txt` — **chính**: mỗi batch nạp lúc nào, rows in/dup/rejected/loaded
- `03_row_counts.txt` — số dòng từng tầng + check dup (0) + check orphan (0)

**Chụp tay bỏ vào cùng thư mục:**
1. Airflow Grid (các run xanh) — http://localhost:8080
2. Dashboard Superset **trước** và **sau** khi nạp (số nhảy) — http://localhost:8088
3. Đồng hồ/timestamp màn hình (chứng minh thời điểm).

Bằng chứng thuyết phục nhất = **ảnh dashboard trước/sau một run** đặt cạnh nhau: số đổi mà
không ai sửa tay → chứng minh auto-update.

---

## 10. Rollback để dựng lại trạng thái demo (kỹ thuật)

Muốn lùi về batch N (dành batch sau cho demo): mọi tầng đều có cột `batch_id`, xoá
`WHERE batch_id IN (...)` trong 1 transaction ở **raw.* + staging.* + mart.fct_order_items
+ mart.fct_orders + ops.rejected_rows + ops.load_audit**. Lưu ý mart chỉ cộng dồn
(`INSERT ON CONFLICT`), **không tự xoá**, nên phải xoá tay ở 2 bảng `mart.fct_*`.
Dimension không lùi (upsert cộng dồn) — chỉ ảnh hưởng KPI "số khách", các số
revenue/fct/reject vẫn lùi sạch. CSV batch còn trên đĩa nên nạp lại bất cứ lúc nào
→ thao tác đảo ngược được. **Nếu Noel đang dựng chart, báo trước vì số sẽ đổi.**
