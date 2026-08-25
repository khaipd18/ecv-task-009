# Đóng góp — Phan Đình Khải (Infrastructure & Orchestration)

> **Mục đích file này:** cung cấp nguyên liệu chính xác để Noel viết README tổng
> của dự án, phần "phân chia công việc". Mọi con số và tên file trong đây đều
> đối chiếu trực tiếp từ source code, không ước lượng.
>
> Phần dành riêng cho việc viết README/resume nằm ở **mục 8 và 9** — có sẵn đoạn
> văn và bullet, dùng được luôn.

---

## 1. Tóm tắt dự án (một đoạn, dùng cho phần mở đầu README)

Mini data platform chạy local bằng Docker Compose, gồm Postgres 16, Apache
Airflow 2.10.5 và Apache Superset 4.1.1. Hệ thống nạp dữ liệu Olist Brazilian
E-commerce (7 bảng) theo từng batch, đi qua kiến trúc bốn tầng
`raw → staging → mart → ops`, và cập nhật dashboard Superset **tự động sau mỗi
lần Airflow chạy**. Dữ liệu mỗi batch cố tình chứa dòng trùng và dòng sai định
dạng để pipeline phải khử trùng lặp và làm sạch; kết quả mỗi lần nạp được ghi
vào bảng kiểm toán `ops.load_audit` làm bằng chứng.

Dự án do hai người thực hiện với ranh giới sở hữu file rõ ràng và một **hợp đồng
tích hợp bằng văn bản** (`INTERFACE_CHO_NOEL.md`) quy định tên file SQL, tên
bảng, tên cột và tham số script mà hai bên phụ thuộc vào nhau.

---

## 2. Ranh giới sở hữu

| Hạng mục | Chủ sở hữu | File |
|---|---|---|
| Hạ tầng container | **Khải** | `docker-compose.yml`, `docker/**` |
| Khởi tạo & phân quyền database | **Khải** | `docker/postgres/init/01-create-databases.sh` |
| Orchestration | **Khải** | `dags/**` |
| Cấu hình Superset (tầng server) | **Khải** | `superset/superset_config.py` |
| Tooling vận hành | **Khải** | `Makefile`, `scripts/capture_evidence.sh`, `scripts/demo_batch.sh` |
| Tài liệu hạ tầng & hợp đồng tích hợp | **Khải** | `README.md`, `RUNBOOK.md`, `INTERFACE_CHO_NOEL.md`, `GHEP_VOI_NOEL.md` |
| DDL, transform, view | **Noel** | `sql/ddl/**`, `sql/transform/**`, `sql/marts/**` |
| Sinh dữ liệu batch | **Noel** | `scripts/generate_batch.py` |
| Nạp raw | **Noel** | `scripts/load_raw.sh` |
| Chart & dashboard | **Noel** | Superset UI, `superset/dashboard_export.zip` |
| Tài liệu dữ liệu | **Noel** | `docs/dataset.md` |

Ranh giới này được chọn để **không chạm file của nhau** — trong suốt dự án không
có merge conflict nào trên file mã nguồn.

---

## 3. Phần Khải đã làm — chi tiết

### 3.1 Hạ tầng container

`docker-compose.yml` — 6 service, 1 network bridge riêng, 1 named volume.

- **Ba image tuỳ biến** thay vì dùng image gốc:
  - `docker/airflow/Dockerfile` — thêm `postgresql-client` (để task chạy `psql`),
    `apache-airflow-providers-postgres`, `pandas`, `psycopg2-binary`, `Faker`.
  - `docker/superset/Dockerfile` — thêm `psycopg2-binary`; từ Superset 4.x driver
    DB bị tách khỏi image gốc, thiếu nó thì `superset db upgrade` chết ngay vì
    chính metadata DB của Superset cũng nằm trên Postgres.
  - Cài package qua Dockerfile, **không** dùng `_PIP_ADDITIONAL_REQUIREMENTS` —
    biến đó cài lại mỗi lần container start, chậm và phụ thuộc mạng đúng lúc demo.
