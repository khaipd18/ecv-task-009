# Giải thích SQL — cheat sheet trả lời mentor

Mỗi view trong `sql/marts/` có 4 phần: câu hỏi kinh doanh nó trả lời, grain
(1 dòng = gì), kỹ thuật SQL đáng chú ý + vì sao phải dùng, và bẫy nếu làm
sai. Viết từ đọc trực tiếp code, không đoán. 7 view được đánh dấu ⭐ là
phần dự kiến bị hỏi nhiều nhất, viết kỹ hơn.

---

## `sql/marts/01_overview.sql`

### `mart.vw_daily_kpi`
- **Câu hỏi:** Doanh thu, số đơn, số khách mỗi ngày biến động ra sao?
- **Grain:** 1 dòng = 1 ngày mua hàng.
- **Kỹ thuật:** Gộp riêng `fct_order_items` và `fct_orders` theo ngày ở 2 CTE khác nhau rồi mới `FULL JOIN` — không join 2 bảng fact gốc trực tiếp. `on_time_rate` dùng `FILTER` để chỉ tính trên đơn `delivered`.
- **Bẫy:** Nếu gộp thiếu 1 trong 2 CTE mà join thẳng 2 bảng fact gốc theo ngày, `SUM(item_revenue)` sẽ nhân theo số dòng payment/review của đơn đó.

### `mart.vw_category_contribution` ⭐
- **Câu hỏi:** Category nào đóng góp bao nhiêu % doanh thu, bao nhiêu category chiếm 80% (Pareto)?
- **Grain:** 1 dòng = 1 `category_en` (giữ đủ 74 dòng, không gộp).
- **Kỹ thuật:** `SUM() OVER ()` cho `pct_of_total`; `SUM() OVER (ORDER BY revenue DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` cho `pct_cumulative` (đường Pareto); `RANK()` cho `rank_revenue`. Phải tách CTE `xep_hang` riêng vì Postgres không cho 1 cột SELECT tham chiếu alias window function khác cùng cấp. `category_display`/`category_sorted` chỉ để hiển thị gọn (74 cột trục X không đọc nổi) — `category_sorted` ghép số thứ tự vì Mixed Chart Superset không có X-AXIS SORT BY.
- **Bẫy:** Group theo `category_pt` thay vì `category_en` sẽ vỡ grain (nhiều pt có thể trùng 1 en). `category_sorted` không được viết `CASE WHEN category_display = 'Others'...` (tham chiếu alias cùng cấp) — phải lặp lại điều kiện `rank_revenue <= 15`.

### `mart.vw_state_revenue`
- **Câu hỏi:** Bang khách hàng nào mang doanh thu cao, giao hàng nhanh/đúng hạn?
- **Grain:** 1 dòng = 1 `customer_state`.
- **Kỹ thuật:** 2 CTE gộp riêng theo bang rồi `FULL JOIN`; CTE lấy từ `fct_orders` phải `JOIN dim_customer` để có `customer_state` (bảng grain đơn không lưu cột địa lý).
- **Bẫy:** Join thẳng `fct_order_items` ↔ `fct_orders` theo `order_id` để "mượn" cột địa lý rồi lỡ `SUM` một cột số của `fct_orders` sẽ nhân sai theo số sản phẩm trong đơn.

### `mart.vw_detail_items`
- **Câu hỏi:** Chi tiết từng dòng sản phẩm để drill-down, filter đủ mọi chiều.
- **Grain:** 1 dòng = 1 sản phẩm trong 1 đơn (giữ nguyên grain `fct_order_items`).
- **Kỹ thuật:** `LEFT JOIN fct_orders` theo `order_id` (nhiều-một, an toàn) chỉ để lấy 4 cột NHÃN: `payment_type_main`, `review_score`, `is_late`, `delivery_days`.
- **Bẫy:** `SUM(payment_value)` hay bất kỳ cột số nào của `fct_orders` ở view này — giá trị đó lặp lại trên mỗi dòng sản phẩm của đơn, `SUM` sẽ nhân sai theo số sản phẩm.

---

