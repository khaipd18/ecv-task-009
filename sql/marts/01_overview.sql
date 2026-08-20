-- =====================================================================
-- MART VIEWS — TỔNG QUAN CHO SUPERSET
-- 4 view phục vụ dashboard tổng quan: KPI theo ngày, đóng góp theo
-- category, doanh thu theo bang, và view chi tiết để drill-down.
--
-- Nhắc lại quy tắc bắt buộc đang áp dụng ở toàn bộ file này:
--   1) ĐÍNH CHÍNH: fct_orders có ĐÚNG 1 dòng / order_id (PRIMARY KEY),
--      nên LEFT JOIN nó vào fct_order_items theo order_id là quan hệ
--      NHIỀU-MỘT, không fan-out, không nhân dòng -- lấy các cột NHÃN
--      (payment_type_main, review_score, is_late...) để filter/group
--      hoàn toàn an toàn. Điều CẤM thật sự là: SUM (hay bất kỳ hàm
--      tổng hợp nào) trên một cột SỐ của fct_orders (vd payment_value)
--      SAU KHI đã join xuống grain sản phẩm -- giá trị đó bị lặp lại
--      trên mỗi dòng sản phẩm của đơn, SUM lên sẽ nhân sai theo số
--      sản phẩm. Khi cần cộng dồn số liệu ở grain đơn, phải gộp riêng
--      fct_orders về đúng grain đó TRƯỚC (như 2 CTE dưới đây), không
--      gộp sau khi đã join xuống grain sản phẩm.
--   2) Mỗi view phải nói rõ trong 7 cột filter chuẩn
--      (order_purchase_date, category_en, price_segment, customer_state,
--      seller_state, order_status, payment_type_main) thì giữ được cột
--      nào, mất cột nào và vì sao.
--   3) delivery_days / delay_days / is_late chỉ tính khi order_status
--      = 'delivered'.
--   4) Đếm khách phải COUNT(DISTINCT customer_unique_id).
--   5) Đếm đơn trong fct_order_items phải COUNT(DISTINCT order_id).
--   6) CREATE OR REPLACE VIEW thường, không dùng materialized view.
-- =====================================================================


