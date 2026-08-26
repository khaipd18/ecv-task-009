-- =====================================================================
-- MART VIEWS — CHẤT LƯỢNG DỮ LIỆU / VẬN HÀNH PIPELINE
-- 3 view đọc từ ops.load_audit và ops.rejected_rows -- evidence cho
-- phần vận hành, KHÔNG phải dữ liệu nghiệp vụ (revenue/customer...).
--
-- LƯU Ý VỀ CÁCH ĐẶT TÊN (áp dụng cho toàn bộ file này): tỷ lệ
-- rows_dup/rows_rejected khác nhau giữa các batch là do MỖI BATCH
-- ĐƯỢC THIẾT KẾ CÓ CHỦ ĐÍCH với 1 loại lỗi khác nhau để kiểm thử từng
-- cơ chế xử lý của pipeline (xem scripts/generate_batch.py): batch 1
-- sạch, batch 2 có dòng trùng, batch 3 có lỗi định dạng, batch 4 hỗn
-- hợp cả hai. Đây KHÔNG phải bằng chứng "pipeline tốt dần lên" hay
-- "chất lượng dữ liệu cải thiện theo thời gian" -- tên cột và comment
-- trong file này được viết trung tính, chỉ mô tả SỐ ĐO, không diễn
-- giải xu hướng.
-- =====================================================================


-- =====================================================================
-- VIEW 1: mart.vw_batch_summary
-- Grain: 1 dòng = 1 batch. Gộp 4 dòng (1 dòng/bảng) của mỗi batch
-- trong ops.load_audit thành 1 dòng tổng cho cả batch đó.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_batch_summary AS
SELECT
    batch_id,
    -- ops.load_audit ghi 1 run_time riêng cho từng bảng (4 dòng/batch),
    -- lấy MAX() làm mốc thời điểm batch này chạy XONG (dòng audit cuối
    -- cùng được ghi trong batch).
    MAX(run_time)         AS run_time,
    SUM(rows_in)          AS rows_in,
    SUM(rows_dup)         AS rows_dup,
    SUM(rows_rejected)    AS rows_rejected,
    SUM(rows_loaded)      AS rows_loaded,
    -- quality_score = % dòng đầu vào thực sự vào được staging, tính
    -- trên TỔNG của cả batch (cộng cả 4 bảng), không phải trung bình
    -- cộng của 4 tỷ lệ riêng lẻ -- tránh sai lệch khi các bảng có số
    -- dòng chênh lệch lớn (vd raw_orders ít dòng hơn raw_order_items).
    ROUND(SUM(rows_loaded) * 100.0 / NULLIF(SUM(rows_in), 0), 2) AS quality_score
FROM ops.load_audit
GROUP BY batch_id
ORDER BY batch_id;


-- =====================================================================
-- VIEW 2: mart.vw_reject_summary
-- Grain thực tế: 1 dòng = 1 bộ ba (batch_id, source_table,
-- reject_reason) -- KHÔNG PHẢI chỉ (batch_id, reject_reason) như tên
-- gọi ngắn gọn ban đầu. Lý do bắt buộc phải thêm source_table vào
-- GROUP BY: cùng 1 chuỗi reject_reason được TÁI SỬ DỤNG ở nhiều bảng
-- khác nhau trong sql/transform/02_stg_orders.sql (ví dụ
-- 'khong tim thay don hang cha' xuất hiện ở CẢ raw_order_items,
-- raw_order_payments VÀ raw_order_reviews). Nếu chỉ group theo
-- (batch_id, reject_reason) thì so_dong của 3 bảng đó sẽ bị CỘNG CHUNG
-- vào 1 dòng, còn cột source_table (vẫn có trong yêu cầu) sẽ không
-- còn ý nghĩa 1-1 với dòng dữ liệu -- vi phạm nguyên tắc "không âm
-- thầm gộp mất thông tin" đã áp dụng xuyên suốt các file view trước.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_reject_summary AS
SELECT
    batch_id,
    source_table,
    reject_reason,
    COUNT(*) AS so_dong
FROM ops.rejected_rows
GROUP BY batch_id, source_table, reject_reason
ORDER BY batch_id, source_table, so_dong DESC;


-- =====================================================================
-- VIEW 3: mart.vw_pipeline_health
-- Một dòng duy nhất, tổng hợp toàn bộ lịch sử ops.load_audit.
--
-- Viết dạng SELECT tổng hợp (aggregate) KHÔNG GROUP BY để LUÔN trả về
-- đúng 1 dòng, kể cả khi ops.load_audit đang RỖNG (lúc đó các số đếm
-- ra 0/NULL thay vì view trả về 0 dòng) -- quan trọng vì Superset cần
-- 1 dòng ổn định để vẽ KPI card, không được để trống bảng.
-- =====================================================================
CREATE OR REPLACE VIEW mart.vw_pipeline_health AS
SELECT
    COUNT(DISTINCT batch_id) AS so_batch_da_chay,
    SUM(rows_loaded)         AS tong_dong_da_nap,
    -- tong_dong_bi_loai = tổng rows_rejected (dòng bị đẩy sang
    -- ops.rejected_rows vì sai định dạng/thiếu dữ liệu bắt buộc).
    -- KHÔNG cộng rows_dup vào đây: dòng trùng là dữ liệu HỢP LỆ, chỉ
    -- không nạp lại vì đã tồn tại (ON CONFLICT DO NOTHING / DISTINCT
    -- ON), khác bản chất với dòng bị coi là lỗi.
    SUM(rows_rejected)       AS tong_dong_bi_loai,
    ROUND(
        SUM(rows_rejected) * 100.0 / NULLIF(SUM(rows_in), 0),
        2
    )                        AS reject_rate_tong,
    -- Batch chạy gần đây nhất theo THỜI ĐIỂM THỰC TẾ (run_time), không
    -- lấy theo thứ tự chuỗi batch_id -- an toàn hơn nếu sau này
    -- batch_id không còn đặt tên theo dạng ngày (YYYYMMDD).
    (SELECT batch_id FROM ops.load_audit ORDER BY run_time DESC LIMIT 1) AS batch_gan_nhat,
    MAX(run_time)             AS thoi_diem_cap_nhat
FROM ops.load_audit;