- **Thứ tự khởi động có điều kiện**: `depends_on` dạng long-form với
  `service_healthy` (Postgres nhận được connection) và
  `service_completed_successfully` (job init exit 0), thay cho script
  `wait-for-it`. Chuỗi: `postgres → airflow-init → {webserver, scheduler}`.
- **Hai job khởi tạo tách riêng** (`airflow-init`, `superset-init`, `restart: "no"`)
  để migration schema không chạy song song từ nhiều container.
- **Healthcheck viết theo đặc thù từng service**: HTTP `/health` cho hai web UI;
  scheduler dùng `airflow jobs check --job-type SchedulerJob` — kiểm tra heartbeat
  trong DB metadata chứ không kiểm tra port, nên bắt được cả trường hợp process
  còn sống nhưng đã treo.
- **Giới hạn RAM từng container** (`deploy.resources.limits`, tổng trần ~6 GB) để
  một container OOM không kéo sập cả máy.
- **Hardening**: `no-new-privileges:true`, user không phải root, Superset kết nối
  DB nghiệp vụ bằng tài khoản chỉ-đọc, log rotation `10m × 3`.
- **Chạy được trên hai kiến trúc**: file compose chính không có `platform:` nào;
  phần cho macOS Apple Silicon tách sang `docker-compose.override.yml.example`
  (Compose tự merge, không cần cờ `-f`) — máy Khải amd64, máy Noel arm64 dùng
  chung một file compose.

### 3.2 Thiết kế database và phân quyền

`docker/postgres/init/01-create-databases.sh` — chạy tự động khi khởi tạo volume.

- **Ba database trên một instance**: `airflow` (metadata), `superset` (metadata),
  `olist` (dữ liệu nghiệp vụ). Gộp một instance để tiết kiệm RAM trên laptop
  nhưng vẫn tách hoàn toàn về mặt logic.
- **Bốn schema** `raw / staging / mart / ops` — khung để Noel viết DDL vào.
- **Hai tài khoản, phân quyền tối thiểu**:
  - `olist_user` — quyền ghi, Airflow dùng.
  - `superset_ro` — chỉ `SELECT` trên `mart` và `ops`, **không thấy** `raw` và
    `staging`. Superset không có đường nào chạm vào dữ liệu chưa làm sạch.
- **`ALTER DEFAULT PRIVILEGES`** để mọi bảng/view Noel tạo *về sau* trong `mart`
  và `ops` tự động được cấp quyền đọc — không phải `GRANT` tay sau mỗi lần thêm
  bảng. Chi tiết nhỏ nhưng loại bỏ hẳn một lớp lỗi lặp lại giữa hai người.

### 3.3 Orchestration — hai DAG

**`olist_seed_static`** (7 task, `schedule=None`, chạy một lần)

```
start → load_seed_raw → stg_static → stg_orders → write_audit → seed_dimensions → end
```

Tách khỏi pipeline chính vì bảng tĩnh (products/customers/sellers/category
translation) không có cột thời gian nên không cắt batch theo ngày được, và nạp
lại mỗi run sẽ làm nhiễu số liệu trong `ops.load_audit`.

**`olist_daily_pipeline`** (9 task, `schedule="*/15 * * * *"`)

```
start → check_seed → pick_batch → load_raw → stg_orders → write_audit → mart_upsert → dq_check → end
```

Bốn cơ chế đáng nói trong DAG này:

1. **`check_seed` — fail-fast có chủ đích.** Đếm số dòng ba bảng dimension, rỗng
   thì chặn ngay toàn bộ pipeline. Lý do: thiếu dimension thì fact join ra NULL
   toàn bộ, dashboard vẫn hiện số nhưng là số vô nghĩa — loại lỗi im lặng, rất
   khó phát hiện khi người bên kia đang dựng chart.

