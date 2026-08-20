#!/usr/bin/env python3
# =====================================================================
# generate_batch.py — cắt dữ liệu Olist thành từng batch cho Airflow nạp dần
#
# Có 2 chế độ:
#   --mode seed         : nạp một lần dữ liệu lịch sử + toàn bộ bảng tĩnh
#   --mode incremental  : cắt đúng 1 ngày, gọi lại mỗi lần Airflow chạy
#
# Nguyên tắc quan trọng nhất: KHÔNG dùng file con trỏ (cursor).
# Batch được xác định hoàn toàn bởi --batch-date, nên chạy lại cùng một ngày
# luôn cho ra file giống hệt. Đây là điều kiện để test tính idempotent.
# =====================================================================

import argparse
import os
import random
import sys
from datetime import datetime

import pandas as pd

# Mốc cắt — chốt dựa trên phân bố đơn theo tháng của dữ liệu thật
SEED_CUTOFF = "2018-07-31"        # seed lấy hết dữ liệu tính đến ngày này
INCREMENTAL_START = "2018-08-01"  # batch đầu tiên
INCREMENTAL_END = "2018-08-31"    # batch cuối cùng

# Ánh xạ tên logic sang tên file gốc tải từ Kaggle
FILE_MAP = {
    "orders": "olist_orders_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "products": "olist_products_dataset.csv",
    "customers": "olist_customers_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
}


def doc_file(source_dir, ten_logic):
    # Đọc toàn bộ cột dưới dạng chuỗi.
    # Lý do: tầng raw trong Postgres cũng để TEXT hết, nên ở đây không được
    # để pandas tự suy kiểu — nếu để nó tự đoán thì dữ liệu bẩn mình cố ý
    # chèn vào sẽ bị pandas "chữa" mất, không còn gì để chứng minh việc clean.
    duong_dan = os.path.join(source_dir, FILE_MAP[ten_logic])
    if not os.path.exists(duong_dan):
        print(f"[LỖI] Không tìm thấy file: {duong_dan}", file=sys.stderr)
        sys.exit(1)
    return pd.read_csv(duong_dan, dtype=str, keep_default_na=False, na_values=[""])


def lay_orders_theo_ngay(df_orders, ngay):
    # Lọc đơn hàng theo đúng một ngày dựa trên order_purchase_timestamp.
    # errors="coerce" để dòng nào timestamp hỏng thì thành NaT chứ không làm crash.
    ngay_mua = pd.to_datetime(df_orders["order_purchase_timestamp"], errors="coerce")
    return df_orders[ngay_mua.dt.date.astype(str) == ngay].copy()


def lay_orders_truoc_ngay(df_orders, moc):
    # Lấy toàn bộ đơn từ đầu đến hết ngày mốc — dùng cho chế độ seed
    ngay_mua = pd.to_datetime(df_orders["order_purchase_timestamp"], errors="coerce")
    return df_orders[ngay_mua.dt.date.astype(str) <= moc].copy()


def loc_con_theo_order(df_con, danh_sach_order_id):
    # ĐÂY LÀ HÀM QUAN TRỌNG NHẤT CỦA CẢ SCRIPT.
    # Khi cắt một ngày orders, phải kéo theo order_items / payments / reviews
    # của ĐÚNG các order_id trong ngày đó.
    # Nếu cắt các bảng con theo ngày riêng của chúng, sẽ sinh ra dòng con
    # mồ côi (item không có đơn cha) và foreign key sẽ vỡ ở tầng mart.
    return df_con[df_con["order_id"].isin(danh_sach_order_id)].copy()


# ---------------------------------------------------------------------
# NHÓM HÀM LÀM BẨN DỮ LIỆU
# Cố ý tạo lỗi để chứng minh pipeline có xử lý thật, không phải nói suông.
# Mỗi hàm trả về (dataframe đã sửa, số ô đã làm bẩn) để ghi vào log.
# ---------------------------------------------------------------------

