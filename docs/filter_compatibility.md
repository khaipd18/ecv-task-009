# Ma trận tương thích filter — dùng khi mentor hỏi "sao chart này không lọc được?"

Dashboard có bộ filter dùng chung gắn vào `mart.vw_detail_items`, 7 chiều:
`order_purchase_date`, `category_en`, `price_segment`, `customer_state`,
`seller_state`, `order_status`, `payment_type_main`.

Bảng dưới liệt kê **toàn bộ 18 view** trong `sql/marts/`: view nào lọc
được theo chiều nào trong 7 chiều chuẩn, view nào không, và vì sao.
"Lọc được" nghĩa là view CÓ cột đó ở đúng grain gốc (chưa bị gộp) —
không tính các cột khám phá riêng của từng view (vd `segment`,
`quadrant`, `route_type`, `customer_type`, `delay_bucket`...) vì đó
không phải 1 trong 7 chiều chuẩn của bộ filter dùng chung.

| View | Grain | Lọc được theo | KHÔNG lọc được theo | Lý do |
|---|---|---|---|---|
| `vw_daily_kpi` | 1 ngày | `order_purchase_date` | `category_en`, `price_segment`, `customer_state`, `seller_state`, `order_status`, `payment_type_main` | Gộp xuyên suốt mọi category/bang/trạng thái/loại thanh toán để ra KPI tổng theo ngày. |
| `vw_category_contribution` | 1 `category_en` (74 dòng) | `category_en` | `order_purchase_date`, `price_segment`, `customer_state`, `seller_state`, `order_status`, `payment_type_main` | Gộp toàn bộ ngày/phân khúc/bang/trạng thái/thanh toán để ra 1 dòng/category (Pareto). |
| `vw_state_revenue` | 1 `customer_state` | `customer_state` | `order_purchase_date`, `category_en`, `price_segment`, `seller_state`, `order_status`, `payment_type_main` | Gộp toàn bộ các chiều khác để ra 1 dòng/bang khách. |
| `vw_detail_items` | 1 sản phẩm/đơn | **Cả 7/7** | *(không thiếu cột nào)* | Đây là nguồn của bộ filter dùng chung — giữ nguyên grain gốc `fct_order_items`, LEFT JOIN thêm 4 cột nhãn từ `fct_orders`. |
| `vw_category_segment` | category × price_segment | `category_en`, `price_segment` | `order_purchase_date`, `customer_state`, `seller_state`, `order_status`, `payment_type_main` | Gộp còn lại để vẽ heatmap category × phân khúc. |
| `vw_category_perf` | 1 `category_en` | `category_en` | `order_purchase_date`, `price_segment`, `customer_state`, `seller_state`, `order_status`, `payment_type_main` | Gộp toàn bộ để ra 1 dòng/category cho scatter 4 góc phần tư. |
| `vw_category_growth` | category × tháng (`order_month`) | `category_en` | `order_purchase_date` (chỉ có `order_month` — KHÁC cột, không lọc chính xác theo ngày được), `price_segment`, `customer_state`, `seller_state`, `order_status`, `payment_type_main` | Gộp theo tháng để tính MoM; đã lọc `orders >= 20` nên không giữ nguyên đơn lẻ theo ngày. |
| `vw_seller_scorecard` | 1 seller (**chỉ >=20 đơn**) | `seller_state` | `order_purchase_date`, `category_en`, `price_segment`, `customer_state`, `order_status`, `payment_type_main` | Gộp toàn bộ để ra scorecard theo seller; ngưỡng >=20 đơn cũng loại bớt dữ liệu (783/3.095 seller). |
| `vw_seller_concentration` | 1 seller (toàn bộ 3.095) | *(không có)* | **Cả 7/7** | Chỉ để vẽ đường Lorenz theo `seller_id`/`revenue`, không giữ bất kỳ chiều kinh doanh nào, kể cả `seller_state`. |
| `vw_seller_detail` ⭐ mới | seller × category × price_segment × ngày | `category_en`, `price_segment`, `seller_state`, `order_purchase_date` | `customer_state`, `order_status`, `payment_type_main` | Tạo riêng để bù cho `vw_seller_scorecard` — KHÔNG áp ngưỡng thống kê, chỉ dùng để lọc/khám phá (xem "Nguyên tắc thiết kế"). |
| `vw_delivery_perf` | 1 tháng (`order_month`), chỉ delivered | *(không có)* | **Cả 7/7** | `order_purchase_date` bị thay bằng `order_month`; `order_status` bị cố định = `'delivered'` nên không còn là cột output để lọc. |
| `vw_delivery_distribution` | 5 nhóm ngày giao | *(không có)* | **Cả 7/7** | Gộp toàn bộ đơn delivered thành 5 bucket, không giữ chiều nào trong 7 chiều chuẩn. |
| `vw_delivery_route` | customer_state × seller_state (**>=30 đơn**) | `customer_state`, `seller_state` | `order_purchase_date`, `category_en`, `price_segment`, `order_status`, `payment_type_main` | Gộp còn lại để ra ma trận tuyến giao hàng; ngưỡng >=30 đơn loại bớt cặp bang hiếm. |
| `vw_review_delay` | 6 nhóm độ trễ | *(không có)* | **Cả 7/7** | Gộp toàn bộ đơn delivered thành 6 nhóm `delay_bucket`, không giữ chiều kinh doanh nào. |
| `vw_customer_summary` | `customer_type` (2 dòng) | *(không có)* | **Cả 7/7** | `customer_type` (`One-time`/`Repeat`) là chiều MỚI thay thế hoàn toàn 7 chiều gốc. |
| `vw_batch_summary` | 1 batch | *(không có — không phải view kinh doanh)* | **Cả 7/7** | View vận hành (ops), gộp theo `batch_id` — batch nạp dữ liệu không gắn với category/bang/khách hàng cụ thể nào. |
| `vw_reject_summary` | batch × source_table × reject_reason | *(không có)* | **Cả 7/7** | Cùng lý do — view vận hành, lỗi nạp dữ liệu không có chiều kinh doanh. |
| `vw_pipeline_health` | 1 dòng duy nhất | *(không có)* | **Cả 7/7** | Chỉ 1 dòng tổng hợp toàn hệ thống, không có gì để lọc theo. |