2. **`pick_batch` — idempotency không cần cursor file.** Đối chiếu danh sách thư
   mục `data/batches/batch_*` với `SELECT DISTINCT batch_id FROM ops.load_audit`,
   lấy batch nhỏ nhất chưa nạp; hết batch thì `AirflowSkipException` (skip, không
   phải fail). Trạng thái "đã nạp tới đâu" sống trong chính database chứ không
   nằm ở file bên ngoài, nên chạy lại DAG không bao giờ nạp trùng. Cố ý **không**
   dùng `{{ ds }}` của Airflow: `logical_date` của run (2026) không liên quan gì
   tới ngày trong dữ liệu Olist (2018).

3. **Chạy SQL của Noel bằng `psql` client, không qua `psycopg2`.** File transform
   của Noel dùng cú pháp biến của psql (`:'batch_id'`, cần `-v batch_id=...`) mà
   psycopg2 không hiểu. Chọn `BashOperator` + `psql -v ON_ERROR_STOP=1` để **SQL
   của Noel giữ nguyên, không phải sửa một phía cho vừa công cụ của bên kia**.
   Đây là lý do image Airflow được thêm `postgresql-client`.

4. **Thứ tự `02 → 04 → 03` và trigger rule.** `write_audit` đặt *trước*
   `mart_upsert` vì audit chỉ đọc staging + `ops.rejected_rows`, không phụ thuộc
   mart; đặt vậy thì nếu mart lỗi, run sau vẫn cuốn batch này vào mart từ staging
   — self-healing, không phải nạp lại raw. Đồng thời **không** dùng
   `trigger_rule="all_done"` cho `write_audit`: `ops.load_audit` là sổ "đã nạp"
   mà `pick_batch` đối chiếu, ghi audit khi upstream fail sẽ vừa đánh dấu nhầm
   batch hỏng là xong, vừa che thất bại khiến DagRun báo success dù chưa nạp gì.

Ngoài ra: `catchup=False` + `max_active_runs=1` + `execution_timeout` nhỏ hơn
schedule interval (10 phút < 15 phút) để hai run không chồng nhau làm hỏng logic
dedup; `retries=2` với `retry_delay` 2 phút; `dq_check` dùng
`SQLColumnCheckOperator` kiểm tra null trên khoá và `price >= 0` trên
`mart.fct_order_items`; toàn bộ SQL tham chiếu qua `template_searchpath` nên Noel
push file `.sql` mới chỉ cần `git pull`, **không phải restart Airflow**.

### 3.4 Cấu hình Superset

`superset/superset_config.py` — file quyết định việc bài có đạt yêu cầu hay không.

Mặc định Superset cache kết quả query. Không tắt thì Airflow chạy xong, dữ liệu
đã vào Postgres, nhưng dashboard vẫn hiện số cũ — hỏng đúng điểm nghiệm thu. Cấu
hình đã tắt **cả bốn tầng cache** (`CACHE_CONFIG`, `DATA_CACHE_CONFIG`,
`FILTER_STATE_CACHE_CONFIG`, `EXPLORE_FORM_DATA_CACHE_CONFIG` = `NullCache`), hạ
ngưỡng chặn auto-refresh xuống 10 giây, chuyển metadata DB từ SQLite mặc định
sang Postgres (SQLite nằm trong container, container chết là mất sạch dashboard),
và đặt `ROW_LIMIT` để một chart lỗi không kéo cả triệu dòng.

Vì Noel dùng `CREATE OR REPLACE VIEW` thường (không phải materialized view), view
tính lại real-time mỗi lần query — nghĩa là **dashboard tự cập nhật phụ thuộc
hoàn toàn vào việc cache đã tắt**, không còn lớp phòng hộ nào khác. Ràng buộc này
được ghi rõ trong docstring DAG và `GHEP_VOI_NOEL.md` để không ai bật lại cache vì
lý do hiệu năng.

