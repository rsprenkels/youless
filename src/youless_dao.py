from pathlib import Path
import logging as log
import os
import sqlite3

log.basicConfig(format="%(asctime)s - %(message)s", level=log.INFO)

db_fn_default = "../data/data.sqlite"

class Dao:
    def __init__(self, db_file: str = db_fn_default):
        data_file = Path(__file__).parent.parent / 'data' / db_file
        data_file.parent.mkdir(exist_ok=True)
        self.db_file = data_file
        if os.path.isfile(self.db_file):
            # self.conn = sqlite3.connect(db_file, check_same_thread=False)
            print(f"database exists {self.db_file}")
        else:
            conn = sqlite3.connect(self.db_file, check_same_thread=False)
            conn.execute(
                """
                create table data (
                    tm int,
                    net numeric,
                    pwr int,
                    ts0 int,
                    cs0 numeric,
                    ps0 int,
                    p1 numeric,
                    p2 numeric,
                    n1 numeric,
                    n2 numeric,
                    gas numeric,
                    gts int,
                    wtr numeric,
                    wts int);
            """
            )
            print(f"database created {self.db_file} and closed it")
            conn.close()

    def add(self, datagram: dict):
        tablename = "data"
        keys = ",".join(datagram.keys())
        question_marks = ",".join(list("?" * len(datagram)))
        values = tuple(datagram.values())
        statement = (
            "INSERT INTO "
            + tablename
            + " ("
            + keys
            + ") VALUES ("
            + question_marks
            + ")"
        )

        conn = sqlite3.connect(self.db_file)
        cursor = conn.cursor()

        try:
            cursor.execute("BEGIN IMMEDIATE")
            conn.execute(statement, values)
            conn.commit()
        except Exception as e:
            conn.rollback()
            raise
        finally:
            cursor.close()
            conn.close()

        # self.conn.execute(statement, values)
        # self.conn.commit()


def remove_if_exists(filename):
    if os.path.isfile(filename):
        os.remove(filename)


# https://gist.github.com/pdc/1188720 for mocking time

def test_1():
    test_db = "test1_dbfile.sqlite"
    remove_if_exists(test_db)
    d = Dao(test_db)
    d.add({"test1key": "test1_value"})

# chatGPT suggested to do it this way:

# import sqlite3
# conn = sqlite3.connect("mydb.sqlite")
# cursor = conn.cursor()
#
# try:
#     cursor.execute("BEGIN IMMEDIATE")
#     cursor.execute("INSERT INTO my_table (col1, col2) VALUES (?, ?)", (val1, val2))
#     conn.commit()
# except Exception as e:
#     conn.rollback()
#     raise
# finally:
#     cursor.close()
#     conn.close()
