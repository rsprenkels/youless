I'll help you set up bi-directional replication between two PostgreSQL instances. Let me first read your readme to understand your current setup.I can see you're running TimescaleDB (PostgreSQL-based) on port 5432. For bi-directional replication between two PostgreSQL instances, you'll need to set up **logical replication** with publications and subscriptions on both sides.

Here's what you need to do:

## Configuration Overview

**Both PostgreSQL instances need:**
1. `wal_level = logical` in postgresql.conf
2. Network connectivity between servers
3. Proper authentication (pg_hba.conf)

## Setup Steps

### On Server 1:

```sql
-- Enable replication user (if not exists)
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password';

-- Create publication for the table
CREATE PUBLICATION server1_pub FOR TABLE your_table_name;

-- Subscribe to Server 2's publication
CREATE SUBSCRIPTION server1_sub
CONNECTION 'host=server2_ip port=5432 dbname=timescale user=replicator password=strong_password'
PUBLICATION server2_pub;
```


### On Server 2:

```sql
-- Enable replication user (if not exists)
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password';

-- Create publication for the table
CREATE PUBLICATION server2_pub FOR TABLE your_table_name;

-- Subscribe to Server 1's publication
CREATE SUBSCRIPTION server2_sub
CONNECTION 'host=server1_ip port=5432 dbname=timescale user=replicator password=strong_password'
PUBLICATION server1_pub;
```


### Docker Compose adjustments:

For each server's docker-compose.yml, add:

```yaml
timescaledb:
  command: postgres -c wal_level=logical -c max_replication_slots=10 -c max_wal_senders=10
```


### pg_hba.conf entry (on both servers):

Add to allow replication connections:
```
host    timescale    replicator    server1_ip/32    scram-sha-256
host    timescale    replicator    server2_ip/32    scram-sha-256
```


**Important considerations:**
- Bi-directional replication can cause conflicts if both servers write to the same row
- TimescaleDB hypertables have limitations with logical replication
- Consider using conflict resolution strategies or partition your writes