---

## Nguyên tắc thiết kế

### 1. Vì sao view đã `GROUP BY` thì không lọc được theo cột đã bị gộp

Khi 1 view `GROUP BY category_en`, mỗi category chỉ còn ĐÚNG 1 dòng —
thông tin "dòng này thuộc bang nào, ngày nào, trạng thái đơn gì" đã bị
**mất vĩnh viễn** trong bước `SUM`/`COUNT`/`AVG`, không cách nào khôi
phục lại từ kết quả đã gộp. Superset chỉ có thể `WHERE` trên các cột
THỰC SỰ TỒN TẠI trong view — cột không còn trong `SELECT`/`GROUP BY` thì
không thể filter, dù dữ liệu gốc ở `fct_order_items`/`fct_orders` vẫn
còn đủ. Đây là đánh đổi bắt buộc: gộp càng sâu (để chart gọn, dễ đọc)
thì càng mất khả năng lọc chi tiết — không có cách "vừa gộp vừa giữ
nguyên khả năng lọc mọi chiều" trong 1 view duy nhất, đó là lý do dự án
có nhiều view cho nhiều mục đích khác nhau thay vì 1 view "làm được
tất cả".

### 2. Vì sao cột % tính sẵn (`pct_of_total`, `pct_cumulative`) không tính lại được khi lọc

`pct_of_total` và `pct_cumulative` (ở `vw_category_contribution`,
`vw_state_revenue`, `vw_seller_scorecard`...) được tính bằng WINDOW
FUNCTION (`SUM() OVER ()`) **ngay tại thời điểm Postgres chạy view**,
so với TOÀN BỘ tập kết quả CHƯA LỌC. Khi Superset áp thêm 1 `WHERE`
(vd chỉ xem category ở bang SP) lên KẾT QUẢ của view, Postgres chỉ lọc
BỚT DÒNG ra khỏi kết quả cuối — các con số `pct_of_total` trên những
dòng còn lại VẪN LÀ % so với tổng TOÀN SÀN ban đầu (trước khi lọc), chứ
KHÔNG tự động tính lại % so với tổng CỦA TẬP ĐÃ LỌC. Hậu quả: sau khi
lọc, cột `pct_of_total` của các dòng còn lại sẽ KHÔNG cộng lại đúng
100% nữa — nhìn vào sẽ thấy vô lý (vd 5 category còn lại sau lọc mà
tổng % chỉ ra 23%).

