# Interface — những gì bên Khải (DAG) gọi tới code của Noel

File này là **hợp đồng một chiều**: liệt kê chính xác những gì DAG bên hạ tầng
gọi tới. Noel tuỳ biến bên trong SQL thoải mái, miễn giữ đúng các điểm dưới.

> **Cập nhật 2026-08-21 — đã đồng bộ với DAG thật đang chạy.** Bản cũ mô tả thiết
> kế ban đầu (`generate_batch`, `{{ ts_nodash }}`, `cursor.json`, `refresh_matviews`,
> XCom, `{{ params.batch_id }}`). Những cái đó **đã bỏ hết**. Đọc bản này, đừng
> theo trí nhớ bản cũ.

Nếu Noel muốn đổi bất kỳ mục nào, báo Khải để sửa DAG tương ứng — đừng đổi ngầm.

---

## 0. Điểm dễ hiểu nhầm nhất — đọc trước

| Chuyện | Sự thật hiện tại |
|---|---|
| Biến batch trong SQL | Giữ **`:'batch_id'`** (cú pháp psql). DAG chạy file `.sql` bằng **psql client** với `-v batch_id=...`, KHÔNG qua Airflow operator. **ĐỪNG đổi sang `{{ params.batch_id }}`** — Airflow không render nó, psql sẽ chạy chuỗi literal và hỏng. |
| Sinh batch | DAG **không** gọi `generate_batch.py`. Batch đã sinh sẵn thành thư mục `data/batches/batch_YYYYMMDD/`. DAG chỉ nạp dần. |
| Chọn batch | Không cursor, không `{{ ds }}`, không `{{ ts_nodash }}`. `pick_batch` lấy thư mục `batch_*` nhỏ nhất chưa có trong `ops.load_audit`. |
| refresh_matviews | Đã bỏ. View thường, tính real-time, không cần refresh. |
| XCom cho audit | Đã bỏ. Audit do `04_write_audit.sql` tự tính bằng SQL. |

---

## 1. File SQL — tên và vị trí (DAG gọi ĐÚNG các đường dẫn này)

DAG khai báo `template_searchpath="/opt/airflow/sql"`. Tất cả nằm dưới `sql/`.

### DAG `olist_seed_static` (chạy 1 lần — `make seed`)

| Task | File SQL |
|---|---|
| `load_seed_raw` | (BashOperator gọi `scripts/load_raw.sh data/batches/seed seed`) |
| `stg_static` | `transform/01_stg_static.sql` |
| `stg_orders` | `transform/02_stg_orders.sql` |
| `write_audit` | `transform/04_write_audit.sql` |
| `seed_dimensions` | `transform/03_mart_upsert.sql` |

> **Không có file `seed/02_mart_dimensions.sql` riêng.** Dimension được dựng trong
> **`03_mart_upsert.sql`** (cùng file với fact). Ở bước seed, staging đã có ~93k
> đơn lịch sử nên 03 dựng đầy đủ dimension + fact lịch sử. Nếu Noel muốn tách
> dimension ra file riêng thì **báo trước** để Khải trỏ lại task `seed_dimensions`
> — đừng tách ngầm, DAG đang gọi `transform/03_mart_upsert.sql`.

### DAG `olist_daily_pipeline` (mỗi run — schedule `*/15`)

| Thứ tự | Task | File SQL |
|---|---|---|
| 1 | `stg_orders` | `transform/02_stg_orders.sql` |
| 2 | `write_audit` | `transform/04_write_audit.sql` |
| 3 | `mart_upsert` | `transform/03_mart_upsert.sql` |

Thứ tự **02 → 04 → 03** theo đúng README của Noel: 04 đọc số từ staging (không phụ
thuộc mart) nên ghi audit trước; 03 rebuild toàn bộ mart sau cùng.

