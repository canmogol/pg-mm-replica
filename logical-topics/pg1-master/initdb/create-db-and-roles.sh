#!/bin/bash

_privileged_username="${PG_PRIVILEGED_USERNAME:=postgres}"

_create_database="${PG_TOPIC_CREATE_DATABASE:=true}"
_database_name="${PG_TOPIC_DATABASE_NAME:=topics}"
_database_schema="${PG_TOPIC_DATABASE_SCHEMA:=public}"
_database_table_name="${PG_TOPIC_DATABASE_TABLE_NAME:=topics}"

_topic_refresh_table_name="${PG_TOPIC_REFRESH_TABLE_NAME:=topic_refresh}"

_create_user="${PG_TOPIC_CREATE_USER:=true}"
_database_username="${PG_TOPIC_DATABASE_USERNAME:=topics}"
_database_password="${PG_TOPIC_DATABASE_PASSWORD:=topics}"

_create_replicator="${PG_CREATE_REPLICATOR:=true}"
_replicator_username="${PG_REPLICATOR_USERNAME:=replicator}"
_replicator_password="${PG_REPLICATOR_PASSWORD:=replicator}"

_random_cluster_oid='1.9.9.9.9.9.9.9.'$((1 + $RANDOM % 100000))
_database_cluster_oid="${PG_TOPIC_DATABASE_CLUSTER_OID:=$_random_cluster_oid}"

_publication_name="${PG_TOPIC_DATABASE_PUBLICATION_NAME:=publication_all_tables}"
_subscription_name="${PG_TOPIC_DATABASE_SUBSCRIPTION_NAME:=subscription_all_tables}"

if [ $_create_database = true ]; then
  echo "Create database flag set to ${_create_database}, a database with ${_database_name} will be created."
  psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" --command="CREATE DATABASE ${_database_name};"
fi

if [ $_create_user = true ]; then
  echo "Create user flag set to ${_create_user}, a user with ${_database_username} will be created with the password using 'PG_TOPIC_DATABASE_USERNAME' env variable or the default 'topics'."
  psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" --command="CREATE USER ${_database_username} WITH ENCRYPTED PASSWORD '${_database_password}';"
fi

echo "Will grant all privileges to user ${_database_username} on ${_database_name} database"
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" --command="GRANT ALL PRIVILEGES ON DATABASE ${_database_name} TO ${_database_username};"

if [ $_create_replicator = true ]; then
  echo "Create replicator flag set to ${_create_replicator}, a replicator user with ${_replicator_username} will be created with the password using 'PG_REPLICATOR_PASSWORD' env variable or the default 'replicator'"
  psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" --command="CREATE ROLE ${_replicator_username} REPLICATION LOGIN PASSWORD '${_replicator_password}';"
fi

echo "Will grant all privileges to replica user ${_replicator_username} on ${_database_name} database"
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" --command="GRANT ALL PRIVILEGES ON DATABASE ${_database_name} TO ${_replicator_username};"

echo "Will create the ${_database_schema} schema if not exists."
psql -v ON_ERROR_STOP=1 --username "${_database_username}" -d "${_database_name}" --command="create schema if not exists ${_database_schema};"

echo "Will create a '${_database_table_name}' table if not exists."
psql -v ON_ERROR_STOP=1 --username "${_database_username}" -d "${_database_name}" <<-END
  create table if not exists ${_database_schema}.${_database_table_name}
  (
    cluster_oid varchar default '${_database_cluster_oid}'::character varying,
    incremental_id serial,
    creation_time timestamptz default now(),
    headers jsonb default '{}' not null,
    topic_name varchar not null,
    key_type varchar not null,
    value_type varchar not null,
    PRIMARY KEY (cluster_oid, incremental_id)
  );
END

echo "Will set ownership of ${_database_table_name} table to ${_database_username} user."
psql -v ON_ERROR_STOP=1 --username "${_database_username}" -d "${_database_name}" --command="ALTER TABLE ${_database_table_name} OWNER TO ${_database_username};"

echo "Will grant all privileges on all tables in ${_database_schema} schema to ${_database_username} user."
psql -v ON_ERROR_STOP=1 --username "${_database_username}" -d "${_database_name}" --command="GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${_database_schema} TO ${_database_username};"

echo "Will grant all privileges on all tables in ${_database_schema} schema to ${_replicator_username} replica user."
psql -v ON_ERROR_STOP=1 --username "${_database_username}" -d "${_database_name}" --command="GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${_database_schema} TO ${_replicator_username};"

echo "Will create publication for all tables on ${_database_name} database with name ${_publication_name}."
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" -d "${_database_name}" --command="CREATE PUBLICATION ${_publication_name} FOR TABLE ${_database_schema}.${_database_table_name};"

