import os
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
import pandas as pd
from typing import Optional
import datetime
import time
from psycopg2.pool import ThreadedConnectionPool
from psycopg2 import OperationalError, InterfaceError
from langchain_core.messages import trim_messages
from langgraph.graph import MessagesState
from langchain_community.utilities.sql_database import SQLDatabase
from langchain_google_vertexai import ChatVertexAI
from langchain_community.agent_toolkits import SQLDatabaseToolkit
from vertexai import init

init(project="soy-blend-462121-m4", location="europe-west8")
load_dotenv()

llm_main = ChatVertexAI(model_name="gemini-2.5-flash", temperature=0, thinking_budget=1024)

engine = create_engine(
    os.environ["POSTGRES_URL"],
    pool_size=20,  # Increased from 10
    max_overflow=40,  # Increased from 20
    connect_args={
        "prepare_threshold": None,
        "sslmode": "require",
        "sslcert": None,
        "sslkey": None,
        "sslrootcert": None,
        "sslcrl": None
    },
    pool_pre_ping=True,
    pool_recycle=1800  # Reduced from 3600 for better connection recycling
)

db_pool = SQLDatabase(engine)

toolkit = SQLDatabaseToolkit(db=db_pool, llm=llm_main)

def save_interaction_to_db(session_id: str, user_input: str, assistant_reply: str, markdown_table: Optional[str] = None):
    timestamp = datetime.datetime.now()

    query = """
                        INSERT INTO interactions (
                            session_id,
                            user_input,
                            assistant_reply,
                            timestamp,
                            markdown_table
                        ) VALUES (%s, %s, %s, %s, %s)
                    """
    with engine.begin() as con:
        con.execute(text(query), (session_id, user_input, assistant_reply, timestamp, markdown_table))
        con.commit()





##########################################
### might need to delete later
# Replace Google Docs constants with DB config
DB_HOST = os.getenv("DB_HOST")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_SSL = os.getenv("DB_SSL", "prefer")  # For secure connections
POOL_SIZE = int(os.getenv("DB_POOL_SIZE", 5))  # Connection pool size


DATABASE_SCHEMA = """
Table: startup_profile
Columns:
    - Startup (TEXT)
    - HQ Location (TEXT)
    - HQ Country (TEXT)
    - Description (TEXT)
    - Sectors (TEXT)
    - Industry Groups (TEXT) (MULTI-SELECT)
    - Last Funding Date (DATE)
    - Last Funding Amount (NUMERIC)
    - Series (TEXT)
    - Total Funding Amount (NUMERIC)
    - Top 5 Investors (TEXT) (MULTI-SELECT)
    - Monthly Visits (INTEGER)
    - Number of Funding Rounds (INTEGER)
    - Estimated Revenue (NUMERIC)

Table: funding_rounds
Columns:
    - Series Company (TEXT)
    - Startup (TEXT)
    - Series (TEXT)
    - Funds Raised (NUMERIC)
    - Announced Date (DATE)
    - Sectors (TEXT) (MULTI-SELECT)
    - All Investors (TEXT) (MULTI-SELECT)
    - Pre Money Valuation (NUMERIC)
    - Number of Investors (INTEGER)
    - Startup Description (TEXT)
    - Company Website (TEXT)
    - Revenue Range (TEXT)
    - Total Funding Amount (NUMERIC)
    - Number of Funding Rounds (INTEGER)
    - Funding Round Type (TEXT)

Relationships:
    - startup_profile.Startup = funding_rounds.Startup (indicating a common identifier for a startup across tables)
"""

### to be deleted later:


SHEETS = {
    "vc_overall_raw":   (os.environ["VC_FIRMS_SHEET_ID"],   0),  # gid 0
    "vc_sector_based_raw": (os.environ["VC_FIRMS_SHEET_ID"], 1673702863),
    "vc_market_cagr": (os.environ["VC_FIRMS_SHEET_ID"], 1104412318),
    "funding_rounds":   (os.environ["FUNDING_ROUNDS_SHEET_ID"], 0),
    "startup_profile": (os.environ["STARTUP_DATA_SHEET_ID"],    0),
}

