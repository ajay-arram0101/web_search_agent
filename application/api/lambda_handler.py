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
    """Stream response from agent."""
    queue = asyncio.Queue()
    streamer = QueueCallbackHandler(queue)
    
    task = asyncio.create_task(agent_executor.invoke(
        input=content,
        streamer=streamer,
        verbose=True
    ))
    
    async for token in streamer:
        try:
            if token == "<<STEP_END>>":
                yield "</step>"
            elif hasattr(token, 'message') and token.message.additional_kwargs.get("tool_calls"):
                tool_calls = token.message.additional_kwargs["tool_calls"]
                if tool_name := tool_calls[0]["function"].get("name"):
                    yield f"<step><step_name>{tool_name}</step_name>"
                if tool_args := tool_calls[0]["function"].get("arguments"):
                    yield tool_args
        except Exception as e:
            print(f"Error streaming token: {e}")
            continue
    
    await task

def handler(event, context):
    """Lambda handler for Function URL."""
    
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
        
        # Run the agent and collect all output
        async def run_agent():
            result = []
            async for chunk in stream_response(content):
                result.append(chunk)
            return ''.join(result)
        
        try:
            loop = asyncio.get_event_loop()
        except RuntimeError:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
        
        try:
            response_body = loop.run_until_complete(run_agent())
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'text/event-stream',
                    'Cache-Control': 'no-cache',
                    'Access-Control-Allow-Origin': '*',
                    'Access-Control-Allow-Methods': '*',
                    'Access-Control-Allow-Headers': '*'
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
