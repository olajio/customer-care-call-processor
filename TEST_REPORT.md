# Test Report — Customer Care Call Processing (dev)

Date: 2026-02-16

## Scope
This report covers:
- Local unit tests for the Lambda code in this repository (`data-pipeline/`).
- Local sanity checks (bytecode compilation).
- AWS smoke tests for deployed dev Lambda functions in `us-east-1`.

Out of scope (not executed): full end-to-end pipeline execution that would create real Transcribe jobs, call Bedrock, or run the Step Functions pipeline end-to-end.

## Environment
- Local OS: macOS
- Local Python (tests): Anaconda Python 3.11.5
- Pytest: 7.4.3
- AWS CLI profile: `default`
- AWS region: `us-east-1`

## Local Unit Tests
### Command
- `pytest -m "not integration" -v`

### Result
- `63 passed, 12 skipped, 6 deselected`

### Issues Found & Fixes
1) **Missing `boto3` during test collection**
- Symptom: integration tests failed to import `boto3` (collection-time failure).
- Cause: `pytest` was running under Anaconda Python, but dependencies were not installed into that interpreter.
- Fix: installed repository dependencies into the Anaconda environment using:
  - `python -m pip install -r requirements.txt`

2) **Webhook handler test failure: missing symbol**
- Symptom: `AttributeError: ... handler ... does not have the attribute validate_webhook_signature`.
- Fix: added `validate_webhook_signature()` as a backward-compatible wrapper around existing token validation.
- Code change:
  - Updated: `src/lambda/webhook/handler.py`

## Local Sanity Check
### Command
- `python -m compileall src/lambda`

### Result
- Successful compilation of Lambda sources (no syntax errors).

## AWS Smoke Tests
### Deployed Dev Lambda Functions
The following functions were targeted:
- `customer-care-call-processor-webhook-handler-dev`
- `customer-care-call-processor-start-transcribe-dev`
- `customer-care-call-processor-process-transcript-dev`
- `customer-care-call-processor-generate-summary-dev`
- `customer-care-call-processor-save-summary-dev`
- `customer-care-call-processor-update-status-dev`
- `customer-care-call-processor-list-summaries-dev`
- `customer-care-call-processor-get-summary-dev`
- `customer-care-call-processor-ws-connect-dev`
- `customer-care-call-processor-ws-disconnect-dev`
- `customer-care-call-processor-ws-notify-dev`

### DryRun Smoke
- Method: `aws lambda invoke --invocation-type DryRun ...`
- Result: all functions accepted `DryRun` invocation (no permission/handler wiring failures).

### RequestResponse Smoke (Safe Invocations)
1) **Webhook handler — sync event**
- Goal: confirm Lambda loads and returns sync acknowledgement.
- Input: sync notification event (no external calls required).
- Result: `200` with body indicating webhook verified.

2) **List summaries — minimal admin context**
- Goal: confirm Lambda executes and can read DynamoDB.
- Input: minimal event with admin-like claims.
- Initial result: `500` caused by DynamoDB `AccessDeniedException` for `dynamodb:Scan`.
- Fix: attached a minimal inline IAM policy to the Lambda execution role permitting DynamoDB access.
- Final result: `200` with empty list (`items: []`).

3) **Get summary — missing call_id (expected controlled failure)**
- Goal: confirm Lambda executes and returns a controlled error.
- Input: event without `call_id`.
- Result: `400` with `call_id is required`.

## AWS Changes Made During Testing
### 1) Webhook Lambda deployment packaging
- Function: `customer-care-call-processor-webhook-handler-dev`
- Change: deployed a proper zip package containing `handler.py` at the zip root plus required Google API dependencies.
- Reason: the previous deployed package was too small and lacked dependencies needed for runtime imports.

### 2) IAM policy fix for DynamoDB access
- Role: `customer-care-call-lambda-role-dev`
- Action: added inline policy `customer-care-call-dynamodb-access-dev` granting DynamoDB actions:
  - `dynamodb:GetItem`, `PutItem`, `UpdateItem`, `DeleteItem`, `Query`, `Scan`, `DescribeTable`
  - Scoped to the dev tables:
    - `customer-care-call-processor-summaries-dev` (and indexes)
    - `customer-care-call-processor-connections-dev` (and indexes)
- Reason: `list-summaries` required `dynamodb:Scan` and was failing with `AccessDeniedException`.

### 3) X-Ray tracing alignment
- Function: `customer-care-call-processor-webhook-handler-dev`
- Change: tracing set to `Active`.

## Notes / Follow-ups
- Full E2E pipeline execution was not run because it may incur cost and mutate resources (Transcribe/Bedrock/Step Functions).
- Some runtime values are placeholders (e.g., Step Functions ARN set to `TBD`). Those must be finalized before an end-to-end smoke test of the full pipeline.
