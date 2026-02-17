# Troubleshooting — Customer Care Call Processing System

This is a practical checklist for diagnosing the most common failures seen during unit tests and AWS smoke tests.

## 1) Local unit tests fail to collect or import modules

### Symptom
- `ModuleNotFoundError: No module named 'boto3'` (or other deps) during `pytest` collection.

### Root cause
- `pytest` is running under a different interpreter than the one you installed packages into (common with Anaconda / multiple Python installs).

### Fix
- Check which executables are being used:
  - `which python && python -V`
  - `which pytest && pytest --version`
- Install requirements using the same interpreter that runs pytest:
  - `python -m pip install -r requirements.txt`
- If `pytest.ini` uses an `env =` block, ensure `pytest-env` is installed:
  - `python -m pip install pytest-env`

## 2) Pytest warning: "Unknown config option: env"

### Symptom
- `PytestConfigWarning: Unknown config option: env`

### Root cause
- `pytest-env` plugin not installed.

### Fix
- Install `pytest-env` (now included in `requirements.txt`).

## 3) Lambda runtime import error: missing third-party libraries

### Symptom
- Webhook Lambda fails at runtime with import errors for Google libraries (`googleapiclient`, `google.oauth2`, etc.).

### Root cause
- Those libraries are not included in the AWS Lambda Python runtime.

### Fix (Terraform path)
- Use the dependency layer built from `requirements-layer.txt`.
- Terraform runs a local build step to populate `build/layer/python`, then zips that folder into the Lambda layer.

### Fix (Manual packaging path)
- Vendor dependencies into the deployment zip (less ideal for long-term maintenance).

## 4) Terraform plan/apply fails with runtime "python3.14" rejected

### Symptom
- `Error: expected runtime to be one of ... got python3.14`

### Root cause
- The Terraform AWS provider validation list may lag AWS Lambda runtime releases. Even if AWS supports `python3.14` in your region, the provider may still reject it during `plan/apply`.

### Fix / Workaround
- Use a provider-accepted runtime for Terraform (currently `python3.13`) via `var.lambda_runtime`.
- The repo defaults Terraform to `python3.13` in `terraform/variables.tf` to keep `plan/apply` unblocked.
- If you need to override:
  - `terraform plan -var='lambda_runtime=python3.13' ...`
- If you manually created Lambdas as `python3.14`, keep them as-is in AWS; Terraform-managed resources should stick to what the provider accepts until the provider adds `python3.14`.

## 5) Lambda returns 500 and CloudWatch logs show DynamoDB AccessDenied

### Symptom
- API Lambdas (e.g., list summaries) return `500`.
- CloudWatch logs show: `AccessDeniedException ... not authorized to perform: dynamodb:Scan ...`

### Root cause
- The Lambda execution role is missing DynamoDB permissions on the target table.

### Fix
- Ensure the Lambda role has the required actions on:
  - Summaries table + indexes
  - Connections table + indexes (for WebSocket)

Terraform already includes DynamoDB permissions in `terraform/iam.tf`. If the function is using a different role than Terraform expects, you’ll see this failure even though Terraform looks correct.

## 6) Role name mismatch (Terraform vs manually created resources)

### Symptom
- Terraform defines permissions, but Lambdas still fail with AccessDenied.

### Root cause
- The Lambda function is using a different IAM role than the role Terraform is managing.

### Fix
- Confirm the role attached to the Lambda:
  - `aws lambda get-function-configuration --function-name <fn> --query Role --output text`
- Confirm the role Terraform creates and attaches in `terraform/iam.tf` and `terraform/lambda.tf`.

## 7) Smoke testing patterns (safe vs side-effect)

### Safe smoke tests
- `DryRun` invocation: checks wiring/permissions without executing.
- Webhook `sync` event: should short-circuit to 200 without calling external services.
- API functions with missing required parameters: should return controlled 400 (proves runtime executes).

### Side-effecting tests (do only when ready)
- Starting real Transcribe jobs.
- Executing Step Functions pipeline.
- Calling Bedrock.

## 8) Quick AWS smoke commands

### List your dev Lambdas
- `aws --profile default --region us-east-1 lambda list-functions --query 'Functions[?starts_with(FunctionName, `customer-care-call-processor-`) && contains(FunctionName, `-dev`)].FunctionName' --output text`

### DryRun one function
- `aws --profile default --region us-east-1 lambda invoke --function-name <fn> --invocation-type DryRun --cli-binary-format raw-in-base64-out --payload '{}' /tmp/out.json`

### Webhook sync smoke
- `aws --profile default --region us-east-1 lambda invoke --function-name customer-care-call-processor-webhook-handler-dev --cli-binary-format raw-in-base64-out --payload '{"headers":{"X-Goog-Resource-State":"sync"}}' /tmp/webhook_out.json && cat /tmp/webhook_out.json`
