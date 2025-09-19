# Prediction is a tool that takes in a VC_name and a sector as input. sector input can be empty. It will return a table with columns (startup, sector(optional), coinvestors, last funding date))

import datetime
import re
from typing import List, Dict, Any, Type
from pydantic import BaseModel, Field
from langchain_core.tools import tool
from sqlalchemy import text
from langchain_community.tools import TavilySearchResults
import VC_chain_database as vc_database
import logging
from langchain_community.agent_toolkits import SQLDatabaseToolkit
from langchain_google_vertexai import ChatVertexAI
from sqlalchemy.dialects.postgresql import ARRAY, TEXT
from sqlalchemy import text, bindparam
from sqlalchemy.types import Numeric
import VC_chain_systemprompts as vc_systemprompts
log = logging.getLogger(__name__)

engine = vc_database.engine

# VC ranking tools suite
class BaseRankingInput(BaseModel):
    sector: str = Field(default="?", description="Sector name or '?' if unknown")
    metric: str = Field(default="?", description="Metric name or '?' if unknown")
    count: int = Field(default=5, description="Number of results, default 5")

def result_clean(result):
    row = result.fetchall()
    if len(row) > 0:
        print("result_clean result: ", row)
        return row
    else:
        return [{"error": "No results found"}]
@tool
def VCRankingTool(
    metric: str,
    count: int = 5,
    sector: str = None
) -> List[Dict[str, Any]]:
    """
    Rank venture-capital firms by `metric`, optionally filtered by `sector`.
    If sector is provided, uses pg_trgm word_similarity for fuzzy sector matching.
    """
    try:
        SIM_THRESHOLD = 0.30
        log.info("VCRankingTool: sector=%s  metric=%s  count=%d",
                 sector, metric, count)

        # ── 1.  Sanitize / look-up  ────────────────────────────────
        try:
            metric_expr = vc_systemprompts.METRIC_EXPR[metric]
        except KeyError:
            return [{"error": f"Unknown metric '{metric}'"}]

        # ── 2.  Build the SQL with *metric_expr* spliced in  ───────
        if sector:
            # With sector filtering
            sector_clean = re.sub(r"[^a-z0-9 ]", " ", sector.lower()).strip()
            sql = f"""
            WITH ranked AS (
                SELECT
                    vs.*,
                    vo.*,
                    vc.*,
                    word_similarity(lower(vs."Sector"), :q) AS sim,
                    {metric_expr}                       AS metric_val
                FROM   vc_sector_based_raw vs
                JOIN   vc_overall_raw      vo ON vo."Top Tier" = vs."Top Tier"
                JOIN   vc_market_cagr      vc ON vc."Sector"   = vs."Sector"
                WHERE  {metric_expr} IS NOT NULL               -- filter blanks
            )
            SELECT *
            FROM   ranked
            WHERE  sim >= :sim_th
            ORDER  BY sim DESC, metric_val DESC NULLS LAST
            LIMIT  :limit;
            """
            params = {
                "q":      sector_clean,
                "sim_th": SIM_THRESHOLD,
                "limit":  count,
            }
        else:
            # Without sector filtering - rank across all sectors
            sql = f"""
            SELECT DISTINCT
                vs.*,
                vo.*,
                vc.*,
                {metric_expr} AS metric_val
            FROM   vc_sector_based_raw vs
            JOIN   vc_overall_raw      vo ON vo."Top Tier" = vs."Top Tier"
            JOIN   vc_market_cagr      vc ON vc."Sector"   = vs."Sector"
            WHERE  {metric_expr} IS NOT NULL               -- filter blanks
            ORDER  BY metric_val DESC NULLS LAST
            LIMIT  :limit;
            """
            params = {
                "limit":  count,
            }

        # ── 3.  Execute  ───────────────────────────────────────────
        with engine.begin() as conn:
            rows = conn.execute(text(sql), params).fetchall()

        log.info("VCRankingTool: returned %d rows", len(rows))
        if not rows:
            if sector:
                return [{"warning":
                         f"No VC found for metric '{metric}' near sector '{sector}'"}]
            else:
                return [{"warning":
                         f"No VC found for metric '{metric}'"}]
        return rows

    except Exception as exc:
        log.exception("VCRankingTool failed")
        return [{"error": str(exc)}]

