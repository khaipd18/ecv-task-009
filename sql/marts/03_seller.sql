-- =====================================================================
-- MART VIEWS — SELLER SCORECARD VÀ MỨC ĐỘ TẬP TRUNG DOANH THU
-- 2 view: xếp hạng/phân nhóm seller (đã lọc seller quá nhỏ), và
-- đường cong tập trung doanh thu kiểu Lorenz (KHÔNG lọc, tính trên
-- toàn bộ seller).
--
-- Nhắc lại quy tắc 1 (bản đã đính chính): fct_orders có ĐÚNG 1 dòng /
-- order_id (PK), nên JOIN nó theo order_id (kể cả từ 1 tập NHIỀU cặp
-- seller-order) là quan hệ NHIỀU-MỘT, an toàn để lấy các cột NHÃN
-- (review_score, is_late, delivery_days) rồi AVG/COUNT theo seller.
-- CẤM là SUM cột số của fct_orders (vd payment_value) sau khi join --
-- không view nào trong file này làm việc đó.
-- Quy tắc 3 (delivery chỉ tính khi delivered), quy tắc 4 (đếm khách
-- DISTINCT customer_unique_id), quy tắc 5 (đếm đơn DISTINCT order_id)
-- vẫn áp dụng đầy đủ.
-- =====================================================================


