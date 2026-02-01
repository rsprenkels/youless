Below is a **copy/paste two-node PostgreSQL logical replication lab** using **Docker Compose**, designed for local testing. It gives you:

* `pg1` exposed on **localhost:5433**
* `pg2` exposed on **localhost:5434**
* Logical replication enabled on both
* A replication role pre-created
* A test table and publications created
* A one-command script to create subscriptions (one-way or bi-directional)

> Note: **Native Postgres logical replication has no conflict resolution.** Bi-directional is viable only if you avoid conflicting writes (e.g., partition key ranges, insert-only, etc.).

---

## 1) Create folder structure

```bash
mkdir -p pg-repl-lab/pg1/init pg-repl-lab/pg2/init pg-repl-lab/scripts
cd pg-repl-lab
```

---

## 2) `docker-compose.yml`

```yaml
version: "3.9"

services:
  pg1:
    image: postgres:16
    container_name: pg1
    environment:
      POSTGRES_DB: lab
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5433:5432"
    volumes:
      - pg1_data:/var/lib/postgresql/data
      - ./pg1/init:/docker-entrypoint-initdb.d
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_wal_senders=10"
      - "-c"
      - "max_replication_slots=10"
      - "-c"
      - "listen_addresses=*"
    networks:
      - replnet

  pg2:
    image: postgres:16
    container_name: pg2
    environment:
      POSTGRES_DB: lab
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5434:5432"
    volumes:
      - pg2_data:/var/lib/postgresql/data
      - ./pg2/init:/docker-entrypoint-initdb.d
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_wal_senders=10"
      - "-c"
      - "max_replication_slots=10"
      - "-c"
      - "listen_addresses=*"
    networks:
      - replnet

networks:
  replnet:

volumes:
  pg1_data:
  pg2_data:
```

---

## 3) Init SQL (runs once per node on first container start)

### `pg1/init/001_setup.sql`

```sql
-- Replication role used by subscriptions
CREATE ROLE repl WITH LOGIN REPLICATION PASSWORD 'replpass';

-- Test table
CREATE TABLE IF NOT EXISTS public.items (
  id bigint PRIMARY KEY,
  payload text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Publication on pg1
DROP PUBLICATION IF EXISTS pub_pg1;
CREATE PUBLICATION pub_pg1 FOR TABLE public.items;
```

### `pg2/init/001_setup.sql`

```sql
CREATE ROLE repl WITH LOGIN REPLICATION PASSWORD 'replpass';

CREATE TABLE IF NOT EXISTS public.items (
  id bigint PRIMARY KEY,
  payload text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP PUBLICATION IF EXISTS pub_pg2;
CREATE PUBLICATION pub_pg2 FOR TABLE public.items;
```

---

## 4) Script to create subscriptions

### `scripts/create_subscriptions.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-oneway}"  # oneway | bidir

echo "Waiting for pg1..."
until docker exec pg1 pg_isready -U postgres -d lab >/dev/null 2>&1; do sleep 1; done
echo "Waiting for pg2..."
until docker exec pg2 pg_isready -U postgres -d lab >/dev/null 2>&1; do sleep 1; done

# One-way: pg2 subscribes to pg1
echo "Creating subscription on pg2 from pg1 (pub_pg1)..."
docker exec -i pg2 psql -U postgres -d lab <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_from_pg1') THEN
    CREATE SUBSCRIPTION sub_from_pg1
      CONNECTION 'host=pg1 port=5432 dbname=lab user=repl password=replpass'
      PUBLICATION pub_pg1
      WITH (copy_data = true, origin = none);
  END IF;
END$$;
SQL

if [[ "$MODE" == "bidir" ]]; then
  # Bi-directional: also pg1 subscribes to pg2
  echo "Creating subscription on pg1 from pg2 (pub_pg2)..."
  docker exec -i pg1 psql -U postgres -d lab <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_from_pg2') THEN
    CREATE SUBSCRIPTION sub_from_pg2
      CONNECTION 'host=pg2 port=5432 dbname=lab user=repl password=replpass'
      PUBLICATION pub_pg2
      WITH (copy_data = false, origin = none);
  END IF;
END$$;
SQL
fi

echo "Done."
```

Make it executable:

```bash
chmod +x scripts/create_subscriptions.sh
```

---

## 5) Start the lab

```bash
docker compose up -d
```

Create subscriptions (choose one):

### One-way (pg1 -> pg2)

```bash
./scripts/create_subscriptions.sh oneway
```

### Bi-directional (pg1 <-> pg2)

```bash
./scripts/create_subscriptions.sh bidir
```

---

## 6) Test replication

### Insert on pg1, verify on pg2

```bash
docker exec -it pg1 psql -U postgres -d lab -c \
"INSERT INTO public.items (id,payload) VALUES (1,'from pg1');"

docker exec -it pg2 psql -U postgres -d lab -c \
"TABLE public.items;"
```

If bi-directional, insert on pg2 and verify on pg1:

```bash
docker exec -it pg2 psql -U postgres -d lab -c \
"INSERT INTO public.items (id,payload) VALUES (2,'from pg2');"

docker exec -it pg1 psql -U postgres -d lab -c \
"TABLE public.items;"
```

---

## 7) Inspect replication status

```bash
docker exec -it pg1 psql -U postgres -d lab -c "SELECT * FROM pg_stat_subscription;"
docker exec -it pg2 psql -U postgres -d lab -c "SELECT * FROM pg_stat_subscription;"
```

---

## 8) Reset the lab (nuclear option)

This deletes containers **and data**:

```bash
docker compose down -v
```

---

## Operational notes (important)

* **Bi-directional conflicts**: if both nodes write the same `id`, replication will error/halt. For safe active/active, partition keys (e.g., pg1 uses odd IDs, pg2 uses even IDs) or use an extension like pglogical/BDR.
* `origin = none` helps prevent feedback loops by filtering origin on apply, but it **does not** solve business-level conflicts.

---

If you tell me your intended write pattern (insert-only vs updates/deletes; partitioned keys vs shared keys), I can adapt this lab to a **conflict-avoidant** setup (e.g., two identity sequences with disjoint ranges, or GUIDs).