-- =====================================================================
-- VIEW 1: mart.vw_daily_kpi
-- Grain: 1 dòng = 1 ngày mua hàng (order_purchase_date).
--
-- Ghi chú quy tắc 2: view này CHỈ giữ được order_purchase_date trong
-- 7 cột filter chuẩn. 6 cột còn lại (category_en, price_segment,
-- customer_state, seller_state, order_status, payment_type_main) bị
-- mất, vì đây là view KPI tổng toàn sàn theo ngày -- gộp xuyên suốt
-- mọi category/bang/trạng thái theo đúng mục đích của nó (theo dõi
-- xu hướng chung). Muốn filter theo các chiều đó, dùng
-- mart.vw_detail_items hoặc các view chuyên biệt khác.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_daily_kpi AS
WITH gop_item_ngay AS (
    -- Gộp fct_order_items (grain sản phẩm) về grain ngày.
    -- Đây là nguồn duy nhất đáng tin cậy cho doanh thu và số sản phẩm,
    -- vì fct_orders không có price/freight_value ở mức chi tiết.
    -- orders phải COUNT DISTINCT order_id vì 1 đơn có thể nhiều dòng
    -- sản phẩm (quy tắc 5); customers phải COUNT DISTINCT
    -- customer_unique_id để không đếm trùng khách mua nhiều lần
    -- trong cùng 1 ngày (quy tắc 4).
    SELECT
        order_purchase_date,
        SUM(item_revenue)                  AS revenue,
        SUM(price)                         AS product_revenue,
        SUM(freight_value)                 AS freight_revenue,
        COUNT(DISTINCT order_id)           AS orders,
        COUNT(DISTINCT customer_unique_id) AS customers,
        COUNT(*)                           AS items_sold  -- mỗi dòng của bảng này đã là 1 sản phẩm, đếm dòng là đúng
    FROM mart.fct_order_items
    GROUP BY order_purchase_date
),
gop_order_ngay AS (
    -- Gộp fct_orders (grain đơn) về grain ngày, lấy 2 chỉ số CHỈ có
    -- ở mức đơn: điểm đánh giá trung bình và tỷ lệ giao đúng hạn.
    -- on_time_rate dùng FILTER để mẫu số chỉ tính đơn đã delivered
    -- (đúng quy tắc 3) -- đơn đang xử lý/đang giao chưa có is_late
    -- (NULL) nên bị loại khỏi cả tử lẫn mẫu, không làm sai lệch tỷ lệ.
    SELECT
        order_purchase_date,
        AVG(review_score) AS avg_review_score,
        COUNT(*) FILTER (
            WHERE order_status = 'delivered' AND is_late = FALSE
        )::NUMERIC
        / NULLIF(
            COUNT(*) FILTER (
                WHERE order_status = 'delivered' AND is_late IS NOT NULL
            ),
            0
          ) AS on_time_rate
    FROM mart.fct_orders
    GROUP BY order_purchase_date
)
-- FULL JOIN 2 bảng ĐÃ GỘP theo ngày (đúng quy tắc 1: không join 2 bảng
-- fact gốc, mà join 2 kết quả GROUP BY cùng grain "ngày" với nhau).
-- Dùng FULL JOIN chứ không INNER JOIN để phòng trường hợp hiếm gặp
-- có ngày chỉ xuất hiện ở 1 trong 2 bảng thì vẫn không mất dòng.
SELECT
    COALESCE(gi.order_purchase_date, go.order_purchase_date) AS order_purchase_date,
    COALESCE(gi.revenue, 0)                                   AS revenue,
    COALESCE(gi.product_revenue, 0)                           AS product_revenue,
    COALESCE(gi.freight_revenue, 0)                           AS freight_revenue,
    COALESCE(gi.orders, 0)                                    AS orders,
    COALESCE(gi.customers, 0)                                 AS customers,
    -- AOV = doanh thu / số đơn. Nếu ngày đó không có đơn (gi.orders
    -- NULL hoặc 0) thì NULLIF trả NULL, tránh lỗi chia cho 0.
    ROUND(gi.revenue / NULLIF(gi.orders, 0), 2)                AS aov,
    COALESCE(gi.items_sold, 0)                                AS items_sold,
    ROUND(go.avg_review_score, 2)                             AS avg_review_score,
    -- Đổi từ tỷ lệ (0..1) sang phần trăm cho dễ đọc trên Superset.
    ROUND(go.on_time_rate * 100, 2)                           AS on_time_rate
FROM gop_item_ngay gi
FULL JOIN gop_order_ngay go
       ON go.order_purchase_date = gi.order_purchase_date
ORDER BY order_purchase_date;


