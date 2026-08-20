# ============================================================================
# Image Superset có driver Postgres.
#
# Vì sao cần file này: apache/superset:4.1.1 KHÔNG đóng gói psycopg2 nữa
# (từ 4.x driver DB bị tách khỏi image gốc). Thiếu nó thì `superset db upgrade`
# chết ngay với ModuleNotFoundError: No module named 'psycopg2' vì chính
# metadata DB của Superset cũng nằm trên Postgres.
#
# Cài qua Dockerfile chứ không phải pip lúc container start — cùng lý do như
# docker/airflow/Dockerfile: tránh cài lại mỗi lần start và fail khi mạng yếu.
#
# apache/superset là image multi-arch nên build được trên cả amd64 lẫn arm64.
# ============================================================================
FROM apache/superset:4.1.1

USER root
RUN pip install --no-cache-dir psycopg2-binary==2.9.9

USER superset
