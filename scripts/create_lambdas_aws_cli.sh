#!/usr/bin/env bash
set -euo pipefail

PROFILE=${PROFILE:-default}
REGION=${REGION:-us-east-1}
ROLE_NAME=${ROLE_NAME:-customer-care-call-lambda-role-dev}

# Env values provided by user
S3_BUCKET=${S3_BUCKET:-customer-care-call-processor-dev-learnkey-cloud}
DYNAMODB_TABLE=${DYNAMODB_TABLE:-customer-care-call-processor-summaries-dev}
ENVIRONMENT=${ENVIRONMENT:-dev}
CONNECTIONS_TABLE=${CONNECTIONS_TABLE:-customer-care-call-processor-connections-dev}
TRANSCRIBE_OUTPUT_BUCKET=${TRANSCRIBE_OUTPUT_BUCKET:-$S3_BUCKET}
BEDROCK_MODEL_ID=${BEDROCK_MODEL_ID:-anthropic.claude-3-5-sonnet-20241022-v2:0}
MAX_TOKENS=${MAX_TOKENS:-4096}
WEBSOCKET_ENDPOINT=${WEBSOCKET_ENDPOINT:-TBD}

OUT_DIR=${OUT_DIR:-/tmp/cccp_lambda_create}
ZIP_DIR="$OUT_DIR/zips"
ENV_DIR="$OUT_DIR/env"

mkdir -p "$ZIP_DIR" "$ENV_DIR"

ROLE_ARN=$(aws --no-cli-pager --profile "$PROFILE" iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text)

echo "Using profile=$PROFILE region=$REGION"
echo "Role ARN: $ROLE_ARN"

# Build single-file zip packages (handler .py at root of zip)
zip -j "$ZIP_DIR/start_transcribe.zip" "$(pwd)/src/lambda/processing/start_transcribe.py" >/dev/null
zip -j "$ZIP_DIR/process_transcript.zip" "$(pwd)/src/lambda/processing/process_transcript.py" >/dev/null
zip -j "$ZIP_DIR/generate_summary.zip" "$(pwd)/src/lambda/processing/generate_summary.py" >/dev/null
zip -j "$ZIP_DIR/save_summary.zip" "$(pwd)/src/lambda/processing/save_summary.py" >/dev/null
zip -j "$ZIP_DIR/update_status.zip" "$(pwd)/src/lambda/processing/update_status.py" >/dev/null

zip -j "$ZIP_DIR/list_summaries.zip" "$(pwd)/src/lambda/api/list_summaries.py" >/dev/null
zip -j "$ZIP_DIR/get_summary.zip" "$(pwd)/src/lambda/api/get_summary.py" >/dev/null

zip -j "$ZIP_DIR/connect.zip" "$(pwd)/src/lambda/websocket/connect.py" >/dev/null
zip -j "$ZIP_DIR/disconnect.zip" "$(pwd)/src/lambda/websocket/disconnect.py" >/dev/null
zip -j "$ZIP_DIR/notify.zip" "$(pwd)/src/lambda/websocket/notify.py" >/dev/null

echo "Built zips in $ZIP_DIR"