-- =====================================================================
-- VIEW 1: mart.vw_seller_scorecard
-- Grain: 1 dòng = 1 seller.
--
-- BẮT BUỘC: chỉ đưa vào view các seller có >= 20 đơn hàng (lọc bằng
-- HAVING trong CTE gộp bên dưới). Lý do: seller chỉ có 1-2 đơn mà bị
-- trễ cả 2 sẽ ra on_time_rate = 0% (hoặc chỉ 1 đơn trễ ra 100% trễ),
-- những con số cực đoan này sẽ đẩy seller đó leo lên đầu hoặc đáy
-- bảng xếp hạng dù mẫu quá nhỏ để kết luận bất cứ điều gì -- làm sai
-- lệch toàn bộ scorecard nếu không loại trừ ngay từ đầu.
--
-- Ghi chú quy tắc 2: giữ được seller_state (1/7 cột filter chuẩn,
-- cộng thêm seller_city ngoài danh sách bắt buộc). 6 cột còn lại
-- (order_purchase_date, category_en, price_segment, customer_state,
-- order_status, payment_type_main) bị mất vì view gộp xuyên suốt các
-- chiều đó để ra 1 dòng cho mỗi seller.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_seller_scorecard AS
WITH gop_item_seller AS (
    -- Gộp fct_order_items theo seller_id -- nguồn doanh thu, số đơn,
    -- số sản phẩm. HAVING lọc >= 20 đơn NGAY TẠI ĐÂY, nghĩa là seller
    -- nhỏ bị loại khỏi TOÀN BỘ view (kể cả seller_state/seller_city),
    -- không chỉ ẩn ở bước tính segment.
    SELECT
        seller_id,
        SUM(item_revenue)        AS revenue,
        COUNT(DISTINCT order_id) AS orders,      -- quy tắc 5: đếm đơn phải DISTINCT
        COUNT(*)                 AS items_sold
    FROM mart.fct_order_items
    GROUP BY seller_id
    HAVING COUNT(DISTINCT order_id) >= 20
),
seller_order_map AS (
    -- Danh sách CẶP (seller_id, order_id) DUY NHẤT. Một seller có thể
    -- có nhiều dòng sản phẩm trong CÙNG 1 đơn -- phải DISTINCT để mỗi
    -- đơn chỉ được tính 1 lần khi gộp review/delivery ở CTE kế tiếp,
    -- nếu không đơn có 3 sản phẩm của cùng 1 seller sẽ bị đếm 3 lần,
    -- làm on_time_rate và avg_review_score lệch có trọng số sai.
    SELECT DISTINCT seller_id, order_id
    FROM mart.fct_order_items
),
gop_order_seller AS (
    -- Đây là CTE "lấy từ fct_orders" theo đúng yêu cầu của mentor --
    -- KHÔNG join trực tiếp fct_orders vào truy vấn chính bên dưới.
    -- JOIN ở đây là NHIỀU (cặp seller-order) - MỘT (fct_orders theo
    -- order_id, PK) -- an toàn theo quy tắc 1 đã đính chính: không
    -- SUM cột số nào của fct_orders, chỉ AVG/COUNT các cột NHÃN
    -- (review_score, is_late, delivery_days) để ra chỉ số PER SELLER.
    -- on_time_rate và avg_delivery_days chỉ tính trên đơn delivered
    -- (quy tắc 3); đơn chưa delivered có is_late/delivery_days = NULL
    -- nên tự động bị loại khỏi cả tử và mẫu qua FILTER.
    SELECT
        m.seller_id,
        AVG(fo.review_score) AS avg_review_score,
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
    FROM seller_order_map m
    JOIN mart.fct_orders fo ON fo.order_id = m.order_id
    GROUP BY m.seller_id
),
tong_doanh_thu_toan_san AS (
    -- Tổng doanh thu TOÀN SÀN, tính trên TOÀN BỘ fct_order_items
    -- (KHÔNG áp ngưỡng >= 20 đơn), vì "% doanh thu toàn sàn" phải so
    -- với tổng thật của cả platform, không phải tổng riêng của nhóm
    -- seller đã lọc trong view này -- nếu lấy SUM(revenue) OVER() trên
    -- tập đã lọc thì % sẽ bị thổi phồng so với thực tế.
    SELECT SUM(item_revenue) AS tong_doanh_thu FROM mart.fct_order_items
),
nguong_median AS (
    -- Median doanh thu tính trên TẬP SELLER ĐÃ LỌC (>= 20 đơn) -- đây
    -- chính là dân số thực tế của view này, nên lấy median của dân số
    -- này làm mốc "trên/dưới trung vị" cho segment là hợp lý nhất.
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY revenue) AS median_revenue
    FROM gop_item_seller
)
SELECT
    gi.seller_id,
    ds.seller_state,
    ds.seller_city,
    gi.revenue,
    gi.orders,
    gi.items_sold,
    ROUND(gi.revenue / NULLIF(gi.orders, 0), 2)      AS aov,
    ROUND(gi.revenue * 100.0 / tt.tong_doanh_thu, 2) AS pct_of_total,
    ROUND(gos.avg_review_score, 2)                   AS avg_review_score,
    ROUND(gos.on_time_rate * 100, 2)                 AS on_time_rate,
    ROUND(gos.avg_delivery_days, 2)                  AS avg_delivery_days,
    -- Phân 4 nhóm dựa trên median doanh thu (của tập seller >= 20 đơn)
    -- + review + on_time_rate. Thứ tự WHEN có chủ đích: nhánh 2
    -- "Risky" bắt hết các trường hợp doanh thu trên trung vị NHƯNG
    -- KHÔNG đạt đủ 2 điều kiện review>=4 và on_time>=90%. Nếu
    -- avg_review_score hoặc on_time_rate là NULL (seller chưa có
    -- review, hoặc chưa có đơn nào delivered) thì so sánh NULL >= x
    -- luôn ra NULL/false, nên seller đó tự động KHÔNG được xếp Star
    -- hay Emerging -- đúng tinh thần "chưa đủ bằng chứng thì không
    -- xếp hạng cao".
    CASE
        WHEN gi.revenue > nm.median_revenue
             AND gos.avg_review_score >= 4
             AND gos.on_time_rate >= 0.90
            THEN 'Star'
        WHEN gi.revenue > nm.median_revenue
            THEN 'Risky'
        WHEN gi.revenue <= nm.median_revenue
             AND gos.avg_review_score >= 4
            THEN 'Emerging'
        ELSE 'Underperform'
    END AS segment
FROM gop_item_seller gi
LEFT JOIN mart.dim_seller ds   ON ds.seller_id = gi.seller_id
LEFT JOIN gop_order_seller gos ON gos.seller_id = gi.seller_id
CROSS JOIN tong_doanh_thu_toan_san tt
CROSS JOIN nguong_median nm
ORDER BY gi.revenue DESC;


