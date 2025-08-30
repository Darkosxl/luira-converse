# VC_chain_logic.py Specifications and Analysis

## Overview
This is a sophisticated venture capital (VC) analysis system built with LangChain, DuckDB, and Google Vertex AI. The system provides intelligent query processing, VC ranking, and data analysis capabilities through a complex chain-based architecture.

## Core Architecture

### 1. Data Layer
- **Primary Database**: DuckDB for analytics and query processing
- **Secondary Database**: PostgreSQL for interaction logging and persistence
- **Data Sources**: Google Sheets integration for real-time data loading
- **Tables**: 5 main tables with specific schemas:
  - `vc_overall_raw`: General VC performance metrics (AUM, Ticket Size, Exit Multiple, etc.)
  - `vc_sector_based_raw`: Sector-specific VC activity and investment data
  - `vc_market_cagr`: Market size and growth data by sector
  - `funding_rounds`: Detailed investment round information
  - `startup_profile`: Startup company profiles and metrics

### 2. AI/LLM Layer
- **Primary LLM**: Google Vertex AI (Gemini 2.5 Flash)
- **Multiple Specialized LLM Instances**:
  - `llm_main`: Main processing and general queries
  - `llm_extractor`: Parameter extraction and parsing
  - `llm_cleaner`: Query refinement and normalization
  - `llm_query_agent`: SQL generation for custom queries

### 3. Processing Pipeline
The system uses a sophisticated chain-based architecture with multiple specialized components for different types of queries.

## Key Components

### 1. Data Loading & Schema Management

#### Google Sheets Integration
```python
SHEETS = {
    "vc_overall_raw": (os.environ["VC_FIRMS_SHEET_ID"], 0),
    "vc_sector_based_raw": (os.environ["VC_FIRMS_SHEET_ID"], 1673702863),
    "vc_market_cagr": (os.environ["VC_FIRMS_SHEET_ID"], 1104412318),
    "funding_rounds": (os.environ["FUNDING_ROUNDS_SHEET_ID"], 0),
    "startup_profile": (os.environ["STARTUP_DATA_SHEET_ID"], 0),
}
```

#### Schema Definitions
- All tables have predefined schemas with appropriate data types
- Special handling for currency, percentage, and multiplier formatting
- Post-load type casting for date and numeric fields

### 2. Memory Management

#### Session-Based Memory
```python
memory_store = {}
def get_session_memory(session_id: str) -> ConversationBufferWindowMemory:
    # Session-based memory with configurable window size (k=4)
```

#### State Management
- Conversation buffer with sliding window
- Custom table dialogue state tracking
- Persistent state across interactions

### 3. Tool Definitions

#### Core Tools
1. **VCRankingTool**: General sector-based VC rankings
2. **VCSubsectorRankingTool**: Subsector-specific rankings
3. **CurrentDateTimeTool**: Time/date queries
4. **TavilySearchResults**: External information retrieval

#### Tool Specifications

##### VCRankingTool
- **Input**: BaseRankingInput (sector, metric, count)
- **Metrics Supported**:
  - AUM, Ticket Size, Follow on Index
  - Total Exits / Total Investments
  - Sector specific metrics
  - CAGR, Current Market Size
- **Output**: Ranked list of VCs with detailed metrics

##### VCSubsectorRankingTool
- **Input**: BaseRankingInput (subsector, metric, count)
- **Metrics Supported**:
  - Subsector specific investment
  - Series # (funding round breakdown)
- **Processing**: Complex SQL with CTEs for investor/sector explosion and aggregation

### 4. Chain Architecture

#### Main Processing Chain
```python
full_chain = (
    RunnablePassthrough.assign(original_input_payload=lambda x: x.copy())
    | RunnablePassthrough.assign(chat_history=...)
    | RunnablePassthrough.assign(cleaned_input=cleaner_chain)
    | RunnablePassthrough.assign(route=router_chain)
    | RunnableLambda(route_main_request)
)
```

#### Specialized Chains
1. **cleaner_chain**: Query refinement and normalization
2. **router_chain**: Request classification and routing
3. **planner_chain**: Parameter extraction for rankings
4. **query_agent_chain**: SQL generation for custom queries

### 5. Query Processing Pipeline

#### 1. Query Cleaner
- **Purpose**: Standardizes and clarifies user input
- **Key Features**:
  - Intent-based refinement
  - Early stage expansion (Pre-Seed, Seed, Series A)
  - Ranking vs. data retrieval classification
  - Context preservation from chat history