cat > "$ENV_DIR/start_transcribe.json" <<EOF
{ "Variables": { "TRANSCRIBE_OUTPUT_BUCKET": "$TRANSCRIBE_OUTPUT_BUCKET", "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/process_transcript.json" <<EOF
{ "Variables": { "S3_BUCKET": "$S3_BUCKET", "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/generate_summary.json" <<EOF
{ "Variables": { "BEDROCK_MODEL_ID": "$BEDROCK_MODEL_ID", "MAX_TOKENS": "$MAX_TOKENS", "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/save_summary.json" <<EOF
{ "Variables": { "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/update_status.json" <<EOF
{ "Variables": { "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/list_summaries.json" <<EOF
{ "Variables": { "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/get_summary.json" <<EOF
{ "Variables": { "DYNAMODB_TABLE": "$DYNAMODB_TABLE", "S3_BUCKET": "$S3_BUCKET", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/ws_connect.json" <<EOF
{ "Variables": { "CONNECTIONS_TABLE": "$CONNECTIONS_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/ws_disconnect.json" <<EOF
{ "Variables": { "CONNECTIONS_TABLE": "$CONNECTIONS_TABLE", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

cat > "$ENV_DIR/ws_notify.json" <<EOF
{ "Variables": { "CONNECTIONS_TABLE": "$CONNECTIONS_TABLE", "WEBSOCKET_ENDPOINT": "$WEBSOCKET_ENDPOINT", "ENVIRONMENT": "$ENVIRONMENT" } }
EOF

create_or_update() {
  local fn="$1" handler="$2" zip_path="$3" timeout="$4" memory="$5" env_file="$6"

  if aws --no-cli-pager --profile "$PROFILE" lambda get-function \
    --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then

    echo "Updating $fn"

    aws --no-cli-pager --profile "$PROFILE" lambda update-function-code \
      --function-name "$fn" --region "$REGION" \
      --zip-file "fileb://$zip_path" >/dev/null

    aws --no-cli-pager --profile "$PROFILE" lambda update-function-configuration \
      --function-name "$fn" --region "$REGION" \
      --runtime python3.14 \
      --role "$ROLE_ARN" \
      --handler "$handler" \
      --timeout "$timeout" \
      --memory-size "$memory" \
      --tracing-config Mode=Active \
      --environment "file://$env_file" >/dev/null

    aws --no-cli-pager --profile "$PROFILE" lambda wait function-updated \
      --function-name "$fn" --region "$REGION"

  else
    echo "Creating $fn"

    aws --no-cli-pager --profile "$PROFILE" lambda create-function \
      --function-name "$fn" --region "$REGION" \
      --runtime python3.14 \
      --role "$ROLE_ARN" \
      --handler "$handler" \
      --zip-file "fileb://$zip_path" \
      --timeout "$timeout" \
      --memory-size "$memory" \
      --tracing-config Mode=Active \
      --environment "file://$env_file" >/dev/null
  fi
}

create_or_update customer-care-call-processor-start-transcribe-dev start_transcribe.handler "$ZIP_DIR/start_transcribe.zip" 60 256 "$ENV_DIR/start_transcribe.json"
create_or_update customer-care-call-processor-process-transcript-dev process_transcript.handler "$ZIP_DIR/process_transcript.zip" 300 512 "$ENV_DIR/process_transcript.json"
create_or_update customer-care-call-processor-generate-summary-dev generate_summary.handler "$ZIP_DIR/generate_summary.zip" 600 1024 "$ENV_DIR/generate_summary.json"
create_or_update customer-care-call-processor-save-summary-dev save_summary.handler "$ZIP_DIR/save_summary.zip" 60 256 "$ENV_DIR/save_summary.json"
create_or_update customer-care-call-processor-update-status-dev update_status.handler "$ZIP_DIR/update_status.zip" 30 128 "$ENV_DIR/update_status.json"
create_or_update customer-care-call-processor-list-summaries-dev list_summaries.handler "$ZIP_DIR/list_summaries.zip" 30 256 "$ENV_DIR/list_summaries.json"
create_or_update customer-care-call-processor-get-summary-dev get_summary.handler "$ZIP_DIR/get_summary.zip" 30 256 "$ENV_DIR/get_summary.json"
create_or_update customer-care-call-processor-ws-connect-dev connect.handler "$ZIP_DIR/connect.zip" 10 128 "$ENV_DIR/ws_connect.json"
create_or_update customer-care-call-processor-ws-disconnect-dev disconnect.handler "$ZIP_DIR/disconnect.zip" 10 128 "$ENV_DIR/ws_disconnect.json"
create_or_update customer-care-call-processor-ws-notify-dev notify.handler "$ZIP_DIR/notify.zip" 30 256 "$ENV_DIR/ws_notify.json"

echo "\nCreated/updated functions:" 
aws --no-cli-pager --profile "$PROFILE" lambda list-functions --region "$REGION" \
  --query "Functions[?starts_with(FunctionName, 'customer-care-call-processor-') && ends_with(FunctionName, '-dev')].[FunctionName,Runtime,TracingConfig.Mode]" \
  --output table
