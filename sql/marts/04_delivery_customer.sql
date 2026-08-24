-- =====================================================================
-- MART VIEWS — GIAO HÀNG, ĐỘ TRỄ VS REVIEW, VÀ SO SÁNH NHÓM KHÁCH
-- 5 view: hiệu suất giao hàng theo tháng, phân bố số ngày giao, giao
-- hàng theo cặp bang, tương quan độ trễ với điểm review, và so sánh
-- khách mua 1 lần vs mua lại.
--
-- Toàn bộ view trong file này đọc từ mart.fct_orders (grain đơn hàng),
-- NGOẠI TRỪ view 3 (vw_delivery_route) -- view đó CỐ Ý đọc từ
-- mart.fct_order_items vì fct_orders không lưu customer_state/
-- seller_state, cần cả 2 bang mới ghép được "tuyến giao hàng".
--
-- Nhắc lại quy tắc 1 (bản đã đính chính): fct_orders có ĐÚNG 1 dòng /
-- order_id (PK). Khi view 3 cần vừa có cặp bang (chỉ có ở
-- fct_order_items) vừa cần delivery_days/is_late (chỉ có ở
-- fct_orders), phải JOIN theo order_id qua 1 CTE riêng rồi AVG/COUNT
-- các cột NHÃN -- KHÔNG được SUM cột số nào của fct_orders sau khi
-- join xuống grain khác.
-- Quy tắc 3 (delivery/delay/is_late chỉ tính khi delivered), quy tắc 4
-- (đếm khách DISTINCT customer_unique_id), quy tắc 5 (đếm đơn DISTINCT
-- order_id khi nguồn là fct_order_items) áp dụng đầy đủ.
-- =====================================================================


-- =====================================================================
-- VIEW 1: mart.vw_delivery_perf
-- Grain: 1 dòng = 1 tháng mua hàng. Chỉ tính đơn delivered (quy tắc 3).
--
-- Ghi chú quy tắc 2: order_purchase_date bị thay bằng order_month (gộp
-- thô hơn theo tháng, đúng mục đích theo dõi xu hướng). 6 cột filter
-- còn lại bị mất: category_en/price_segment/customer_state/
-- seller_state không tồn tại ở fct_orders; order_status bị cố định =
-- 'delivered' nên không còn là cột filter; payment_type_main có trong
-- fct_orders nhưng không cần thiết ở view giao hàng này nên không lấy.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_delivery_perf AS
SELECT
    DATE_TRUNC('month', order_purchase_date)::DATE AS order_month,
    -- fct_orders có grain 1 dòng = 1 đơn (PK order_id), nên sau khi đã
    -- WHERE order_status = 'delivered' thì COUNT(*) = số đơn, không
    -- cần COUNT(DISTINCT order_id) như khi đọc từ fct_order_items.
    COUNT(*) AS orders,
    ROUND(
        COUNT(*) FILTER (WHERE is_late = FALSE)::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE is_late IS NOT NULL), 0) * 100,
        2
    ) AS on_time_rate,
    ROUND(
        COUNT(*) FILTER (WHERE is_late = TRUE)::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE is_late IS NOT NULL), 0) * 100,
        2
    ) AS late_rate,
    ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
    ROUND(AVG(delay_days), 2)    AS avg_delay_days
FROM mart.fct_orders
WHERE order_status = 'delivered'
GROUP BY DATE_TRUNC('month', order_purchase_date)
ORDER BY order_month;