**Cách thay thế:** dùng tính năng **Contribution Mode** của Superset
(có ở hầu hết chart type dạng bar/table) — tính năng này tính % ở TẦNG
CHART, SAU KHI query đã trả về đúng tập dữ liệu ĐÃ LỌC, nên luôn tự
động cộng đúng 100% trên tập hiện tại. Với các chart cần % LUÔN đúng
sau khi lọc, dùng `revenue` (số tuyệt đối) từ view + bật Contribution
Mode trên Superset, thay vì dựa vào `pct_of_total`/`pct_cumulative` đã
tính sẵn trong view.

### 3. Vì sao chart pipeline (`vw_batch_summary`, `vw_reject_summary`, `vw_pipeline_health`) cố ý không gắn filter kinh doanh

3 view này thuộc tầng `ops` (vận hành/audit), đo lường CHÍNH BẢN THÂN
QUÁ TRÌNH NẠP DỮ LIỆU (`ops.load_audit`, `ops.rejected_rows`), không
đo lường hoạt động kinh doanh (doanh thu/khách/sản phẩm). Một batch nạp
dữ liệu KHÔNG thuộc về 1 category, 1 bang, hay 1 loại thanh toán cụ
thể nào — nó nạp TẤT CẢ các dòng của TẤT CẢ các chiều đó cùng lúc. Gắn
filter `category_en`/`customer_state`... vào các chart này về mặt khái
niệm KHÔNG CÓ Ý NGHĨA (câu hỏi "batch này nạp dữ liệu tốt không, riêng
cho category X?" không phải câu hỏi vận hành hợp lý — chất lượng nạp
dữ liệu là thuộc tính của CẢ BATCH, không tách theo category được vì
lỗi format/trùng lặp xảy ra ở tầng CSV thô, trước khi dữ liệu được gắn
category). Vì vậy 3 chart này được thiết kế để đứng ĐỘC LẬP với bộ
filter kinh doanh dùng chung — đây là chủ đích, không phải thiếu sót.

### 4. Trọng số item khi tính AVG trên `vw_detail_items` (review_score, is_late)

`review_score` và `is_late` trong `vw_detail_items` được lấy từ
`fct_orders` (grain đơn) qua `LEFT JOIN`, nhưng nằm trên các dòng grain
SẢN PHẨM — nghĩa là 1 đơn có 3 sản phẩm thì giá trị `review_score` của
đơn đó XUẤT HIỆN 3 LẦN trong view. Nếu tính `AVG(review_score)` trực
tiếp trên `vw_detail_items`, đơn nhiều sản phẩm sẽ có TRỌNG SỐ CAO HƠN
đơn ít sản phẩm một cách không chủ đích — đây là hệ quả tất yếu của
việc giữ nguyên grain sản phẩm để phục vụ filter (VIỆC 1), không phải
lỗi code.

**Đã đo mức lệch thực tế** (chạy trên `olist-dev`, xem câu SQL bên dưới):

| Cách tính | avg_review_score |
|---|---|
| a) `AVG(review_score)` trên `vw_detail_items` (có trọng số item) | **4,0324** |
| b) `AVG(review_score)` trên `fct_orders` (không trọng số, đúng 1 dòng/đơn) | **4,1047** |

Chênh lệch: **-0,0723 điểm, tương đương -1,76%** — **DƯỚI ngưỡng 2%**,
**mức lệch CHẤP NHẬN ĐƯỢC**. Có thể dùng `AVG(review_score)` trực tiếp
trên `vw_detail_items` cho các chart lọc theo 7 chiều chuẩn mà không
cần xử lý gì thêm. Nếu sau này cần con số review chính xác tuyệt đối
(không lệch trọng số) mà VẪN cần lọc theo 7 chiều, nên tính trên
`fct_orders` JOIN với `DISTINCT (7 chiều, order_id)` lấy từ
`fct_order_items` — đúng kỹ thuật đã dùng ở `vw_seller_detail` và
`vw_delivery_route`.

```sql
-- a) Có trọng số item (mỗi dòng sản phẩm tính 1 lần)
SELECT AVG(review_score) FROM mart.vw_detail_items;

-- b) Không trọng số (mỗi đơn tính đúng 1 lần)
SELECT AVG(review_score) FROM mart.fct_orders;
```