def public_csv_url(sheet_id: str, gid: int):
    return (f"https://docs.google.com/spreadsheets/d/{sheet_id}/"
            f"export?format=csv&gid={gid}")

LOAD_SHEETS = os.getenv("LOAD_SHEETS", "false").lower() == "true"

if LOAD_SHEETS:
    with engine.begin() as conn:
        for table, (sheet_id, gid) in SHEETS.items():
            df = pd.read_csv(public_csv_url(sheet_id, gid))
            df.replace({'NO DATA': None}, inplace=True)   # keep NULL semantics
            df.to_sql(table, conn, if_exists="replace", index=False)  # 👈 creates or overwrites

        # Optional: run any type-casts Supabase needs
        conn.execute(text("""
            ALTER TABLE funding_rounds
            ALTER COLUMN "Announced Date" TYPE date USING to_date("Announced Date", 'Mon DD, YYYY'),
            ALTER COLUMN "Funds Raised" TYPE numeric USING replace(replace("Funds Raised", ',', ''), '$', '')::numeric;
            
            ALTER TABLE startup_profile
            ALTER COLUMN "Last Funding Date" TYPE date USING to_date("Last Funding Date", 'Mon DD, YYYY');
        """))


# Database connection pool (using psycopg2)
db_pool = None

def init_db_pool():
    global db_pool
    if not all([DB_HOST, DB_NAME, DB_USER, DB_PASSWORD]):
        return
    
    try:
        db_pool = ThreadedConnectionPool(
            minconn=1,
            maxconn=POOL_SIZE,
            host=DB_HOST,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            sslmode=DB_SSL
        )
    except Exception as e:
        print(f"Error initializing database pool: {e}")

# Initialize pool when module loads
init_db_pool()


def save_interaction_to_db(session_id: str, user_input: str, assistant_reply: str, markdown_table: Optional[str] = None):
    """Saves interaction to PostgreSQL database with retry logic"""
    if not db_pool:
        return
    
    max_retries, retry_delay = 3, 2
    conn = None
    
    try:
        for attempt in range(max_retries):
            try:
                conn = db_pool.getconn()
                with conn.cursor() as cur:
                    query = """
                        INSERT INTO interactions (
                            session_id,
                            user_input,
                            assistant_reply,
                            timestamp,
                            markdown_table
                        ) VALUES (%s, %s, %s, %s, %s)
                    """
                    timestamp = datetime.datetime.now()
                    cur.execute(query, (
                        session_id,
                        user_input,
                        assistant_reply,
                        timestamp,
                        markdown_table
                    ))
                    conn.commit()
                    return
            except (OperationalError, InterfaceError) as e:
                if attempt + 1 == max_retries:
                    raise
                time.sleep(retry_delay)
                retry_delay *= 2
                # Reset connection
                if conn:
                    db_pool.putconn(conn, close=True)
                    conn = None
    except Exception as e:
        print(f"Failed to save interaction after {max_retries} attempts: {e}")
    finally:
        if conn:
            db_pool.putconn(conn)

print("Defining memory function...")
memory_store = {}


def get_session_memory(state: MessagesState, session_id: str):
    if session_id in memory:
        selected_messages = trim_messages(
            memory[session_id],
            token_counter=len,  # <-- len will simply count the number of messages rather than tokens
            max_tokens=5,  # <-- allow up to 5 messages.
            strategy="last",
            start_on="human",
            include_system=True,
            allow_partial=False,
        )
        memory[session_id] = selected_messages
    else:
        memory[session_id] = state["messages"]
    return {"messages": memory[session_id]}

def get_chat_history(session_id: str, limit: int = 20):
    query = """
        SELECT parts
        FROM "Message_v2"
        WHERE "chatId" = :session_id
        ORDER BY "createdAt" DESC
        LIMIT :limit
    """
    max_retries = 3
    retry_delay = 1

    for attempt in range(max_retries):
        try:
            with engine.begin() as con:
                return con.execute(text(query), {"session_id": session_id, "limit": limit}).fetchall()
        except Exception as e:
            print(f"Database connection attempt {attempt + 1} failed: {e}")
            if attempt + 1 == max_retries:
                print(f"Failed to get chat history after {max_retries} attempts")
                return []
            time.sleep(retry_delay)
            retry_delay *= 2