## `sql/marts/02_product.sql`

### `mart.vw_category_segment` ⭐
- **Câu hỏi:** Trong mỗi category, phân khúc giá nào (Budget/Mid-range/Premium) chiếm doanh thu nhiều nhất — heatmap.
- **Grain:** 1 dòng = 1 cặp (`category_en`, `price_segment`).
- **Kỹ thuật:** `pct_within_category` dùng `SUM(item_revenue) OVER (PARTITION BY category_en)` — chia theo tổng CỦA CHÍNH category đó, không phải tổng toàn sàn, để mỗi hàng heatmap cộng dồn đúng 100%.
- **Bẫy:** Quên `PARTITION BY` thì % tính trên tổng toàn sàn (số rất nhỏ, vô nghĩa cho heatmap theo hàng). `COUNT(*)` thay vì `COUNT(DISTINCT order_id)` sẽ đếm trùng đơn có nhiều sản phẩm.

### `mart.vw_category_perf` ⭐
- **Câu hỏi:** Category nào "Core" (bán nhiều + giá cao), "Mass", "Premium" hay "Underperform" — scatter 4 góc phần tư.
- **Grain:** 1 dòng = 1 `category_en`.
- **Kỹ thuật:** `PERCENTILE_CONT(0.5)` tính median `items_sold` và `avg_price` (không dùng `AVG`) làm mốc phân loại, tránh outlier kéo lệch. `freight_share = SUM(freight_value)/SUM(item_revenue)` — tỷ lệ CỦA TỔNG, không phải `AVG(freight_ratio)` từng dòng.
- **Bẫy:** Bản đầu dùng `revenue` làm 1 trong 2 trục — vì `items_sold` và `revenue` tương quan quá mạnh nên gần hết category dồn lên đường chéo, scatter mất tác dụng (đã đổi sang `avg_price`, 2 trục độc lập hơn). `AVG(freight_ratio)` cho món rẻ/đắt cùng trọng số 1 dòng = sai lệch so với tỷ lệ tổng thật.

### `mart.vw_category_growth`
- **Câu hỏi:** Doanh thu category tăng/giảm bao nhiêu % so với tháng trước (MoM)?
- **Grain:** 1 dòng = 1 cặp (`category_en`, tháng), chỉ từ 2017-01 trở đi, chỉ tháng có `orders >= 20`.
- **Kỹ thuật:** `LAG(revenue) OVER (PARTITION BY category_en ORDER BY order_month)` lấy doanh thu tháng trước CÙNG category.
- **Bẫy:** Không lọc `orders >= 20` thì 1 đơn lên 5 đơn ra +400% nhưng vô nghĩa kinh doanh. Sinh thêm khung tháng đầy đủ (`generate_series`) để tránh `LAG` nhảy cóc sẽ tạo `revenue_prev_month = 0` → % tăng trưởng vô cực — cố ý KHÔNG làm vậy.

---

## `sql/marts/03_seller.sql`

### `mart.vw_seller_scorecard` ⭐
- **Câu hỏi:** Seller nào là Star (đáng đầu tư), Risky, Emerging hay Underperform?
- **Grain:** 1 dòng = 1 seller, CHỈ seller có `>= 20 đơn` (783/3.095).
- **Kỹ thuật:** `seller_order_map` (DISTINCT seller_id, order_id) rồi JOIN nhiều-một sang `fct_orders` để `AVG`/`COUNT` review/delivery theo seller — không `SUM`. `PERCENTILE_CONT(0.5)` làm mốc median revenue của TẬP ĐÃ LỌC. Tổng doanh thu toàn sàn tính ở CTE riêng KHÔNG áp ngưỡng, để `pct_of_total` không bị thổi phồng.
- **Bẫy:** Không lọc `>= 20 đơn` thì seller 1-2 đơn bị trễ ra `on_time_rate` = 0%/100% cực đoan, leo lên đầu/đáy bảng xếp hạng sai lệch. Quên `DISTINCT` trong `seller_order_map` thì đơn 3 sản phẩm của cùng 1 seller bị đếm 3 lần, méo `on_time_rate`/`avg_review_score`.

