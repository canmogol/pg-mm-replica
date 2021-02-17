#!/bin/bash

psql -v ON_ERROR_STOP=1 --username "postgres" <<-END
  create database events;
  create user events with encrypted password 'events';
  grant all privileges on database events to events;
  CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'replicator';
  grant all privileges on database events to replicator;
END

psql -v ON_ERROR_STOP=1 --username "events" -d "events"  <<-END
  create schema if not exists public;
  create table if not exists public.event
  (
    cluster varchar default '1.3.6.1.4.1.56465.100.1'::character varying,
    id serial,
    created timestamptz default now(),
    event jsonb not null,
    type varchar not null,
    PRIMARY KEY (cluster, id)
  );
  CREATE INDEX event_type_hash_index ON event USING hash(type);
  alter table event owner to events;
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO events;
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO replicator;
END

psql -v ON_ERROR_STOP=1 --username "postgres" -d "events" <<-END
  CREATE PUBLICATION publication_all_tables FOR ALL TABLES;
END

psql -v ON_ERROR_STOP=1 --username "postgres" -d "events" <<-END
  CREATE OR REPLACE FUNCTION public.resolve()
      RETURNS trigger
      LANGUAGE plpgsql
  AS \$function\$
  DECLARE
      id1 int;
  BEGIN
      select id into id1 from public.event where cluster = new.cluster and id = new.id;
      if id1 is not null then
          RETURN null;
      end if;
      RETURN new;
  END;
  \$function\$;

  CREATE TRIGGER trigger_before_insert_row BEFORE INSERT ON event FOR EACH ROW EXECUTE PROCEDURE resolve();
  ALTER TABLE event ENABLE ALWAYS TRIGGER trigger_before_insert_row;
END
