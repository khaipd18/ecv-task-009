-- =====================================================================
-- MART VIEWS — PHÂN TÍCH SẢN PHẨM / CATEGORY CHO SUPERSET
-- 3 view: ma trận category x phân khúc giá, hiệu suất category (scatter
-- 4 góc phần tư), và tăng trưởng category theo tháng (MoM).
--
-- Cả 3 view đều CHỈ đọc từ mart.fct_order_items (grain sản phẩm) nên
-- không phát sinh tình huống phải join với mart.fct_orders.
-- Quy tắc 5 (đếm đơn phải COUNT DISTINCT order_id) áp dụng ở cả 3 view.
-- =====================================================================


-- =====================================================================
-- VIEW 1: mart.vw_category_segment
-- Grain: 1 dòng = 1 cặp (category_en, price_segment).
-- Dùng để vẽ heatmap category x phân khúc giá.
--
-- Ghi chú quy tắc 2: giữ được category_en và price_segment (2/7 cột
-- filter chuẩn). 5 cột còn lại (order_purchase_date, customer_state,
-- seller_state, order_status, payment_type_main) bị mất vì view gộp
-- xuyên suốt các chiều đó để ra 1 dòng cho mỗi cặp (category, phân khúc).
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_category_segment AS
SELECT
    category_en,
    price_segment,
    SUM(item_revenue)        AS revenue,
    COUNT(*)                 AS items_sold,            -- mỗi dòng đã là 1 sản phẩm
    COUNT(DISTINCT order_id) AS orders,                -- quy tắc 5: phải DISTINCT
    ROUND(AVG(price), 2)     AS avg_price,
    -- % doanh thu của phân khúc giá này SO VỚI TỔNG DOANH THU CỦA
    -- CHÍNH category đó (PARTITION BY category_en) -- không phải so
    -- với tổng toàn sàn. Đây là điểm khác biệt quan trọng cho heatmap:
    -- mỗi hàng (category) trên heatmap sẽ cộng dồn đúng 100%.
    ROUND(
        SUM(item_revenue) * 100.0
        / SUM(SUM(item_revenue)) OVER (PARTITION BY category_en),
        2
    ) AS pct_within_category
FROM mart.fct_order_items
GROUP BY category_en, price_segment
ORDER BY category_en, price_segment;