@tool
def VCSubsectorRankingTool(sector: str, metric: str, count: int = 5):
    """Ranks VCs by subsector activity using funding rounds data. Requires subsector, metric, count."""
    try:
        log.info(f"Starting Subsector ranking with parameters - Subsector: '{sector}', Metric: '{metric}', Count: {count}")
        
        query = f"""
            WITH exploded AS (
                SELECT
                    TRIM(firm_el)::text            AS venture_capital_firm,
                    TRIM(sector_el)::text          AS sector,
                    fr.round_name                  AS series_raw
                FROM funding_rounds_v2 AS fr
                CROSS JOIN LATERAL unnest(string_to_array(COALESCE(fr.investors, ''),  ',')) AS firm_el
                CROSS JOIN LATERAL unnest(string_to_array(COALESCE(fr.categories, ''),  ',')) AS sector_el
                WHERE
                    TRIM(firm_el)   <> '' AND
                    TRIM(sector_el) <> '' AND
                    firm_el         <> '#NAME? ()'
            ),

            series_typed AS (
                SELECT
                    venture_capital_firm,
                    sector,
                    CASE
                        WHEN series_raw ILIKE 'Series %%'
                            THEN REGEXP_REPLACE(series_raw,
                                                '^Series\\s+([A-Za-z0-9\\+]+).*',
                                                'Series \\1',
                                                'i')
                        WHEN series_raw ILIKE 'Seed%%'      OR series_raw ILIKE 'Pre-Seed%%' THEN 'Seed'
                        WHEN series_raw ILIKE 'Angel%%'                                     THEN 'Angel'
                        WHEN series_raw ILIKE 'Bridge%%'                                    THEN 'Bridge'
                        ELSE 'Unknown'
                    END AS series_type
                FROM exploded
            ),

            aggregated AS (
                SELECT
                    venture_capital_firm                  AS "VC",
                    sector                                AS "Sector",
                    COUNT(*)                              AS "Subsector specific investment",
                    STRING_AGG(
                        CASE WHEN series_type <> 'Unknown'
                            THEN series_type || ': ' || cnt::text END,
                        ', ' ORDER BY series_type
                    )                                     AS "Series #"
                FROM (
                    SELECT
                        venture_capital_firm,
                        sector,
                        series_type,
                        COUNT(*) AS cnt
                    FROM series_typed
                    GROUP BY venture_capital_firm, sector, series_type
                ) subq
                GROUP BY venture_capital_firm, sector
            ),

            cleaned AS (
                SELECT *
                FROM   aggregated
                WHERE  "VC" NOT IN ('Ä‚n cá»©t ChÃ³', 'â€ŽIntegr8d Capital', 'â€"')
            )

            SELECT *
            FROM   cleaned
            WHERE  LOWER("Sector") LIKE LOWER('%{sector}%')
            ORDER  BY "{metric}" DESC
            LIMIT  {count};
            """
        log.debug("Executing Subsector SQL query")
        with engine.connect() as conn:
            rows = conn.execute(text(query)).fetchall()
        log.info(f"Returned {len(rows)} rows")
        return rows or [{"warning": "No results found"}]

    except Exception as e:
        log.error(
            f"VCSubsectorRankingTool error – Subsector: '{sector}', "
            f"Metric: '{metric}': {e}",
            exc_info=True,
        )
        return [{"error": f"PostgreSQL query error: {e}"}]
#reasoning tool suite