-- =====================================================================
-- VIEW 2: mart.vw_category_contribution
-- Grain: 1 dòng = 1 category_en. Dùng cho biểu đồ Pareto (80/20).
--
-- Ghi chú quy tắc 2: chỉ giữ được category_en (và category_pt đại
-- diện) trong 7 cột filter chuẩn. 5 cột còn lại (order_purchase_date,
-- price_segment, customer_state, seller_state, payment_type_main) bị
-- mất vì view gộp xuyên suốt mọi ngày/bang/phân khúc để ra 1 dòng
-- duy nhất cho mỗi category. order_status cũng không còn là cột filter
-- được nữa (đã gộp), nhưng dữ liệu vẫn chỉ tính trên đơn không bị
-- huỷ/không khả dụng vì fct_order_items đã lọc sẵn từ lúc nạp mart.
-- =====================================================================
-- DROP trước vì lần sửa này chèn thêm category_display vào GIỮA danh
-- sách cột (trước revenue) -- CREATE OR REPLACE VIEW không cho đổi
-- tên/thứ tự các cột đã tồn tại, chỉ cho thêm cột mới vào CUỐI.
DROP VIEW IF EXISTS mart.vw_category_contribution;
CREATE OR REPLACE VIEW mart.vw_category_contribution AS
WITH gop_category AS (
    -- Gộp theo category_en. category_pt có thể có nhiều biến thể ứng
    -- với cùng 1 category_en (ví dụ do thiếu bản dịch nên category_pt
    -- được giữ nguyên làm category_en luôn), nên KHÔNG group theo
    -- category_pt kẻo vỡ grain "1 dòng = 1 category". Lấy MIN() chỉ
    -- để có 1 giá trị category_pt đại diện cho hiển thị.
    SELECT
        category_en,
        MIN(category_pt)         AS category_pt,
        SUM(item_revenue)        AS revenue,
        COUNT(DISTINCT order_id) AS orders,  -- quy tắc 5: đếm đơn phải DISTINCT
        COUNT(*)                 AS items_sold
    FROM mart.fct_order_items
    GROUP BY category_en
),
xep_hang AS (
    -- Tính rank_revenue trước ở CTE riêng vì Postgres không cho phép
    -- một cột trong SELECT tham chiếu bí danh (alias) của cột window
    -- function khác cùng cấp -- phải tách lớp mới dùng lại được
    -- rank_revenue để suy ra category_display bên dưới.
    SELECT
        category_en,
        category_pt,
        revenue,
        orders,
        items_sold,
        ROUND(revenue / NULLIF(orders, 0), 2) AS aov,
        -- % doanh thu của category này trên tổng doanh thu toàn sàn.
        ROUND(revenue * 100.0 / SUM(revenue) OVER (), 2) AS pct_of_total,
        -- % tích luỹ khi xếp category theo doanh thu giảm dần -- đây là
        -- cột chính để vẽ đường Pareto (trục line cộng dồn tới 100%).
        ROUND(
            SUM(revenue) OVER (
                ORDER BY revenue DESC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) * 100.0 / SUM(revenue) OVER (),
            2
        ) AS pct_cumulative,
        -- Thứ hạng theo doanh thu, dùng RANK() để category đồng doanh
        -- thu (nếu có) nhận cùng 1 hạng thay vì hạng liên tiếp giả tạo.
        RANK() OVER (ORDER BY revenue DESC) AS rank_revenue
    FROM gop_category
)
SELECT
    category_en,
    category_pt,
    -- Có 74 category, vẽ Pareto 74 cột thì trục X không đọc được.
    -- category_display CHỈ là nhãn hiển thị: giữ tên riêng cho 15
    -- category doanh thu cao nhất, các category còn lại gộp nhãn
    -- 'Others'. KHÔNG gộp dòng dữ liệu -- view vẫn giữ đủ 74 dòng gốc,
    -- Superset có thể dùng category_en (cột gốc) để lọc/drill xuống
    -- từng category thật khi cần, chỉ trục hiển thị dùng
    -- category_display cho gọn.
    CASE WHEN rank_revenue <= 15 THEN category_en ELSE 'Others' END AS category_display,
    revenue,
    orders,
    items_sold,
    aov,
    pct_of_total,
    pct_cumulative,
    rank_revenue
FROM xep_hang
ORDER BY revenue DESC;


-- =====================================================================
-- VIEW 3: mart.vw_state_revenue
-- Grain: 1 dòng = 1 customer_state (bang của KHÁCH HÀNG, không phải
-- bang người bán).
--
-- Ghi chú quy tắc 2: chỉ giữ được customer_state trong 7 cột filter
-- chuẩn. 5 cột còn lại (order_purchase_date, category_en,
-- price_segment, seller_state, payment_type_main) bị mất vì view gộp
-- xuyên suốt các chiều đó để ra 1 dòng cho mỗi bang khách hàng.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_state_revenue AS
WITH gop_item_bang AS (
    -- Gộp fct_order_items theo customer_state -- nguồn của doanh thu,
    -- số đơn, số khách (các số liệu chỉ có ở grain sản phẩm).
    SELECT
        customer_state,
        SUM(item_revenue)                  AS revenue,
        COUNT(DISTINCT order_id)           AS orders,           -- quy tắc 5
        COUNT(DISTINCT customer_unique_id) AS customers         -- quy tắc 4
    FROM mart.fct_order_items
    GROUP BY customer_state
),
gop_order_bang AS (
    -- Gộp fct_orders theo customer_state để lấy chỉ số giao hàng.
    -- fct_orders KHÔNG có sẵn cột customer_state (bảng grain đơn
    -- không lưu chiều địa lý), nên phải JOIN sang mart.dim_customer
    -- qua customer_unique_id để lấy state -- đây là join fact-dimension
    -- bình thường (1 fact - 1 chiều), KHÔNG phải join 2 bảng fact với
    -- nhau nên KHÔNG vi phạm quy tắc 1.
    -- avg_delivery_days và on_time_rate chỉ tính trên đơn delivered
    -- (quy tắc 3).
    SELECT
        dc.customer_state,
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
    FROM mart.fct_orders fo
    JOIN mart.dim_customer dc ON dc.customer_unique_id = fo.customer_unique_id
    GROUP BY dc.customer_state
)
-- FULL JOIN 2 kết quả GROUP BY đã cùng về grain "bang" -- vẫn đúng
-- quy tắc 1 vì không có bảng fact gốc nào được join trực tiếp.
SELECT
    COALESCE(gi.customer_state, go.customer_state) AS customer_state,
    COALESCE(gi.revenue, 0)                        AS revenue,
    COALESCE(gi.orders, 0)                         AS orders,
    COALESCE(gi.customers, 0)                      AS customers,
    ROUND(gi.revenue / NULLIF(gi.orders, 0), 2)     AS aov,
    ROUND(gi.revenue * 100.0 / SUM(gi.revenue) OVER (), 2) AS pct_of_total,
    ROUND(go.avg_delivery_days, 2)                 AS avg_delivery_days,
    ROUND(go.on_time_rate * 100, 2)                AS on_time_rate