-- =====================================================================
-- VIEW 2: mart.vw_delivery_distribution
-- Grain: 1 dòng = 1 nhóm (bucket) số ngày giao hàng. Chỉ tính đơn
-- delivered có delivery_days khác NULL (quy tắc 3).
--
-- sort_order: Superset mặc định sort bucket dạng text theo alphabet
-- ('0-7' < '15-21' < '22-30' < '30+' < '8-14' -- SAI thứ tự thực tế),
-- nên thêm cột số riêng để ép đúng thứ tự thời gian tăng dần.
-- Ngoài cột sort_order, bucket cũng được GHÉP SẴN số thứ tự vào tên
-- (vd '1. 0-7d') vì Superset không cho chọn sort theo cột rời trên
-- trục biểu đồ -- ghép số vào tên thì sort alphabet tự nhiên ra đúng
-- thứ tự. sort_order vẫn giữ nguyên để query trực tiếp cho tiện.
--
-- Ghi chú quy tắc 2: KHÔNG giữ cột filter chuẩn nào trong 7 cột (view
-- gộp toàn bộ đơn delivered thành 5 nhóm, mất hết ngày/category/bang/
-- trạng thái/loại thanh toán).
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_delivery_distribution AS
WITH gop_bucket AS (
    SELECT
        CASE
            WHEN delivery_days <= 7  THEN '1. 0-7d'
            WHEN delivery_days <= 14 THEN '2. 8-14d'
            WHEN delivery_days <= 21 THEN '3. 15-21d'
            WHEN delivery_days <= 30 THEN '4. 22-30d'
            ELSE '5. 30d+'
        END AS bucket,
        CASE
            WHEN delivery_days <= 7  THEN 1
            WHEN delivery_days <= 14 THEN 2
            WHEN delivery_days <= 21 THEN 3
            WHEN delivery_days <= 30 THEN 4
            ELSE 5
        END AS sort_order
    FROM mart.fct_orders
    WHERE order_status = 'delivered'
      AND delivery_days IS NOT NULL
)
SELECT
    bucket,
    sort_order,
    COUNT(*) AS orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM gop_bucket
GROUP BY bucket, sort_order
ORDER BY sort_order;


-- =====================================================================
-- VIEW 3: mart.vw_delivery_route
-- Grain: 1 dòng = 1 cặp (customer_state, seller_state).
-- Đọc từ mart.fct_order_items (KHÔNG phải fct_orders) vì cần cả 2
-- cột bang -- fct_orders không lưu customer_state/seller_state.
--
-- BẮT BUỘC: chỉ giữ cặp bang có >= 30 đơn. Có 27 bang nên về lý
-- thuyết tối đa 27 x 27 = 729 cặp, nhưng phần lớn chỉ 1-2 đơn (ví dụ
-- 1 khách ở bang hiếm mua của 1 seller ở bang khác hiếm) -- avg_
-- delivery_days/on_time_rate tính trên mẫu 1-2 đơn không có ý nghĩa
-- thống kê và sẽ làm nhiễu biểu đồ ma trận giao hàng.
--
-- Ghi chú quy tắc 2: giữ được CẢ customer_state VÀ seller_state
-- (2/7 cột filter chuẩn). 5 cột còn lại (order_purchase_date,
-- category_en, price_segment, order_status, payment_type_main) bị mất
-- vì view gộp xuyên suốt các chiều đó.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_delivery_route AS
WITH cap_bang_don AS (
    -- DISTINCT (customer_state, seller_state, order_id): 1 đơn có thể
    -- có nhiều dòng sản phẩm cùng seller_state (hoặc nhiều seller
    -- khác bang trong cùng đơn), DISTINCT để không đếm trùng đơn khi
    -- gộp theo cặp bang ở bước sau.
    SELECT DISTINCT customer_state, seller_state, order_id
    FROM mart.fct_order_items
),
gop_cap_bang AS (
    SELECT
        customer_state,
        seller_state,
        COUNT(DISTINCT order_id) AS orders   -- quy tắc 5
    FROM cap_bang_don
    GROUP BY customer_state, seller_state
    HAVING COUNT(DISTINCT order_id) >= 30
),
gop_giao_hang AS (
    -- Lấy delivery_days/is_late từ fct_orders theo order_id -- quan hệ
    -- NHIỀU (cặp bang-đơn) - MỘT (fct_orders theo order_id, PK), an
    -- toàn theo quy tắc 1 đã đính chính vì chỉ AVG/COUNT cột NHÃN,
    -- không SUM cột số nào của fct_orders.
    -- Tính trên TOÀN BỘ cặp bang_don (chưa lọc >=30), lọc thực tế xảy
    -- ra khi JOIN với gop_cap_bang (đã lọc) ở SELECT cuối.
    SELECT
        cb.customer_state,
        cb.seller_state,
        AVG(fo.delivery_days) FILTER (
            WHERE fo.order_status = 'delivered'
        ) AS avg_delivery_days,
        COUNT(*) FILTER (
            WHERE fo.order_status = 'delivered' AND fo.is_late = FALSE
        )::NUMERIC
        / NULLIF(
            COUNT(*) FILTER (
                WHERE fo.order_status = 'delivered' AND fo.is_late IS NOT NULL
            ),
            0
          ) AS on_time_rate
    FROM cap_bang_don cb
    JOIN mart.fct_orders fo ON fo.order_id = cb.order_id
    GROUP BY cb.customer_state, cb.seller_state
)
SELECT
    gc.customer_state,
    gc.seller_state,
    gc.orders,
    ROUND(gg.avg_delivery_days, 2) AS avg_delivery_days,
    ROUND(gg.on_time_rate * 100, 2) AS on_time_rate,
    -- Bang khách khác bang seller hay không -- xác định trực tiếp từ
    -- chính cặp bang của grain này, không cần gộp/đếm gì thêm.
    (gc.customer_state IS DISTINCT FROM gc.seller_state) AS is_cross_state,
    -- route_type: nhãn chữ cho is_cross_state, vì chart hiện true/false
    -- người xem không hiểu ngay là gì. Giữ cả is_cross_state gốc (kiểu
    -- boolean) để filter/tính toán, route_type chỉ để hiển thị.
    CASE WHEN gc.customer_state IS DISTINCT FROM gc.seller_state
         THEN 'Cross-state' ELSE 'Same-state' END AS route_type
