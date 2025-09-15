import os
from typing import (
    Annotated,
    Sequence,
    TypedDict,
    Optional,
)
from langchain_core.prompts.chat import SystemMessagePromptTemplate
from langchain_core.messages import BaseMessage
from langgraph.graph.message import add_messages
from langchain.embeddings import init_embeddings
from langchain.schema.runnable import RunnableConfig
from langgraph.graph import add_messages
from langgraph.prebuilt import create_react_agent
from dotenv import load_dotenv
from pydantic import BaseModel, Field
import logging
import os
from langchain_openai import ChatOpenAI
from pydantic_core.core_schema import TypedDictSchema
import VC_chain_tools as vc_tools
import VC_chain_systemprompts as vc_systemprompts
from langgraph.store.memory import InMemoryStore
import VC_chain_database as vc_database
from langchain_core.messages import (
    BaseMessage,
    HumanMessage,
    trim_messages,
)
from typing import Annotated
from typing_extensions import TypedDict
from langgraph.checkpoint.postgres import PostgresSaver
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages

load_dotenv()                      
keyfile_path = os.getenv("SERVICE_ACCOUNT_FILE")
GOOGLE_DOC_ID = os.getenv("GOOGLE_DOC_ID")

# OpenRouter LLM class
class ChatOpenRouter(ChatOpenAI):
    @property
    def lc_secrets(self) -> dict[str, str]:
        return {"openai_api_key": "OPENROUTER_API"}

    def __init__(self,
                 openai_api_key: Optional[str] = None,
                 **kwargs):
        openai_api_key = openai_api_key or os.environ.get("OPENROUTER_API")
        super().__init__(base_url="https://openrouter.ai/api/v1", openai_api_key=openai_api_key, **kwargs)

print("Defining LLMs...")
llm_main = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)

####### Router output parser #######
class RouterOutput(TypedDict):
    query_type: Annotated[str, "The agent to be routed to"]

# --- Configure Logging ---
log = logging.getLogger(__name__)
log.setLevel(logging.INFO) # Adjust level as needed
# Ensure handler is added only once if run multiple times (e.g., in dev server reload)
if not log.handlers:
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    handler.setFormatter(formatter)
    log.addHandler(handler)




################## AGENTS ##################
class AgentState(TypedDict):
    input: str
    chat_history: list[BaseMessage]
    general_agent_check: bool
    reasoning_validated_check: bool
    output: str


################## AGENT MEMORY SUMMARIZER ##################

summarizer = create_react_agent(llm_main, tools=[], prompt="You are responsible with summarizing the chat history for an LLM to remember only the important details")
def run_summarizer(state: AgentState, config: RunnableConfig):
    if len(state["chat_history"]) > 0:
        summarizer_response = summarizer.invoke({"messages": state["chat_history"]}, config)
        return {"chat_history": [summarizer_response["messages"][-1]]}
    else:
        return {"chat_history": []}

# ------------------------------------------------------------
# -------------- ROUTER AGENT CHAIN -------------------------
# -----------CONVERTED TO LANGGRAPH REACT AGENT --------------

router_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
router_llm = router_llm.with_structured_output(RouterOutput)
#router_agent = create_react_agent(router_llm, tools=, prompt=vc_systemprompts.ROUTER_SYSTEM_PROMPT)
def run_router_model(state: AgentState, config: RunnableConfig):
    print("\033[94m🧭 Running ROUTER agent\033[0m")
    messages = [vc_systemprompts.ROUTER_SYSTEM_PROMPT, HumanMessage(content=state["input"])] + state["chat_history"]
    response = router_llm.invoke(messages, config)
    return {"output": response}


# ------------------------------------------------------------
# -------------- GENERAL AGENT CHAIN -------------------------
# -----------CONVERTED TO LANGGRAPH REACT AGENT --------------

general_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
general_agent = create_react_agent(general_llm, vc_tools.general_tools)