def lam_ban_timestamp(df, rng, ty_le=0.05):
    # Đổi định dạng ngày từ chuẩn ISO sang kiểu Mỹ MM/DD/YYYY.
    # Đây là lỗi thực tế hay gặp nhất khi dữ liệu đi qua Excel.
    if len(df) == 0:
        return df, 0
    so_dong = max(1, int(len(df) * ty_le))
    vi_tri = rng.sample(range(len(df)), min(so_dong, len(df)))
    dem = 0
    for i in vi_tri:
        goc = df.iloc[i]["order_purchase_timestamp"]
        try:
            dt = datetime.strptime(goc, "%Y-%m-%d %H:%M:%S")
            df.iat[i, df.columns.get_loc("order_purchase_timestamp")] = dt.strftime("%m/%d/%Y %H:%M")
            dem += 1
        except (ValueError, TypeError):
            # Dòng nào đã hỏng sẵn thì bỏ qua, không làm hỏng thêm
            continue
    return df, dem


def lam_ban_status(df, rng, ty_le=0.03):
    # Thêm khoảng trắng thừa và viết hoa lung tung vào order_status.
    # Bên SQL sẽ phải TRIM và LOWER để chuẩn hoá lại.
    if len(df) == 0:
        return df, 0
    so_dong = max(1, int(len(df) * ty_le))
    vi_tri = rng.sample(range(len(df)), min(so_dong, len(df)))
    for i in vi_tri:
        goc = df.iloc[i]["order_status"]
        df.iat[i, df.columns.get_loc("order_status")] = f"  {goc.upper()} "
    return df, len(vi_tri)


def lam_ban_gia(df, rng, ty_le=0.04):
    # Ba kiểu lỗi tiền tệ hay gặp: giá trị âm, ô rỗng, và chữ lẫn vào cột số.
    # Kiểu thứ ba nguy hiểm nhất — nó làm câu CAST fail và kéo sập cả batch
    # nếu SQL không xử lý an toàn.
    if len(df) == 0:
        return df, 0
    so_dong = max(1, int(len(df) * ty_le))
    vi_tri = rng.sample(range(len(df)), min(so_dong, len(df)))
    dem = 0
    for i in vi_tri:
        chon = rng.choice(["am", "rong", "chu"])
        if chon == "am":
            try:
                gia = float(df.iloc[i]["price"])
                df.iat[i, df.columns.get_loc("price")] = str(-abs(gia))
            except (ValueError, TypeError):
                continue
        elif chon == "rong":
            df.iat[i, df.columns.get_loc("freight_value")] = ""
        else:
            df.iat[i, df.columns.get_loc("price")] = "N/A"
        dem += 1
    return df, dem


def lam_ban_review(df, rng, ty_le=0.04):
    # Điểm review hợp lệ chỉ từ 1 đến 5.
    # Chèn 0, 7, -1 và ô rỗng để bảng staging có CHECK constraint bắt được.
    if len(df) == 0:
        return df, 0
    so_dong = max(1, int(len(df) * ty_le))
    vi_tri = rng.sample(range(len(df)), min(so_dong, len(df)))
    for i in vi_tri:
        df.iat[i, df.columns.get_loc("review_score")] = rng.choice(["0", "7", "-1", ""])
    return df, len(vi_tri)


def lam_ban_payment(df, rng, ty_le=0.03):
    # Viết hoa và thêm khoảng trắng vào payment_type.
    # Nếu không chuẩn hoá, chart cơ cấu thanh toán sẽ tách "credit_card"
    # và "CREDIT_CARD " thành hai nhóm riêng — lỗi nhìn thấy ngay trên dashboard.
    if len(df) == 0:
        return df, 0
    so_dong = max(1, int(len(df) * ty_le))
    vi_tri = rng.sample(range(len(df)), min(so_dong, len(df)))
    for i in vi_tri:
        goc = df.iloc[i]["payment_type"]
        df.iat[i, df.columns.get_loc("payment_type")] = goc.upper() + " "
    return df, len(vi_tri)


