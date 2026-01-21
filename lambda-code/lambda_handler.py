"""
AWS Lambda handler for FastAPI streaming application.
Supports Lambda Function URL with response streaming.
"""
import os
import json
import asyncio
import boto3

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

async def stream_response(content: str):
    """Stream response from agent - adapted for Lambda."""
    queue = asyncio.Queue()
    streamer = QueueCallbackHandler(queue)
    
    # Run agent invoke in the background
    task = asyncio.create_task(agent_executor.invoke(
        input=content,
        streamer=streamer,
        verbose=True
    ))
    
    result = []
    final_answer_started = False   # True when we START streaming final_answer
    final_answer_complete = False  # True when we COMPLETE final_answer (STEP_END received)
    
    # Collect tokens from streamer until done
    while True:
        # Check if streamer has tokens
        if queue.empty():
            if task.done():
                break
            await asyncio.sleep(0.1)
            continue
        
        token = await queue.get()
        
        if token == "<<DONE>>":
            break
            
        try:
            if token == "<<STEP_END>>":
                # Only output step end if we haven't completed final_answer yet
                if not final_answer_complete:
                    result.append("</step>")
                    # If we were in final_answer, mark it complete now
                    if final_answer_started:
                        final_answer_complete = True
            else:
                # Skip everything after final_answer is complete
                if final_answer_complete:
                    continue
                    
                # Get tool calls - handle new langchain format
                tool_name = None
                tool_args = None
                
                if hasattr(token, 'message'):
                    msg = token.message
                    # New langchain format: tool_calls has complete info on first chunk
                    if hasattr(msg, 'tool_calls') and msg.tool_calls:
                        tc = msg.tool_calls[0]
                        tool_name = tc.get('name', '')
                        tool_args = tc.get('args', {})
                        # Args might be a dict, convert to JSON string
                        if isinstance(tool_args, dict) and tool_args:
                            tool_args = json.dumps(tool_args)
                        elif isinstance(tool_args, dict):
                            tool_args = None
                    
                    # tool_call_chunks streams args - only has name on first chunk
                    if hasattr(msg, 'tool_call_chunks') and msg.tool_call_chunks:
                        tc = msg.tool_call_chunks[0]
                        if tc.get('name'):
                            tool_name = tc['name']
                        if tc.get('args'):
                            # This is a streaming chunk of args JSON
                            tool_args = tc['args']
                    
                    # Old format fallback
                    if not tool_name and not tool_args:
                        if hasattr(msg, 'additional_kwargs') and msg.additional_kwargs.get("tool_calls"):
                            tc = msg.additional_kwargs["tool_calls"][0]
                            tool_name = tc["function"].get("name")
                            tool_args = tc["function"].get("arguments")
                
                if tool_name:
                    result.append(f"<step><step_name>{tool_name}</step_name>")
                    if tool_name == 'final_answer':
                        final_answer_started = True
                if tool_args:
                    result.append(tool_args)
        except Exception as e:
            print(f"Error streaming token: {e}")
            continue
    
    # Ensure task completes
    if not task.done():
        await task
    return ''.join(result)

def handler(event, context):
    """Lambda handler for Function URL with streaming support."""
    
    # Parse request
    http_method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    path = event.get('rawPath', '/')
    query_params = event.get('queryStringParameters', {}) or {}
    
    # Health check
    if path == '/health' and http_method == 'GET':
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'status': 'healthy'})
        }
    
    # Invoke endpoint
    if path == '/invoke' and http_method == 'POST':
        content = query_params.get('content', '')
        
        if not content:
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({'error': 'content parameter required'})
            }
        
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
        
        try:
            response_body = loop.run_until_complete(stream_response(content))
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'text/plain',
                    'Cache-Control': 'no-cache',
                },
                'body': response_body
            }
        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()
            return {
                'statusCode': 500,
                'headers': {'Content-Type': 'application/json'},
                'body': json.dumps({'error': str(e)})
            }
    
    # Default 404
    return {
        'statusCode': 404,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps({'error': 'Not found'})
    }


# Streaming handler for RESPONSE_STREAM mode
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


def streaming_handler(event, context):
    """Handler for Lambda Response Streaming mode."""
    http_method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    path = event.get('rawPath', '/')
    query_params = event.get('queryStringParameters', {}) or {}
    
    if path == '/invoke' and http_method == 'POST':
        content = query_params.get('content', '')
        
        if not content:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'content parameter required'})
            }
        
        # For streaming, we need to return a generator
        # But Lambda doesn't support native async generators yet
        # So we fall back to buffered response
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
        
        response_body = loop.run_until_complete(stream_response(content))
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'text/plain'},
            'body': response_body
        }
    
    return handler(event, context)
