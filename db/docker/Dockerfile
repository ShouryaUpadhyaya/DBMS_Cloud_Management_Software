# PostgreSQL 16 plus pg_cron (pg_stat_statements, btree_gist, pgcrypto ship with contrib).
FROM postgres:16
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-cron \
 && rm -rf /var/lib/apt/lists/*
CMD ["postgres", \
     "-c", "shared_preload_libraries=pg_cron,pg_stat_statements", \
     "-c", "cron.database_name=crms", \
     "-c", "pg_stat_statements.track=all"]
