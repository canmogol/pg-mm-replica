# pg-mm-replica
PostgreSQL Master - Master logical bi-directional event replication.

## How to run

Just to run `docker-compose up` and three PostgreSQL docker containers start running.

## How to enable replication

After docker-compose starts all three PostgreSQL servers, follow these steps to enable bi-directional logical replication on event table.

```
# connect to the pg1-master and run the following SQL
CREATE SUBSCRIPTION pg1_subscription_all_tables CONNECTION 'dbname=events host=pg2-master user=replicator password=replicator' PUBLICATION pg2_publication_all_tables;

# connect to the pg2-master and run the following SQL
CREATE SUBSCRIPTION pg2_subscription_all_tables CONNECTION 'dbname=events host=pg1-master user=replicator password=replicator' PUBLICATION pg1_publication_all_tables;
```

Now you can insert events into both masters and the data will be replicated.

```
# on pg1-master
insert into event(event, type) values ('{"a":1}', 'kv');
select * from event;

# on pg2-master
insert into event(event, type) values ('{"b":2}', 'kv');
select * from event;
```

Also, you can stop one of the masters and continue to insert events on the other master. The stopped master will replicate the new entries when the it is started again.

```
# stop the second master
docker-compose stop pg2-master

# insert new events into pg1-master
# restart the pg2-master
docker-compose star pg2-master

# you should see the same events on both masters
```