### 3.5 Tooling vận hành

**`Makefile` — 25 target**, nhóm theo vòng đời: khởi tạo (`init`, `build`, `up`),
chuẩn bị dữ liệu (`ddl`, `views`, `seed`, `check-seed`, `set-vars`), điều khiển
DAG (`dag-list`, `dag-test`, `dag-trigger`, `dag-unpause`, `batches`), bằng chứng
và backup (`evidence`, `dashboard-export`, `dashboard-import`), chẩn đoán
(`ps`, `logs`, `psql`, `tailscale-info`), dọn dữ liệu (`truncate-data`, `reset`).

Hai chi tiết về an toàn vận hành:

- **`make reset` bắt gõ đúng chuỗi xác nhận** trước khi `down -v`, kèm cảnh báo
  liệt kê chính xác cái gì sẽ mất (dashboard của Noel + lịch sử DagRun = evidence).
- **`make truncate-data`** là đường thoát an toàn: xoá dữ liệu nghiệp vụ động
  nhưng **giữ** bảng tĩnh, `ops.load_audit` và toàn bộ dashboard. Có lệnh này thì
  không ai phải với tới `reset`.

**`scripts/capture_evidence.sh`** — thu thập bằng chứng theo từng run vào
`docs/evidence/<timestamp>/`: trạng thái container, bảng `ops.load_audit`, số
dòng từng tầng bảng, kiểm tra không còn duplicate trong mart, kiểm tra không có
dòng mồ côi, kèm export CSV. Tự động hoá để số liệu giữa các run nhất quán —
không phải gõ query khác nhau mỗi lần.

**`scripts/demo_batch.sh`** — kịch bản demo "dashboard tự cập nhật": chụp số
trước → trigger một run → đợi run xanh → chụp số sau → in bảng so sánh có delta.
Biến phần chứng minh khó nhất của bài thành một lệnh.

### 3.6 Tài liệu

| File | Nội dung |
|---|---|
| `README.md` | Quickstart, bảng port, hướng dẫn macOS Apple Silicon, troubleshooting, quy trình làm việc chung qua Tailscale |
| `RUNBOOK.md` | Vận hành: định nghĩa từng lệnh `make` thực chất chạy gì, kịch bản demo từng bước, xử lý sự cố, rollback |
| `INTERFACE_CHO_NOEL.md` | **Hợp đồng tích hợp** — đường dẫn từng file SQL mà DAG gọi, cột bắt buộc của `ops.load_audit`, quy ước `batch_id`, XCom key, tham số `load_raw.sh` |
| `GHEP_VOI_NOEL.md` | Nhật ký tích hợp: điểm đã chốt, điểm còn mở, lý do từng thay đổi trong DAG |

---

## 4. Điểm giao giữa hai bên (nội dung hợp đồng tích hợp)

Đây là phần đáng kể nhất về mặt cộng tác — hai người làm trên hai máy khác kiến
trúc, không đọc code của nhau, ghép được là nhờ chốt trước bằng văn bản:

| DAG gọi tới | Bên Noel cung cấp |
|---|---|
| `bash scripts/load_raw.sh <batch_dir> <batch_id>` | Script nạp raw bằng `COPY` |
| `psql -f sql/transform/01_stg_static.sql` | Làm sạch bảng tĩnh |
| `psql -f sql/transform/02_stg_orders.sql -v batch_id=...` | Làm sạch + dedup bảng động |
| `psql -f sql/transform/04_write_audit.sql -v batch_id=...` | Ghi `ops.load_audit` |
| `psql -f sql/transform/03_mart_upsert.sql` | Dựng dimension + fact |
| `SELECT COUNT(*) FROM mart.dim_{product,customer,seller}` | Bảng dimension |
| `SELECT DISTINCT batch_id FROM ops.load_audit` | Cột `batch_id` |
| `mart.fct_order_items` (`order_id`, `order_item_id`, `price`) | Bảng fact cho `dq_check` |
| XCom `pick_batch.batch_id` / `batch_dir` | — (DAG cung cấp cho script Noel) |