#### 2. Router System
- **Classification Types**:
  - `vc_ranking_query`: Ranking and comparison requests
  - `reasoning_agent_query`: Custom SQL queries
  - `general_query`: General information requests
- **Ensemble Routing**: Multiple models vote on classification

#### 3. Ranking Planner
- **Parameters Extracted**:
  - `ranking_type`: "sector" or "subsector"
  - `sector`: Target sector/subsector
  - `metric`: Ranking metric
  - `count`: Number of results (1-20)

### 6. Data Processing Features

#### Available Options
- **Sectors**: Extracted from `vc_sector_based_raw.Sector`
- **Subsectors**: Derived from funding rounds sector splits
- **Metrics**: Predefined lists for general and subsector rankings
- **Pagination**: Support for large option lists (75 items per page)

#### Data Normalization
- VC name normalization (removes suffixes like Inc, LLC, Partners)
- Currency formatting handling ($, commas)
- Percentage formatting (%)
- Multiplier formatting (x)

### 7. Query Execution Pathways

#### 1. Ranking Pathway
```
User Input → Cleaner → Router → Planner → Tool Selection → Execution → Formatting
```

#### 2. Custom Query Pathway
```
User Input → Cleaner → Router → SQL Agent → DuckDB Execution → Results Formatting
```

#### 3. General Query Pathway
```
User Input → Cleaner → Router → General Agent → Tool Execution → Response
```

### 8. Output Formatting

#### JSON Response Structure
```json
{
  "reply": "formatted_response",
  "options_data": null | {
    "type": "option_type",
    "items": ["item1", "item2"],
    "requires_pagination": boolean
  }
}
```

#### Table Formatting
- **Markdown Tables**: Primary output format
- **JSON Conversion**: Structured data for frontend consumption
- **Metadata**: Title, description, and context information

### 9. Error Handling

#### Query Validation
- Parameter validation against available options
- SQL injection prevention
- Column name validation and auto-correction

#### Retry Logic
- Database connection retries (3 attempts)
- Column name correction using candidate bindings
- Graceful degradation on failures

### 10. Session Management

#### Memory Structure
```python
memory_store[session_id] = {
    "buffer": ConversationBufferWindowMemory,
    "custom_table_state": {
        "active_dialogue": boolean,
        "original_query": string,
        "last_proposed_approach": string,
        "dialogue_turn_count": integer
    }
}
```

#### State Persistence
- PostgreSQL storage for interaction logging
- Session-based memory with configurable window size
- Custom table dialogue state tracking

## Environment Dependencies

### Required Environment Variables
```
# Database
DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, DB_SSL
POSTGRES_URL

# Google Sheets
VC_FIRMS_SHEET_ID, FUNDING_ROUNDS_SHEET_ID, STARTUP_DATA_SHEET_ID

# AI Models
GOOGLE_VERTEX_PROJECT, GOOGLE_VERTEX_LOCATION

# Services
SERVICE_ACCOUNT_FILE, GOOGLE_DOC_ID
```

### Python Dependencies
- LangChain ecosystem (langchain, langchain-community, langchain-google-vertexai)
- DuckDB for data processing
- Pandas for data manipulation
- Google APIs (gspread, google-auth-library)
- PostgreSQL (psycopg2)
- Pydantic for data validation

## Performance Considerations

### Data Loading
- HTTP-based CSV loading from Google Sheets
- Schema-aware data type casting
- Bulk table creation and indexing

### Query Optimization
- DuckDB's columnar storage for analytics
- Prepared statements and parameterized queries
- Connection pooling for PostgreSQL

### Memory Management
- Conversation buffer with sliding window
- Session-based state isolation
- Automatic cleanup and garbage collection

## Security Features

### Input Validation
- Pydantic models for type safety
- SQL injection prevention
- Parameter validation against whitelists

### Access Control
- Session-based isolation
- Environment variable configuration
- Service account authentication

## Extensibility Points

### Adding New Data Sources
1. Add table definition to `SHEETS`
2. Define schema in `SCHEMAS`
3. Update available options lists
4. Extend tool capabilities

### Adding New Query Types
1. Extend router classification
2. Add new tool classes
3. Update main routing logic
4. Add output formatting

### Adding New AI Models
1. Configure in LLM definitions
2. Add to ensemble routing
3. Update chain configurations
4. Test compatibility

