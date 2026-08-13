# ---------------------------------------------------------------
# DynamoDB — connections
#
# Access patterns this schema supports:
#   1. Get/delete a connection on $disconnect      → PK lookup (GetItem/DeleteItem)
#   2. Fan out a message to everyone in a room      → GSI query by roomId
# ---------------------------------------------------------------

resource "aws_dynamodb_table" "connections" {
  name         = "${local.prefix}-connections"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  # GSI partition key — roomId, to find every connection currently in a room
  attribute {
    name = "roomId"
    type = "S"
  }

  global_secondary_index {
    name            = "roomId-index"
    hash_key        = "roomId"
    projection_type = "ALL"
  }

  # TTL — stale connections (missed $disconnect, e.g. Lambda cold-kill) expire automatically
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# Item schema (for reference — not enforced by DynamoDB):
#
# connectionId (S) — PK, API Gateway's WebSocket connection ID
# userId       (S) — Cognito sub
# displayName  (S) — shown next to messages
# roomId       (S) — room this connection is currently joined to ("" until joinRoom)
# connectedAt  (S) — ISO 8601 timestamp
# expiresAt    (N) — Unix timestamp, ~24h out, for TTL cleanup of stale connections

# ---------------------------------------------------------------
# DynamoDB — rooms
#
# Access patterns this schema supports:
#   1. Get a room by ID                       → PK lookup (GetItem)
#   2. List all rooms, newest first           → GSI query on constant partition
# ---------------------------------------------------------------

resource "aws_dynamodb_table" "rooms" {
  name         = "${local.prefix}-rooms"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "roomId"

  attribute {
    name = "roomId"
    type = "S"
  }

  # GSI partition key — constant value, lets us Query instead of Scan when listing all rooms
  attribute {
    name = "listKey"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "listKey-createdAt-index"
    hash_key        = "listKey"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# Item schema (for reference — not enforced by DynamoDB):
#
# roomId    (S) — PK, e.g. "general" or a generated ID
# listKey   (S) — constant "ROOM", exists purely to support the listKey-createdAt-index GSI
# name      (S) — display name, e.g. "General"
# createdBy (S) — Cognito sub of the creator
# createdAt (S) — ISO 8601 timestamp

# ---------------------------------------------------------------
# DynamoDB — messages
#
# Access patterns this schema supports:
#   1. Get the last N messages in a room, newest first → PK query, ScanIndexForward=false
# ---------------------------------------------------------------

resource "aws_dynamodb_table" "messages" {
  name         = "${local.prefix}-messages"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "roomId"
  range_key    = "sortKey"

  attribute {
    name = "roomId"
    type = "S"
  }

  # Sort key — "<createdAt ISO8601>#<messageId>" keeps messages ordered by time
  # while the messageId suffix guarantees uniqueness for same-millisecond writes
  attribute {
    name = "sortKey"
    type = "S"
  }

  # Stream of every new message — triggers the fanout Lambda, which is what
  # actually delivers messages to a room's connections. sendMessage only
  # writes here; it doesn't deliver anything itself.
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# Item schema (for reference — not enforced by DynamoDB):
#
# roomId      (S) — PK
# sortKey     (S) — SK, "<createdAt>#<messageId>"
# messageId   (S) — unique message ID
# userId      (S) — Cognito sub of the sender
# displayName (S) — sender's display name at time of send
# body        (S) — message text
# createdAt   (S) — ISO 8601 timestamp