Ba điểm được đàm phán và ghi lại trong `GHEP_VOI_NOEL.md`: thứ tự chạy transform
`02 → 04 → 03`, việc seed phải bao gồm ~93k đơn lịch sử (nếu không `dim_customer`
rỗng và `check_seed` chặn), và `execution_timeout` được nới nhưng có trần để
không chồng run.

---

## 5. Chuỗi nhân quả của yêu cầu nghiệm thu

Yêu cầu "dashboard tự cập nhật sau mỗi lần Airflow chạy" thành công nhờ bốn mắt
xích, thiếu một là hỏng:

```
Airflow (schedule */15) chạy pick_batch → nạp đúng 1 batch chưa nạp
        ↓
transform ghi vào mart.fct_order_items + ops.load_audit
        ↓
view của Noel là VIEW thường → đọc lại bảng mart ngay khi được query
        ↓
Superset cache = NullCache → mỗi lần mở dashboard là một query thật xuống Postgres
        ↓
dashboard hiện số mới, không cần thao tác tay nào
```

Bằng chứng cho từng run: lịch sử DagRun trong Airflow UI, bảng `ops.load_audit`
(rows_in / rows_dup / rows_rejected / rows_loaded), và thư mục
`docs/evidence/<timestamp>/` do `capture_evidence.sh` sinh.

---

## 6. Quyết định kỹ thuật và lý do

Bảng này dùng được khi cần trả lời câu "vì sao làm thế" lúc phỏng vấn.

| Quyết định | Lý do |
|---|---|
| `LocalExecutor` thay vì Celery | Chạy song song thật mà không cần thêm Redis + worker + Flower; phù hợp phạm vi bài, đổi lại vẫn phải dùng Postgres làm metadata DB |
| Ba database trên một instance Postgres | Tiết kiệm RAM laptop, vẫn tách logic hoàn toàn |
| Tài khoản `superset_ro` chỉ đọc `mart`/`ops` | Superset không có đường chạm dữ liệu chưa làm sạch |
| SQL để trong file `.sql`, không nhúng vào Python | Noel push → `git pull` là có hiệu lực, không rebuild, không restart Airflow; đồng thời giữ ranh giới sở hữu file |
| Chạy SQL bằng `psql` client, không `psycopg2` | Giữ nguyên cú pháp biến psql của Noel — công cụ thích nghi với code, không bắt code sửa theo công cụ |
| `pick_batch` đối chiếu `ops.load_audit` | Trạng thái nằm trong DB, idempotent, không có file cursor để lệch |
| Bind mount cho `dags/sql/scripts/data/logs`, named volume cho `pgdata` | Thứ người sửa và git theo dõi thì bind mount; thứ Postgres sinh ra và không ai đọc tay thì named volume — đồng thời để `logs/` (evidence) sống sót qua `down -v` |
| `NullCache` toàn bộ tầng cache Superset | Yêu cầu cốt lõi của bài; view thường không có lớp phòng hộ nào khác |
| `check_seed` chặn sớm | Ngăn lỗi im lặng dimension rỗng → fact NULL → dashboard hiện số sai mà trông vẫn bình thường |
| `write_audit` giữ `all_success`, không `all_done` | Audit là sổ "đã nạp"; ghi khi upstream fail sẽ đánh dấu nhầm và che thất bại |
| Không `platform:` trong compose chính | File override riêng cho máy arm64, một file compose dùng chung cho hai kiến trúc |

---

## 7. Phạm vi bằng con số