def them_dong_trung(df_hien_tai, df_truoc, rng, ty_le=0.15):
    # Lấy ngẫu nhiên 15% đơn của ngày hôm trước rồi nối vào batch hôm nay.
    # Mô phỏng đúng tình huống thật: hệ thống nguồn gửi lại dữ liệu chồng lấn.
    # Những đơn này đã nằm trong mart rồi, nên ON CONFLICT phải bỏ qua chúng
    # và rows_loaded trong load_audit sẽ nhỏ hơn rows_in.
    if len(df_truoc) == 0:
        return df_hien_tai, 0
    so_dong = max(1, int(len(df_truoc) * ty_le))
    so_dong = min(so_dong, len(df_truoc))
    vi_tri = rng.sample(range(len(df_truoc)), so_dong)
    df_trung = df_truoc.iloc[vi_tri].copy()
    return pd.concat([df_hien_tai, df_trung], ignore_index=True), len(df_trung)


def kich_ban_theo_ngay(ngay):
    # Gắn kịch bản dữ liệu bẩn theo thứ tự ngày, khớp với bảng Evidence:
    #   ngày 1 sạch -> ngày 2 có trùng -> ngày 3 có bẩn -> từ ngày 4 hỗn hợp
    # Nhờ vậy mỗi run demo cho chị đều chứng minh được một khả năng khác nhau.
    thu_tu = (datetime.strptime(ngay, "%Y-%m-%d")
              - datetime.strptime(INCREMENTAL_START, "%Y-%m-%d")).days + 1
    if thu_tu <= 1:
        return "sạch"
    if thu_tu == 2:
        return "trùng"
    if thu_tu == 3:
        return "bẩn"
    return "hỗn hợp"


def ghi_ra(df, thu_muc, ten_file):
    # Tạo thư mục nếu chưa có rồi ghi file CSV, trả về số dòng để in log
    os.makedirs(thu_muc, exist_ok=True)
    duong_dan = os.path.join(thu_muc, ten_file)
    df.to_csv(duong_dan, index=False)
    return duong_dan, len(df)


def chay_seed(source_dir, out_dir):
    # Chế độ seed chạy đúng MỘT LẦN trước khi bật schedule.
    # Nạp toàn bộ dữ liệu lịch sử cộng với 4 bảng tĩnh
    # (products, customers, sellers, translation).
    # Bốn bảng này không cắt theo ngày vì chúng là bảng tra cứu,
    # không phải bảng sự kiện.
    print(f"[SEED] Cắt dữ liệu lịch sử đến hết {SEED_CUTOFF}")

    orders = doc_file(source_dir, "orders")
    orders_seed = lay_orders_truoc_ngay(orders, SEED_CUTOFF)
    ids = set(orders_seed["order_id"])

    items = loc_con_theo_order(doc_file(source_dir, "order_items"), ids)
    payments = loc_con_theo_order(doc_file(source_dir, "order_payments"), ids)
    reviews = loc_con_theo_order(doc_file(source_dir, "order_reviews"), ids)

    products = doc_file(source_dir, "products")
    customers = doc_file(source_dir, "customers")
    sellers = doc_file(source_dir, "sellers")
    translation = doc_file(source_dir, "category_translation")

    # Làm bẩn nhẹ cột category ngay trong seed.
    # Phải làm ở đây chứ không làm ở batch, vì products là bảng tĩnh.
    # Mục đích: chứng minh bước chuẩn hoá TRIM + LOWER ở tầng staging.
    rng = random.Random(20180731)
    so_dong = max(1, int(len(products) * 0.02))
    vi_tri = rng.sample(range(len(products)), so_dong)
    for i in vi_tri:
        goc = products.iloc[i]["product_category_name"]
        if isinstance(goc, str) and goc:
            products.iat[i, products.columns.get_loc("product_category_name")] = f" {goc.upper()}  "

    for ten, df in [
        ("orders.csv", orders_seed),
        ("order_items.csv", items),
        ("order_payments.csv", payments),
        ("order_reviews.csv", reviews),
        ("products.csv", products),
        ("customers.csv", customers),
        ("sellers.csv", sellers),
        ("category_translation.csv", translation),
    ]:
        _, n = ghi_ra(df, out_dir, ten)
        print(f"  {ten:28s} {n:>8,} dòng")
    return 0


