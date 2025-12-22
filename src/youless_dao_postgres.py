import logging as log
import os
import psycopg2
from psycopg2 import sql

log.basicConfig(format="%(asctime)s - %(message)s", level=log.INFO)


class Dao:
    def __init__(self):
        # Get DATABASE_URL from environment variable
        # Expected format: postgresql://user:password@host:port/database
        database_url = os.getenv("PG_DSN")
        if not database_url:
            raise ValueError("PG_DSN environment variable is not set")

        self.connection_params = database_url

        # Test connection and create table if needed
        try:
            conn = psycopg2.connect(self.connection_params)
            cursor = conn.cursor()

            # Create table if it doesn't exist
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS data (
                    tm TIMESTAMPTZ,
                    net NUMERIC,
                    pwr INTEGER,
                    ts0 BIGINT,
                    cs0 NUMERIC,
                    ps0 INTEGER,
                    p1 NUMERIC,
                    p2 NUMERIC,
                    n1 NUMERIC,
                    n2 NUMERIC,
                    gas NUMERIC,
                    gts BIGINT,
                    wtr NUMERIC,
                    wts BIGINT
                )
            """
            )

            conn.commit()
            print(f"Connected to PostgreSQL database")

        except Exception as e:
            print(f"Error connecting to database: {e}")
            raise
        finally:
            if cursor:
                cursor.close()
            if conn:
                conn.close()

    def add(self, datagram: dict):
        from datetime import datetime, timezone

        tablename = "data"

        # Convert Unix timestamp to datetime for 'tm' field
        converted_datagram = datagram.copy()
        if 'tm' in converted_datagram:
            converted_datagram['tm'] = datetime.fromtimestamp(converted_datagram['tm'], tz=timezone.utc)

        keys = list(converted_datagram.keys())
        values = tuple(converted_datagram.values())

        # Build parameterized query for PostgreSQL
        columns = sql.SQL(", ").join(map(sql.Identifier, keys))
        placeholders = sql.SQL(", ").join(sql.Placeholder() * len(keys))
        statement = sql.SQL("INSERT INTO {} ({}) VALUES ({})").format(
            sql.Identifier(tablename), columns, placeholders
        )

        conn = None
        cursor = None

        try:
            conn = psycopg2.connect(self.connection_params)
            cursor = conn.cursor()
            cursor.execute(statement, values)
            conn.commit()
        except Exception as e:
            if conn:
                conn.rollback()
            raise
        finally:
            if cursor:
                cursor.close()
            if conn:
                conn.close()


def test_1():
    # Set DATABASE_URL environment variable before running:
    # export DATABASE_URL="postgresql://postgres:your_password@localhost:5432/youless_test"
    d = Dao()
    d.add({"tm": 1234567890, "net": 123.45, "pwr": 100})
