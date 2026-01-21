FROM public.ecr.aws/lambda/python:3.12

# Copy requirements first for better caching
COPY requirements-lambda.txt ${LAMBDA_TASK_ROOT}/

# Install dependencies
RUN pip install --no-cache-dir -r requirements-lambda.txt

# Copy application code
COPY agent.py ${LAMBDA_TASK_ROOT}/
COPY main.py ${LAMBDA_TASK_ROOT}/
COPY lambda_handler.py ${LAMBDA_TASK_ROOT}/

# Set the handler
CMD [ "lambda_handler.handler" ]
