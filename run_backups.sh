mkdir -p backups
docker exec -t cl-postgres pg_dump -U postgres -d chainlink | gzip > backups/chainlink_backup_$(date +%Y-%m-%d).sql.gz
docker exec -t cl-postgres pg_dumpall -U postgres | gzip > backups/postgres_full_backup_$(date +%Y-%m-%d).sql.gz
# docker exec chainlink chainlink jobs list > backups/jobs_backup_$(date +%Y-%m-%d).txt
# docker exec chainlink tar czf - -C /root/.chainlink keystore > backups/keystore_backup_$(date +%Y-%m-%d).tgz
# docker exec chainlink cat /root/.chainlink/.password > backups/keystore_password_$(date +%Y-%m-%d).txt