FROM gop_cap_bang gc
JOIN gop_giao_hang gg
     ON gg.customer_state = gc.customer_state
    AND gg.seller_state   = gc.seller_state
ORDER BY gc.orders DESC;


-- =====================================================================
-- VIEW 4: mart.vw_review_delay
-- Grain: 1 dòng = 1 nhóm độ trễ giao hàng (delay_days). Chỉ tính đơn
-- delivered có delay_days khác NULL (quy tắc 3).
--
-- delay_days = ngày giao thực tế - ngày dự kiến: âm là giao SỚM,
-- dương là giao TRỄ, 0 là đúng ngày dự kiến.
--
-- pct_score_1_2 tính trên TỔNG SỐ ĐƠN của bucket (kể cả đơn chưa có
-- review), không chỉ trên số đơn đã được review -- đúng nghĩa "% đơn
-- bị chấm 1-2 sao trong nhóm này", đơn chưa review coi như chưa bị
-- chấm 1-2 sao nên không được tính vào tử số nhưng vẫn nằm trong mẫu số.
--
-- Ghi chú quy tắc 2: KHÔNG giữ cột filter chuẩn nào trong 7 cột (view
-- gộp toàn bộ đơn delivered thành 6 nhóm độ trễ).
--
-- delay_bucket đổi sang tiếng Anh và GHÉP SẴN số thứ tự vào tên nhóm
-- (vd '1. Early >7d') vì Superset không cho chọn sort theo cột riêng
-- (sort_order) trên trục biểu đồ -- ghép số vào tên thì sort theo
-- alphabet của Superset tự nhiên ra đúng thứ tự thời gian. Vẫn giữ
-- cột sort_order để query trực tiếp cho tiện, không phải parse số ra
-- khỏi chuỗi.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_review_delay AS
WITH gop_delay AS (
    SELECT
        CASE
            WHEN delay_days < -7                THEN '1. Early >7d'
            WHEN delay_days BETWEEN -7 AND -1    THEN '2. Early 1-7d'
            WHEN delay_days = 0                  THEN '3. On time'
            WHEN delay_days BETWEEN 1 AND 7      THEN '4. Late 1-7d'
            WHEN delay_days BETWEEN 8 AND 15     THEN '5. Late 8-15d'
            ELSE '6. Late >15d'
        END AS delay_bucket,
        CASE
            WHEN delay_days < -7                THEN 1
            WHEN delay_days BETWEEN -7 AND -1    THEN 2
            WHEN delay_days = 0                  THEN 3
            WHEN delay_days BETWEEN 1 AND 7      THEN 4
            WHEN delay_days BETWEEN 8 AND 15     THEN 5
            ELSE 6
        END AS sort_order,
        review_score
    FROM mart.fct_orders
    WHERE order_status = 'delivered'
      AND delay_days IS NOT NULL
)
SELECT
    delay_bucket,
    sort_order,
    COUNT(*) AS orders,
    ROUND(AVG(review_score), 2) AS avg_review_score,
    ROUND(
        COUNT(*) FILTER (WHERE review_score IN (1, 2)) * 100.0 / COUNT(*),
        2
    ) AS pct_score_1_2