-- =====================================================================
-- VIEW 2: mart.vw_category_perf
-- Grain: 1 dòng = 1 category_en.
-- Dùng cho biểu đồ scatter số lượng bán vs giá trung bình, chia 4 góc
-- phần tư theo trung vị (median) để tránh outlier (category quá lớn)
-- kéo lệch mốc phân loại -- dùng median thay vì trung bình (AVG)
-- chính vì lý do này.
--
-- Ghi chú quy tắc 2: chỉ giữ được category_en (1/7 cột filter chuẩn).
-- 6 cột còn lại bị mất vì view gộp toàn bộ ngày/phân khúc/bang/trạng
-- thái/loại thanh toán để ra 1 dòng duy nhất cho mỗi category.
-- =====================================================================
-- DROP trước vì lần sửa này đổi TÊN cột avg_freight_ratio thành
-- freight_share -- CREATE OR REPLACE VIEW không cho đổi tên cột đã
-- tồn tại ở cùng vị trí.
DROP VIEW IF EXISTS mart.vw_category_perf;
CREATE OR REPLACE VIEW mart.vw_category_perf AS
WITH gop_category AS (
    -- Gộp fct_order_items theo category_en. tong_freight và revenue
    -- (đã là SUM) dùng để tính freight_share theo TỶ LỆ CỦA TỔNG bên
    -- dưới, không tính AVG(freight_ratio) từng dòng nữa.
    SELECT
        category_en,
        COUNT(*)                 AS items_sold,
        SUM(item_revenue)        AS revenue,
        ROUND(AVG(price), 2)     AS avg_price,
        COUNT(DISTINCT order_id) AS orders,           -- quy tắc 5
        SUM(freight_value)       AS tong_freight
    FROM mart.fct_order_items
    GROUP BY category_en
),
nguong_median AS (
    -- Đổi 2 trục phân loại từ (items_sold, revenue) sang
    -- (items_sold, avg_price). Lý do: items_sold và revenue tương
    -- quan quá mạnh (category bán nhiều gần như luôn có doanh thu
    -- cao), khiến gần hết category dồn lên đường chéo Core/
    -- Underperform (thực tế đã thấy: 33 Core / 32 Underperform / chỉ
    -- 5 Mass / 4 Premium) -- scatter ra 1 đường thẳng chứ không phải
    -- 4 cụm. avg_price ĐỘC LẬP với số lượng bán nên tách nhóm rõ hơn:
    -- "bán nhiều nhưng giá thấp" (Mass) khác hẳn "bán ít nhưng giá
    -- cao" (Premium). Vẫn dùng PERCENTILE_CONT(0.5) làm mốc, tính
    -- trên tập category (không phải trên từng dòng sản phẩm).
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY items_sold) AS median_items,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_price)  AS median_price
    FROM gop_category
)
SELECT
    gc.category_en,
    gc.items_sold,
    -- Giữ lại revenue để Superset dùng làm KÍCH THƯỚC ĐIỂM (bubble
    -- size) trên scatter, KHÔNG còn dùng để phân loại quadrant nữa.
    gc.revenue,
    gc.avg_price,
    gc.orders,
    -- freight_share = TỶ LỆ CỦA TỔNG: SUM(freight_value) / SUM(item_revenue),
    -- KHÔNG PHẢI trung bình cộng các freight_ratio từng dòng (AVG).
    -- AVG cho món rẻ và món đắt CÙNG trọng số 1 dòng = 1 phiếu, sai
    -- lệch nếu category có nhiều đơn giá trị nhỏ nhưng vài đơn giá
    -- trị lớn (hoặc ngược lại). Tỷ lệ của tổng phản ánh đúng gánh
    -- nặng phí ship thực tế trên toàn bộ doanh thu category.
    ROUND(gc.tong_freight * 100.0 / NULLIF(gc.revenue, 0), 2) AS freight_share,
    -- So sánh từng category với 2 mốc median (items_sold, avg_price)
    -- để xếp vào 4 nhóm:
    --   Core          = bán nhiều  VÀ giá cao   (>= median cả 2 trục)
    --   Mass          = bán nhiều  VÀ giá thấp  (hàng phổ thông, số lượng lớn)
    --   Premium       = bán ít     VÀ giá cao   (hàng cao cấp, ít nhưng đắt)
    --   Underperform  = bán ít     VÀ giá thấp  (nhóm cần xem lại)
    CASE
        WHEN gc.items_sold >= nm.median_items AND gc.avg_price >= nm.median_price THEN 'Core'
        WHEN gc.items_sold >= nm.median_items AND gc.avg_price <  nm.median_price THEN 'Mass'
        WHEN gc.items_sold <  nm.median_items AND gc.avg_price >= nm.median_price THEN 'Premium'
        ELSE 'Underperform'
    END AS quadrant
FROM gop_category gc
CROSS JOIN nguong_median nm   -- nguong_median chỉ có 1 dòng nên CROSS JOIN an toàn, không nhân dòng
ORDER BY gc.revenue DESC;


