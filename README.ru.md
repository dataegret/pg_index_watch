## Минимальные требования для инсталяции и использования:
- Версия PostgreSQL 12.0 и выше
- superuser доступ в базу с взможностью крон прописать от текущего пользователя (psql доступ достаточнен... рут не требуется... sudo на postgres на самом деле тоже)
- возможность беспарольного или ~/.pgpass доступа от имени superuser ко всем ЛОКАЛЬНЫМ базам (т.е. если вы можете от пользователя из п2 сделать psql -U postgres -d datname не вводя пароля для всех баз кластера - всё будет ок).



## Рекомендации:
- Если ресурсы сервера позволяют - установить max_parallel_maintenance_workers=8 (лучше даже 16). 
- Достаточно большой wal_keep_segments (5000 обычно достаточно = 80GB) если не используется wal архив для подпорки потоковой репликации.


## Инсталяция (от posgres пользователя):
```
#достаём код
git clone https://github.com/dataegret/pg_index_watch
cd pg_index_watch
#создаём структуру таблиц
psql -1 -d postgres -f index_watch_tables.sql
#заливаем код (хранимые процедуры)
psql -1 -d postgres -f index_watch_functions.sql
```


## Первоачальный запуск:
__ВАЖНО при первом запуске ВСЕ индексы больше 10MB (настройка по умолчанию) будут ОДНОКРАТНО перестроены. __

Может занять многие часы на больших многотерабайтных базах. Так что делайте его в ручном режиме.  Далее - только новые крупные индексы и распухшие будут обрабатываться.
```
nohup psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);" >> index_watch.log
```



## Автоматическая работа далее:
Установить в крон раз в сутки например в полночь (работа от superuser пользователя базы = обычно postgres)

__ВАЖНО Очень желательно не пересекать по времени с pg_dump и прочими долгими maintenance задачами.__
```
00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery();" | grep -qx t || exit; psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);"
```



## Обновление (от posgres пользователя):
```
cd pg_index_watch
git pull
#заливаем обновленный код (хранимки)
psql -1 -d postgres -f index_watch_functions.sql
```
Обновление структуры таблиц index_watch будет произведено АВТОМАТИЧЕСКИ при очередном вызове index_watch.periodic если будет необходимость.

Так же можно обновить структуру таблиц до актуальной для текущей версии кода руками (при обычной эксплуатации не требуется):
```
psql -1 -d postgres -c "SELECT index_watch._check_update_structure_version()"
```


## Просмотр истории реиндексации (она обновляется и во время начального запуска и при запусках из кронов):
```
psql -1 -d postgres -c "SELECT * FROM index_watch.history LIMIT 20"
```


## просмотр текущего состояния bloat в конкретной базе DB_NAME:
__Предполагает что крон index_watch.periodic РАБОТАЕТ, иначе данные не будут обновляться.__
```
psql -1 -d postgres -c "select * from index_watch.get_index_bloat_estimates('DB_NAME') order by estimated_bloat desc nulls last limit 40;"
```



