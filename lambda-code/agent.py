import asyncio
import aiohttp
import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), '..', '..', '.env'))

from langchain_core.callbacks import AsyncCallbackHandler
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.runnables import ConfigurableField
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from pydantic import BaseModel, SecretStr


# Constants and Configuration
OPENAI_API_KEY = SecretStr(os.environ["OPENAI_API_KEY"])
SERPAPI_API_KEY = SecretStr(os.environ["SERPAPI_API_KEY"])

# LLM and Prompt Setup
llm = ChatOpenAI(
    model="gpt-4o-mini",
    temperature=0.0,
    streaming=True,
    api_key=OPENAI_API_KEY
).configurable_fields(
    callbacks=ConfigurableField(
        id="callbacks",
        name="callbacks",
        description="A list of callbacks to use for streaming",
    )
)

prompt = ChatPromptTemplate.from_messages([
    ("system", (
        "You're a helpful assistant. When answering a user's question "
        "you should first use one of the tools provided. After using a "
        "tool the tool output will be provided back to you. When you have "
        "all the information you need, you MUST use the final_answer tool "
        "to provide a final answer to the user. Use tools to answer the "
        "user's CURRENT question, not previous questions."
    )),
    MessagesPlaceholder(variable_name="chat_history"),
    ("human", "{input}"),
    MessagesPlaceholder(variable_name="agent_scratchpad"),
])

# we use the article object for parsing serpapi results later
class Article(BaseModel):
    title: str
    source: str
    link: str
    snippet: str

    @classmethod
    def from_serpapi_result(cls, result: dict) -> "Article":
        return cls(
            title=result["title"],
            source=result["source"],
            link=result["link"],
            snippet=result["snippet"],
        )

# Tools definition
# note: we define all tools as async to simplify later code, but only the serpapi
# tool is actually async
@tool
async def add(x: float, y: float) -> float:
    """Add 'x' and 'y'."""
    return x + y

@tool
async def multiply(x: float, y: float) -> float:
    """Multiply 'x' and 'y'."""
    return x * y

@tool
async def exponentiate(x: float, y: float) -> float:
    """Raise 'x' to the power of 'y'."""
    return x ** y

@tool
async def subtract(x: float, y: float) -> float:
    """Subtract 'x' from 'y'."""
    return y - x

@tool
async def serpapi(query: str) -> list[Article]:
    """Use this tool to search the web."""
    params = {
        "api_key": SERPAPI_API_KEY.get_secret_value(),
        "engine": "google",
        "q": query,
    }
    async with aiohttp.ClientSession() as session:
        async with session.get(
            "https://serpapi.com/search",
            params=params
        ) as response:
            results = await response.json()
    return [Article.from_serpapi_result(result) for result in results["organic_results"]]

@tool
async def final_answer(answer: str, tools_used: list[str]) -> dict[str, str | list[str]]:
    """Use this tool to provide a final answer to the user."""
    return {"answer": answer, "tools_used": tools_used}

tools = [add, subtract, multiply, exponentiate, final_answer, serpapi]
# note when we have sync tools we use tool.func, when async we use tool.coroutine
name2tool = {tool.name: tool.coroutine for tool in tools}

# Streaming Handler
class QueueCallbackHandler(AsyncCallbackHandler):
    def __init__(self, queue: asyncio.Queue):
        self.queue = queue
        self.final_answer_seen = False

    async def __aiter__(self):
        while True:
            if self.queue.empty():
                await asyncio.sleep(0.1)
                continue
            token_or_done = await self.queue.get()
            if token_or_done == "<<DONE>>":
                return
            if token_or_done:
                yield token_or_done
    
    async def on_llm_new_token(self, *args, **kwargs) -> None:
        chunk = kwargs.get("chunk")
        if chunk:
            msg = chunk.message
            tool_name = None
            
            # New langchain format: check tool_calls first
            if hasattr(msg, 'tool_calls') and msg.tool_calls:
                tool_name = msg.tool_calls[0].get('name', '')
            # Also check tool_call_chunks for streaming
            elif hasattr(msg, 'tool_call_chunks') and msg.tool_call_chunks:
                tool_name = msg.tool_call_chunks[0].get('name', '')
            # Old format fallback
            elif hasattr(msg, 'additional_kwargs') and msg.additional_kwargs.get("tool_calls"):
                tool_name = msg.additional_kwargs["tool_calls"][0]["function"].get("name")
            
            if tool_name == "final_answer":
                self.final_answer_seen = True
        
        self.queue.put_nowait(kwargs.get("chunk"))
    
    async def on_llm_end(self, *args, **kwargs) -> None:
        if self.final_answer_seen:
            self.queue.put_nowait("<<DONE>>")
        else:
            self.queue.put_nowait("<<STEP_END>>")

