# Lambda Console Test Events

This folder contains ready-to-use **AWS Lambda Console “Test Event”** payloads for each `customer-care-call-processor-*-dev` function.

## How to use
1. Open the AWS Lambda function in the AWS Console.
2. Click **Test** → **Create new event**.
3. Pick **Event name** (e.g., `smoke`), then paste the JSON from the matching file below.
4. For the processing Lambdas (Transcribe/S3/Bedrock), **replace the `REPLACE_ME_*` placeholders** with real values.

## Events included
- Webhook handler: `webhook_handler_sync.json`
- Processing:
  - `start_transcribe.json`
  - `process_transcript.json`
  - `generate_summary.json`
  - `save_summary.json`
  - `update_status.json`
- REST API:
  - `list_summaries.json`
  - `get_summary.json`
- WebSocket:
  - `ws_connect.json`
  - `ws_disconnect.json`
  - `ws_notify.json`

## Notes / safety
- `start_transcribe.json` will **start an Amazon Transcribe job** if your S3 object + IAM permissions are valid.
- `generate_summary.json` will **call Amazon Bedrock** and **write to S3**, which can incur cost.
- `process_transcript.json` and `save_summary.json` will **read/write S3 and update DynamoDB**.
- `ws_notify.json` will attempt to post messages via API Gateway Management API only if `WEBSOCKET_ENDPOINT` is configured. If it’s missing, the function will no-op (log a warning) and return successfully.
