"""
FastAPI application for Lambda Web Adapter.
This enables true HTTP streaming via Lambda Function URL.
"""
import os
import json
import asyncio
import boto3
from fastapi import FastAPI, Query
from fastapi.responses import StreamingResponse

# Fetch SSM parameters at cold start
def get_ssm_parameters():
    """Fetch secrets from SSM Parameter Store."""
    if os.environ.get("AWS_EXECUTION_ENV"):
        ssm = boto3.client('ssm')
        try:
            response = ssm.get_parameters(
                Names=['/streaming-agent/OPENAI_API_KEY', '/streaming-agent/SERPAPI_API_KEY'],
                WithDecryption=True
            )
            for param in response['Parameters']:
                name = param['Name'].split('/')[-1]
                os.environ[name] = param['Value']
        except Exception as e:
            print(f"Error fetching SSM parameters: {e}")

get_ssm_parameters()

# Import after env vars are set
from agent import QueueCallbackHandler, agent_executor

app = FastAPI()

# Note: CORS is handled by Lambda Function URL configuration
# Do not add CORSMiddleware here to avoid duplicate headers


async def stream_generator(content: str):
    """Async generator that yields chunks as they're ready."""
    queue = asyncio.Queue()
    streamer = QueueCallbackHandler(queue)
    
    # Run agent invoke in the background
    task = asyncio.create_task(agent_executor.invoke(
        input=content,
        streamer=streamer,
        verbose=True
    ))
    
    final_answer_started = False
    final_answer_complete = False
    
    while True:
        if queue.empty():
            if task.done():
                break
            await asyncio.sleep(0.05)
            continue
        
        token = await queue.get()
        
        if token == "<<DONE>>":
            break
            
        try:
            if token == "<<STEP_END>>":
                if not final_answer_complete:
                    yield "</step>"
                    if final_answer_started:
                        final_answer_complete = True
            else:
                if final_answer_complete:
                    continue
                    
                tool_name = None
                tool_args = None
                
                if hasattr(token, 'message'):
                    msg = token.message
                    if hasattr(msg, 'tool_calls') and msg.tool_calls:
                        tc = msg.tool_calls[0]
                        tool_name = tc.get('name', '')
                        tool_args = tc.get('args', {})
                        if isinstance(tool_args, dict) and tool_args:
                            tool_args = json.dumps(tool_args)
                        elif isinstance(tool_args, dict):
                            tool_args = None
                    
                    if hasattr(msg, 'tool_call_chunks') and msg.tool_call_chunks:
                        tc = msg.tool_call_chunks[0]
                        if tc.get('name'):
                            tool_name = tc['name']
                        if tc.get('args'):
                            tool_args = tc['args']
                    
                    if not tool_name and not tool_args:
                        if hasattr(msg, 'additional_kwargs') and msg.additional_kwargs.get("tool_calls"):
                            tc = msg.additional_kwargs["tool_calls"][0]
                            tool_name = tc["function"].get("name")
                            tool_args = tc["function"].get("arguments")
                
                if tool_name:
                    yield f"<step><step_name>{tool_name}</step_name>"
                    if tool_name == 'final_answer':
                        final_answer_started = True
                if tool_args:
                    yield tool_args
        except Exception as e:
            print(f"Error streaming token: {e}")
            continue
    
    if not task.done():
        await task


@app.get("/health")
async def health():
    return {"status": "healthy"}


@app.post("/invoke")
async def invoke(content: str = Query(...)):
    """Stream response from agent."""
    return StreamingResponse(
        stream_generator(content),
        media_type="text/plain",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        }
    )


# For local testing
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
