# ============================================================================
# Build image Airflow có sẵn package cần dùng.
#
# Vì sao KHÔNG dùng _PIP_ADDITIONAL_REQUIREMENTS:
#   biến đó cài lại package MỖI LẦN container start -> khởi động rất chậm và
#   fail khi mạng chập chờn. Đúng lúc demo trước mặt chị thì rất rủi ro.
#
# Image gốc apache/airflow là multi-arch (có cả amd64 và arm64) nên build
# được trên cả WSL của Khải lẫn M2 của Noel, không cần khai báo platform.
# ============================================================================
FROM apache/airflow:2.10.5-python3.11

# OCI labels — truy vết nguồn gốc image (docker inspect / registry đọc được).
LABEL org.opencontainers.image.title="dataplat-airflow" \
      org.opencontainers.image.description="Airflow 2.10.5 + postgres client & providers cho Olist pipeline" \
      org.opencontainers.image.base.name="apache/airflow:2.10.5-python3.11" \
      org.opencontainers.image.source="https://github.com/khaipd18/ecv-task-009"

USER root
# psql client để task gọi được COPY/psql; build-essential phòng khi package
# nào đó thiếu wheel aarch64 và phải compile từ source trên M2.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER airflow
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