### `mart.vw_seller_concentration` ⭐
- **Câu hỏi:** Bao nhiêu % seller nắm giữ bao nhiêu % doanh thu — đường cong tập trung (Lorenz)?
- **Grain:** 1 dòng = 1 seller, TOÀN BỘ 3.095 seller (không lọc ngưỡng, kể cả seller doanh thu 0).
- **Kỹ thuật:** `ROW_NUMBER()` (không phải `RANK()`) để tính `pct_sellers_cumulative` — `RANK()` nhảy số khi đồng hạng sẽ làm % số seller sai. `SUM() OVER (ORDER BY thu_tu ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` cộng dồn doanh thu.
- **Bẫy:** Áp ngưỡng `>= 20 đơn` như `vw_seller_scorecard` sẽ làm SAI mẫu số (không còn là "toàn bộ seller"), % tập trung bị tính lệch. Kết quả thực tế: top 10% seller = 67,82% doanh thu, top 20% = 83,06%, 50% cuối chỉ 2,88%.

---

## `sql/marts/04_delivery_customer.sql`

### `mart.vw_delivery_perf`
- **Câu hỏi:** Tỷ lệ giao đúng hạn và thời gian giao trung bình theo tháng ra sao?
- **Grain:** 1 dòng = 1 tháng, chỉ đơn `delivered`.
- **Kỹ thuật:** `COUNT(*) FILTER (WHERE is_late = ...)` tính `on_time_rate`/`late_rate` cùng lúc trong 1 lượt quét.
- **Bẫy:** Quên `WHERE order_status = 'delivered'` thì đơn chưa giao (delivery_days NULL) làm lệch `AVG`, hoặc tệ hơn đơn huỷ lọt vào tử số `on_time_rate`.

### `mart.vw_delivery_distribution`
- **Câu hỏi:** Phần lớn đơn giao trong bao nhiêu ngày (0-7d, 8-14d...)?
- **Grain:** 1 dòng = 1 nhóm ngày giao (5 nhóm), chỉ đơn `delivered` có `delivery_days`.
- **Kỹ thuật:** `bucket` ghép sẵn số thứ tự vào tên (`'1. 0-7d'`...) vì Superset không cho chọn sort theo cột rời trên trục biểu đồ — sort alphabet của chuỗi mới ra đúng thứ tự thời gian. `sort_order` giữ song song để query trực tiếp.
- **Bẫy:** Để `bucket` dạng `'0-7'`/`'8-14'`/... không đánh số thì Superset sort alphabet ra sai thứ tự (`'30+'` đứng trước `'8-14'`).

### `mart.vw_delivery_route` ⭐
- **Câu hỏi:** Tuyến giao hàng (bang khách → bang seller) nào giao nhanh/chậm, đúng hạn cao/thấp?
- **Grain:** 1 dòng = 1 cặp (`customer_state`, `seller_state`), CHỈ cặp có `>= 30 đơn` (123/729 cặp lý thuyết).
- **Kỹ thuật:** Đọc từ `fct_order_items` (có cả 2 cột bang), KHÔNG phải `fct_orders`. `DISTINCT (customer_state, seller_state, order_id)` trước khi JOIN nhiều-một sang `fct_orders` lấy `delivery_days`/`is_late` — không `SUM`.
- **Bẫy:** 729 cặp lý thuyết nhưng phần lớn chỉ 1-2 đơn — không lọc `>= 30` thì `avg_delivery_days`/`on_time_rate` của cặp hiếm vô nghĩa thống kê, nhiễu ma trận. Quên `DISTINCT` ở `cap_bang_don` thì 1 đơn nhiều sản phẩm cùng `seller_state` bị đếm nhiều lần.