## Known Limitations

### Data Constraints
- Google Sheets API rate limits
- DuckDB memory constraints for large datasets
- Manual schema updates required

### Query Complexity
- Limited to predefined metrics
- Complex joins may require manual optimization
- SQL agent may need query refinement

### Session Management
- In-memory session storage (not persistent across restarts)
- Fixed conversation window size
- Manual session cleanup required

## Integration Points

### Flask Application
- Main entry point: `get_assistant_response(user_input, session_id)`
- Returns structured JSON response
- Handles session management automatically

### Frontend Integration
- Standardized JSON response format
- Options data for interactive UI
- Markdown table support

### External Services
- Google Sheets for data updates
- Vertex AI for language processing
- PostgreSQL for persistence
- Tavily for web search

## Code Quality Observations

### Strengths
- Comprehensive error handling
- Modular architecture with clear separation of concerns
- Extensive logging and debugging capabilities
- Type safety with Pydantic models

### Areas for Improvement
- Large monolithic file (1991 lines)
- Some code duplication in tool definitions
- Complex nested function structures
- Limited test coverage indicators

### Technical Debt
- Hardcoded constants and magic numbers
- Some unused imports and variables
- Inconsistent naming conventions in places
- Complex conditional logic in routing

## Testing Recommendations

### Unit Tests Needed
- Individual tool functionality
- Data loading and schema validation
- Query parsing and validation
- Output formatting

### Integration Tests
- End-to-end query processing
- Session state management
- Database connectivity
- External API integrations

### Performance Tests
- Large dataset handling
- Concurrent session management
- Memory usage patterns
- Query response times

## File Structure Summary

The file is organized into logical sections:
1. **Imports & Configuration** (lines 1-50)
2. **Data Loading & Schema** (lines 51-200)
3. **Helper Functions** (lines 201-400)
4. **Tool Definitions** (lines 401-600)
5. **Chain Definitions** (lines 601-1000)
6. **Routing Logic** (lines 1001-1400)
7. **Main Processing** (lines 1401-1800)
8. **Wrapper Functions** (lines 1801-1991)

## Key Features Summary

### 1. Intelligent Query Processing
- Multi-stage query cleaning and routing
- Context-aware parameter extraction
- Dynamic SQL generation for custom queries

### 2. VC Ranking System
- Two-tier ranking (general sector + subsector)
- Multiple metrics support
- Interactive clarification for missing parameters

### 3. Data Integration
- Real-time Google Sheets integration
- Dual database architecture (DuckDB + PostgreSQL)
- Comprehensive schema management

### 4. AI-Powered Analysis
- Multiple specialized LLM instances
- Ensemble routing for query classification
- Dynamic response formatting

### 5. Session Management
- Persistent conversation memory
- State tracking across interactions
- Error recovery and retry logic

This architecture provides a robust, scalable foundation for VC data analysis with sophisticated AI-powered query processing and ranking capabilities.


TODO: 
-no duckdb, ever should be used, all my data is in the supabase SQL dataset but that should be fine
-related to first point:An error occurred: DuckDB query error: Not an executable object: '\n SELECT \n vo."Top Tier" AS VC,\n vo."AUM" AS "AUM",\n vs.Sector,\n vs.* EXCLUDE (Sector, "Top Tier"), -- Get all sector-based columns except already selected\n vo.* EXCLUDE ("Top Tier"), -- Get all overall columns except VC name\n vc.* EXCLUDE (Sector) -- Get all market/cagr columns except sector\n FROM vc_overall_raw vo\n INNER JOIN vc_sector_based_raw vs \n ON vo."Top Tier" = vs."Top Tier"\n INNER JOIN vc_market_cagr vc \n ON vs.Sector = vc.Sector\n WHERE LOWER(TRIM(vs.Sector)) LIKE LOWER('%FinTech%')\n AND vo."AUM" IS NOT NULL\n ORDER BY TRY_CAST(REPLACE(REPLACE("AUM", ',', ''), '$', '') AS BIGINT) DESC NULLS LAST\n LIMIT 10\n '
-a prediction tool has to be added: the point of the tool is to map closest coinvestors based on sector and give the top startups that have the closest coinvestors invested in them but not the VC that is asked for, an example prompt is "predict the next startup that sequoia capital would invest in". The LLM decider (I don't remember the exact name) should decide whether to pick 1) reasoning 2) ranking or 3) prediction


