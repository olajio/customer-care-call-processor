# Manual AWS Resource Setup (Step-by-Step, AWS Console)

This document is a **click-by-click** guide to manually create the same AWS resources that this repo provisions with Terraform (see [terraform](terraform)).

If you follow these steps exactly, you’ll end up with:
- [S3 bucket(s) for audio/transcripts/summaries](#create-s3)
- [DynamoDB tables (3)](#create-dynamodb)
- [Secrets Manager secrets (Google service account JSON + webhook token)](#create-secrets)
- [IAM roles/policies (Lambda + Step Functions + optional API Gateway logging role)](#create-iam)
- [Lambda layer + Lambda functions (11)](#create-lambdas)
- [Step Functions state machine](#create-step-functions)
- [API Gateway (HTTP API + WebSocket API)](#create-api-gateway)
- [Cognito User Pool + Domain + App Client + Groups](#create-cognito)
- [Monitoring: CloudWatch log groups, dashboard, alarms + SNS topic](#create-monitoring)

The goal is to **not assume you already know AWS Console workflows**.

---

## 0) Before You Start

### 0.1 Sign in + pick your region
1. Sign in to the AWS Console.
2. In the top-right region selector, choose your region (default in Terraform: `us-east-1`).
3. Keep the same region for every service in this guide.

### 0.2 Permissions you need
You need permissions to create IAM roles/policies, Lambda, API Gateway, Step Functions, Cognito, S3, DynamoDB, CloudWatch, SNS, Secrets Manager.

If you don’t have admin access, make sure your IAM user/role has the deployer policy described in [SETUP_GUIDE.md](SETUP_GUIDE.md).

### 0.3 Fill in your “values worksheet” (don’t skip)
Pick values once, then reuse them everywhere:

- `aws_region`: `us-east-1`
- `environment`: `dev` (or `staging`, `prod`)
- `project_name`: `customer-care-call-processor`
- `s3_bucket_name`: (must be globally unique, example: `customer-care-call-processor-dev-<yourname>-<random>`)
- `google_credentials_secret_name`: default in Terraform: `google-drive-credentials`
- `webhook_token_secret_name`: recommended: `customer-care-call-processor-webhook-config`
- `cognito_domain_prefix`: default in Terraform: `call-processor`
- `gdrive_folder_id`: your Google Drive folder ID

### 0.4 Recommended creation order (reduces backtracking)
1. S3
2. DynamoDB
3. Secrets Manager
4. IAM roles/policies
5. Cognito
6. API Gateway (HTTP + WebSocket)
7. Lambda layer + Lambdas (some env vars reference APIs and Step Functions; you’ll set placeholders and come back)
8. Step Functions
9. Monitoring (SNS, alarms, dashboards)

### 0.5 One AWS “gotcha”: Amazon Bedrock model access
If you plan to use the Bedrock summarization Lambda, you must enable model access:
1. Open **Amazon Bedrock** in the Console.
2. Go to **Model access**.
3. Request/enable access to the model family you will call (Terraform defaults to Claude: `anthropic.claude-3-5-sonnet-*`).

### 0.6 Test as you go (unit tests + smoke tests)
You can test this system at two levels:

1) **Unit tests (local, fast)**
- These run on your laptop and validate the Python logic without deploying AWS infrastructure.
- They live under [tests](tests) and run with `pytest`.

2) **Smoke/integration checks (AWS, slower)**
- These verify the AWS resources are created correctly and can be called.
- For infrastructure (S3/DynamoDB/IAM/API Gateway), AWS CLI checks are more realistic than “unit tests”.

Local unit test setup (recommended):
1. Create/activate a virtual environment.
2. Install dependencies:
   - `pip install -r requirements.txt`
3. Run unit tests:
   - `pytest -m "not integration" -v`

Useful test files:
- Webhook handler: [tests/test_webhook_handler.py](tests/test_webhook_handler.py)
- Transcribe + processing: [tests/test_processing.py](tests/test_processing.py)
- API handlers: [tests/test_api.py](tests/test_api.py)

If you want to run AWS integration tests (only after deploying resources):
- Some integration tests are gated by environment variables (example: `RUN_INTEGRATION_TESTS=true`).
- Start with the AWS CLI “smoke tests” in each section below before running integration test suites.

---

<a id="create-s3"></a>
## 1) Create S3 Buckets
Source: [terraform/s3.tf](terraform/s3.tf)

### 1.1 Create the primary bucket
1. Go to **S3** → **Buckets** → **Create bucket**.
2. **Bucket name**: your `s3_bucket_name`.
3. **AWS Region**: same as your worksheet.
4. **Object Ownership**: keep default (recommended).
5. **Block Public Access settings**: leave **Block all public access = ON**.
6. **Bucket Versioning**:
   - `prod`: **Enable**
   - non-prod: **Suspend** (or leave disabled)
7. **Default encryption**:
   - **Server-side encryption**: enable
   - **Encryption type**: `SSE-S3`
8. Click **Create bucket**.

### 1.1.1 (If needed) Allow Amazon Transcribe to write output to this bucket
This project’s `start_transcribe` Lambda starts jobs with `OutputBucketName` + `OutputKey` (see [src/lambda/processing/start_transcribe.py](src/lambda/processing/start_transcribe.py)).

In most same-account setups with `SSE-S3` encryption, Transcribe can write to the output bucket without extra work. If Transcribe fails with an S3 `AccessDenied` (or the job shows failure writing output), add a bucket policy that allows the Transcribe service principal to write to your transcripts prefix.

S3 → your bucket → **Permissions** → **Bucket policy** → add a statement like:

```json
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Sid": "AllowTranscribeWrite",
         "Effect": "Allow",
         "Principal": {"Service": "transcribe.amazonaws.com"},
         "Action": ["s3:PutObject"],
         "Resource": "arn:aws:s3:::<s3_bucket_name>/transcripts/*",
         "Condition": {
            "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"},
            "ArnLike": {"aws:SourceArn": "arn:aws:transcribe:<REGION>:<ACCOUNT_ID>:transcription-job/*"}
         }
      }
   ]
}
```

If you don’t want to add a policy, an alternative is to omit `OutputBucketName` and let Transcribe write to its default output location and then fetch the result by URI; this repo currently uses `OutputBucketName`, so bucket access must be correct.

### 1.2 Configure CORS (dev only)
1. Open the bucket → **Permissions** tab.
2. Scroll to **Cross-origin resource sharing (CORS)** → **Edit**.
3. Paste the CORS configuration:
```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedOrigins": ["http://localhost:3000", "http://localhost:5173"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```
4. Click **Save changes**.

### 1.3 Configure lifecycle rules
1. Open the bucket → **Management** tab.
2. Under **Lifecycle rules**, click **Create lifecycle rule**.

Rule A: raw audio archival
1. **Lifecycle rule name**: `archive-raw-audio`.
2. **Filter**: choose **Prefix** and set `raw-audio/`.
3. **Lifecycle rule actions**:
   - **Move current versions of objects between storage classes**:
     - Transition after `90` days → `Glacier Instant Retrieval`
     - Transition after `365` days → `Glacier Deep Archive`
   - **Expire current versions of objects** after `2555` days.
4. Save.

Rule B: transcripts archival
1. Create another rule named `archive-transcripts`.
2. Prefix: `transcripts/`.
3. Transition after `180` days → `Glacier Instant Retrieval`.
4. Expire after `2555` days.

Rule C: abort incomplete multipart uploads
1. Create another rule named `cleanup-incomplete-uploads`.
2. No filter needed.
3. Enable **Abort incomplete multipart uploads** after `7` days.

### 1.4 (Prod only) Create a logs bucket and enable access logging
Terraform creates a logs bucket only for `prod`.

1. Create another bucket named `${s3_bucket_name}-logs`.
2. Keep **Block Public Access = ON**.
3. Add a lifecycle rule to expire logs after `90` days.
4. Go back to your primary bucket → **Properties**.
5. Find **Server access logging** → **Edit** → **Enable**.
6. Target bucket: `${s3_bucket_name}-logs`.
7. Prefix: `s3-access-logs/`.
8. Save.

### 1.5 Test / verify S3
AWS CLI smoke tests (replace values from your worksheet):
1. Confirm bucket exists:
   - `aws s3api head-bucket --bucket <s3_bucket_name>`
2. Confirm encryption is enabled:
   - `aws s3api get-bucket-encryption --bucket <s3_bucket_name>`
3. Confirm public access block:
   - `aws s3api get-public-access-block --bucket <s3_bucket_name>`
4. Confirm CORS (dev only):
   - `aws s3api get-bucket-cors --bucket <s3_bucket_name>`
5. Confirm lifecycle rules:
   - `aws s3api get-bucket-lifecycle-configuration --bucket <s3_bucket_name>`
6. Upload + download a test object:
   - `echo "hello" > /tmp/s3-test.txt`
   - `aws s3 cp /tmp/s3-test.txt s3://<s3_bucket_name>/test/s3-test.txt`
   - `aws s3 cp s3://<s3_bucket_name>/test/s3-test.txt /tmp/s3-test-downloaded.txt`
   - `diff /tmp/s3-test.txt /tmp/s3-test-downloaded.txt`
   - Cleanup: `aws s3 rm s3://<s3_bucket_name>/test/s3-test.txt`

---

<a id="create-dynamodb"></a>
## 2) Create DynamoDB Tables (3)
Source: [terraform/dynamodb.tf](terraform/dynamodb.tf)

General DynamoDB notes:
- Billing mode in Terraform defaults to `PAY_PER_REQUEST`.
- Server-side encryption is enabled.
- TTL is enabled for the connections/channels tables.

### 2.1 Call summaries table
1. Go to **DynamoDB** → **Tables** → **Create table**.
2. **Table name**: `${project_name}-summaries-${environment}`.
3. **Partition key**: `call_id` (Type: **String**).
4. **Table settings**: choose **Customize settings**.
5. **Billing mode**: **On-demand (PAY_PER_REQUEST)**.
6. **Encryption at rest**: keep enabled.
7. Click **Create table**.

Add attributes + GSIs
1. Open the table → **Indexes** tab → **Create index**.
2. Create GSI: `status-index`
   - Partition key: `status` (String)
   - Sort key: `created_at` (String)
   - Projection: **All**
3. Create GSI: `user-index`
   - Partition key: `assigned_user_id` (String)
   - Sort key: `created_at` (String)
   - Projection: **All**

Point-in-time recovery (prod only)
1. Open the table → **Backups** tab.
2. Under **Point-in-time recovery**, click **Edit**.
3. Enable for `prod`.

### 2.2 WebSocket connections table
1. DynamoDB → Tables → **Create table**.
2. **Table name**: `${project_name}-connections-${environment}`.
3. Partition key: `connection_id` (String).
4. Customize settings → On-demand billing.
5. Create.

Create GSI: `user-index`
1. Table → **Indexes** → **Create index**.
2. Partition key: `user_id` (String)
3. Projection: All

Enable TTL
1. Table → **Additional settings** (or **Table details**) → find **Time to Live (TTL)**.
2. Click **Enable TTL**.
3. TTL attribute name: `ttl`.

### 2.3 Webhook channels table
1. DynamoDB → Tables → **Create table**.
2. **Table name**: `${project_name}-channels-${environment}`.
3. Partition key: `channel_id` (String).
4. Customize settings → On-demand billing.
5. Create.

Create GSI: `folder-index`
1. Table → **Indexes** → **Create index**.
2. Partition key: `folder_id` (String)
3. Projection: All

Enable TTL
1. Enable TTL using attribute name `ttl`.

### 2.4 Test / verify DynamoDB
AWS CLI smoke tests:
1. Confirm tables exist:
   - `aws dynamodb describe-table --table-name ${project_name}-summaries-${environment}`
   - `aws dynamodb describe-table --table-name ${project_name}-connections-${environment}`
   - `aws dynamodb describe-table --table-name ${project_name}-channels-${environment}`
2. Confirm required GSIs:
   - In each `describe-table` output, look for `GlobalSecondaryIndexes`.
3. Put/get a test item in the summaries table:
   - `NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)`
   - `aws dynamodb put-item --table-name ${project_name}-summaries-${environment} --item '{"call_id":{"S":"test-call-001"},"status":{"S":"TESTING"},"created_at":{"S":"'"$NOW"'"}}'`
   - `aws dynamodb get-item --table-name ${project_name}-summaries-${environment} --key '{"call_id":{"S":"test-call-001"}}'`
   - Cleanup: `aws dynamodb delete-item --table-name ${project_name}-summaries-${environment} --key '{"call_id":{"S":"test-call-001"}}'`

---

<a id="create-secrets"></a>
## 3) Create Secrets in AWS Secrets Manager

Terraform expects a Google credentials secret name (default `google-drive-credentials`) and the system also needs a webhook token.

### 3.1 Store Google service account JSON
1. Go to **Secrets Manager** → **Secrets** → **Store a new secret**.
2. **Secret type**: choose **Other type of secret**.
3. Under **Key/value pairs**, switch to **Plaintext**.
4. Paste the full JSON for your Google service account key.
5. Click **Next**.
6. **Secret name**: your `google_credentials_secret_name`.
7. Click **Next** through the remaining steps (rotation can be **Disabled** for dev).
8. Click **Store**.

### 3.2 Generate + store a webhook token
The webhook handler validates requests using `WEBHOOK_TOKEN` (environment variable). This guide recommends storing it in Secrets Manager too, then copying it into the Lambda env var.

1. Generate a token on your machine:
   - `openssl rand -hex 32`
2. Secrets Manager → **Store a new secret** → **Other type of secret** → **Plaintext**.
3. Store JSON like:
```json
{ "webhook_token": "<paste-token-here>" }
```
4. **Secret name**: your `webhook_token_secret_name` (recommended: `customer-care-call-processor-webhook-config`).
5. Store.

### 3.3 Test / verify Secrets Manager
AWS CLI smoke tests:
1. Confirm the secret exists:
   - `aws secretsmanager describe-secret --secret-id <google_credentials_secret_name>`
2. Confirm you can read it (this should return JSON):
   - `aws secretsmanager get-secret-value --secret-id <google_credentials_secret_name> --query SecretString --output text | head -c 200 && echo`

Note: you should not print secrets in logs or commit them to git.

---

<a id="create-iam"></a>
## 4) Create IAM Roles and Policies
Sources: [terraform/iam.tf](terraform/iam.tf), [terraform/step_functions.tf](terraform/step_functions.tf)

AWS Console path: **IAM** → **Roles**.

### 4.1 Lambda execution role
Goal: a role that every Lambda function uses.

1. IAM → Roles → **Create role**.
2. **Trusted entity type**: AWS service.
3. **Use case**: **Lambda**.
4. Click **Next**.
5. Attach managed permissions:
   - `AWSLambdaBasicExecutionRole`
   - `AWSXRayDaemonWriteAccess`
6. Click **Next**.
7. **Role name**: `${project_name}-lambda-role-${environment}`.
8. Create role.

Add the base inline policy (no “future ARNs”)
1. Open the new role.
2. Go to **Permissions** tab → **Add permissions** → **Create inline policy**.
3. Choose **JSON**.
4. Paste and edit this policy. You must replace placeholders like `<S3_BUCKET_ARN>` with real values.
   - Tip: open each resource in the Console and copy its ARN.

Important:
- At this point in the guide, you *do not yet have* the Step Functions state machine ARN, the WebSocket API execution ARN, or the SNS topic ARN.
- So this base policy intentionally does **not** include:
   - `states:StartExecution` (add after Section 6)
   - `execute-api:ManageConnections` (add after Section 8)
   - `sns:Publish` (add after Section 9)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
         "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "<S3_BUCKET_ARN>/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "<S3_BUCKET_ARN>"
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"],
      "Resource": [
        "<DDB_SUMMARIES_TABLE_ARN>",
        "<DDB_SUMMARIES_TABLE_ARN>/index/*",
        "<DDB_CONNECTIONS_TABLE_ARN>",
        "<DDB_CONNECTIONS_TABLE_ARN>/index/*",
        "<DDB_CHANNELS_TABLE_ARN>",
        "<DDB_CHANNELS_TABLE_ARN>/index/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:<REGION>:<ACCOUNT_ID>:secret:<GOOGLE_SECRET_NAME>*"]
    },
    {
      "Effect": "Allow",
      "Action": ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob", "transcribe:ListTranscriptionJobs"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": ["arn:aws:bedrock:<REGION>::foundation-model/anthropic.claude-*"]
    },
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/lambda/<PROJECT_NAME>-*"
    }
  ]
}
```

5. Click **Next**.
6. **Policy name**: `${project_name}-lambda-policy-${environment}`.
7. Click **Create policy**.

Later, come back and add the missing permissions:
- After Section 6: add `states:StartExecution` on your state machine
- After Section 8: add `execute-api:ManageConnections` on your WebSocket API execution ARN
- After Section 9: add `sns:Publish` to your alerts topic ARN

### 4.2 Step Functions role
1. IAM → Roles → **Create role**.
2. AWS service → **Step Functions**.
3. Role name: `${project_name}-sfn-role-${environment}`.
4. Create.
5. Do **not** add the inline policy yet.

Why: the Step Functions policy needs the **Lambda ARNs**, and you won’t have those until after you create the Lambda functions in Section 5.

You will come back in Section 6 (right before creating the state machine) to add the inline policy named `${project_name}-sfn-policy-${environment}`.

### 4.3 (Optional) API Gateway CloudWatch logging role
Terraform optionally creates a role for API Gateway logging.

1. IAM → Roles → Create role → AWS service → **API Gateway**.
2. Role name: `${project_name}-apigw-cloudwatch-${environment}`.
3. Attach managed policy `AmazonAPIGatewayPushToCloudWatchLogs`.

Enable it in API Gateway:
1. API Gateway → **Settings**.
2. Find **CloudWatch log role ARN**.
3. Paste the role ARN.
4. Save.

### 4.4 Test / verify IAM permissions
The fastest way to validate IAM is to **invoke the Lambdas** and see whether they can access S3/DynamoDB/Secrets.

If you want a direct IAM-only check, use the IAM Policy Simulator:
1. Go to IAM → **Roles** → open `${project_name}-lambda-role-${environment}`.
2. Click **Permissions** → **Policy simulator**.
3. Simulate actions like:
   - `s3:PutObject` on your bucket
   - `dynamodb:PutItem` on your tables
   - `secretsmanager:GetSecretValue` on your secret
4. Fix policy mistakes before moving on.

---

<a id="create-lambdas"></a>
## 5) Create the Lambda Layer + Lambda Functions
Source: [terraform/lambda.tf](terraform/lambda.tf)

### 5.0 Packaging note (important)
Terraform builds a dependency layer from pip-installed packages under `build/layer/python` and publishes it as a layer.

For a working Python dependency layer (recommended), you usually need the Lambda layer structure:
`python/` (contains site-packages).

This guide gives you two options:
- Option A (mirror Terraform): build the same dependency layer folder Terraform expects (recommended).
- Option B: skip layers and vendor dependencies into each function zip (not recommended for this repo).

### 5.1 (Recommended) Build the dependency layer zip locally
This repo already includes the canonical layer dependency list and a build script:
- Layer deps: [requirements-layer.txt](requirements-layer.txt)
- Build script: [scripts/build_lambda_layer.sh](scripts/build_lambda_layer.sh)

From the repo root:
1. Build the layer folder:
   - `./scripts/build_lambda_layer.sh`
2. Zip it (Lambda layer zips must contain a top-level `python/` directory):
   - `cd build/layer && zip -r ../../dependencies_layer.zip .`

### 5.2 Create the Lambda layer in AWS Console
1. Go to **Lambda** → **Layers** → **Create layer**.
2. Name: `${project_name}-dependencies-${environment}`.
3. Upload: choose your `dependencies_layer.zip`.
4. Compatible runtimes: select **Python 3.13**.
5. Create.

### 5.3 Create Lambda functions (11)
All functions:
- Runtime: **Python 3.13**
- Execution role: `${project_name}-lambda-role-${environment}`
- Tracing: **Active** (X-Ray)

Create each function:
1. Lambda → **Functions** → **Create function**.
2. Choose **Author from scratch**.
3. Name: (use the names below)
4. Runtime: **Python 3.13**
5. Permissions: choose **Use an existing role** → select `${project_name}-lambda-role-${environment}`.
6. Create function.
7. In the function page:
   - **Code**: upload the correct `.zip` for that function
   - **Runtime settings**: set the handler
   - **Configuration → General configuration**: set memory + timeout
   - **Configuration → Environment variables**: set variables
   - **Layers**: add `${project_name}-dependencies-${environment}`
   - **Configuration → Monitoring and operations tools**: enable **Active tracing**

Zip packaging quick reference (from repo root):
- Webhook handler (folder):
  - `cd src/lambda/webhook && zip -r ../../../webhook_handler.zip .`
- Single-file lambdas (zip file at root of zip):
  - `zip -j start_transcribe.zip src/lambda/processing/start_transcribe.py`
  - `zip -j process_transcript.zip src/lambda/processing/process_transcript.py`
  - `zip -j generate_summary.zip src/lambda/processing/generate_summary.py`
  - `zip -j save_summary.zip src/lambda/processing/save_summary.py`
  - `zip -j update_status.zip src/lambda/processing/update_status.py`
  - `zip -j list_summaries.zip src/lambda/api/list_summaries.py`
  - `zip -j get_summary.zip src/lambda/api/get_summary.py`
  - `zip -j ws_connect.zip src/lambda/websocket/connect.py`
  - `zip -j ws_disconnect.zip src/lambda/websocket/disconnect.py`
  - `zip -j ws_notify.zip src/lambda/websocket/notify.py`

Functions (match Terraform names/handlers):

1) Webhook handler
- Name: `${project_name}-webhook-handler-${environment}`
- Handler: `handler.handler`
- Timeout: `60` (Terraform variable: `webhook_handler_timeout`)
- Memory: `512` (Terraform variable: `webhook_handler_memory`)
- Env vars:
  - `S3_BUCKET` = your S3 bucket name
  - `DYNAMODB_TABLE` = `${project_name}-summaries-${environment}`
  - `STEP_FUNCTION_ARN` = (placeholder for now; fill after Step Functions)
  - `GOOGLE_CREDENTIALS_SECRET` = `google_credentials_secret_name`
  - `GDRIVE_FOLDER_ID` = your folder id
  - `WEBHOOK_TOKEN` = the token you generated
  - `ENVIRONMENT` = `environment`

2) Start Transcribe
- Name: `${project_name}-start-transcribe-${environment}`
- Handler: `start_transcribe.handler`
- Timeout: 60, Memory: 256
- Env vars: `TRANSCRIBE_OUTPUT_BUCKET`, `DYNAMODB_TABLE`, `ENVIRONMENT`

3) Process Transcript
- Name: `${project_name}-process-transcript-${environment}`
- Handler: `process_transcript.handler`
- Timeout: 300, Memory: 512
- Env vars: `S3_BUCKET`, `DYNAMODB_TABLE`, `ENVIRONMENT`

4) Generate Summary (Bedrock)
- Name: `${project_name}-generate-summary-${environment}`
- Handler: `generate_summary.handler`
- Timeout: 600, Memory: 1024
- Env vars: `BEDROCK_MODEL_ID`, `MAX_TOKENS`, `DYNAMODB_TABLE`, `ENVIRONMENT`

5) Save Summary
- Name: `${project_name}-save-summary-${environment}`
- Handler: `save_summary.handler`
- Timeout: 60, Memory: 256
- Env vars: `DYNAMODB_TABLE`, `ENVIRONMENT`

6) Update Status
- Name: `${project_name}-update-status-${environment}`
- Handler: `update_status.handler`
- Timeout: 30, Memory: 128
- Env vars: `DYNAMODB_TABLE`, `ENVIRONMENT`

7) List Summaries
- Name: `${project_name}-list-summaries-${environment}`
- Handler: `list_summaries.handler`
- Timeout: 30, Memory: 256
- Env vars: `DYNAMODB_TABLE`, `ENVIRONMENT`

8) Get Summary
- Name: `${project_name}-get-summary-${environment}`
- Handler: `get_summary.handler`
- Timeout: 30, Memory: 256
- Env vars: `DYNAMODB_TABLE`, `S3_BUCKET`, `ENVIRONMENT`

9) WebSocket connect
- Name: `${project_name}-ws-connect-${environment}`
- Handler: `connect.handler`
- Timeout: 10, Memory: 128
- Env vars: `CONNECTIONS_TABLE`, `ENVIRONMENT`

10) WebSocket disconnect
- Name: `${project_name}-ws-disconnect-${environment}`
- Handler: `disconnect.handler`
- Timeout: 10, Memory: 128
- Env vars: `CONNECTIONS_TABLE`, `ENVIRONMENT`

11) WebSocket notify
- Name: `${project_name}-ws-notify-${environment}`
- Handler: `notify.handler`
- Timeout: 30, Memory: 256
- Env vars: `CONNECTIONS_TABLE`, `WEBSOCKET_ENDPOINT`, `ENVIRONMENT`
   - Set `WEBSOCKET_ENDPOINT` after you create the WebSocket API stage.
   - IMPORTANT: this Lambda uses the **API Gateway Management API** via boto3, which requires an **HTTPS** endpoint of the form:
      - `https://{api-id}.execute-api.{region}.amazonaws.com/{stage}`
      - (This is different from the WebSocket client URL, which is `wss://...`.)
   - Do not set placeholders like `TBD` — boto3 will fail fast with “Invalid endpoint”.

### 5.4 Unit test + smoke test Lambda
Local unit tests (no AWS deploy required):
1. Install dependencies:
   - `pip install -r requirements.txt`
2. Run the unit test suites:
   - `pytest -m "not integration" -v`
3. Run only the most relevant files:
   - `pytest tests/test_webhook_handler.py -v`
   - `pytest tests/test_processing.py -v`
   - `pytest tests/test_api.py -v`

Optional local “sanity checks”:
- Syntax/bytecode compile:
  - `python -m compileall src/lambda`

AWS smoke tests (after deployment):
1. Invoke webhook handler with a **sync** notification (expected: `200` if token validation passes, otherwise `401`):
   - `aws lambda invoke --function-name ${project_name}-webhook-handler-${environment} --payload '{"headers":{"X-Goog-Resource-State":"sync","X-Goog-Channel-Token":"<WEBHOOK_TOKEN>"}}' /tmp/webhook_out.json && cat /tmp/webhook_out.json`
2. Invoke list summaries handler (will likely return 401 without authorizer claims when invoked directly; that’s fine for a basic “Lambda runs” check):
   - `aws lambda invoke --function-name ${project_name}-list-summaries-${environment} --payload '{}' /tmp/list_out.json && cat /tmp/list_out.json`

---

<a id="create-step-functions"></a>
## 6) Create the Step Functions State Machine
Source: [terraform/step_functions.tf](terraform/step_functions.tf)

### 6.1 Create the Step Functions log group
1. Go to **CloudWatch** → **Logs** → **Log groups** → **Create log group**.
2. Name: `/aws/step-functions/${project_name}-pipeline-${environment}`.
3. Retention: `log_retention_days` (Terraform default: 30).
4. Create.

### 6.1.1 Finish the Step Functions role inline policy (now you have the log group)
You created the role in Section 4.2, but you delayed the policy until the Lambdas existed.

1. IAM → Roles → open `${project_name}-sfn-role-${environment}`.
2. Permissions → **Add permissions** → **Create inline policy** → JSON.
3. Use the JSON shape from [terraform/step_functions.tf](terraform/step_functions.tf) and replace placeholders with your real ARNs:
   - The 6 pipeline Lambda ARNs you pasted into the state machine definition
   - The Step Functions log group ARN for `/aws/step-functions/${project_name}-pipeline-${environment}`
4. Policy name: `${project_name}-sfn-policy-${environment}`.
5. Create.

### 6.2 Create the state machine
1. Go to **Step Functions** → **State machines** → **Create state machine**.
2. Type: **Standard**.
3. Definition: open [stepfunctions/call-processing.asl.json](stepfunctions/call-processing.asl.json).
4. Replace the template variables with real Lambda ARNs:
   - `UpdateStatusFunctionArn`
   - `StartTranscribeFunctionArn`
   - `ProcessTranscriptFunctionArn`
   - `GenerateSummaryFunctionArn`
   - `SaveSummaryFunctionArn`
   - `NotifyFunctionArn`
5. Paste the final JSON into the definition editor.
6. Name: `${project_name}-pipeline-${environment}`.
7. Permissions: choose **Use an existing role** → `${project_name}-sfn-role-${environment}`.
8. Logging:
   - Destination: the log group you created
   - Level: **ALL**
   - Include execution data: **Enabled**
9. Tracing: enable **X-Ray tracing**.
10. Create.

### 6.3 Update Lambda environment variables that depend on Step Functions
Go back to the webhook handler Lambda and set:
- `STEP_FUNCTION_ARN` = your state machine ARN

### 6.3.1 Update the Lambda execution role to allow starting the state machine
Now that the state machine exists, go back and add this permission to `${project_name}-lambda-role-${environment}`.

IAM → Roles → `${project_name}-lambda-role-${environment}` → Permissions → edit your inline policy JSON and add:
```json
{
   "Effect": "Allow",
   "Action": ["states:StartExecution"],
   "Resource": "<STATE_MACHINE_ARN>"
}
```

### 6.4 (Optional) Create an EventBridge rule for Transcribe completion
Terraform defines a rule but does not attach a target. If you want this to actually trigger Step Functions, you must add a target.

1. Go to **EventBridge** → **Rules** → **Create rule**.
2. Name: `${project_name}-transcribe-complete-${environment}`.
3. Event pattern:
   - Source: `aws.transcribe`
   - Detail type: `Transcribe Job State Change`
   - Status: `COMPLETED` and `FAILED`
4. Target: **Step Functions state machine** → pick `${project_name}-pipeline-${environment}`.
5. Allow EventBridge to invoke Step Functions (it will guide you to create a role).
6. Create.

### 6.5 Test / verify Step Functions
AWS Console smoke test:
1. Step Functions → open `${project_name}-pipeline-${environment}`.
2. Click **Start execution**.
3. Use a simple input JSON (you may need to adjust for your definition):
```json
{
   "call_id": "test-call-001",
   "s3_bucket": "<s3_bucket_name>",
   "s3_key": "raw-audio/test/test-call-001.mp3",
   "caller_id": "+10000000000",
   "assigned_user_id": "test-user"
}
```
4. Start execution and confirm:
    - Execution is created
    - It transitions through the first state(s)

AWS CLI smoke test:
- `aws stepfunctions list-state-machines | head`
- `aws stepfunctions describe-state-machine --state-machine-arn <STATE_MACHINE_ARN>`

---

<a id="create-cognito"></a>
## 7) Create Cognito (User Pool + Domain + Client + Groups)
Source: [terraform/cognito.tf](terraform/cognito.tf)

### 7.1 Create the user pool
1. Go to **Amazon Cognito** → **User pools** → **Create user pool**.
2. **Sign-in options**:
   - Choose **Email** as the sign-in attribute.
3. **Security requirements**:
   - Password policy: minimum length 12; require upper/lower/number/symbol.
   - MFA: `prod` = ON, otherwise OPTIONAL.
4. **Sign-up experience**:
   - Allow users to self sign-up.
   - Auto-verify: email.
5. **Message delivery**:
   - Email provider: Cognito default.
   - Verification subject: `Your verification code`
   - Verification message: `Your verification code is {####}`
6. **Attributes**:
   - Required: `email`, `name`
   - Optional: `department`
7. Name: `${project_name}-users-${environment}`.
8. Create.

### 7.2 Create a user pool domain
1. In your user pool → **App integration**.
2. Find **Domain** → **Create domain**.
3. Prefix: `${cognito_domain_prefix}-${environment}`.
4. Create.

### 7.3 Create the app client
1. In user pool → **App integration** → **App clients** → **Create app client**.
2. Name: `${project_name}-frontend-${environment}`.
3. Client secret: **do not generate** (SPA).
4. OAuth:
   - Allowed flows: Authorization code grant
   - Scopes: `openid`, `email`, `profile`
5. Callback URLs (dev):
   - `http://localhost:3000/callback`
   - `http://localhost:5173/callback`
6. Sign out URLs (dev):
   - `http://localhost:3000`
   - `http://localhost:5173`
7. Token validity: access 1h, id 1h, refresh 30d.
8. Create.

### 7.4 Create groups
1. User pool → **Groups** → **Create group**.
2. Create:
   - `caseworkers` (precedence 3)
   - `supervisors` (precedence 2)
   - `admin` (precedence 1)

### 7.5 Test / verify Cognito
The most beginner-friendly test is the Hosted UI:
1. Go to Cognito → your user pool → **App integration**.
2. Find the **Hosted UI** / domain URL.
3. Create a test user in the Console:
   - Users → **Create user**
   - Set a temporary password
4. Add the user to a group (admin/caseworkers).
5. Use the Hosted UI login to confirm the user can authenticate.

If you want to call the API from curl/Postman, you’ll need a valid JWT access token. The easiest way is Postman OAuth2 (Authorization Code flow) using:
- Cognito domain
- Client ID
- Callback URL configured on the app client
- Scopes: `openid email profile`

---

<a id="create-api-gateway"></a>
## 8) Create API Gateway (HTTP API + WebSocket)
Source: [terraform/api_gateway.tf](terraform/api_gateway.tf)

### 8.1 HTTP API (for /webhook and summaries)
1. Go to **API Gateway** → **Create API**.
2. Choose **HTTP API** → **Build**.
3. API name: `${project_name}-api-${environment}`.
4. Configure CORS:
   - Allow origins: `http://localhost:3000`, `http://localhost:5173` (dev)
   - Allow methods: GET, POST, PUT, DELETE, OPTIONS
   - Allow headers: Content-Type, Authorization, X-Amz-Date, X-Api-Key
5. Create.

Create integrations + routes
1. In the API, go to **Routes** → **Create**.
2. Create route `POST /webhook`.
3. Attach integration to the webhook handler Lambda.
   - Integration type should be **Lambda proxy** / **AWS_PROXY** (payload format `2.0`).
   - If prompted, allow API Gateway to add `lambda:InvokeFunction` permission on the target Lambda.
4. Create route `GET /summaries` → integration: list_summaries Lambda.
5. Create route `GET /summaries/{call_id}` → integration: get_summary Lambda.

Create JWT authorizer (Cognito)
1. Go to **Authorizers** → **Create and attach authorizer**.
2. Type: JWT.
3. Issuer URL:
   - `https://cognito-idp.<region>.amazonaws.com/<user_pool_id>`
4. Audience:
   - your Cognito app client ID.
5. Attach the authorizer to the `GET /summaries` and `GET /summaries/{call_id}` routes.

Stage + logging
1. Go to **Stages** → create stage named `${environment}`.
2. Enable auto-deploy.
3. Access logs: create/use log group `/aws/apigateway/${project_name}-${environment}` and enable logging.
4. Throttling: burst 100, rate 50.

### 8.2 WebSocket API (for real-time notifications)
1. API Gateway → **Create API**.
2. Choose **WebSocket API**.
3. API name: `${project_name}-websocket-${environment}`.
4. Route selection expression: `$request.body.action`.
5. Create.

Create routes
1. Routes → create `$connect` → integrate with `ws-connect` Lambda.
2. Routes → create `$disconnect` → integrate with `ws-disconnect` Lambda.

Create stage
1. Stages → create stage `${environment}`.
2. Auto-deploy ON.
3. Throttling: burst 500, rate 100.
4. Copy the stage invoke URL (client URL), which looks like `wss://.../${environment}`.
5. Set the `ws-notify` Lambda env var `WEBSOCKET_ENDPOINT` to the **management** endpoint, which is the same URL but with `https://`:
   - `https://<websocket-api-id>.execute-api.<region>.amazonaws.com/${environment}`

### 8.2.1 Update the Lambda execution role to allow WebSocket ManageConnections
Now that the WebSocket API exists, go back and add this permission to `${project_name}-lambda-role-${environment}`:

```json
{
   "Effect": "Allow",
   "Action": ["execute-api:ManageConnections"],
   "Resource": "<WEBSOCKET_CONNECTIONS_ARN>"
}
```

How to get the execution ARN:
- It is the `arn:aws:execute-api:...` ARN for your WebSocket API connections endpoint (includes API ID, stage, and `@connections`).
- If you’re unsure, use the AWS CLI to derive it:
   - `aws apigatewayv2 get-apis --query "Items[?Name=='${project_name}-websocket-${environment}'].[ApiId,Name]" --output table`
   - Then build: `arn:aws:execute-api:<REGION>:<ACCOUNT_ID>:<ApiId>/${environment}/POST/@connections/*`

### 8.3 Test / verify API Gateway
HTTP API smoke tests:

1) Test `/webhook` without Google (simulate a sync request)
- Build the URL:
   - `WEBHOOK_URL="https://<http-api-id>.execute-api.<region>.amazonaws.com/${environment}/webhook"`
- Send a sync request with the token header:
   - `curl -i -X POST "$WEBHOOK_URL" -H "X-Goog-Resource-State: sync" -H "X-Goog-Channel-Token: <WEBHOOK_TOKEN>"`

Expected outcomes:
- `200` means your handler accepted the sync event
- `401` means token validation failed (check `WEBHOOK_TOKEN` env var and header spelling)

2) Test authenticated endpoints (`/summaries`)
- You need a Cognito JWT (see Section 7.5).
- Example:
   - `API_URL="https://<http-api-id>.execute-api.<region>.amazonaws.com/${environment}"`
   - `curl -sS -H "Authorization: Bearer <ACCESS_TOKEN>" "$API_URL/summaries" | head -c 300 && echo`

WebSocket smoke tests:
1. Install a client:
    - `npm install -g wscat`
2. Connect:
    - `wscat -c "wss://<websocket-api-id>.execute-api.<region>.amazonaws.com/${environment}"`
3. If your connect/disconnect Lambdas write to DynamoDB, confirm connection records appear in `${project_name}-connections-${environment}`.

---

<a id="create-monitoring"></a>
## 9) Monitoring (CloudWatch + SNS)
Source: [terraform/cloudwatch.tf](terraform/cloudwatch.tf)

### 9.1 Create the SNS topic (alerts)
1. Go to **SNS** → **Topics** → **Create topic**.
2. Type: Standard.
3. Name: `${project_name}-alerts-${environment}`.
4. Create.

Add email subscription (optional)
1. Open the topic → **Create subscription**.
2. Protocol: Email.
3. Endpoint: your email.
4. Create.
5. Confirm the subscription from your email.

### 9.1.1 Update the Lambda execution role to allow publishing alerts
Now that the SNS topic exists, go back and add this permission to `${project_name}-lambda-role-${environment}`:

```json
{
   "Effect": "Allow",
   "Action": ["sns:Publish"],
   "Resource": "<SNS_TOPIC_ARN>"
}
```

### 9.2 Set CloudWatch log retention
Log groups are created automatically when services write logs, but retention defaults to “Never expire”. Set it to 30 days (or your preferred value):
1. CloudWatch → Logs → Log groups.
2. For each log group for this project, choose **Actions** → **Edit retention setting**.
3. Set to `30 days`.

### 9.3 Create a CloudWatch dashboard (optional)
Terraform creates a dashboard. Manually, you can start simple:
1. CloudWatch → **Dashboards** → **Create dashboard**.
2. Name: `${project_name}-${environment}`.
3. Add widgets:
   - Lambda: Invocations / Errors / Duration
   - Step Functions: ExecutionsStarted / ExecutionsFailed
   - DynamoDB: SuccessfulRequestLatency / ThrottledRequests

### 9.4 Create basic alarms (recommended)
1. CloudWatch → **Alarms** → **Create alarm**.
2. Lambda Errors alarm:
   - Select metric: AWS/Lambda → By Function Name → pick a function → Errors
   - Threshold: `>= 1` over 1 datapoint (5 minutes)
   - Notification: send to your SNS topic
3. Step Functions failures alarm:
   - AWS/States → By State Machine ARN → ExecutionsFailed
   - Threshold: `>= 1`

### 9.5 Test / verify Monitoring
SNS publish smoke test:
1. Go to SNS → Topics → open `${project_name}-alerts-${environment}`.
2. Click **Publish message** and send a test message.
3. If you added an email subscription, confirm you receive it.

CloudWatch logs smoke test:
1. CloudWatch → Logs → Log groups.
2. Confirm log groups exist for:
   - `/aws/lambda/${project_name}-webhook-handler-${environment}`
   - `/aws/step-functions/${project_name}-pipeline-${environment}`
   - `/aws/apigateway/${project_name}-${environment}`
3. Trigger activity (invoke Lambda / start Step Functions) and confirm new log events appear.

---

## 10) Post-Setup Checklist (to make the system actually work)

1. Verify Bedrock model access is enabled (Section 0.5).
2. Confirm the Google credentials secret exists (Section 3.1).
3. Confirm webhook handler env vars are set:
   - `STEP_FUNCTION_ARN` points to your state machine
   - `WEBHOOK_TOKEN` is set
4. Register the Google Drive webhook (script-driven step):
   - See [scripts/register_webhook.py](scripts/register_webhook.py)
   - You’ll need the webhook URL: `https://<http-api-id>.execute-api.<region>.amazonaws.com/<env>/webhook`
5. Configure frontend env vars (see Terraform output format in [terraform/outputs.tf](terraform/outputs.tf)).

6. Run local unit tests to validate the code paths:
   - `pytest -m "not integration" -v`

7. Run AWS smoke tests (minimal):
   - S3 upload/download (Section 1.5)
   - DynamoDB put/get (Section 2.4)
   - Lambda invoke (Section 5.4)
   - Step Functions start execution (Section 6.5)
   - API Gateway webhook call (Section 8.3)

### 10.1 Incremental multi-component tests (build up to full workflow)
These tests deliberately connect **several components at once**. Run them in order. Don’t move to the next level until the current one passes.

Before you start, set shell variables once:
- `REGION=<your-region>`
- `ENV=<environment>`
- `PROJECT=customer-care-call-processor`
- `S3_BUCKET=<s3_bucket_name>`
- `DDB_SUMMARIES=${PROJECT}-summaries-${ENV}`
- `DDB_CONNECTIONS=${PROJECT}-connections-${ENV}`
- `API_URL=https://<http-api-id>.execute-api.${REGION}.amazonaws.com/${ENV}`
- `WEBHOOK_URL=${API_URL}/webhook`
- `WS_URL=wss://<websocket-api-id>.execute-api.${REGION}.amazonaws.com/${ENV}`

#### Level 1 — HTTP API Gateway → Lambda (webhook) → CloudWatch logs
Goal: confirm API Gateway is invoking the Lambda integration and you can see logs.
1. Send a webhook “sync” request:
   - `curl -i -X POST "$WEBHOOK_URL" -H "X-Goog-Resource-State: sync" -H "X-Goog-Channel-Token: <WEBHOOK_TOKEN>"`
2. In CloudWatch Logs, open log group:
   - `/aws/lambda/${PROJECT}-webhook-handler-${ENV}`
3. Confirm you see a new log stream/event for that request.

If this fails:
- `403/5xx` from API Gateway usually means route/integration/stage misconfigured.
- `401` often means webhook token validation failed.

#### Level 2 — Step Functions → Lambda(s) → DynamoDB status updates
Goal: confirm Step Functions can invoke Lambdas and Lambdas can read/write DynamoDB.

This is a “wiring test”. It can still pass even if Transcribe/Bedrock later fail.
1. Create a placeholder audio object in S3 (so S3 keys exist):
   - `echo "fake audio" > /tmp/fake-audio.txt`
   - `aws s3 cp /tmp/fake-audio.txt s3://$S3_BUCKET/raw-audio/test/fake-audio.txt --region $REGION`
2. Start a Step Functions execution from the Console (recommended first) OR via CLI:
   - `aws stepfunctions start-execution --state-machine-arn <STATE_MACHINE_ARN> --input '{"call_id":"test-call-001","s3_bucket":"'"$S3_BUCKET"'","s3_key":"raw-audio/test/fake-audio.txt","caller_id":"+10000000000","assigned_user_id":"test-user"}' --region $REGION`
3. In DynamoDB `${DDB_SUMMARIES}`, look for an item with `call_id = test-call-001`.
4. Confirm you see status transitions written by the `update-status` Lambda (even if later steps fail).

If this fails:
- Check the Step Functions execution event history for the exact failing state.
- Most common cause is missing IAM permissions (Step Functions role invoking Lambda; Lambda role writing to DynamoDB).

#### Level 3 — Cognito login → HTTP API authorized route → DynamoDB read
Goal: confirm Cognito JWT auth works and the API can read from DynamoDB.
1. Create a test user in Cognito and add them to `admin` group.
2. Obtain an access token (Hosted UI / Postman OAuth2 Authorization Code flow).
3. Call the summaries endpoint:
   - `curl -sS -H "Authorization: Bearer <ACCESS_TOKEN>" "$API_URL/summaries" | head -c 500 && echo`
4. Confirm you get a `200` and a JSON body containing `items`.

If this fails:
- `401/403` usually means authorizer issuer/audience is wrong, or the token is expired.
- `5xx` usually means Lambda runtime error or DynamoDB permissions.

#### Level 4 — WebSocket connect → DynamoDB connections table → notify Lambda
Goal: confirm the WebSocket connection flow works end-to-end and the notify Lambda can publish messages back to a live connection.

1. Connect with `wscat`:
   - `wscat -c "$WS_URL"`
2. In another terminal, verify the connect lambda ran (CloudWatch logs):
   - `/aws/lambda/${PROJECT}-ws-connect-${ENV}`
3. Check `${DDB_CONNECTIONS}` in DynamoDB for the most recent `connection_id`.
   - (If your connect lambda doesn’t write to DynamoDB yet, you’ll need to capture the connection id from logs.)
4. Trigger a notify:
   - Invoke `${PROJECT}-ws-notify-${ENV}` with a payload that targets the connection id you found.
   - Confirm `wscat` receives the message.

If this fails:
- Ensure `WEBSOCKET_ENDPOINT` env var on `ws-notify` is the **HTTPS management endpoint** (not `wss://`):
   - `https://<websocket-api-id>.execute-api.<region>.amazonaws.com/${ENV}`
- Ensure the Lambda execution role has `execute-api:ManageConnections` on the WebSocket API execution ARN.

#### Level 5 — Full end-to-end workflow (only after Levels 1–4)
Goal: confirm the real workflow (webhook → pipeline → summary saved → API reads it → optional notification) works.

Prerequisites:
- A real audio file that Amazon Transcribe can process (mp3/wav/etc).
- Bedrock model access enabled (Section 0.5).
- Google Drive webhook registration completed (or an equivalent manual trigger path).

Minimal full-workflow test approach (without Google Drive):
1. Upload a small real audio file to:
   - `s3://$S3_BUCKET/raw-audio/test/<yourfile>.mp3`
2. Start a Step Functions execution pointing at that S3 key.
3. Watch execution until it completes (or fails).
4. Confirm DynamoDB item status is `COMPLETED` and summary fields are populated.
5. Call `GET /summaries` and `GET /summaries/{call_id}` from the HTTP API to validate the API can serve the result.

If this fails:
- Use the failing state in Step Functions + the Lambda logs for that state to pinpoint whether it’s Transcribe access, S3 permissions, Bedrock access, or JSON parsing.

---

## 11) Cleanup (Cost-Saving Teardown)

> Warning: This deletes data. Export anything needed first.

Recommended order (Console):
1. **API Gateway**
   - Delete HTTP API and WebSocket API (deletes routes/integrations/stages)
2. **Step Functions**
   - Delete the state machine
   - Delete the Step Functions log group
   - Delete EventBridge rule/targets (if you created them)
3. **Lambda**
   - Delete all functions
   - Delete the layer
4. **Cognito**
   - Delete app client
   - Delete domain
   - Delete groups
   - Delete user pool
5. **DynamoDB**
   - Delete all 3 tables
6. **S3**
   - Empty the bucket(s) first: bucket → **Empty** → type `permanently delete`
   - Delete primary bucket
   - Delete logs bucket (prod only)
7. **CloudWatch**
   - Delete dashboard(s)
   - Delete alarms if created manually
8. **SNS**
   - Delete topic(s) and subscriptions
9. **IAM**
   - Delete inline policies and roles created for Lambda/Step Functions/API Gateway logging

---

## Reference: Terraform files
- [terraform/s3.tf](terraform/s3.tf)
- [terraform/dynamodb.tf](terraform/dynamodb.tf)
- [terraform/iam.tf](terraform/iam.tf)
- [terraform/lambda.tf](terraform/lambda.tf)
- [terraform/step_functions.tf](terraform/step_functions.tf)
- [terraform/api_gateway.tf](terraform/api_gateway.tf)
- [terraform/cognito.tf](terraform/cognito.tf)
- [terraform/cloudwatch.tf](terraform/cloudwatch.tf)