def run_general_model(state: AgentState, config: RunnableConfig):
    print("\033[94m🤖 Running GENERAL agent\033[0m")
    messages = [vc_systemprompts.GENERAL_SYSTEM_PROMPT, HumanMessage(content=state["input"])] + state["chat_history"]
    response = general_agent.invoke({"messages": messages}, config)
    return {"output": response["messages"][-1]}


# ------------------------------------------------------------
# -------------- RANKING AGENT CHAIN -------------------------
# -----------CONVERTED TO LANGGRAPH REACT AGENT --------------

ranking_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
ranking_agent = create_react_agent(ranking_llm, vc_tools.ranking_tools)

def run_ranking_model(state: AgentState, config: RunnableConfig):
    print("\033[94m📊 Running RANKING agent\033[0m")
    messages = [vc_systemprompts.RANKING_SYSTEM_PROMPT, HumanMessage(content=state["input"])] + state["chat_history"]
    response = ranking_agent.invoke({"messages": messages}, config)
    return {"output": response["messages"][-1]}
print(type(vc_tools.ranking_tools))


# ------------------------------------------------------------
# -------------- REASONING AGENT CHAIN -----------------------
# -----------CONVERTED TO LANGGRAPH REACT AGENT --------------

reasoning_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
reasoning_agent = create_react_agent(reasoning_llm, vc_tools.reasoning_tools, prompt=vc_systemprompts.REASONING_SYSTEM_PROMPT)

def run_reasoning_model(state: AgentState, config: RunnableConfig):
    print("\033[94m🧠 Running REASONING agent\033[0m")
    messages = [HumanMessage(content=state["input"])] + state["chat_history"]
    try:
        # Add recursion limit for the reasoning agent specifically
        reasoning_config = {**config, "configurable": {**config.get("configurable", {}), "recursion_limit": 25}}

        print(f"🔍 REASONING AGENT - Input messages: {len(messages)}")
        print(f"🔍 REASONING AGENT - User input: {state['input']}")

        response = reasoning_agent.invoke({"messages": messages}, reasoning_config)

        print(f"🔍 REASONING AGENT - Response message count: {len(response['messages'])}")
        print(f"🔍 REASONING AGENT - Response types: {[type(msg).__name__ for msg in response['messages']]}")

        # Log all the intermediate messages to see the ReAct flow
        for i, msg in enumerate(response["messages"]):
            print(f"🔍 REASONING AGENT - Message {i}: {type(msg).__name__}")
            if hasattr(msg, 'content'):
                content_preview = str(msg.content)[:500] + "..." if len(str(msg.content)) > 500 else str(msg.content)
                print(f"🔍 REASONING AGENT - Content preview: {content_preview}")
            if hasattr(msg, 'tool_calls') and msg.tool_calls:
                print(f"🔍 REASONING AGENT - Tool calls: {msg.tool_calls}")

        final_message = response["messages"][-1]
        print(f"🔍 REASONING AGENT - Final message type: {type(final_message).__name__}")
        print(f"🔍 REASONING AGENT - Final content length: {len(str(final_message.content)) if hasattr(final_message, 'content') else 'No content'}")

        return {"output": final_message}
    except Exception as e:
        print(f"Error in reasoning agent: {e}")
        return {"output": HumanMessage(content=f"Analysis encountered an error: {str(e)}")} 


reasoning_validator_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
reasoning_validator = create_react_agent(reasoning_validator_llm, vc_tools.reasoning_tools)

def run_reasoning_validator(state: AgentState, config: RunnableConfig):
    print("\033[94m🧠 Running REASONING VALIDATOR agent\033[0m")
    messages = [vc_systemprompts.REASONING_VALIDATOR_SYSTEM_PROMPT, HumanMessage(content=state["input"])] + state["chat_history"]
    response = reasoning_validator.invoke({"messages": messages}, config)
    return {"output": response["messages"][-1], "reasoning_validated_check": str("reasoning_validated_check: True") in response["messages"][-1].content}


# ------------------------------------------------------------
# -------------- PREDICTION AGENT CHAIN ----------------------
# -----------CONVERTED TO LANGGRAPH REACT AGENT --------------