Ba file nhận biến batch qua **`-v batch_id`** → tham chiếu bằng **`:'batch_id'`**.
Riêng `03_mart_upsert.sql` rebuild toàn bộ lịch sử nên **không dùng** `batch_id`
cũng không sao (DAG vẫn truyền `-v`, thừa thì bỏ qua).

DDL (`sql/ddl/`) và view (`sql/marts/`) **không** do DAG gọi. Apply bằng
`make ddl` và `make views` (chạy bằng `olist_user`). Xem `GHEP_VOI_NOEL.md`.

---

## 2. Cơ chế chọn batch & tính idempotent (thay cho cursor cũ)

`pick_batch`: liệt kê `data/batches/batch_*`, bỏ những `batch_id` đã có trong
`ops.load_audit`, lấy cái nhỏ nhất còn lại. Mỗi run tiến đúng một batch.

- **`batch_id` = đúng tên thư mục** (`batch_20180801`, cả tiền tố `batch_`). Cột
  `batch_id` trong `raw.*` và `ops.load_audit` phải mang đúng giá trị này để
  `pick_batch` đối chiếu khớp. `load_raw.sh` đã set đúng.
- **Idempotent** không nằm ở cursor mà nằm ở hai chỗ: (1) `pick_batch` bỏ batch đã
  có trong `load_audit` → không nạp lại; (2) `03_mart_upsert.sql` là UPSERT rebuild
  toàn bộ lịch sử → chạy lại ra cùng kết quả. Vì stack tích hợp **tiêu thụ file có
  sẵn** của Noel (không sinh lại), tính "chạy lại ra file y hệt" của script Noel
  được bảo toàn tự nhiên.
- **Run 5 (chứng minh idempotent)**: nạp lại một batch đã nạp. Vì `pick_batch` bỏ
  qua batch đã có, cách demo là copy lại thư mục batch đó (hoặc dùng
  `data/lan2/batch_20180804/`) và cho chạy tay lại các task transform → số trong
  mart **không đổi**. Đó là bằng chứng idempotent.

---

## 3. Bảng raw + cột `batch_id` + cách COPY

`scripts/load_raw.sh` nạp từng CSV bằng `\copy` với **danh sách cột tường minh**
(không dựa header vị trí), rồi set `batch_id` bằng `ALTER COLUMN ... SET DEFAULT`
trước COPY và `DROP DEFAULT` sau. Vì vậy:

- **Mọi bảng raw phải có cột `batch_id TEXT`** — kể cả 3 bảng tĩnh
  (`raw_products`, `raw_customers`, `raw_sellers`) và `raw_category_translation`.
  (Bản interface cũ nói bảng tĩnh không có `batch_id` — **sai, đã bỏ.**)
- CSV **không** chứa cột `batch_id`; script tự điền. DDL của Noel cứ khai `batch_id`
  là cột cuối, để DEFAULT của script rót vào.
- Vì đã liệt kê cột tường minh, chuyện "lệch số cột" mà Noel lo **không xảy ra** —
  miễn tên cột trong DDL khớp danh sách trong `load_raw.sh`.

Ánh xạ file → bảng (cả động lẫn tĩnh) đã cứng trong `load_raw.sh`:

| File CSV | Bảng đích |
|---|---|
| `orders.csv` | `raw.raw_orders` |
| `order_items.csv` | `raw.raw_order_items` |
| `order_payments.csv` | `raw.raw_order_payments` |
| `order_reviews.csv` | `raw.raw_order_reviews` |
| `products.csv` | `raw.raw_products` |
| `customers.csv` | `raw.raw_customers` |
| `sellers.csv` | `raw.raw_sellers` |
| `category_translation.csv` | `raw.raw_category_translation` |

---

## 4. Seed phải gồm dữ liệu lịch sử — ĐỒNG Ý

`data/batches/seed/` chứa **8 file**: 4 bảng động của mẻ nền (gồm ~92.909 đơn lịch
sử tới 2018-07-31) + 4 bảng tĩnh (`products`, `customers`, `sellers`,
**`category_translation`** — 71 dòng, bắt buộc, thiếu là category rỗng).

