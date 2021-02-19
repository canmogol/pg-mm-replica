# Replicating Topic Creation
PostgreSQL Master - Master logical bi-directional event replication.

'logical-topics' implementation handles 'topic' table creation and logical replication of the newly created tables. 

## How to run

Just to run `docker-compose up` and three PostgreSQL docker containers start running.

## How to enable replication

After docker-compose starts all three PostgreSQL servers, 
follow these steps to enable bi-directional logical replication on topic tables.

```
# connect to the pg1-master and run the following SQL
CREATE SUBSCRIPTION subscription_all_tables CONNECTION 'dbname=events host=pg2-master user=replicator password=replicator' PUBLICATION publication_all_tables;

# connect to the pg2-master and run the following SQL
CREATE SUBSCRIPTION subscription_all_tables CONNECTION 'dbname=events host=pg1-master user=replicator password=replicator' PUBLICATION publication_all_tables;
```

Now you can insert events into both masters and the data will be replicated.

```
# on pg1-master
# following insert will create a new topic table with name 'topic_hello_1' and key as 'varchar' and value as 'json'.  
insert into topics(topic_name, key_type, value_type) values ('topic_hello_1', 'varchar', 'json');
# you should see the 'topic_hello_1' class created in the pg1-master and pg2-master databases.
# on the pg1-master run the following query and you should see the data on the pg1-master and pg2-master databases.
insert into topic_hello_1(key, value) values('key-1', '{"a":1}');


# on pg2-master
# the following select queries show that the 'topic_hello_1' table and related data replicated to pg2-master database.
select * from topics;
select * from topic_hello_1;

# on the pg2-master run the following query and you should see the data on the pg1-master and pg2-master databases.
insert into topic_hello_1(key, value) values('key-2', '{"b":1}');
```

Also, you can stop one of the masters and continue to insert data on the other master. 
The stopped master will replicate the new entries when it's started again.

```
# stop the second master
docker-compose stop pg2-master

# insert new events into pg1-master
# restart the pg2-master
docker-compose star pg2-master

# you should see the same events on both masters
```