async def execute_tool(tool_call: AIMessage) -> ToolMessage:
    tool_name = tool_call.tool_calls[0]["name"]
    tool_args = tool_call.tool_calls[0]["args"]
    tool_out = await name2tool[tool_name](**tool_args)
    return ToolMessage(
        content=f"{tool_out}",
        tool_call_id=tool_call.tool_calls[0]["id"]
    )

# Agent Executor
class CustomAgentExecutor:
    def __init__(self, max_iterations: int = 3):
        self.chat_history: list[BaseMessage] = []
        self.max_iterations = max_iterations
        self.agent = (
            {
                "input": lambda x: x["input"],
                "chat_history": lambda x: x["chat_history"],
                "agent_scratchpad": lambda x: x.get("agent_scratchpad", [])
            }
            | prompt
            | llm.bind_tools(tools, tool_choice="any")
        )

    async def invoke(self, input: str, streamer: QueueCallbackHandler, verbose: bool = False) -> dict:
        # invoke the agent but we do this iteratively in a loop until
        # reaching a final answer
        count = 0
        final_answer: str | None = None
        agent_scratchpad: list[AIMessage | ToolMessage] = []
        # streaming function
        async def stream(query: str) -> list[AIMessage]:
            response = self.agent.with_config(
                callbacks=[streamer]
            )
            # we initialize the output dictionary that we will be populating with
            # our streamed output
            outputs = []
            # now we begin streaming
            async for token in response.astream({
                "input": query,
                "chat_history": self.chat_history,
                "agent_scratchpad": agent_scratchpad
            }):
                # Handle new langchain format - check tool_call_chunks for streaming
                tool_call_chunks = None
                tool_calls_complete = None
                
                if hasattr(token, 'tool_call_chunks') and token.tool_call_chunks:
                    tool_call_chunks = token.tool_call_chunks
                if hasattr(token, 'tool_calls') and token.tool_calls:
                    tool_calls_complete = token.tool_calls
                
                # Also check old format for backwards compatibility
                if not tool_call_chunks and not tool_calls_complete:
                    if hasattr(token, 'additional_kwargs') and token.additional_kwargs.get("tool_calls"):
                        tool_call_chunks = token.additional_kwargs.get("tool_calls")
                
                if tool_call_chunks or tool_calls_complete:
                    # Check if this is a new tool call (has id or name in first chunk)
                    chunk_or_call = tool_call_chunks[0] if tool_call_chunks else (tool_calls_complete[0] if tool_calls_complete else None)
                    if chunk_or_call:
                        # New tool call if has id or name
                        has_id = chunk_or_call.get("id") if isinstance(chunk_or_call, dict) else getattr(chunk_or_call, 'id', None)
                        has_name = chunk_or_call.get("name") if isinstance(chunk_or_call, dict) else getattr(chunk_or_call, 'name', None)
                        
                        if has_id or has_name:
                            outputs.append(token)
                        elif outputs:
                            outputs[-1] += token
                else:
                    pass
            
            return [
                AIMessage(
                    content=x.content,
                    tool_calls=x.tool_calls,
                    tool_call_id=x.tool_calls[0]["id"] if x.tool_calls else None
                ) for x in outputs if x.tool_calls
            ]

        while count < self.max_iterations:
            # invoke a step for the agent to generate a tool call
            tool_calls = await stream(query=input)
            # gather tool execution coroutines
            tool_obs = await asyncio.gather(
                *[execute_tool(tool_call) for tool_call in tool_calls]
            )
            # append tool calls and tool observations to the scratchpad in order
            id2tool_obs = {tool_call.tool_call_id: tool_obs for tool_call, tool_obs in zip(tool_calls, tool_obs)}
            for tool_call in tool_calls:
                agent_scratchpad.extend([
                    tool_call,
                    id2tool_obs[tool_call.tool_call_id]
                ])
            
            count += 1
            # if the tool call is the final answer tool, we stop
            found_final_answer = False
            for tool_call in tool_calls:
                if tool_call.tool_calls[0]["name"] == "final_answer":
                    final_answer_call = tool_call.tool_calls[0]
                    final_answer = final_answer_call["args"]["answer"]
                    found_final_answer = True
                    break
            
            # Only break the loop if we found a final answer
            if found_final_answer:
                break
            
        # add the final output to the chat history, we only add the "answer" field
        self.chat_history.extend([
            HumanMessage(content=input),
            AIMessage(content=final_answer if final_answer else "No answer found")
        ])
        # return the final answer in dict form
        return final_answer_call if final_answer else {"answer": "No answer found", "tools_used": []}

# Initialize agent executor
agent_executor = CustomAgentExecutor()  