| | |
|---|---|
| Service Docker | 6 (Postgres, Airflow init/web/scheduler, Superset init/server) |
| Image tuỳ biến | 2 (Airflow, Superset) |
| Database / Schema | 3 / 4 |
| DAG | 2 — tổng 16 task |
| Batch dữ liệu | 1 seed + 15 batch ngày (2018-08-01 → 2018-08-15) |
| Target `make` | 25 |
| Dòng code + tài liệu (phần Khải) | ~1.870 |
| Commit | 21 |

---

## 8. Gợi ý cấu trúc README tổng

Đề xuất cho Noel — phần **Phân công** đặt sau phần kiến trúc, dùng bảng hai cột
thay vì liệt kê dài:

```markdown
## Phân công

Dự án chia theo hai vai trò với ranh giới sở hữu file rõ ràng, ghép qua một
hợp đồng tích hợp bằng văn bản (INTERFACE_CHO_NOEL.md).

| Vai trò | Người | Phạm vi |
|---|---|---|
| Data & Analytics | Noel | Mô hình hoá dữ liệu (DDL 4 tầng), SQL transform (làm sạch, dedup, upsert), view phục vụ báo cáo, sinh dữ liệu batch có lỗi cố ý, xây dựng chart & dashboard Superset |
| Infrastructure & Orchestration | Khải | Docker Compose 6 service, image Airflow/Superset tuỳ biến, khởi tạo & phân quyền Postgres, 2 DAG Airflow, cấu hình Superset, tooling vận hành & thu thập bằng chứng, tài liệu hạ tầng |

Chi tiết phần hạ tầng: [DONG_GOP_KHAI.md](DONG_GOP_KHAI.md).
Hợp đồng giữa hai bên: [INTERFACE_CHO_NOEL.md](INTERFACE_CHO_NOEL.md).
```

---

## 9. Bullet dùng cho resume

### 9.1 Mô tả chung dự án (cả hai đều dùng được)

> **Mini Data Platform — Olist E-commerce Analytics** · Docker Compose, PostgreSQL 16,
> Apache Airflow 2.10, Apache Superset 4.1
> Batch data pipeline nạp dữ liệu thương mại điện tử qua kiến trúc bốn tầng
> `raw → staging → mart → ops`, khử trùng lặp và loại bỏ bản ghi sai định dạng,
> ghi kiểm toán từng lần nạp, và cập nhật dashboard BI tự động sau mỗi lần chạy.
> Dự án hai người với ranh giới sở hữu file và hợp đồng tích hợp bằng văn bản.

**English**

> **Mini Data Platform — Olist E-commerce Analytics** · Docker Compose, PostgreSQL 16,
> Apache Airflow 2.10, Apache Superset 4.1
> Batch pipeline ingesting e-commerce data through a four-layer
> `raw → staging → mart → ops` architecture with deduplication, format validation,
> and per-batch audit logging; BI dashboards refresh automatically after every
> pipeline run. Two-person project with explicit file ownership boundaries and a
> written integration contract.

### 9.2 Bullet cho Noel (Data & Analytics)

- Thiết kế mô hình dữ liệu bốn tầng `raw / staging / mart / ops` cho bộ dữ liệu
  Olist 7 bảng, gồm bảng fact và ba bảng dimension.
- Viết SQL transform xử lý dữ liệu bẩn: khử trùng lặp theo khoá nghiệp vụ, tách
  bản ghi sai định dạng sang bảng `ops.rejected_rows`, upsert vào mart theo từng
  batch.
- Xây dựng view báo cáo và bộ dashboard Superset (tổng quan doanh thu, sản phẩm,
  người bán, giao hàng & khách hàng, chất lượng dữ liệu).
- Xây dựng công cụ sinh dữ liệu batch có chèn lỗi và bản ghi trùng có kiểm soát
  để kiểm chứng năng lực làm sạch của pipeline.
- Phối hợp qua hợp đồng tích hợp bằng văn bản: thống nhất tên bảng, tên cột và
  tham số script với phần orchestration mà không sửa chéo file của nhau.

**English**