FROM gop_delay
GROUP BY delay_bucket, sort_order
ORDER BY sort_order;


-- =====================================================================
-- VIEW 5: mart.vw_customer_summary
-- Grain: 1 dòng = 1 nhóm khách ('One-time' / 'Repeat'), dựa trên cờ
-- is_repeat_customer đã tính sẵn ở fct_orders (theo dim_customer.
-- total_orders > 1 -- xem sql/transform/03_mart_upsert.sql). Cờ này
-- giống nhau cho MỌI đơn của cùng 1 customer_unique_id (kể cả đơn đầu
-- tiên của khách sau này mua lại), nên GROUP BY is_repeat_customer cho
-- đúng 2 nhóm khách không chồng lấn.
--
-- LƯU Ý: chỉ khoảng 3,12% khách Olist mua lại (COUNT DISTINCT
-- customer_unique_id của nhóm 'Repeat' rất nhỏ so với 'One-time') --
-- nên khi so sánh 2 nhóm trên Superset, đừng ngạc nhiên nếu revenue/
-- orders của nhóm 'Repeat' nhỏ hơn nhiều dù aov hay avg_orders_per_
-- customer có thể cao hơn.
--
-- Ghi chú quy tắc 2: KHÔNG giữ cột filter chuẩn nào trong 7 cột --
-- customer_type là 1 chiều MỚI, không nằm trong danh sách 7 cột bắt
-- buộc, thay thế hoàn toàn các chiều gốc ở view này.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_customer_summary AS
SELECT
    CASE WHEN is_repeat_customer THEN 'Repeat' ELSE 'One-time' END AS customer_type,
    COUNT(DISTINCT customer_unique_id) AS customers,          -- quy tắc 4
    -- fct_orders grain 1 dòng = 1 đơn (PK order_id), COUNT(*) = số đơn.
    COUNT(*)                           AS orders,
    SUM(order_revenue)                 AS revenue,
    ROUND(SUM(order_revenue) / NULLIF(COUNT(*), 0), 2) AS aov,
    ROUND(AVG(review_score), 2)        AS avg_review_score,
    ROUND(
        COUNT(*) FILTER (WHERE order_status = 'delivered' AND is_late = FALSE)::NUMERIC
        / NULLIF(
            COUNT(*) FILTER (WHERE order_status = 'delivered' AND is_late IS NOT NULL),
            0
          ) * 100,
        2
    ) AS on_time_rate,
    -- Số đơn trung bình / khách. Nhóm 'One-time' luôn ra đúng 1.0000
    -- (mỗi khách 1 đơn) -- dùng làm phép kiểm tra chéo cho logic view.
    ROUND(
        COUNT(*)::NUMERIC / NULLIF(COUNT(DISTINCT customer_unique_id), 0),
        4
    ) AS avg_orders_per_customer
FROM mart.fct_orders
GROUP BY is_repeat_customer
ORDER BY is_repeat_customer;