-- =====================================================================
-- VIEW 2: mart.vw_seller_concentration
-- Grain: 1 dòng = 1 seller, xếp hạng theo doanh thu giảm dần.
-- Dùng cho biểu đồ đường cong tập trung doanh thu (kiểu Lorenz curve).
--
-- View này KHÔNG áp ngưỡng >= 20 đơn -- tính trên TOÀN BỘ seller có
-- trong mart.dim_seller (3.095 seller), kể cả seller doanh thu = 0
-- (seller chỉ có đơn bị huỷ/không khả dụng nên không còn dòng nào ở
-- fct_order_items). Nếu bỏ sót nhóm seller doanh thu 0 thì con số %
-- tập trung sẽ bị tính sai (mẫu số số seller bị hụt).
--
-- Ghi chú quy tắc 2: view này KHÔNG giữ cột filter chuẩn nào (kể cả
-- seller_state) vì mục đích duy nhất là vẽ đường cong tập trung theo
-- seller_id/revenue -- không phải view để lọc theo 7 chiều chuẩn.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_seller_concentration AS
WITH gop_item_seller AS (
    SELECT
        seller_id,
        SUM(item_revenue) AS revenue
    FROM mart.fct_order_items
    GROUP BY seller_id
),
tat_ca_seller AS (
    -- LEFT JOIN từ dim_seller (toàn bộ 3.095 seller) sang doanh thu đã
    -- gộp, COALESCE về 0 cho seller không có dòng nào ở fct_order_items.
    SELECT
        ds.seller_id,
        COALESCE(gi.revenue, 0) AS revenue
    FROM mart.dim_seller ds
    LEFT JOIN gop_item_seller gi ON gi.seller_id = ds.seller_id
),
xep_hang AS (
    SELECT
        seller_id,
        revenue,
        -- rank_revenue dùng RANK() để hiển thị hạng đúng nghĩa (đồng
        -- doanh thu thì đồng hạng).
        RANK() OVER (ORDER BY revenue DESC) AS rank_revenue,
        -- thu_tu dùng ROW_NUMBER() RIÊNG cho việc tính % số seller
        -- tích luỹ bên dưới -- không dùng rank_revenue vì RANK() nhảy
        -- số khi đồng hạng (ví dụ 5 seller đồng hạng 10 thì hạng tiếp
        -- theo là 15), sẽ làm pct_sellers_cumulative sai lệch.
        ROW_NUMBER() OVER (ORDER BY revenue DESC) AS thu_tu
    FROM tat_ca_seller
)
SELECT
    seller_id,
    revenue,
    rank_revenue,
    ROUND(thu_tu * 100.0 / COUNT(*) OVER (), 4) AS pct_sellers_cumulative,
    ROUND(
        SUM(revenue) OVER (
            ORDER BY thu_tu
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) * 100.0 / SUM(revenue) OVER (),
        4
    ) AS pct_revenue_cumulative
FROM xep_hang
ORDER BY thu_tu;


-- =====================================================================
-- CÂU SQL RIÊNG (KHÔNG PHẢI VIEW): 3 con số mức độ tập trung doanh thu
-- Lấy điểm cắt gần nhất tại pct_sellers_cumulative <= X% rồi đọc
-- pct_revenue_cumulative tương ứng từ mart.vw_seller_concentration.
-- =====================================================================
WITH moc_cat AS (
    SELECT
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 10) AS doanh_thu_top10,
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 20) AS doanh_thu_top20,
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 50) AS doanh_thu_top50
    FROM mart.vw_seller_concentration
)
SELECT
    ROUND(doanh_thu_top10, 2)        AS pct_doanh_thu_top_10pct_seller,
    ROUND(doanh_thu_top20, 2)        AS pct_doanh_thu_top_20pct_seller,
    -- Nhóm 50% cuối = phần còn lại sau khi trừ đi doanh thu của 50%
    -- seller đứng đầu.
    ROUND(100 - doanh_thu_top50, 2)  AS pct_doanh_thu_50pct_cuoi
FROM moc_cat;