DAG seed chạy `02_stg_orders` để đưa lịch sử vào `staging.stg_orders` — nếu không
`dim_customer` (JOIN stg_customers × stg_orders) sẽ rỗng và `check_seed` của daily
chặn ngay. Đã test: dim_customer ≈ 89.819. Chốt như Noel đề xuất.

---

## 5. `ops.load_audit` — cột DAG cần

DAG **không** insert trực tiếp vào bảng này — `04_write_audit.sql` làm việc đó.
DAG chỉ **đọc `SELECT DISTINCT batch_id`** trong `pick_batch`. Nên:

- **Bắt buộc**: có cột `batch_id` mang đúng tên thư mục batch.
- Các cột số (`rows_in`, `rows_dup`, `rows_rejected`, `rows_loaded`): tuỳ Noel,
  dùng cho dashboard/evidence. Thêm/bớt cột khác (kể cả `table_name`, bỏ NOT NULL)
  **tự do** — không đụng DAG, miễn `batch_id` còn đó.

---

## 6. `dq_check` — DAG kiểm tra `mart.fct_order_items`

`SQLColumnCheckOperator` trên 3 cột: `order_id` (NULL = 0), `order_item_id`
(NULL = 0), `price` (min ≥ 0). Đổi tên cột thì báo Khải sửa `column_mapping`.

---

## 7. Truy cập stack qua Tailscale + kết nối DB

Máy Khải là server, mở qua Tailscale Serve (chỉ vào được khi stack đã `up`):

| Dịch vụ | URL |
|---|---|
| **Superset UI** | https://desktop-dhus7gb-1.tail3824f2.ts.net |
| **Airflow UI** | https://desktop-dhus7gb-1.tail3824f2.ts.net:8443 |
| **Postgres** (nếu cần psql trực tiếp) | `desktop-dhus7gb-1.tail3824f2.ts.net:5433` |

Superset chạy trên stack của Khải và tự nối DB nội bộ (`postgres:5432`), nên Noel
**chủ yếu chỉ cần dùng Superset UI** — dựng Dataset/Chart trên đó. Không cần cấu
hình connection DB thủ công trừ khi muốn chạy psql từ máy mình để test.

Connection read-only cho Superset (đã cấu hình sẵn phía Khải):

```
Host:     postgres      # trong container. Từ máy Noel: desktop-dhus7gb-1.tail3824f2.ts.net
Port:     5432          # trong container. Từ máy Noel: 5433
Database: olist
Username: superset_ro   # chỉ đọc mart + ops, KHÔNG đọc raw/staging (cố ý)
```

4 schema `raw/staging/mart/ops` đã tạo `AUTHORIZATION olist_user`; `superset_ro`
được `GRANT USAGE + SELECT` trên `mart, ops` và có `ALTER DEFAULT PRIVILEGES` nên
object mới do `olist_user` tạo tự được cấp quyền. **View/bảng phải tạo bằng
`olist_user`** (qua `make ddl`/`make views`) thì Superset mới thấy.

---

## 8. execution_timeout — ĐỒNG Ý nới, nhưng có trần

- Daily: **10 phút/task** (mart chạy ~1–2 phút → dư). Trần này **phải < 15 phút**
  (schedule interval) để tránh 2 run chồng nhau. Nếu mart thật sự chạm 10 phút thì
  báo Khải — sẽ cân lại cả interval.
- Seed: 20 phút (chạy 1 lần, thoải mái).

---

## 9. Những gì Noel KHÔNG cần đụng

`docker-compose.yml`, `docker/`, `superset/superset_config.py`, `dags/`,
`Makefile`, `scripts/capture_evidence.sh`, `scripts/load_raw.sh`.

Cache Superset đã tắt sẵn (`NullCache`). Không có task refresh — nếu dashboard
không tự update, kiểm tra cache có bị bật lại không, đừng thêm refresh.