-- =====================================================================
-- VIEW 3: mart.vw_category_growth
-- Grain: 1 dòng = 1 cặp (category_en, order_month).
-- Tính tăng trưởng doanh thu tháng-so-tháng (MoM) cho từng category.
--
-- QUAN TRỌNG: chỉ lấy dữ liệu từ 2017-01-01 trở đi. Dữ liệu năm 2016
-- quá thưa (có tháng cả sàn chỉ 1 đơn), nếu tính MoM trên nền đó thì
-- % tăng trưởng sẽ bị bóp méo hoàn toàn (ví dụ từ 1 đơn lên 5 đơn ra
-- +400% nhưng vô nghĩa về mặt kinh doanh). Chỉ làm MoM, KHÔNG làm YoY
-- theo đúng yêu cầu.
--
-- Về vấn đề LAG nhảy cóc tháng (đã nêu ở lần trước): KHÔNG sinh thêm
-- khung tháng đầy đủ (generate_series), vì tháng trống sẽ cho
-- revenue_prev_month = 0 và ra % tăng trưởng vô cực. Thay vào đó, chỉ
-- giữ lại các dòng (category, tháng) có orders >= 20 -- category/tháng
-- có quá ít đơn thì % tăng trưởng vốn không có ý nghĩa thống kê (biến
-- động vài đơn cũng ra % rất lớn). Hệ quả: LAG() có thể lấy đúng
-- "tháng liền trước CÒN LẠI sau khi lọc", không nhất thiết là tháng
-- liền kề theo lịch -- đây là đánh đổi có chủ đích, ưu tiên không tạo
-- ra tăng trưởng giả tạo từ nền quá nhỏ.
--
-- Ghi chú quy tắc 2: giữ được category_en; order_purchase_date bị thay
-- bằng order_month (gộp thô hơn, mất chi tiết theo ngày) vì bản chất
-- view là phân tích XU HƯỚNG THEO THÁNG. 4 cột còn lại (price_segment,
-- customer_state, seller_state, order_status, payment_type_main) bị
-- mất vì gộp xuyên suốt các chiều đó.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_category_growth AS
WITH gop_thang AS (
    -- Gộp fct_order_items theo (category_en, tháng), chỉ tính từ
    -- 2017-01-01 trở đi như yêu cầu.
    SELECT
        category_en,
        DATE_TRUNC('month', order_purchase_date)::DATE AS order_month,
        SUM(item_revenue)        AS revenue,
        COUNT(DISTINCT order_id) AS orders          -- quy tắc 5
    FROM mart.fct_order_items
    WHERE order_purchase_date >= DATE '2017-01-01'
    GROUP BY category_en, DATE_TRUNC('month', order_purchase_date)
),
gop_thang_du_lon AS (
    -- Chỉ giữ (category, tháng) có orders >= 20 -- xem giải thích lựa
    -- chọn này ở comment đầu view. Không dùng HAVING ngay trong
    -- gop_thang vì HAVING không nhìn thấy alias "orders" của SELECT
    -- cùng cấp, nên lọc ở CTE riêng cho rõ ràng.
    SELECT * FROM gop_thang WHERE orders >= 20
),
voi_thang_truoc AS (
    -- LAG lấy doanh thu tháng liền trước CỦA CÙNG category (trong tập
    -- ĐÃ LỌC orders >= 20), dựa trên PARTITION BY category_en để
    -- không lấy nhầm doanh thu tháng trước của category khác.
    SELECT
        category_en,
        order_month,
        revenue,
        orders,
        LAG(revenue) OVER (
            PARTITION BY category_en ORDER BY order_month
        ) AS revenue_prev_month
    FROM gop_thang_du_lon
)
SELECT
    category_en,
    order_month,
    revenue,
    orders,
    revenue_prev_month,
    -- % tăng trưởng = (tháng này - tháng trước) / tháng trước.
    -- Tháng đầu tiên của mỗi category không có tháng trước nên
    -- revenue_prev_month NULL -> NULLIF/chia NULL tự động ra NULL,
    -- không lỗi, Superset hiển thị trống là đúng bản chất (chưa đủ
    -- dữ liệu để so sánh).
    ROUND(
        (revenue - revenue_prev_month) * 100.0 / NULLIF(revenue_prev_month, 0),
        2
    ) AS mom_growth_pct
FROM voi_thang_truoc
ORDER BY category_en, order_month;