def chay_incremental(source_dir, out_dir, batch_date, batch_id):
    # Chế độ này được Airflow gọi mỗi lần chạy, mỗi lần đúng một ngày dữ liệu
    kich_ban = kich_ban_theo_ngay(batch_date)
    print(f"[BATCH] {batch_id} | ngày {batch_date} | kịch bản: {kich_ban}")

    # Seed cố định theo ngày, KHÔNG dùng thời gian hệ thống.
    # Nhờ vậy chạy lại cùng một batch-date luôn cho ra file y hệt,
    # và chạy trên máy Khải hay máy Noel cũng ra kết quả giống nhau.
    rng = random.Random(int(batch_date.replace("-", "")))

    orders_all = doc_file(source_dir, "orders")
    orders = lay_orders_theo_ngay(orders_all, batch_date)
    if len(orders) == 0:
        print(f"[CẢNH BÁO] Ngày {batch_date} không có đơn nào.")

    # Lấy đơn của ngày hôm trước để làm nguồn tạo dòng trùng
    ngay_truoc = (datetime.strptime(batch_date, "%Y-%m-%d")
                  - pd.Timedelta(days=1)).strftime("%Y-%m-%d")
    orders_truoc = lay_orders_theo_ngay(orders_all, ngay_truoc)

    so_trung = 0
    if kich_ban in ("trùng", "hỗn hợp"):
        orders, so_trung = them_dong_trung(orders, orders_truoc, rng)

    # Lấy các bảng con SAU khi đã thêm dòng trùng,
    # để những đơn trùng cũng kéo theo item và payment của chúng
    ids = set(orders["order_id"])
    items = loc_con_theo_order(doc_file(source_dir, "order_items"), ids)
    payments = loc_con_theo_order(doc_file(source_dir, "order_payments"), ids)
    reviews = loc_con_theo_order(doc_file(source_dir, "order_reviews"), ids)

    tong_ban = 0
    if kich_ban in ("bẩn", "hỗn hợp"):
        orders, d1 = lam_ban_timestamp(orders, rng)
        orders, d2 = lam_ban_status(orders, rng)
        items, d3 = lam_ban_gia(items, rng)
        reviews, d4 = lam_ban_review(reviews, rng)
        payments, d5 = lam_ban_payment(payments, rng)
        tong_ban = d1 + d2 + d3 + d4 + d5

    # Mỗi batch là một thư mục riêng chứa 4 file, để task load bên Airflow
    # chỉ cần trỏ vào thư mục là biết nạp gì
    thu_muc = os.path.join(out_dir, f"batch_{batch_id}")
    for ten, df in [
        ("orders.csv", orders),
        ("order_items.csv", items),
        ("order_payments.csv", payments),
        ("order_reviews.csv", reviews),
    ]:
        _, n = ghi_ra(df, thu_muc, ten)
        print(f"  {ten:22s} {n:>7,} dòng")

    print(f"  -> dòng trùng thêm vào: {so_trung}, ô bị làm bẩn: {tong_ban}")
    return 0


def main():
    p = argparse.ArgumentParser(
        description="Cắt dữ liệu Olist thành batch cho pipeline Airflow"
    )
    p.add_argument("--mode", choices=["seed", "incremental"], required=True)
    p.add_argument("--source-dir", required=True, help="Thư mục chứa 9 file CSV gốc")
    p.add_argument("--out", required=True, help="Thư mục ghi kết quả")
    p.add_argument("--batch-date", help="Ngày cần cắt, dạng YYYY-MM-DD")
    p.add_argument("--batch-id", help="Mã batch, mặc định lấy từ batch-date")
    a = p.parse_args()

    if a.mode == "seed":
        return chay_seed(a.source_dir, a.out)

    if not a.batch_date:
        print("[LỖI] Chế độ incremental bắt buộc phải có --batch-date", file=sys.stderr)
        return 1

    batch_id = a.batch_id or a.batch_date.replace("-", "")
    return chay_incremental(a.source_dir, a.out, a.batch_date, batch_id)


if __name__ == "__main__":
    # Exit code khác 0 khi lỗi để Airflow biết task fail
    sys.exit(main())