@tool
def execute_query(query: str) -> List[Dict[str, Any]]:
    """Executes a SQL query and returns the results."""
    print("execute_query result: ", query)
    with engine.connect() as conn:
        result = conn.execute(text(query))
        rows = result.fetchall()
        if len(rows) > 0:
            return rows
        else:
            return [{"error": "No results found"}]

@tool
def get_available_tables() -> List[str]:
    """Get a list of all available tables"""
    
    query = """SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"""
    with engine.connect() as conn:
        result = conn.execute(text(query))
        return result_clean(result)

@tool
def get_available_fields(table: str) -> List[str]:
    """Get a list of all available fields for a table"""
    query = f"""SELECT column_name FROM information_schema.columns WHERE table_name = '{table}'"""
    with engine.connect() as conn:
        result = conn.execute(text(query))
        return result_clean(result)

#prediction tool suite
@tool
def get_available_metrics() -> List[str]:
    """Get a list of all available metrics"""
    print("get_available_metrics result: ", list(vc_systemprompts.METRIC_EXPR.keys()))
    return list(vc_systemprompts.METRIC_EXPR.keys())

@tool
def get_available_subsectors() -> List[str]:
    """Get a list of all available subsectors"""
    query = text("""WITH sectors_exploded as (
        SELECT TRIM(sector_split.value) AS sector 
        FROM funding_rounds_v2 fr 
        CROSS JOIN LATERAL string_to_array(COALESCE(fr.categories, ''), ',') AS sector_split(value) 
        WHERE TRIM(sector_split.value) <> '' 
        AND TRIM(sector_split.value) <> '#NAME? ()'
    )
    SELECT DISTINCT sector FROM sectors_exploded ORDER BY RANDOM() LIMIT 100""")
    with engine.connect() as conn:
        result = conn.execute(query)
        return result_clean(result)




print("Defining tools...")
@tool
def CurrentDateTimeTool() -> str:
    """Returns the current date and time."""
    now = datetime.datetime.now(); fmt_dt = now.strftime("%A, %B %d, %Y, %I:%M:%S %p %Z")
    log.info(f"CurrentDateTimeTool executed: {fmt_dt}")
    return f"The current date and time is {fmt_dt}."



search_tool = TavilySearchResults(max_results=5)