prediction_llm = ChatOpenRouter(model="z-ai/glm-4.5", temperature=0)
prediction_agent = create_react_agent(prediction_llm, vc_tools.prediction_tools, prompt=vc_systemprompts.PREDICTION_SYSTEM_PROMPT)

def run_prediction_model(state: AgentState, config: RunnableConfig):
    print("\033[94m🔮 Running PREDICTION agent\033[0m")
    # Don't add system prompt here since it's already in the agent
    messages = [HumanMessage(content=state["input"])] + state["chat_history"]
    try:
        # Add recursion limit for the prediction agent specifically
        prediction_config = {**config, "configurable": {**config.get("configurable", {}), "recursion_limit": 15}}
        response = prediction_agent.invoke({"messages": messages}, prediction_config)
        return {"output": response["messages"][-1]}
    except Exception as e:
        print(f"Error in prediction agent: {e}")
        return {"output": HumanMessage(content=f"Prediction analysis encountered an error: {str(e)}")}

# ------------------------------------------------------------
# -------------- NEW FULL CHAIN ------------------------------
# ------------------LANGGRAPH---------------------------------

graph_builder = StateGraph(AgentState)

def router_function(state: AgentState):
    print("routed to the " + state["output"]["query_type"])
    if state["general_agent_check"] == True:
        return "general"
    else:
        # Parse router agent's JSON response
        router_output = state["output"]["query_type"]
        if "prediction_agent_query" in router_output:
            return "prediction"
        elif "ranking_agent_query" in router_output:
            return "ranking"
        elif "reasoning_agent_query" in router_output:
            return "reasoning"
        else:
            return "general"

def validator_function(state: AgentState):
    if state["reasoning_validated_check"] == False:
        return "reasoning"
    else:
        return "END"

# -------------------CHAIN ASSEMBLY--------------------------

graph_builder.add_node("summarizer", run_summarizer)
graph_builder.add_node("router", run_router_model)
graph_builder.add_node("general", run_general_model)
graph_builder.add_node("ranking", run_ranking_model)
graph_builder.add_node("reasoning", run_reasoning_model)
graph_builder.add_node("prediction", run_prediction_model)
graph_builder.add_node("reasoning_validator", run_reasoning_validator)

graph_builder.add_edge(START, "router")
#graph_builder.add_edge("router", "summarizer")
graph_builder.add_conditional_edges("router", router_function, {"general": "general", "ranking": "ranking", "reasoning": "reasoning", "prediction": "prediction"})
graph_builder.add_edge("general", END)
graph_builder.add_edge("ranking", END)
graph_builder.add_edge("reasoning", END)
#graph_builder.add_edge("reasoning", "reasoning_validator")
#graph_builder.add_conditional_edges("reasoning_validator", validator_function, {"END": END, "reasoning": "reasoning"})
graph_builder.add_edge("prediction", END)



# -----------------------------------------------------------------------
# -------------- NEW FULL CHAIN VISUALIZATION ---------------------------
# ------------------LANGGRAPH VISUALIZED---------------------------------

#checkpointer = PostgresSaver.from_conn_string(os.getenv("POSTGRES_URL"))
#checkpointer.setup()    
#graph = graph_builder.compile(checkpointer=checkpointer)
graph = graph_builder.compile()

try:
    png_bytes = graph.get_graph().draw_mermaid_png()
    with open("vc_chain_graph.png", "wb") as f:
        f.write(png_bytes)
except Exception:
    # This requires some extra dependencies and is optional
    pass



def get_assistant_response(user_input: str, session_id: str, general_agent_check: bool, chat_history: list[BaseMessage]):
    state = {"input": user_input, "chat_history": chat_history, "general_agent_check": general_agent_check}
    try:
        response = graph.invoke(state, {"configurable": {"thread_id": session_id, "recursion_limit": 50}})
        print(response)
        ai_message = response["output"]
        return ai_message.content if hasattr(ai_message, 'content') else str(ai_message)
    except Exception as e:
        print(f"Error in get_assistant_response: {e}")
        return "I apologize, but I encountered an error processing your request. Please try again."





