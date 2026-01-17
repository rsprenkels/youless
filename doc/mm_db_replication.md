You can do “bi-directional replication of the same table” in PostgreSQL in two materially different ways:

1. **Native logical replication (PUBLICATION/SUBSCRIPTION)** – workable **only if you can prevent conflicting writes** (or you accept that conflicts will stop replication and require manual intervention). PostgreSQL does **not** provide built-in conflict resolution. ([PostgreSQL][1])
2. **Multi-master extensions (pglogical / BDR / PGD/EDB Postgres Distributed)** – designed for bi-directional replication and (in pglogical/BDR) can offer configurable conflict handling. ([GitHub][2])

Below is a practical setup for both. I will keep it “same single table on two writable instances”.

---

## Option A — Native logical replication (Postgres 16+ recommended)

### Preconditions

* The table **must have a primary key** (or another replica identity) for UPDATE/DELETE to replicate reliably. ([PostgreSQL][1])
* You must accept one of these operating models:

    * **Active/active but partitioned writes** (each node writes disjoint key ranges), or
    * **Active/passive** (only one node writes at a time), or
    * **Manual conflict operations** when they occur (unique violations / update conflicts stop apply). ([postgresql.fastware.com][3])

### 1) Configure both instances (`postgresql.conf`)

On **both** DBs:

```conf
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
# recommended:
wal_sender_timeout = 60s
```

Reload/restart as needed.

### 2) Create a replication role on both

Run on **DB A** and **DB B**:

```sql
CREATE ROLE repl WITH LOGIN REPLICATION PASSWORD 'REPLACE_ME';
GRANT CONNECT ON DATABASE yourdb TO repl;
```

### 3) Ensure schema/table identical on both

Create/verify the table and PK on both nodes:

```sql
ALTER TABLE public.your_table REPLICA IDENTITY USING INDEX your_table_pkey;
-- or simply ensure it has a PRIMARY KEY; default replica identity is fine in most cases.
```

(Replica identity is core to logical replication.) ([PostgreSQL][1])

### 4) Create publications (A publishes to B, B publishes to A)

On **DB A**:

```sql
CREATE PUBLICATION pub_a FOR TABLE public.your_table;
```

On **DB B**:

```sql
CREATE PUBLICATION pub_b FOR TABLE public.your_table;
```

### 5) Create subscriptions (the “bi-directional” part)

On **DB A** subscribe to **pub_b**:

```sql
CREATE SUBSCRIPTION sub_from_b
  CONNECTION 'host=DB_B_HOST port=5432 dbname=yourdb user=repl password=REPLACE_ME'
  PUBLICATION pub_b
  WITH (copy_data = true, origin = none);
```

On **DB B** subscribe to **pub_a**:

```sql
CREATE SUBSCRIPTION sub_from_a
  CONNECTION 'host=DB_A_HOST port=5432 dbname=yourdb user=repl password=REPLACE_ME'
  PUBLICATION pub_a
  WITH (copy_data = true, origin = none);
```

**Why `origin = none`:** Postgres 16 introduced subscription origin filtering so you can avoid “looping” and re-sending already replicated changes. ([postgresql.fastware.com][4])

> If the table already has data on both sides, don’t use `copy_data=true` blindly. Instead:
>
> * pick one node as the “seed”, `copy_data=true` only from that side, or
> * pre-sync via dump/restore, then use `copy_data=false`.

### 6) Monitor

```sql
SELECT * FROM pg_stat_subscription;
```

### Native approach: what will break

* If both nodes insert the same PK (or violate a unique constraint) you will get apply errors and replication halts until you resolve it. ([postgresql.fastware.com][3])
* DDL is **not** replicated natively; you must apply schema changes on both. ([EDB][5])

---

## Option B — pglogical (recommended if you truly need active/active with conflicts)

pglogical is an extension that supports bi-directional patterns and provides **configurable conflict resolution modes** (e.g., keep local, apply remote, last update wins). ([Amazon Web Services, Inc.][6])

High-level steps:

1. Install pglogical on both instances, enable `shared_preload_libraries = 'pglogical'`, restart.
2. `CREATE EXTENSION pglogical;` on both DBs
3. Create pglogical nodes + replication sets
4. Add the table to a replication set on both
5. Create subscriptions each way
6. Set `pglogical.conflict_resolution` to an explicit policy (e.g. `last_update_wins`) if you expect concurrent updates. ([Amazon Web Services, Inc.][6])

If you want, I can provide an exact pglogical command sequence for your Postgres version/OS; the syntax is more verbose than native.

---

## What I would recommend in practice

* If this is for **HA/failover** and you can enforce “only one writer at a time”: use **native logical replication**.
* If you need **two writers at once** on the same table and you cannot strictly partition writes: use **pglogical or BDR/PGD** (because you will otherwise be doing conflict management yourself). ([Amazon Web Services, Inc.][6])

---

### Minimal info I need to tailor an exact runbook (no back-and-forth)

* PostgreSQL versions on both sides (e.g., 15/16/17)
* Are both nodes allowed to write the same primary keys, or can you partition keys (e.g., A writes IDs 1–1B, B writes 1B+1–2B)?
* Is the table insert-only, or updates/deletes also occur?

If you reply with those three items, I will give you a copy-paste-ready runbook for your exact situation (native or pglogical).

[1]: https://www.postgresql.org/docs/current/logical-replication.html?utm_source=chatgpt.com "Documentation: 18: Chapter 29. Logical Replication"
[2]: https://github.com/2ndQuadrant/pglogical?utm_source=chatgpt.com "2ndQuadrant/pglogical: Logical Replication extension ..."
[3]: https://www.postgresql.fastware.com/blog/how-to-handle-logical-replication-conflicts-in-postgresql?utm_source=chatgpt.com "How to handle logical replication conflicts in PostgreSQL"
[4]: https://www.postgresql.fastware.com/blog/bi-directional-replication-using-origin-filtering-in-postgresql?utm_source=chatgpt.com "Bi-directional replication using origin filtering in PostgreSQL"
[5]: https://www.enterprisedb.com/blog/logical-replication-postgres-basics?utm_source=chatgpt.com "Logical Replication in Postgres: Understand the Basics"
[6]: https://aws.amazon.com/blogs/database/postgresql-bi-directional-replication-using-pglogical/?utm_source=chatgpt.com "PostgreSQL bi-directional replication using pglogical"


# More stuff
```
ALTER TABLE public.data
ADD COLUMN id integer;


CREATE SEQUENCE public.data_id_seq OWNED BY public.data.id;

UPDATE public.data
SET id = nextval('public.data_id_seq')
WHERE id IS NULL;

select * from public.data
order by tm desc;

ALTER TABLE public.data
ALTER COLUMN id SET DEFAULT nextval('public.data_id_seq');

select distinct wtr from data;
select * from data;

ALTER TABLE public.data
ADD COLUMN uid text
GENERATED ALWAYS AS ('A' || id) STORED;






```