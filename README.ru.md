

Это ЧЕРНОВИК без деталей внутренней реализации и настроек.

Минимальные требования для инсталяции
1. Версия PostgreSQL 12.0 и выше (ToDo добавить в index_watch_functions.sql проверку чтобы не ставилось на 11 версию и ранее в принципе)
2. superuser доступ в базу с взможностью крон прописать от текущего пользователя (psql доступ достаточнен... рут не требуется... sudo на postgres на самом деле тоже)
3. возможность беспарольного или ~/.pgpass доступа от имени superuser ко всем базам (т.е. если вы можете от пользователя из п2 сделать psql -U postgres -d datname не вводя пароля для всех баз кластера - все ок).
при несоблюдении этих правил тупо не будет работать но и ничего не сломает.

Инсталяция (от posgres пользователя)
cd ~/stuff
git pull
#создаем структуру таблиц рабочих
psql -q -1 -d postgres -f index_watch/index_watch_tables.sql
#заливаем код (хранимки)
psql -q -1 -d postgres -f index_watch/index_watch_functions.sql

Начальный ручной запуск
ВАЖНО: при первом запуске ВСЕ индексы больше 100MB будут перестроены. Так что делайте его в ручном режиме. Далее - только новые больше 100MB и распухшие.
psql -qt -c "CALL index_watch.periodic(TRUE);"

Установка в крон раз в сутки (от posgres пользователя)
Очень желательно не пересекать по времени с pg_dump и прочими долгими maintenance задачами.
# Automatic reindex based on bloat
00 00 * * *   psql -qt -c "CALL index_watch.periodic(TRUE);" > /var/log/postgresql/index_watch.log

Обновление (от posgres пользователя)
ToDo: придумать что делать с обновлением структуры таблиц если понадобится. Сейчас в коде есть проверка на совместимость версии таблиц с текущим кодом (так что ТЕОРЕТИЧЕСКИ код не должен будет запускаться на несовместимой структуре)
cd ~/stuff
git pull
#заливаем обновленный код (хранимки)
psql -q -1 -d postgres -f index_watch/index_watch_functions.sql


Просмотр истории реиндексации (она обновляется и во время начального запуска и при запусках из кронов)
select date_trunc('second', entry_timestamp)::timestamp as ts,datname as db,schemaname as schema,relname as table,indexrelname as index,indexsize_before as size_before,indexsize_after as size_after,(indexsize_before::float/indexsize_after)::numeric(12,2) as ratio, estimated_tuples as tuples,date_trunc('seconds', reindex_duration) as duration from index_watch.reindex_history order by id desc limit 40;


просмотр текущего состояния bloat в заданной базе (предполагает что крон РАБОТАЕТ обновляющий эти данные)
select * from index_watch.get_index_bloat_estimates('DB_NAME') order by estimated_bloat desc nulls last limit 40;