- Designed a four-layer `raw / staging / mart / ops` data model over a 7-table
  e-commerce dataset, including one fact table and three dimensions.
- Authored SQL transformations handling dirty data: business-key deduplication,
  quarantine of malformed rows into a rejects table, and per-batch upserts into
  the mart layer.
- Built reporting views and Superset dashboards covering revenue, products,
  sellers, delivery/customer behaviour, and data quality.
- Built a batch generator that injects controlled duplicates and format errors to
  validate the pipeline's cleaning logic.
- Collaborated through a written integration contract, agreeing table/column
  names and script parameters with the orchestration side with zero cross-edits.

### 9.3 Bullet cho Khải (Infrastructure & Orchestration)

- Dựng stack sáu service bằng Docker Compose (PostgreSQL, Airflow webserver/
  scheduler/init, Superset server/init) với thứ tự khởi động theo health check,
  giới hạn tài nguyên từng container và hai image tuỳ biến.
- Thiết kế sơ đồ database ba DB / bốn schema với phân quyền tối thiểu — tài khoản
  chỉ-đọc riêng cho BI, chỉ nhìn thấy tầng `mart` và `ops`.
- Xây dựng hai DAG Airflow (16 task) với cơ chế chọn batch idempotent đối chiếu
  bảng kiểm toán, kiểm tra tiền điều kiện chặn sớm, và kiểm tra chất lượng dữ
  liệu sau khi nạp.
- Tắt toàn bộ tầng cache Superset để dashboard phản ánh dữ liệu mới ngay sau mỗi
  lần chạy — yêu cầu nghiệm thu chính của dự án.
- Viết tooling vận hành: 25 lệnh `make`, script thu thập bằng chứng theo từng run
  và script demo so sánh số liệu trước/sau.
- Chủ trì hợp đồng tích hợp giữa hai vai trò, cho phép hai người trên hai kiến
  trúc máy khác nhau (amd64 / Apple Silicon) ghép việc mà không có merge conflict.

**English**

- Built a six-service Docker Compose stack (PostgreSQL, Airflow webserver/
  scheduler/init, Superset server/init) with health-check-gated startup ordering,
  per-container resource limits, and two custom images.
- Designed a three-database / four-schema layout with least-privilege access — a
  dedicated read-only BI account restricted to the `mart` and `ops` layers.
- Implemented two Airflow DAGs (16 tasks) featuring idempotent batch selection
  driven by an audit table, fail-fast precondition checks, and post-load data
  quality assertions.
- Disabled every Superset cache layer so dashboards reflect new data immediately
  after each run — the project's primary acceptance criterion.
- Wrote operational tooling: 25 `make` targets, a per-run evidence collector, and
  a before/after comparison demo script.
- Owned the integration contract between the two roles, letting two developers on
  different CPU architectures (amd64 / Apple Silicon) work in parallel with zero
  merge conflicts.

---

## 10. Ghi chú trung thực

Để không mô tả quá lời khi đưa vào resume — những gì dự án **không** có:

- Chạy local trên một máy, không deploy lên cloud, không có CI/CD.
- `LocalExecutor`, một node — không phải cụm phân tán.
- Không có alerting, monitoring stack, hay lineage tool.
- Dữ liệu ở quy mô ~100k dòng, không phải big data.
- Không có test tự động; kiểm chứng bằng `airflow dags test`, `dq_check` trong
  DAG và evidence thu thập thủ công theo từng run.

Đây là bài tập được giao trong 5 buổi, và mô tả nên giữ đúng phạm vi đó. Phần
đáng nói của dự án không nằm ở quy mô mà ở **thiết kế đúng**: idempotency, phân
quyền tối thiểu, fail-fast, ranh giới sở hữu và hợp đồng tích hợp giữa hai người.

---

*Cập nhật: 2026-08-25 · Nhánh `khaipd18-infra` · Đối chiếu tại commit `af62697`.*