FROM gop_item_bang gi
FULL JOIN gop_order_bang go
       ON go.customer_state = gi.customer_state
ORDER BY revenue DESC NULLS LAST;


-- =====================================================================
-- VIEW 4: mart.vw_detail_items
-- Grain: 1 dòng = 1 sản phẩm trong 1 đơn (giữ nguyên grain của
-- fct_order_items). Dùng cho drill-to-detail và các chart cần filter
-- linh hoạt trên Superset.
--
-- Ghi chú quy tắc 2: sau khi thêm payment_type_main qua LEFT JOIN
-- (xem bên dưới), view này giữ ĐỦ 7/7 cột filter chuẩn.
--
-- Cách lấy payment_type_main (và review_score, is_late, delivery_days)
-- từ mart.fct_orders: LEFT JOIN theo order_id. AN TOÀN vì fct_orders
-- có ĐÚNG 1 dòng / order_id (PRIMARY KEY) -- quan hệ NHIỀU (dòng sản
-- phẩm) - MỘT (dòng đơn), không fan-out, không nhân dòng, không làm
-- sai items_sold/orders/revenue của view này.
-- CẢNH BÁO BẮT BUỘC: đây là các cột NHÃN dùng để filter/group. TUYỆT
-- ĐỐI KHÔNG được SUM(payment_value) hay SUM bất kỳ cột số nào của
-- fct_orders ở view này -- 1 giá trị payment_value của 1 đơn sẽ bị
-- lặp lại trên mỗi dòng sản phẩm của đơn đó, SUM lên sẽ nhân sai theo
-- số sản phẩm trong đơn. Muốn cộng dồn payment_value, dùng
-- mart.fct_orders hoặc mart.vw_daily_kpi (đã gộp đúng grain đơn).
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_detail_items AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    i.seller_id,
    i.customer_id,
    i.customer_unique_id,
    i.order_purchase_timestamp,
    i.order_purchase_date,
    -- Cột tháng để Superset group nhanh theo tháng mà không cần
    -- date_trunc lại mỗi lần query.
    DATE_TRUNC('month', i.order_purchase_date)::DATE AS order_month,
    i.price,
    i.freight_value,
    i.item_revenue,
    i.order_status,
    i.category_pt,
    i.category_en,
    i.customer_state,
    i.customer_city,
    i.seller_state,
    i.seller_city,
    i.price_segment,
    i.is_cross_state,
    i.freight_ratio,
    -- 4 cột NHÃN lấy thêm từ fct_orders qua LEFT JOIN nhiều-một theo
    -- order_id (xem giải thích an toàn ở comment phía trên view).
    o.payment_type_main,
    o.review_score,
    o.is_late,
    o.delivery_days
FROM mart.fct_order_items i
LEFT JOIN mart.fct_orders o ON o.order_id = i.order_id;