@tool
def sector_lookup_tool(startup: str) -> List[Dict[str, Any]]:
    """Looks up the sector of a startup."""
    query = text("""
    SELECT categories
    FROM funding_rounds_v2
    WHERE org_name ILIKE :startup
    LIMIT 2;
    """)
    params = {
        "startup":      f"%{startup}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        print(f"sector_lookup_tool query for '{startup}': {result.rowcount} rows found")
        return result_clean(result)
    


@tool
def investor_lookup_tool(startup: str) -> List[Dict[str, Any]]:
    """Looks up the investors of a startup."""
    query = text("""
    SELECT investors
    FROM funding_rounds_v2
    WHERE org_name ILIKE :startup
    LIMIT 5;
    """)
    params = {
        "startup":      f"%{startup}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        print(f"investor_lookup_tool query for '{startup}': {result.rowcount} rows found")
        return result_clean(result)

@tool
def debug_startup_search(startup: str) -> List[Dict[str, Any]]:
    """Debug tool to find startups with similar names."""
    query = text("""
    SELECT DISTINCT org_name
    FROM funding_rounds_v2
    WHERE org_name ILIKE :startup
    ORDER BY org_name
    LIMIT 10;
    """)
    params = {
        "startup":      f"%{startup}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        rows = result.fetchall()
        print(f"debug_startup_search for '{startup}': found {len(rows)} matches")
        return rows if rows else [{"info": f"No startups found matching '{startup}'"}]

@tool
def list_sample_startups() -> List[Dict[str, Any]]:
    """Get a sample of startup names from the database."""
    query = text("""
    SELECT DISTINCT org_name
    FROM funding_rounds_v2
    WHERE org_name IS NOT NULL AND org_name != ''
    ORDER BY RANDOM()
    LIMIT 20;
    """)
    with engine.connect() as conn:
        result = conn.execute(query, params={})
        return result.fetchall()

@tool
def VC_coinvestor_tool(sector: str, VC_name: str) -> List[Dict[str, Any]]:
    """Looks up the coinvestors of a VC in a sector."""
    query = text("""
    WITH coinvestor_exploded AS (
        SELECT DISTINCT
            TRIM(firm.value)  AS venture_capital_firm,
            TRIM(sec.value)   AS sector,
            fr.org_name || ' - ' || fr.round_name AS series_company,
            fr.announced_on          AS announced_date,
            fr.money_raised_usd    AS total_funding_amount
        FROM funding_rounds_v2 fr
        CROSS JOIN LATERAL unnest(string_to_array(fr.investors, ',')) AS firm(value)
        CROSS JOIN LATERAL unnest(string_to_array(fr.categories, ',')) AS sec(value)
        WHERE fr.investors ILIKE :vc_pattern
        AND lower(trim(sec.value)) ILIKE ANY(:sectors)
      )
    SELECT
        venture_capital_firm AS "Coinvestor",
        sector               AS "Sector",
        COUNT(DISTINCT series_company) AS "Total Coinvestments"
    FROM coinvestor_exploded
    WHERE venture_capital_firm <> :vc_pattern
    GROUP BY venture_capital_firm, sector
    ORDER BY "Total Coinvestments" DESC
    LIMIT 5;
    """)
    sectors = [s.strip().lower() for s in sector.split(',')]
    params = {
        "vc_pattern":      f"%{VC_name}%",
        "sectors":         sectors
    }
    with engine.connect() as conn:
        try:
            result = conn.execute(query, params)
            return result_clean(result)
        except Exception as e:
            log.error(f"Error in VC_coinvestor_tool - Sector: '{sector}', VC_name: '{VC_name}': {str(e)}", exc_info=True)
            return [{"error": f"PostgreSQL query error: {str(e)}"}]
@tool
def get_available_sectors() -> List[str]:
    """Get a list of all available general ranking sectors"""
    query = text("""SELECT DISTINCT vc."Sector" FROM vc_sector_based_raw vc""")
    with engine.connect() as conn:
        result = conn.execute(query)
        return result_clean(result)
@tool 
def get_vc_available_sectors(VC_name: str) -> List[Dict[str, Any]]:
    """Looks up the available sectors of a VC."""
    query = text("""
    SELECT DISTINCT "Top Tier", "Sector"
    FROM vc_sector_based_raw
    WHERE "Top Tier" ILIKE :VC_name
    """)
    params = {
        "VC_name":      f"%{VC_name}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        return result_clean(result)

@tool
def vc_best_sector_tool(VC_name: str) -> List[Dict[str, Any]]:
    """Looks up the best sector of a VC."""
    query = text("""
    SELECT "Sector"
    FROM vc_sector_based_raw
    WHERE "Top Tier" ILIKE :vc_name
    AND "Sector specific exit/investment" IS NOT NULL
    ORDER BY "Sector specific exit/investment" DESC
    LIMIT 1;
    """)
    params = {
        "vc_name":      f"%{VC_name}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        return result_clean(result)

@tool
def vc_best_sector_tool_2(VC_name: str) -> List[Dict[str, Any]]:
    """Looks up the best sector of a VC."""
    query = text("""
        WITH sectors_exploded AS (
            SELECT
                TRIM(s.sector) AS sector,
                fr.org_name,
                fr.org_name || ' - ' || fr.round_name AS series_company
            FROM   funding_rounds_v2 fr
            -- turn "A, B, C" → ['A','B','C'] and explode to rows
            CROSS  JOIN LATERAL unnest(
                    string_to_array(COALESCE(fr.categories, ''), ',')
                ) AS s(sector)
            WHERE  fr.investors ILIKE :vc_name
            AND  TRIM(s.sector) <> ''
            AND  TRIM(s.sector) <> '#NAME? ()'
        )
        SELECT   sector,
                COUNT(DISTINCT org_name) AS "Total Coinvestments"
        FROM     sectors_exploded
        GROUP BY sector
        ORDER BY "Total Coinvestments" DESC
        LIMIT 1;
        """)
    params = {
        "vc_name":      f"%{VC_name}%"
    }
    with engine.connect() as conn:
        result = conn.execute(query, params)
        return result_clean(result)

@tool
def coinvestor_startup_tool(sector: str, VC_name: str, coinvestor_vcs: List[str]) -> List[Dict[str, Any]]:
    """Looks up the startups that VC_Name hasn't invested in yet, but the coinvestors have."""
    query = text("""
    WITH coinvestor_exploded AS (
        SELECT
            TRIM(firm.value) AS venture_capital_firm,
            TRIM(sec.value)  AS sector,
            fr.org_name                AS startup,
            fr.round_name                 AS series,
            fr.org_name || ' - ' || fr.round_name       AS series_company,
            fr.announced_on         AS announced_date,
            fr.money_raised_usd   AS total_funding_amount
        FROM funding_rounds_v2 fr
        -- one row per investor
        CROSS JOIN LATERAL unnest(
            string_to_array(coalesce(fr.investors, ''), ',')
        ) AS firm(value)
        -- one row per sector
        CROSS JOIN LATERAL unnest(
            string_to_array(coalesce(fr.categories, ''), ',')
        ) AS sec(value)
        WHERE fr.investors NOT ILIKE :vc_pattern
        AND sec.value          ILIKE :sector_pattern
    ),

    coinvestor_score AS (
        SELECT
            startup,
            sector,
            COUNT(DISTINCT series_company) AS coinvestor_score
        FROM coinvestor_exploded
        WHERE venture_capital_firm = ANY(:coinvestor_array)
        GROUP BY startup, sector
    ),

    last_series AS (
        /* DISTINCT ON keeps the latest round per startup‑sector */
        SELECT DISTINCT ON (startup, sector)
            startup,
            sector,
            series,
            announced_date AS last_series_announced_date
        FROM coinvestor_exploded
        WHERE venture_capital_firm = ANY(:coinvestor_array)
        ORDER BY startup, sector, announced_date DESC
    )

    SELECT
        cs.startup              AS "Startup",
        cs.sector               AS "Sector",
        cs.coinvestor_score     AS "Coinvestor Score",
        ls.last_series_announced_date AS "Last Series Announced Date",
        ls.series               AS "Latest Round"
    FROM coinvestor_score cs
    JOIN last_series ls USING (startup, sector)
    ORDER BY cs.coinvestor_score DESC
    LIMIT 10;
    """)
    params = dict(
        vc_pattern=f"%{VC_name}%",
        sector_pattern=f"%{sector}%",
        coinvestor_array=coinvestor_vcs,      # will be cast to text[]
    )
    SQL_bound = query.bindparams(
        bindparam("coinvestor_array", type_=ARRAY(TEXT))
    )
    with engine.connect() as conn:
        rows = conn.execute(SQL_bound, params).mappings().all()
        print("coinvestor_startup_tool result: ", rows)
        return rows

toolkit = vc_database.toolkit

general_tools = [search_tool, CurrentDateTimeTool]
prediction_tools = [get_available_metrics, get_available_sectors, get_vc_available_sectors, sector_lookup_tool, investor_lookup_tool, VC_coinvestor_tool, coinvestor_startup_tool, VCRankingTool, vc_best_sector_tool, vc_best_sector_tool_2, debug_startup_search, list_sample_startups, search_tool]
reasoning_tools = [execute_query, get_available_tables, get_available_fields, search_tool]
ranking_tools = [VCRankingTool, VCSubsectorRankingTool, get_available_sectors, get_available_subsectors, search_tool]
final_tools = [search_tool]



