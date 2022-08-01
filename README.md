Managing index bloat with pg_index_watch.
With the introduction of REINDEX CONCURRENTLY in PostgreSQL 12 there was no longer a need for a safe rebuild of indexes without any locks.
Despite that, the question remained - based on which criteria do we determine a bloat and whether there is a need to rebuild the index.
pg_index_watch utilizes the relation between index size and pg_class.reltuples (that is kept up-to-date through autovacuum) to determine the extent of index bloat relative to the ideal situation of the newly built index. 
It also allows rebuilding bloated indexes of any type. 
Furthermore, this becomes possible without the need in pgstattuple for the analysis or the index rebuild.
This talk will take you through my thinking that led to the development of pg_index_watch, dive into details of how it works and will review use cases.

— Readme for pg_index_watch –

Utility for prevention of bloat on frequently updated tables.
##Program purpose
Uncontrollable index bloat on frequently updated tables is a known issue in PostgreSQL.
The built-in autovacuum doesn’t deal well with bloat regardless of its settings. 
Pg_index_watch resolves this issue by automatically rebuilding indexes when needed. 
##Concept
With the introduction of REINDEX CONCURRENTLY in PostgreSQL 12 there was no longer a need for a safe rebuild of indexes without any locks.
The question remained - based on which criterion we can determine whether or not to rebuild the index, i.e. there was a need for a simple statistical model that will allow us to assess the extent to which index is bloated without the need to review index in full.

pg_index_watch offers following approach to this problem:

PostgreSQL allows you to access the following (and almost free of charge):
1) number of rows in the index (in pg_class.reltuples for the index) and 2) index size.

Further on, assuming that the relation of index size to the number of entries is constant (this is correct in 99.9% of cases), we can speculate that if, compared to its regular state, the relation has doubled it is most certain that the index has also doubled in size.

Next, we receive a similar to autovacuum system that automatically tracks the level of index bloat and reshuffles them as needed without the need to manually manipulate  database work.
## Basic requirements for installation and usage:


    • PostgreSQL version 12.0 or higher
    • Superuser access to the database with the possibility  writing cron from the current user 
        ◦ psql access is sufficient
        ◦ Root or sudo to PostgreSQL isn’t required
    • Possibility of passwordless or ~/.pgpass access on behalf of superuser to all local databases (i.e. if you should be able to create  psql -U postgres -d datname out of p2 without entering the password.
    • 
## Recommendations 
    • If server resources allow max_parallel_maintenance_workers=16 will need to be installed (8 is also possible).


    • Significant wal_keep_segments (5000 is normally sufficient = 80GB)unless the wal archive is used to support streaming replication.

## Installation (as PostgreSQL user)

# get the code git clone
https://github.com/dataegret/pg_index_watch
cd pg_index_watch
#create tables’ structure
psql -1 -d postgres -f index_watch_tables.sql
#importing the code (stored procedures)
psql -1 -d postgres -f index_watch_functions.sql

## The initial launch
IMPORTANT with first start ALL the indexes that are bigger than 10MB (default setting) will be rebuilt at once.  

This process might take several hours on large databases sized several TB therefore I suggest performing the launch manually. After that only new large or bloated indexes will be processed.

nohup psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);" >> index_watch.log

## Automated work following the installation
Set up the cron daily, for example at midnight (from superuser of the database = normally postgres) or hourly if there is a high number of writes to a database. 

__IMPORTANT
It’s highly advisable to make sure that the time doesn’t coincide with pg_dump and other long maintenance tasks. ___

00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery();" | grep -qx t || exit; psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);"

##UPDATE (from a postgres user)
cd pg_index_watch
git pull
#заливаем обновленный код (хранимки)
psql -1 -d postgres -f index_watch_functions.sql
index_watch table structure update will be performed AUTOMATICALLY if needed with the next index_watch.periodic command.

In the same way you can manually update the structure of the tables up to the current version (normally, this is not required):

psql -1 -d postgres -c "SELECT index_watch._check_update_structure_version()"

## Viewing reindexing history (it is renewed during the initial launch and with launch from crons): 
psql -1 -d postgres -c "SELECT * FROM index_watch.history LIMIT 20"

## review of current bloat status in  
specific database DB_NAME:
__Assumes that cron index_watch.periodic WORKS, otherwise data will not be updated.__

psql -1 -d postgres -c "select * from index_watch.get_index_bloat_estimates('DB_NAME') order by estimated_bloat desc nulls last limit 40;"
```