echo "Will create a 'create_topic' BEFORE INSERT TRIGGER on ${_database_schema} schema in ${_database_name} database."
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" -d "${_database_name}" <<-END
  CREATE OR REPLACE FUNCTION ${_database_schema}.create_topic()
      RETURNS trigger
      LANGUAGE plpgsql
  AS \$function\$
  DECLARE
    -- constants
    clusterOID      constant text := '${_random_cluster_oid}';
    databaseUser    constant text := '${_database_username}';
    replicatorUser  constant text := '${_replicator_username}';
    subscriptionName  constant text := '${_subscription_name}';
    topicRefreshTableName  constant text := '${_topic_refresh_table_name}';
    -- variables
    incremental_id1 int;
    selectQuery     text;
    createQuery     text;
  BEGIN
    selectQuery := 'select incremental_id from public.' || TG_TABLE_NAME ||
                   ' where cluster_oid = \$1  and incremental_id = \$2';
    EXECUTE selectQuery INTO incremental_id1 USING NEW.cluster_oid, NEW.incremental_id;
    if incremental_id1 is not null then
        RETURN null;
    end if;
    -- here we create a new table for the NEW.topic_name using NEW.key_type and NEW.value_type types.
    createQuery := '
    create table if not exists ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name || '
    (
        cluster_oid varchar default ''' || clusterOID || '''::character varying,
        incremental_id serial,
        creation_time timestamptz default now(),
        headers jsonb default ''{}'' not null,
        key ' || NEW.key_type || ' not null,
        value ' || NEW.value_type || ' not null,
        PRIMARY KEY (cluster_oid, incremental_id)
    );';
    EXECUTE createQuery;

    createQuery := 'CREATE INDEX IF NOT EXISTS ' || NEW.topic_name || '_key_hash_index ON ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name || ' USING hash(key);';
    EXECUTE createQuery;

    createQuery := 'ALTER TABLE ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name || ' OWNER TO ' || databaseUser;
    EXECUTE createQuery;

    createQuery := 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ' || TG_TABLE_SCHEMA || ' TO ' || databaseUser;
    EXECUTE createQuery;

    createQuery := 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ' || TG_TABLE_SCHEMA || ' TO '  || replicatorUser;
    EXECUTE createQuery;

    createQuery := 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ' || TG_TABLE_SCHEMA || ' TO '  || replicatorUser;
    EXECUTE createQuery;

    createQuery := 'DROP TRIGGER IF EXISTS trigger_before_insert_row ON ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name;
    EXECUTE createQuery;

    createQuery := 'CREATE TRIGGER trigger_before_insert_row BEFORE INSERT ON ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name || ' FOR EACH ROW EXECUTE PROCEDURE ' || TG_TABLE_SCHEMA || '.resolve_conflicting_pk()';
    EXECUTE createQuery;

    createQuery := 'ALTER TABLE ' || TG_TABLE_SCHEMA || '.' || NEW.topic_name || ' ENABLE ALWAYS TRIGGER trigger_before_insert_row';
    EXECUTE createQuery;

    RETURN NEW;
  END;
  \$function\$;

  DROP TRIGGER IF EXISTS trigger_before_insert_row ON ${_database_schema}.${_database_table_name};
  CREATE TRIGGER trigger_before_insert_row BEFORE INSERT ON ${_database_schema}.${_database_table_name} FOR EACH ROW EXECUTE PROCEDURE create_topic();
  ALTER TABLE ${_database_table_name} ENABLE ALWAYS TRIGGER trigger_before_insert_row;
END

echo "Will create a 'resolve_conflicting_pk' function on ${_database_schema} schema in ${_database_name} database."
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" -d "${_database_name}" <<-END
  CREATE OR REPLACE FUNCTION ${_database_schema}.resolve_conflicting_pk()
      RETURNS trigger
      LANGUAGE plpgsql
  AS \$function\$
  DECLARE
    -- variables
    incremental_id1 int;
    selectQuery     text;
  BEGIN
    selectQuery := 'select incremental_id from public.' || TG_TABLE_NAME ||
                   ' where cluster_oid = \$1  and incremental_id = \$2';
    EXECUTE selectQuery INTO incremental_id1 USING NEW.cluster_oid, NEW.incremental_id;
    if incremental_id1 is not null then
        RETURN null;
    end if;
    RETURN NEW;
  END;
  \$function\$;
END

echo "Will create a 'refresh_subscription' AFTER INSERT TRIGGER on ${_database_schema} schema in ${_database_name} database."
psql -v ON_ERROR_STOP=1 --username "${_privileged_username}" -d "${_database_name}" <<-END
CREATE OR REPLACE FUNCTION refresh_subscription()
    RETURNS trigger
    LANGUAGE plpgsql
  as
  \$function\$
  DECLARE
    MAX_RETRY constant integer := 10;
    SLEEP_FOR_SECONDS constant integer := 2;
    counter integer := 0;
    table_exist integer;
    query     text;
  BEGIN
    query := 'SELECT count(*) FROM information_schema.tables WHERE table_schema = \$1 AND table_name = \$2';
    EXECUTE query INTO table_exist USING '${_database_schema}', NEW.topic_name;
    while counter < MAX_RETRY
        loop
            if table_exist = 0 then
                perform pg_sleep(SLEEP_FOR_SECONDS);
            else
                CREATE EXTENSION IF NOT EXISTS pg_background SCHEMA ${_database_schema};
                query := 'select pg_sleep(' || SLEEP_FOR_SECONDS || '); ALTER PUBLICATION ${_publication_name} ADD TABLE ${_database_schema}.' || NEW.topic_name || ';';
                perform ${_database_schema}.pg_background_launch(query);

                query := 'select pg_sleep(' || SLEEP_FOR_SECONDS || ');select pg_sleep(' || SLEEP_FOR_SECONDS || '); ALTER SUBSCRIPTION ${_subscription_name} REFRESH PUBLICATION;';
                perform ${_database_schema}.pg_background_launch(query);
                raise notice 'Successfully created publication on table % and refreshed subscription %', NEW.topic_name, '${_subscription_name}';

                return NEW;
            end if;
            counter := counter + 1;
        end loop;
    raise exception 'update_subscriptions failed, could not create PUBLICATION for % and could not REFRESH PUBLICATION on SUBSCRIPTION %', NEW.topic_name, '${_subscription_name}';
  END;
  \$function\$;

  DROP TRIGGER IF EXISTS trigger_after_insert ON ${_database_schema}.${_database_table_name};
  CREATE TRIGGER trigger_after_insert AFTER INSERT ON ${_database_schema}.${_database_table_name} FOR EACH ROW EXECUTE PROCEDURE refresh_subscription();
  ALTER TABLE ${_database_table_name} ENABLE ALWAYS TRIGGER trigger_after_insert;
END
