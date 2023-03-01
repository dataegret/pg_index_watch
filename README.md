Utility for automatical rebuild of bloated indexes (a-la smart autovacuum to deal with index bloat) in PostgreSQL.

## Program purpose
Uncontrollable index bloat on frequently updated tables is a known issue in PostgreSQL.
The built-in autovacuum doesn’t deal well with bloat regardless of its settings. 
The pg_index_watch resolves this issue by automatically rebuilding indexes when needed. 

## Where to get support
create github issue
or email maxim.boguk@dataegret.com
or write in telegram channel https://t.me/pg_index_watch_support


## Concept
With the introduction of REINDEX CONCURRENTLY in PostgreSQL 12 there is now a safe and (almost) lock-free way to rebuild bloated indexes.
Despite that, the question remaines - based on which criteria do we determine a bloat and whether there is a need to rebuild the index.
The pg_index_watch utilizes the ratio between index size and pg_class.reltuples (which is kept up-to-date with help of autovacuum/autoanalyze) to determine the extent of index bloat relative to the ideal situation of the newly built index.
It also allows rebuilding bloated indexes of any type without dependency on pgstattuple for estimating index bloat.

pg_index_watch offers following approach to this problem:

PostgreSQL allows you to access (and almost free of charge):
1) number of rows in the index (in pg_class.reltuples for the index) and 2) index size.

Further on, assuming that the ratio of index size to the number of entries is constant (this is correct in 99.9% of cases), we can speculate that if, compared to its regular state, the ratio has doubled is is most certainly that the index have bloated 2x.

Next, we receive a similar to autovacuum system that automatically tracks level of index bloat and rebuilds (via REINDEX CONCURRENTLY) them as needed.


## Basic requirements for installation and usage:
    • PostgreSQL version 12.0 or higher
    • Superuser access to the database with the possibility writing cron from the current user 
        ◦ psql access is sufficient
        ◦ Root or sudo to PostgreSQL isn’t required
    • Possibility of passwordless or ~/.pgpass access on behalf of superuser to all local databases
    (i.e. you should be able to run psql -U postgres -d datname without entering the password.)

## Recommendations 
    • If server resources allow set non-zero max_parallel_maintenance_workers (exact amount depends on server parameters).
    • To set wal_keep_segments to at least 5000, unless the wal archive is used to support streaming replication.

## Installation (as PostgreSQL user)

# get the code git clone
```
git clone https://github.com/dataegret/pg_index_watch
cd pg_index_watch
#create tables’ structure
psql -1 -d postgres -f index_watch_tables.sql
#importing the code (stored procedures)
psql -1 -d postgres -f index_watch_functions.sql
```

## The initial launch

IMPORTANT!!! During the FIRST (and ONLY FIRST) launch ALL!! the indexes that are bigger than 10MB (default setting) will be rebuilt.  
This process might take several hours (or even days).
On the large databases (sized several TB) I suggest performing the FIRST launch manually. 
After that, only bloated indexes will be processed.

```
nohup psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);" >> index_watch.log
```


## Automated work following the installation
Set up the cron daily, for example at midnight (from superuser of the database = normally postgres) or hourly if there is a high number of writes to a database. 

IMPORTANT!!! It’s highly advisable to make sure that the time doesn’t coincide with pg_dump and other long maintenance tasks.

```
00 00 * * *   psql -d postgres -AtqXc "select not pg_is_in_recovery();" | grep -qx t || exit; psql -d postgres -qt -c "CALL index_watch.periodic(TRUE);"
```

## UPDATE to new versions (from a postgres user)
```
cd pg_index_watch
git pull
#load updated codebase
psql -1 -d postgres -f index_watch_functions.sql
index_watch table structure update will be performed AUTOMATICALLY (if needed) with the next index_watch.periodic command.
```

However, you can manually update tables structure to the current version (normally, this is not required):

```
psql -1 -d postgres -c "SELECT index_watch._check_update_structure_version()"
```

## Viewing reindexing history (it is renewed during the initial launch and with launch from crons): 
```
psql -1 -d postgres -c "SELECT * FROM index_watch.history LIMIT 20"
```

## review of current bloat status in  
specific database DB_NAME:
Assumes that cron index_watch.periodic WORKS, otherwise data will not be updated.

```
psql -1 -d postgres -c "select * from index_watch.get_index_bloat_estimates('DB_NAME') order by estimated_bloat desc nulls last limit 40;"
```


## todo
Add docmentation/howto about working with advanced settings and custom configuration of utility.
Add support of watching remote databases.
Add better commentaries to code.