### `mart.vw_review_delay` ⭐
- **Câu hỏi:** Giao trễ bao nhiêu ngày thì điểm review giảm mạnh?
- **Grain:** 1 dòng = 1 nhóm độ trễ (6 nhóm `delay_days`), chỉ đơn `delivered`.
- **Kỹ thuật:** `delay_bucket` ghép số thứ tự vào tên (`'1. Early >7d'`...`'6. Late >15d'`) để Superset sort đúng. `pct_score_1_2` tính trên TỔNG SỐ ĐƠN của bucket (kể cả đơn chưa review), không chỉ trên số đơn đã review.
- **Bẫy:** Lấy mẫu số là số đơn ĐÃ review thay vì tổng số đơn trong bucket sẽ ra % cao hơn thực tế. Kết quả thực tế: nhóm trễ >15 ngày review rớt còn 1,72đ (75% bị 1-2 sao), nhóm sớm >7 ngày vẫn 4,31đ.

### `mart.vw_customer_summary`
- **Câu hỏi:** Khách mua 1 lần (`One-time`) vs mua lại (`Repeat`) khác nhau thế nào về doanh thu, AOV, on-time rate?
- **Grain:** 1 dòng = 1 nhóm khách, dựa vào cờ `is_repeat_customer` có sẵn ở `fct_orders`.
- **Kỹ thuật:** `GROUP BY is_repeat_customer` trực tiếp trên `fct_orders`, không cần join gì thêm vì cờ này đã tính sẵn (theo `dim_customer.total_orders > 1`) lúc nạp mart.
- **Bẫy:** Tưởng nhầm `is_repeat_customer` chỉ đúng cho đơn thứ 2 trở đi — thực tế nó áp cho MỌI đơn của khách đó, kể cả đơn đầu tiên của khách sau này mua lại, nên `GROUP BY` mới cho đúng 2 nhóm không chồng lấn (chỉ ~3,12% khách thuộc nhóm `Repeat`).

---

## `sql/marts/05_data_quality.sql`

### `mart.vw_batch_summary`
- **Câu hỏi:** Batch nào nạp bao nhiêu dòng, tỷ lệ vào được staging (`quality_score`) bao nhiêu?
- **Grain:** 1 dòng = 1 batch (gộp 4 dòng/bảng của `ops.load_audit`).
- **Kỹ thuật:** `quality_score` tính trên TỔNG `SUM(rows_loaded)/SUM(rows_in)` của cả batch, không phải trung bình cộng 4 tỷ lệ riêng của từng bảng.
- **Bẫy:** `AVG` của 4 tỷ lệ riêng lẻ (thay vì tổng/tổng) cho trọng số sai khi các bảng chênh lệch số dòng lớn (vd `raw_orders` ít dòng hơn `raw_order_items`).

### `mart.vw_reject_summary`
- **Câu hỏi:** Batch nào, bảng nào, lỗi gì, bao nhiêu dòng bị loại?
- **Grain:** 1 dòng = 1 bộ BA (`batch_id`, `source_table`, `reject_reason`) — không phải chỉ cặp (batch, reason).
- **Kỹ thuật:** `GROUP BY` phải có `source_table` vì cùng 1 mã `reject_reason` (vd `'orphan_row'`) được tái dùng ở nhiều bảng khác nhau trong `02_stg_orders.sql`.
- **Bẫy:** `GROUP BY` chỉ (`batch_id`, `reject_reason`) sẽ cộng chung `so_dong` của 3 bảng khác nhau vào 1 dòng, làm mất ý nghĩa cột `source_table`.

### `mart.vw_pipeline_health`
- **Câu hỏi:** Tổng quan: đã chạy bao nhiêu batch, nạp bao nhiêu dòng, tỷ lệ lỗi tổng?
- **Grain:** Đúng 1 dòng duy nhất.
- **Kỹ thuật:** `SELECT` aggregate KHÔNG `GROUP BY` để luôn ra đúng 1 dòng kể cả khi `ops.load_audit` rỗng (0/NULL thay vì 0 dòng) — cần thiết vì Superset KPI card không chấp nhận bảng trống.
- **Bẫy:** `tong_dong_bi_loai` chỉ tính `rows_rejected`, KHÔNG cộng `rows_dup` — cộng nhầm sẽ coi dòng trùng (dữ liệu hợp lệ, chỉ không nạp lại) như lỗi thật.
